#!/bin/bash
# Builds Mowa.app (macOS 14+).
#
#   bash scripts/build.sh              build into build/Mowa.app (Apple silicon only)
#   bash scripts/build.sh --universal  Apple silicon + Intel in one app (what releases ship)
#   bash scripts/build.sh --install    ...then copy to /Applications and launch
#   bash scripts/build.sh --test       run MowaCore unit tests only
#   bash scripts/build.sh --dev        developer build: Settings → General → "Save recordings for
#                                      testing" (saves every dictation into build/dev-recordings for
#                                      scripts/eval.sh), no automatic updates. Never released:
#                                      release builds never include it. Combine: --dev --install
#
# The Intel half is a second build of the same Sources/ from Package.intel.swift (llama.cpp
# instead of MLX, which only runs on Apple silicon), joined with the arm64 binary by lipo.
# Test it on an Apple silicon Mac: Finder → Mowa → Get Info → "Open using Rosetta".
#
# Needs Xcode 26+ (Swift 6.2). Uses xcodebuild because SwiftPM on the command
# line cannot compile MLX's Metal shaders. Full log: build/build.log, short
# result: build/summary.txt.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build"
LOG="$OUT/build.log"
SUM="$OUT/summary.txt"
mkdir -p "$OUT"
: > "$LOG"; : > "$SUM"
say() { echo "$*" | tee -a "$SUM"; }
CONFIG="${CONFIG:-Release}"
INSTALL=0; TEST_ONLY=0; DEV="${DEV:-0}"
UNIVERSAL="${UNIVERSAL:-0}"
for a in "$@"; do
  case "$a" in
    --install) INSTALL=1 ;;
    --universal) UNIVERSAL=1 ;;
    --test) TEST_ONLY=1 ;;
    --debug) CONFIG=Debug ;;
    --dev) DEV=1 ;;
  esac
done

say "== Mowa build $(date '+%Y-%m-%d %H:%M:%S') config=$CONFIG"
say "$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
say "$(sw_vers -productName) $(sw_vers -productVersion) $(uname -m)"

if [ "$(uname -m)" != "arm64" ]; then
  say "FAIL: Mowa needs an Apple silicon Mac (MLX runs on the Apple GPU)."
  exit 1
fi

if [ "$TEST_ONLY" = 1 ]; then
  if swift test --filter MowaCoreTests >>"$LOG" 2>&1; then say "ok: MowaCore tests passed"; exit 0
  else say "FAIL: tests (see build/build.log)"; grep -E "error|failed" "$LOG" | head -40 >>"$SUM"; exit 1; fi
fi

# Xcode 26 ships the Metal compiler as a separate download.
if ! xcrun metal -v >/dev/null 2>&1; then
  say "-- downloading Xcode's Metal toolchain (one-time)"
  xcodebuild -downloadComponent MetalToolchain >>"$LOG" 2>&1 || say "warn: Metal toolchain download failed; build may fail"
fi

say "-- resolving packages + compiling (first build downloads dependencies, ~5-10 min)"
DD="$OUT/DerivedData"
if ! xcodebuild \
    -scheme Mowa \
    -configuration "$CONFIG" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DD" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    ONLY_ACTIVE_ARCH=YES \
    build >>"$LOG" 2>&1; then
  say "FAIL: compile (full log: build/build.log)"
  grep -E -A3 "error:|fatal error|Fatal|BUILD FAILED" "$LOG" | head -80 | tee -a "$SUM"
  exit 1
fi
say "ok: compiled (Apple silicon)"

PRODUCTS="$DD/Build/Products/$CONFIG"
PRODUCTS_X86=""
if [ "$UNIVERSAL" = 1 ]; then
  say "-- compiling the Intel half (x86_64, llama.cpp + whisper.cpp)"
  IPKG="$OUT/intel-pkg"
  mkdir -p "$IPKG"
  # llama.cpp + whisper.cpp for x86_64 with AVX2 (built once, ~5–10 min; see the script).
  if ! bash "$ROOT/scripts/build-ggml-intel.sh" >>"$LOG" 2>&1; then
    say "FAIL: building llama.cpp/whisper.cpp for Intel (full log: build/build.log)"
    grep -E "ggml-intel:|error:|CMake Error" "$LOG" | tail -20 | tee -a "$SUM"
    exit 1
  fi
  say "ok: $(grep 'ggml-intel: up to date\|ggml-intel: done' "$LOG" | tail -1)"
  rsync -a --delete "$OUT/ggml-intel/" "$IPKG/Vendor/"
  rsync -a --delete "$ROOT/Sources/" "$IPKG/Sources/"
  cp "$ROOT/Package.intel.swift" "$IPKG/Package.swift"
  DDX="$OUT/DerivedData-intel"
  if ! (cd "$IPKG" && xcodebuild \
      -scheme Mowa \
      -configuration "$CONFIG" \
      -destination 'platform=macOS,arch=x86_64' \
      -derivedDataPath "$DDX" \
      -skipPackagePluginValidation \
      -skipMacroValidation \
      ONLY_ACTIVE_ARCH=YES \
      build) >>"$LOG" 2>&1; then
    say "FAIL: compile of the Intel half (full log: build/build.log)"
    grep -E -A3 "error:|fatal error|Fatal|BUILD FAILED" "$LOG" | head -80 | tee -a "$SUM"
    exit 1
  fi
  PRODUCTS_X86="$DDX/Build/Products/$CONFIG"
  say "ok: compiled (Intel)"
fi
APP="$OUT/Mowa.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

if [ -n "$PRODUCTS_X86" ]; then
  lipo -create "$PRODUCTS/Mowa" "$PRODUCTS_X86/Mowa" -output "$APP/Contents/MacOS/Mowa"
else
  cp "$PRODUCTS/Mowa" "$APP/Contents/MacOS/Mowa"
fi
say "ok: architectures: $(lipo -archs "$APP/Contents/MacOS/Mowa")"
# Automatic updates: put the public update-signing key into Info.plist if this Mac has it.
if [ -f "$ROOT/scripts/sparkle-key.sh" ]; then  # maintainer-only script, not in the public repo
  bash "$ROOT/scripts/sparkle-key.sh" >/dev/null 2>>"$LOG" || say "warn: update key check failed (see build/build.log)"
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/Support/Info.plist" 2>/dev/null)" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  say "ok: automatic updates enabled (Sparkle)"
else
  say "note: no update-signing key yet — this build uses the website update check"
fi
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
if [ "$DEV" = 1 ]; then
  # Developer build: where DevRecorder saves recordings (the key's presence is what makes it a
  # developer build; release builds never have it).
  mkdir -p "$OUT/dev-recordings"
  /usr/libexec/PlistBuddy -c "Add :MowaDevRecordingsDir string $OUT/dev-recordings" "$APP/Contents/Info.plist"
  say "ok: DEVELOPER build — recordings go to build/dev-recordings, automatic updates off (never release this build)"
fi

# SwiftPM resource bundles (MLX's default.metallib lives in mlx-swift_Cmlx.bundle).
shopt -s nullglob
for b in "$PRODUCTS"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
# Intel half: its resource bundles are the same packages' (arch-independent); add any missing.
if [ -n "$PRODUCTS_X86" ]; then
  for b in "$PRODUCTS_X86"/*.bundle; do
    [ -e "$APP/Contents/Resources/$(basename "$b")" ] || cp -R "$b" "$APP/Contents/Resources/"
  done
fi
if [ ! -d "$APP/Contents/Resources/mlx-swift_Cmlx.bundle" ]; then
  say "warn: mlx-swift_Cmlx.bundle not found next to the binary — the cleanup model will fail to load"
fi
# Dynamic package frameworks, if any.
for f in "$PRODUCTS"/PackageFrameworks/*.framework "$PRODUCTS"/*.framework; do
  ditto "$f" "$APP/Contents/Frameworks/$(basename "$f")"
done
# Intel half: llama.framework + whisper.framework (x86_64 only); Sparkle is the same one, already copied.
if [ -n "$PRODUCTS_X86" ]; then
  for f in "$PRODUCTS_X86"/PackageFrameworks/*.framework "$PRODUCTS_X86"/*.framework; do
    [ -e "$APP/Contents/Frameworks/$(basename "$f")" ] || ditto "$f" "$APP/Contents/Frameworks/$(basename "$f")"
  done
  if [ ! -d "$APP/Contents/Frameworks/llama.framework" ]; then
    say "warn: llama.framework not found in the Intel build products — the cleanup model won't load on Intel Macs"
  fi
  # The shipped llama/whisper frameworks must be our AVX2 builds, not the SSE2-only official
  # ones (a stale DerivedData-intel could still hold those).
  for fw in llama whisper; do
    bin="$APP/Contents/Frameworks/$fw.framework/Versions/A/$fw"
    # grep -c reads all of otool's output (grep -q + pipefail = false failure via SIGPIPE).
    if [ -f "$bin" ] && [ "$(otool -arch x86_64 -tv "$bin" 2>/dev/null | grep -c '%ymm' || true)" = 0 ]; then
      say "FAIL: $fw.framework in the app has no AVX2 code — run: rm -rf build/DerivedData-intel build/intel-pkg, then build again"
      exit 1
    fi
  done
  say "ok: Intel llama/whisper frameworks use AVX2"
fi
if [ ! -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  say "warn: Sparkle.framework not found in build products — automatic updates won't work"
fi
if [ -n "$(ls -A "$APP/Contents/Frameworks")" ]; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Mowa" 2>/dev/null || true
else
  rmdir "$APP/Contents/Frameworks"
fi
shopt -u nullglob

cp -R "$ROOT"/Support/Localization/*.lproj "$APP/Contents/Resources/"
# Voice filter ("Ignore other people's voices"): compile the speaker-embedding Core ML model.
if xcrun coremlcompiler compile "$ROOT/Support/SpeakerEmbedding.mlpackage" "$APP/Contents/Resources/" >>"$LOG" 2>&1 \
   && [ -d "$APP/Contents/Resources/SpeakerEmbedding.mlmodelc" ]; then
  say "ok: voice model compiled"
else
  say "FAIL: compiling Support/SpeakerEmbedding.mlpackage (see build/build.log)"
  exit 1
fi
# Licenses: our own + every bundled open-source component (MIT/Apache require shipping these).
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$ROOT/Support/THIRD_PARTY_NOTICES.txt" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
SPARKLE_LICENSE="$(find "$DD/SourcePackages/checkouts" -maxdepth 2 -iname 'LICENSE*' -path '*Sparkle*' 2>/dev/null | head -1)"
if [ -n "$SPARKLE_LICENSE" ]; then
  { printf '\n==============================================================================\nSparkle — https://github.com/sparkle-project/Sparkle\n==============================================================================\n\n'; cat "$SPARKLE_LICENSE"; } >> "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
fi
iconutil -c icns "$ROOT/Support/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Unomage logo for the About page ("Mowa by Unomage").
cp "$ROOT/Support/unomage-logo.png" "$APP/Contents/Resources/unomage-logo.png"
# Start/stop dictation sounds (<name>-start.wav / <name>-stop.wav, see SoundChoice).
cp "$ROOT"/Support/Sounds/*.wav "$APP/Contents/Resources/"

# Signing: Developer ID if available (needed for distribution), else Apple
# Development, else ad-hoc. A stable identity keeps macOS permissions
# (microphone, Accessibility) across rebuilds; ad-hoc resets them every build.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/')"
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | sed -E 's/.*"(.*)"/\1/')"
fi
[ -z "$IDENTITY" ] && IDENTITY="-"

SIGN_ARGS=(--force --options runtime --entitlements "$ROOT/Support/Mowa.entitlements" --sign "$IDENTITY")
[[ "$IDENTITY" == Developer\ ID* ]] && SIGN_ARGS+=(--timestamp)
TS=(); [[ "$IDENTITY" == Developer\ ID* ]] && TS=(--timestamp)
# Apple's timestamp server is needed only for distributed builds; when it can't be reached,
# sign without it (fine on this Mac, not for release) instead of failing the build.
if [ ${#TS[@]} -gt 0 ] && ! curl -s -m 8 -o /dev/null http://timestamp.apple.com/ts01; then
  TS=()
  say "warn: Apple's timestamp server unreachable — signed without a timestamp (fine locally, not for release)"
fi
[ ${#TS[@]} -eq 0 ] && SIGN_ARGS=(--force --options runtime --entitlements "$ROOT/Support/Mowa.entitlements" --sign "$IDENTITY")
if [ -d "$APP/Contents/Frameworks" ]; then
  SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
  if [ -d "$SP" ]; then
    # Sparkle's helpers first (inside-out), as documented by Sparkle for Developer ID apps.
    for x in "$SP/XPCServices/Installer.xpc" "$SP/Autoupdate" "$SP/Updater.app"; do
      [ -e "$x" ] && codesign --force --options runtime ${TS[@]+"${TS[@]}"} --sign "$IDENTITY" "$x" >>"$LOG" 2>&1
    done
    [ -e "$SP/XPCServices/Downloader.xpc" ] && codesign --force --options runtime ${TS[@]+"${TS[@]}"} --preserve-metadata=entitlements --sign "$IDENTITY" "$SP/XPCServices/Downloader.xpc" >>"$LOG" 2>&1
  fi
  for f in "$APP"/Contents/Frameworks/*.framework; do codesign --force --options runtime ${TS[@]+"${TS[@]}"} --sign "$IDENTITY" "$f" >>"$LOG" 2>&1; done
fi
if codesign "${SIGN_ARGS[@]}" "$APP" >>"$LOG" 2>&1 && codesign --verify --strict "$APP" >>"$LOG" 2>&1; then
  say "ok: signed with: $IDENTITY"
else
  say "FAIL: codesign (see build/build.log)"
  tail -20 "$LOG" >>"$SUM"
  exit 1
fi

say "ok: built $APP ($(du -sh "$APP" | cut -f1))"

if [ "$INSTALL" = 1 ]; then
  # Quit the running copy and wait until it's really gone, otherwise
  # LaunchServices can refuse the relaunch (error -600).
  pkill -x Mowa 2>/dev/null
  for _ in $(seq 1 20); do pgrep -x Mowa >/dev/null || break; sleep 0.25; done
  pkill -9 -x Mowa 2>/dev/null
  rm -rf /Applications/Mowa.app
  cp -R "$APP" /Applications/Mowa.app
  sleep 1
  launched=0
  for _ in 1 2 3 4 5; do
    if open /Applications/Mowa.app 2>/dev/null; then launched=1; break; fi
    sleep 1
  done
  if [ "$launched" = 1 ]; then say "ok: installed to /Applications and launched"
  else say "ok: installed to /Applications — open Mowa from Applications to start it"; fi
fi
