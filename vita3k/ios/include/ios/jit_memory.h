// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace vita::ios {

/// CS_DEBUGGED: 1 = debugging allowed, 0 = unavailable, -1 = error.
/// The flag can remain set after detachment; it does not prove attachment.
int cs_debugged_state();

enum class JitMappingMode {
    DualMap, ///< RX view + separate RW alias
    MapJit, ///< single MAP_JIT view with per-thread write protection
};

struct JitCodeRegion {
    uintptr_t rx = 0;
    uintptr_t rw = 0;
    int mode = 0; ///< 0 = dual map, 1 = MAP_JIT
};

/// Each JIT owns a private page-aligned slice of this process-wide arena.
/// Emit through RW, publish the data cache, then invalidate RX's I-cache.
/// Neither allocation nor MAP_JIT itself synchronizes emitted code.
class JitMemory {
public:
    static JitMemory& instance();

    /// Call on a background thread. Device uses StikDebug Prepare/Detach.
    /// Reuses a sufficiently large reservation; resizing with live slices
    /// is rejected. The protocol runs synchronously: no detached worker may
    /// retain references to returned stack objects or unmapped pages.
    bool prepare(size_t reservation_bytes);
    bool is_prepared() const;
    bool single_mapping() const;
    JitMappingMode mapping_mode() const;
    std::optional<JitCodeRegion> allocate_slice(size_t bytes);

    /// Stop execution and destroy the owning JIT before returning its slice.
    /// Both views and rounded size must match an exact live allocation.
    void release_slice(const JitCodeRegion& region, size_t bytes);

    /// Check preparation/debugging status without touching executable bytes.
    /// This does not test instructions or guarantee future access.
    bool validate_alive();

    /// Refuses to unmap a reservation while slices remain owned.
    void shutdown();
    size_t reservation_bytes() const;
    size_t free_bytes() const;
    size_t allocated_bytes() const;
    std::string describe() const;

private:
    JitMemory() = default;
    void shutdown_locked();
    void fail_locked(const std::string &why);

    struct Block {
        size_t offset;
        size_t size;
    };
    uintptr_t rx_base_ = 0;
    uintptr_t rw_base_ = 0;
    size_t reservation_bytes_ = 0;
    size_t cursor_ = 0;
    size_t allocated_bytes_ = 0;
    bool is_prepared_ = false;
    JitMappingMode mapping_mode_ = JitMappingMode::DualMap;
    /// Why the last prepare() attempt gave up (empty after a success).
    /// Surfaced by describe() so the on-device report is self-explanatory.
    std::string last_error_;
    mutable std::mutex mutex_;
    std::vector<Block> live_blocks_;
    std::vector<Block> free_blocks_;
};

} // namespace vita::ios
