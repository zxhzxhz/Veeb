#!/usr/bin/env bash
# Build a static MoltenVK slice for the iOS SIMULATOR (arm64, deployment 18.0).
#
# The MoltenVK v1.4.1 release ships an XCFramework with only the `ios-arm64`
# (device) slice; there is no simulator slice in the release. Step 7 of the
# iOS port needs Vulkan on the simulator (first homebrew boot presents frames
# through the production MoltenVK path), so this script builds the same
# v1.4.1 source into a static lib for the simulator.
#
# MoltenVK's CMake tree is macOS-oriented: it unconditionally links AppKit
# (absent from the iOS SDK) and only builds the shared lib. Two small patches
# are applied to the (gitignored) source clone, idempotently:
#   - Common/CMakeLists.txt:   AppKit only on non-Apple-mobile platforms
#   - MoltenVK/CMakeLists.txt: MVK_BUILD_STATIC -> static lib
#
# Output (stable path consumed by the app + stage-core.sh):
#   build/external/mkv-ios-simulator/libMoltenVK.a
# The app links exactly ONE archive: MoltenVK + ShaderConverter + Common +
# SPIRV-Cross are combined with `libtool -static`, mirroring the device
# flavor's single force-loaded XCFramework slice.
#
# The clone lives in build/external/MoltenVK-src (gitignored) and is reused
# between runs. SPIRV-Cross/SPIRV-Tools/cereal come from the CPM cache
# (pinned by the repo's ExternalRevisions), fetched on first use.
set -euo pipefail

ROOT="$(cd "$(dirname "${0}")/../../.." && pwd)"
SRC="$ROOT/build/external/MoltenVK-src"
BUILD="$ROOT/build/external/MoltenVK-ios-simulator"
OUT="$ROOT/build/external/mkv-ios-simulator"
TAG="v1.4.1"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

if [ ! -f "$SRC/CMakeLists.txt" ]; then
  echo "Cloning MoltenVK $TAG..."
  git clone --depth 1 --branch "$TAG" https://github.com/KhronosGroup/MoltenVK.git "$SRC"
fi

# Idempotent iOS patches (the clone is under build/, which is gitignored).
python3 - "$SRC" <<'PYEOF'
import sys, pathlib
src = pathlib.Path(sys.argv[1])

common = src / "Common" / "CMakeLists.txt"
text = common.read_text()
if "APPKIT_ONLY_DESKTOP" not in text:
    old = """find_library(APPKIT_LIBRARY AppKit REQUIRED)"""
    new = """# APPKIT_ONLY_DESKTOP: the iOS/tvOS/visionOS SDKs have no AppKit; the
# macOS-only sources are excluded by TARGET_OS guards at compile time.
if(CMAKE_SYSTEM_NAME MATCHES "iOS|tvOS|visionOS")
	set(APPKIT_LIBRARY "")
else()
	find_library(APPKIT_LIBRARY AppKit REQUIRED)
endif()"""
    assert old in text, "Common/CMakeLists.txt AppKit line not found"
    common.write_text(text.replace(old, new))
    print("patched Common/CMakeLists.txt")

mvk = src / "MoltenVK" / "CMakeLists.txt"
text = mvk.read_text()
if "MVK_BUILD_STATIC" not in text:
    old = "add_library(MoltenVK SHARED ${SOURCES})"
    new = """if(MVK_BUILD_STATIC)
	add_library(MoltenVK STATIC ${SOURCES})
else()
	add_library(MoltenVK SHARED ${SOURCES})
endif()"""
    assert old in text, "MoltenVK/CMakeLists.txt add_library line not found"
    mvk.write_text(text.replace(old, new))
    print("patched MoltenVK/CMakeLists.txt")
PYEOF

if [ ! -f "$OUT/libMoltenVK.a" ] || [ "${FORCE:-0}" = "1" ]; then
  cmake -S "$SRC" -B "$BUILD" \
    -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_SYSTEM_VERSION=18.0 \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DMVK_BUILD_STATIC=ON \
    -DMVK_EXCLUDE_SPIRV_TOOLS=ON
  cmake --build "$BUILD" -j "$JOBS"

  mkdir -p "$OUT"
  MVK_LIB="$BUILD/MoltenVK/libMoltenVK.a"
  COMMON_LIB="$BUILD/Common/libMoltenVK_Common.a"
  SC_LIB="$BUILD/MoltenVKShaderConverter/MoltenVKShaderConverter/libMoltenVK_ShaderConverter.a"
  SPVC_LIBS=()
  while IFS= read -r lib; do SPVC_LIBS+=("$lib"); done \
    < <(find "$BUILD" -name 'libspirv-cross-*.a' | sort)
  for lib in "$MVK_LIB" "$COMMON_LIB" "$SC_LIB" "${SPVC_LIBS[@]}"; do
    [ -n "$lib" ] && [ -f "$lib" ] || { echo "missing archive: $lib" >&2; exit 1; }
  done
  [ "${#SPVC_LIBS[@]}" -ge 4 ] || { echo "expected 4 SPIRV-Cross archives, found ${#SPVC_LIBS[@]}" >&2; exit 1; }
  # One combined archive so the app force-loads a single static lib.
  xcrun libtool -static -o "$OUT/libMoltenVK.a" \
    "$MVK_LIB" "$SC_LIB" "$COMMON_LIB" "${SPVC_LIBS[@]}"
  lipo -info "$OUT/libMoltenVK.a" || true
else
  echo "Reusing existing $OUT/libMoltenVK.a (FORCE=1 to rebuild)"
fi

echo "Done: $OUT"
