# Vita3K iOS device toolchain (cross-compiled on macOS).
#
# Usage via preset:  cmake --preset ios-device
# Or manually:       cmake -DCMAKE_TOOLCHAIN_FILE=cmake/ios-device.cmake -G Ninja -B build/ios-device
#
# The toolchain file sets everything CMake needs *before* project() runs, so the
# 13.3 macOS deployment target in the root CMakeLists cannot leak into the iOS build.
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_VERSION 18.0)
# Some dependencies test ${CMAKE_SYSTEM_PROCESSOR} unquoted; keep it defined.
set(CMAKE_SYSTEM_PROCESSOR arm64)

# iphoneos = device SDK. Never mix with the simulator SDK in the same build tree.
set(CMAKE_OSX_SYSROOT iphoneos)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 18.0)

# The iOS adapters (bridge, frame host, JIT arena) are Objective-C++; the root
# CMakeLists enables OBJCXX for the build (enable_language cannot run inside a
# toolchain file: it is processed while project() is already enabling C/CXX).

# Cross-compilation: never pick up host (macOS) programs/libraries/headers.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Host tools that run *during* the build (code generation) still live on the
# macOS side; point CMake at them explicitly since program lookup is restricted
# to the iOS root by the settings above. The i18n generator needs Python 3.12+
# (f-strings with backslashes), so prefer a modern interpreter over the 3.9
# that ships with macOS.
find_program(_VITA3K_HOST_PYTHON3 NAMES python3.14 python3.13 python3.12 python3 NO_CMAKE_FIND_ROOT_PATH)
if(_VITA3K_HOST_PYTHON3)
	set(Python3_EXECUTABLE "${_VITA3K_HOST_PYTHON3}" CACHE FILEPATH "Host Python 3 interpreter for build-time code generation" FORCE)
endif()
