// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

#include <ios/jit_memory.h>
#include <util/log.h>
#include <fmt/format.h>

#include <TargetConditionals.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <setjmp.h>
#include <thread>

namespace vita::ios {
namespace {

size_t host_page_size() {
    static const size_t page_size = static_cast<size_t>(getpagesize());
    return page_size;
}

size_t aligned_size(size_t bytes) {
    const size_t mask = host_page_size() - 1;
    if (bytes == 0 || bytes > std::numeric_limits<size_t>::max() - mask)
        return 0;
    return (bytes + mask) & ~mask;
}

extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

int is_cs_debugged() {
#if TARGET_OS_IPHONE
    uint32_t flags = 0;
    if (csops(getpid(), 0, &flags, sizeof(flags)) != 0)
        return -1;
    return (flags & 0x10000000u) != 0 ? 1 : 0;
#else
    return -1;
#endif
}

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
// prepare() serializes this process-wide handler. Only the calling thread
// owns the jump target; unrelated traps must never jump across threads.
thread_local sigjmp_buf brk_jmp;
thread_local volatile sig_atomic_t brk_active = 0;
struct sigaction previous_sigtrap {};

void jit_sigtrap_handler(int sig, siginfo_t* info, void* context) {
    if (brk_active)
        siglongjmp(brk_jmp, 1);
    if (previous_sigtrap.sa_handler == SIG_IGN)
        return;
    if (previous_sigtrap.sa_handler == SIG_DFL) {
        sigaction(sig, &previous_sigtrap, nullptr);
        raise(sig);
    } else if (previous_sigtrap.sa_flags & SA_SIGINFO) {
        previous_sigtrap.sa_sigaction(sig, info, context);
    } else {
        previous_sigtrap.sa_handler(sig);
    }
}

uintptr_t brk_prepare_region(void* addr, size_t len, bool legacy) {
    register uintptr_t x0 __asm__("x0") = reinterpret_cast<uintptr_t>(addr);
    register size_t x1 __asm__("x1") = len;
    if (legacy) {
        __asm__ volatile("brk #0x69" : "+r"(x0), "+r"(x1) : : "memory");
    } else {
        __asm__ volatile("mov x16, #1\nbrk #0xf00d"
            : "+r"(x0), "+r"(x1) : : "x16", "memory");
    }
    return x0;
}

void brk_detach() {
    __asm__ volatile("mov x16, #0\nbrk #0xf00d" : : : "x16", "memory");
}

bool prepare_with_debugger(void* rx, size_t size) {
    std::string protocol;
    if (const char* env = std::getenv("VITA3K_JIT_PROTOCOL")) {
        protocol = env;
    } else if (const char* home = std::getenv("HOME")) {
        std::ifstream file(std::string(home) + "/Documents/jit-protocol");
        file >> protocol;
    }
    const bool legacy = protocol == "legacy";
    struct sigaction handler {};
    handler.sa_sigaction = jit_sigtrap_handler;
    handler.sa_flags = SA_SIGINFO;
    sigemptyset(&handler.sa_mask);
    if (sigaction(SIGTRAP, &handler, &previous_sigtrap) != 0)
        return false;

    bool prepared = false;
    for (int attempt = 0; attempt < 10; ++attempt) {
        if (sigsetjmp(brk_jmp, 1) == 0) {
            brk_active = 1;
            const uintptr_t result = brk_prepare_region(rx, size, legacy);
            brk_active = 0;
            // universal.js rejects legacy BRKs with an error in x0.
            // Returning from BRK alone does not establish a valid grant.
            prepared = result == reinterpret_cast<uintptr_t>(rx);
            if (!prepared)
                LOG_ERROR("JitMemory: debugger rejected {} protocol (x0=0x{:x})",
                    legacy ? "legacy" : "universal", result);
            break;
        }
        brk_active = 0;
        if (attempt != 9)
            std::this_thread::sleep_for(std::chrono::milliseconds(1500));
    }
    if (prepared && !legacy) {
        // Some versions deliver a final SIGTRAP on detach. Preparation has
        // already completed, so that signal does not undo the grant.
        if (sigsetjmp(brk_jmp, 1) == 0) {
            brk_active = 1;
            brk_detach();
        }
        brk_active = 0;
    }
    sigaction(SIGTRAP, &previous_sigtrap, nullptr);
    if (prepared)
        LOG_INFO("JitMemory: JIT grant via {} (rx=0x{:x}, size={})",
            legacy ? "legacy brk #0x69" : "universal brk #0xf00d", reinterpret_cast<uintptr_t>(rx), size);
    return prepared;
}
#endif

} // namespace

JitMemory& JitMemory::instance() {
    static JitMemory arena;
    return arena;
}

int cs_debugged_state() {
    return is_cs_debugged();
}

bool JitMemory::prepare(size_t reservation_bytes) {
    const size_t size = aligned_size(reservation_bytes);
    if (size == 0)
        return false;
    std::lock_guard guard(mutex_);
    if (is_prepared_ && size <= reservation_bytes_)
        return true;
    if (!live_blocks_.empty()) {
        LOG_ERROR("JitMemory: cannot replace reservation with live slices");
        return false;
    }
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (is_cs_debugged() != 1) {
        LOG_INFO("JitMemory: JIT unavailable; launch via StikDebug");
        return false;
    }
#endif

    LOG_INFO("JitMemory: preparing reservation ({} bytes)", size);
    // The dual-map arena is the only path validated on device (iOS 26/TXM
    // denies MAP_JIT outright). Keep it the default on every iOS version:
    // the old symbol probe silently switched iOS 18 processes to MAP_JIT,
    // whose per-thread write protection this code never toggles.
    void* rx = MAP_FAILED;
    if (const char* map_jit_env = std::getenv("VITA3K_JIT_MAPJIT"); map_jit_env && *map_jit_env == '1' && dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np")) {
        rx = mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC,
            MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    }
    if (rx != MAP_FAILED) {
        shutdown_locked();
        rx_base_ = rw_base_ = reinterpret_cast<uintptr_t>(rx);
        reservation_bytes_ = size;
        mapping_mode_ = JitMappingMode::MapJit;
        is_prepared_ = true;
        LOG_INFO("JitMemory: MAP_JIT ready (rx=rw=0x{:x}, size={})", rx_base_, size);
        return true;
    }

    rx = mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (rx == MAP_FAILED) {
        LOG_ERROR("JitMemory: mmap RX failed (errno={})", errno);
        return false;
    }
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (!prepare_with_debugger(rx, size)) {
        LOG_ERROR("JitMemory: preparation failed; select the universal script in StikDebug and relaunch");
        munmap(rx, size);
        return false;
    }
#endif

    vm_address_t rw = 0;
    vm_prot_t current = 0, maximum = 0;
    const kern_return_t kr = vm_remap(mach_task_self(), &rw, size, 0, VM_FLAGS_ANYWHERE,
        mach_task_self(), reinterpret_cast<vm_address_t>(rx), false,
        &current, &maximum, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        LOG_ERROR("JitMemory: vm_remap failed (kr=0x{:x})", kr);
        munmap(rx, size);
        return false;
    }
    if (mprotect(reinterpret_cast<void*>(rw), size, PROT_READ | PROT_WRITE) != 0) {
        LOG_ERROR("JitMemory: mprotect RW failed (errno={})", errno);
        vm_deallocate(mach_task_self(), rw, size);
        munmap(rx, size);
        return false;
    }
    shutdown_locked();
    rx_base_ = reinterpret_cast<uintptr_t>(rx);
    rw_base_ = rw;
    reservation_bytes_ = size;
    mapping_mode_ = JitMappingMode::DualMap;
    is_prepared_ = true;
    LOG_INFO("JitMemory: reservation ready (rx=0x{:x}, rw=0x{:x}, size={})", rx_base_, rw_base_, size);
    return true;
}

bool JitMemory::is_prepared() const {
    std::lock_guard guard(mutex_);
    return is_prepared_;
}

bool JitMemory::single_mapping() const {
    std::lock_guard guard(mutex_);
    return mapping_mode_ != JitMappingMode::DualMap;
}

JitMappingMode JitMemory::mapping_mode() const {
    std::lock_guard guard(mutex_);
    return mapping_mode_;
}

std::optional<JitCodeRegion> JitMemory::allocate_slice(size_t bytes) {
    const size_t size = aligned_size(bytes);
    std::lock_guard guard(mutex_);
    if (!is_prepared_ || size == 0)
        return std::nullopt;
    for (auto it = free_blocks_.begin(); it != free_blocks_.end(); ++it) {
        if (it->size < size)
            continue;
        const size_t offset = it->offset;
        live_blocks_.push_back({ offset, size });
        it->offset += size;
        it->size -= size;
        if (it->size == 0)
            free_blocks_.erase(it);
        allocated_bytes_ += size;
        return JitCodeRegion{ rx_base_ + offset, rw_base_ + offset, static_cast<int>(mapping_mode_) };
    }
    if (size > reservation_bytes_ - cursor_) {
        LOG_WARN("JitMemory: no room for slice of {} bytes", size);
        return std::nullopt;
    }
    const size_t offset = cursor_;
    live_blocks_.push_back({ offset, size });
    cursor_ += size;
    allocated_bytes_ += size;
    return JitCodeRegion{ rx_base_ + offset, rw_base_ + offset, static_cast<int>(mapping_mode_) };
}

void JitMemory::release_slice(const JitCodeRegion& region, size_t bytes) {
    const size_t size = aligned_size(bytes);
    std::lock_guard guard(mutex_);
    if (!rx_base_ || region.rx < rx_base_ || size == 0)
        return;
    const size_t offset = region.rx - rx_base_;
    const auto live = std::find_if(live_blocks_.begin(), live_blocks_.end(),
        [offset, size](const Block& b) { return b.offset == offset && b.size == size; });
    if (live == live_blocks_.end() || region.rw != rw_base_ + offset || region.mode != static_cast<int>(mapping_mode_)) {
        LOG_ERROR("JitMemory: rejected non-live or mismatched slice (rx=0x{:x}, size={})", region.rx, size);
        return;
    }
    auto it = std::lower_bound(free_blocks_.begin(), free_blocks_.end(), offset,
        [](const Block& b, size_t value) { return b.offset < value; });
    it = free_blocks_.insert(it, { offset, size });
    live_blocks_.erase(live);
    allocated_bytes_ -= size;
    if (it != free_blocks_.begin()) {
        auto prev = std::prev(it);
        if (prev->offset + prev->size == it->offset) {
            prev->size += it->size;
            it = std::prev(free_blocks_.erase(it));
        }
    }
    const auto next = std::next(it);
    if (next != free_blocks_.end() && it->offset + it->size == next->offset) {
        it->size += next->size;
        free_blocks_.erase(next);
    }
    if (!free_blocks_.empty() && free_blocks_.back().offset + free_blocks_.back().size == cursor_) {
        cursor_ = free_blocks_.back().offset;
        free_blocks_.pop_back();
    }
}

bool JitMemory::validate_alive() {
    std::lock_guard guard(mutex_);
    if (!is_prepared_)
        return false;
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (is_cs_debugged() != 1) {
        is_prepared_ = false;
        return false;
    }
#endif
    return true;
}

void JitMemory::shutdown() {
    std::lock_guard guard(mutex_);
    if (!live_blocks_.empty()) {
        LOG_ERROR("JitMemory: shutdown refused with {} live slices", live_blocks_.size());
        return;
    }
    shutdown_locked();
}

void JitMemory::shutdown_locked() {
    // A revoked grant still owns mappings; cleanup must not depend on
    // is_prepared_, which validate_alive() may have cleared.
    if (rw_base_ && rw_base_ != rx_base_)
        vm_deallocate(mach_task_self(), rw_base_, reservation_bytes_);
    if (rx_base_)
        munmap(reinterpret_cast<void*>(rx_base_), reservation_bytes_);
    rx_base_ = rw_base_ = 0;
    reservation_bytes_ = cursor_ = allocated_bytes_ = 0;
    free_blocks_.clear();
    live_blocks_.clear();
    is_prepared_ = false;
}

size_t JitMemory::reservation_bytes() const {
    std::lock_guard guard(mutex_);
    return reservation_bytes_;
}

size_t JitMemory::free_bytes() const {
    std::lock_guard guard(mutex_);
    return reservation_bytes_ - allocated_bytes_;
}

size_t JitMemory::allocated_bytes() const {
    std::lock_guard guard(mutex_);
    return allocated_bytes_;
}

std::string JitMemory::describe() const {
    std::lock_guard guard(mutex_);
    return fmt::format("prepared: {}\nmode: {}\nrx: 0x{:x}\nrw:  0x{:x}\nreservation: {} bytes\nallocated: {} bytes\nfree:    {} bytes\nfree slices: {}",
        is_prepared_ ? "yes" : "no", mapping_mode_ == JitMappingMode::MapJit ? "mapjit" : "dualmap",
        rx_base_, rw_base_, reservation_bytes_, allocated_bytes_, reservation_bytes_ - allocated_bytes_, free_blocks_.size());
}

} // namespace vita::ios
