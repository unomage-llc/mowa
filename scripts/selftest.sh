#!/bin/bash
# End-to-end test of Mowa on this Mac, no microphone needed:
#   1. MowaCore unit tests
#   2. rebuild Mowa.app
#   3. synthesize test sentences in all 8 languages with macOS `say`
#   4. run them through the real pipeline (Whisper → cleanup models) via `Mowa --selftest`
# Results: build/selftest.txt
#
#   bash scripts/selftest.sh
#   INTEL=1 bash scripts/selftest.sh   same, with the Intel half under Rosetta (build/selftest-intel.txt)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build"; mkdir -p "$OUT"
INTEL="${INTEL:-0}"
REPORT="$OUT/selftest.txt"; [ "$INTEL" = 1 ] && REPORT="$OUT/selftest-intel.txt"
: > "$REPORT"
say_() { echo "$*" | tee -a "$REPORT"; }

say_ "== 1/4 unit tests"
if swift test --filter MowaCoreTests > "$OUT/unittests.log" 2>&1; then
  say_ "ok: $(grep -Eo 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$OUT/unittests.log" | tail -1)"
else
  say_ "FAIL: unit tests"
  grep -E "error|failed|XCTAssert" "$OUT/unittests.log" | head -40 | tee -a "$REPORT"
fi

# App-modal sessions (runModal) stop all main-queue work, so dictations hang on the spinner
# while such a window is open. Mowa must only use non-modal windows (UI/NonModalAlert.swift).
if grep -rn "runModal" Sources --include=*.swift | grep -v "^[^:]*:[0-9]*: *///\|// " > "$OUT/runmodal.txt"; then
  say_ "FAIL: runModal found (use NonModalAlert / panel.begin instead):"
  cat "$OUT/runmodal.txt" | tee -a "$REPORT"
else
  say_ "ok: no runModal in Sources"
fi

say_ "== 2/4 build"
BUILD_ARGS=(); [ "$INTEL" = 1 ] && BUILD_ARGS=(--universal)
if bash scripts/build.sh ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} > /dev/null 2>&1; then say_ "ok: built"; else say_ "FAIL: build (see build/summary.txt)"; cat "$OUT/summary.txt" >> "$REPORT"; exit 1; fi

say_ "== 3/4 test audio"
AUD="$OUT/selftest-audio"; rm -rf "$AUD"; mkdir -p "$AUD"
VOICES="$(say -v '?' 2>/dev/null)"
mk() { # name "Voice|Fallback voice" "text to speak" "expected result"
  local name="$1" voices="$2" text="$3" expected="$4" voice="" v
  IFS='|' read -ra _mk_voices <<<"$voices"
  for v in "${_mk_voices[@]}"; do grep -q "^$v " <<<"$VOICES" && { voice="$v"; break; }; done
  if [ -z "$voice" ]; then say_ "skip $name: voice '$voices' not installed (System Settings → Accessibility → Spoken Content)"; return; fi
  say -v "$voice" -o "$AUD/$name.wav" --data-format=LEI16@16000 "$text" && printf '%s\n' "$expected" > "$AUD/$name.txt"
}
# The clip list lives in selftest-installed.sh (also used to test an installed Mowa).
MOWA_CLIPS_ONLY=1 source "$ROOT/scripts/selftest-installed.sh"
mowa_clips
say_ "ok: $(ls "$AUD"/*.wav 2>/dev/null | wc -l | tr -d ' ') clips"

say_ "== 4/4 pipeline"
RUN=("$OUT/Mowa.app/Contents/MacOS/Mowa")
[ "$INTEL" = 1 ] && RUN=(arch -x86_64 "$OUT/Mowa.app/Contents/MacOS/Mowa")
"${RUN[@]}" --selftest "$AUD" 2>/dev/null | tee -a "$REPORT"
say_ "Report: ${REPORT#$ROOT/}"
