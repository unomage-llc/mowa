#!/bin/bash
# Builds the Intel (x86_64) llama.cpp and whisper.cpp frameworks Mowa's Intel half links.
#
#   bash scripts/build-ggml-intel.sh          build if missing or out of date (build.sh calls this)
#   bash scripts/build-ggml-intel.sh --force  rebuild
#
# Why not the official prebuilt xcframeworks: their macOS slice is compiled for arm64+x86_64 in
# one pass, so ggml's x86 branch never runs and the x86_64 code is plain SSE2 — no AVX2/FMA/F16C.
# On a 2019 i9 that made whisper-small take 7–16 s for a 3 s clip. Every Intel Mac that runs
# macOS 14 (2018+) has AVX2, FMA, F16C and BMI2, so we build x86_64 alone with those on.
# AVX-512 stays off (only some iMac Pro / Mac Pro have it).
#
# Uses each project's own build-xcframework.sh at the pinned tag, patched to: macOS only,
# x86_64 only, macOS 14 minimum, AVX2 set. Output: build/ggml-intel/{llama,whisper}.xcframework.
# Needs Xcode + CMake 3.28+ (brew install cmake). Takes ~5–10 min the first time.
set -euo pipefail

LLAMA_TAG=b11501
WHISPER_TAG=b5454
X86_FLAGS="-DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON -DGGML_AVX512=OFF"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/ggml-src"
DEST="$ROOT/build/ggml-intel"
STAMP="$DEST/stamp.txt"
WANT="llama $LLAMA_TAG, whisper $WHISPER_TAG, x86_64 macOS 14, $X86_FLAGS"

if [ "${1:-}" != "--force" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ] \
   && [ -d "$DEST/llama.xcframework" ] && [ -d "$DEST/whisper.xcframework" ]; then
  echo "ggml-intel: up to date ($WANT)"
  exit 0
fi
command -v cmake >/dev/null || { echo "ggml-intel: CMake is missing — run: brew install cmake"; exit 1; }

# Fails unless the x86_64 code really uses 256-bit AVX registers.
check_avx2() {
  local bin="$1"
  # grep -c, not grep -q: -q exits at the first match, otool dies of SIGPIPE, and pipefail
  # then reports the whole pipeline as failed even though AVX2 code was found.
  local n
  n=$(otool -arch x86_64 -tv "$bin" 2>/dev/null | grep -c '%ymm' || true)
  if [ "${n:-0}" -eq 0 ]; then
    echo "ggml-intel: FAIL — $bin has no AVX2 code"; exit 1
  fi
  echo "ggml-intel: ok — $(basename "$bin") x86_64 uses AVX2"
}

# Common patches to an official build-xcframework.sh (file edited in place).
patch_common() {
  perl -0pi -e '
    s/MACOS_MIN_OS_VERSION=13\.3/MACOS_MIN_OS_VERSION=14.0/;
    s/(\n\s*)-DGGML_NATIVE=OFF/$1-DGGML_NATIVE=OFF$1'"${X86_FLAGS// /\$1}"'/;
    s/-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"/-DCMAKE_OSX_ARCHITECTURES="x86_64"/g;
    s/(sdk="macosx"\s*\n\s*archs=)"arm64 x86_64"/$1"x86_64"/;
  ' "$1"
  grep -q 'DGGML_AVX2=ON' "$1" || { echo "ggml-intel: patching $1 failed (AVX2 flag)"; exit 1; }
  grep -q 'archs="x86_64"' "$1" || { echo "ggml-intel: patching $1 failed (archs)"; exit 1; }
}

fetch() { # name tag
  local dir="$SRC/$1-$2"
  if [ ! -d "$dir" ]; then
    mkdir -p "$SRC"
    git clone --quiet --depth 1 --branch "$2" "https://github.com/ggml-org/$1.cpp" "$dir"
  fi
  echo "$dir"
}

mkdir -p "$DEST"

# --- llama.cpp: its script takes the platform list, so just "macos".
L="$(fetch llama "$LLAMA_TAG")"
cp "$L/build-xcframework.sh" "$L/build-xcframework-intel.sh"
patch_common "$L/build-xcframework-intel.sh"
echo "ggml-intel: building llama.cpp $LLAMA_TAG (x86_64, AVX2)…"
(cd "$L" && bash build-xcframework-intel.sh macos)
check_avx2 "$L/build-apple/llama.xcframework/macos-x86_64/llama.framework/Versions/A/llama"
rm -rf "$DEST/llama.xcframework"
cp -R "$L/build-apple/llama.xcframework" "$DEST/llama.xcframework"

# --- whisper.cpp: its script always builds every platform, so keep only the part before the
# first platform build (settings + functions) and add the macOS steps ourselves.
W="$(fetch whisper "$WHISPER_TAG")"
CUT=$(grep -n '^echo "Building for iOS simulator..."' "$W/build-xcframework.sh" | cut -d: -f1)
[ -n "$CUT" ] || { echo "ggml-intel: whisper build script layout changed"; exit 1; }
head -n $((CUT - 1)) "$W/build-xcframework.sh" > "$W/build-xcframework-intel.sh"
cat >> "$W/build-xcframework-intel.sh" <<'MAC'
echo "Building for macOS (x86_64)..."
cmake -B build-macos -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION} \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -DWHISPER_COREML="ON" \
    -DWHISPER_COREML_ALLOW_FALLBACK="ON" \
    -S .
cmake --build build-macos --config Release -- -quiet
setup_framework_structure "build-macos" ${MACOS_MIN_OS_VERSION} "macos"
combine_static_libraries "build-macos" "Release" "macos" "false"
xcodebuild -create-xcframework \
    -framework $(pwd)/build-macos/framework/whisper.framework \
    -debug-symbols $(pwd)/build-macos/dSYMs/whisper.dSYM \
    -output $(pwd)/build-apple/whisper.xcframework
MAC
patch_common "$W/build-xcframework-intel.sh"   # also turns the arch line above into x86_64
echo "ggml-intel: building whisper.cpp $WHISPER_TAG (x86_64, AVX2)…"
(cd "$W" && bash build-xcframework-intel.sh)
check_avx2 "$W/build-apple/whisper.xcframework/macos-x86_64/whisper.framework/Versions/A/whisper"
rm -rf "$DEST/whisper.xcframework"
cp -R "$W/build-apple/whisper.xcframework" "$DEST/whisper.xcframework"

echo "$WANT" > "$STAMP"
echo "ggml-intel: done → build/ggml-intel"
