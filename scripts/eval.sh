#!/bin/bash
# Mowa evaluation suite — quality and speed in all 8 languages, one command (Tests/eval/README.md).
#
#   bash scripts/eval.sh               unit tests + build + every case and audio variant
#   QUICK=1 bash scripts/eval.sh       clean audio only (no noise/phone/fast/… variants)
#   ONLY=pl CAT=selfcorr …             one language / one category
#   REAL=1 …                           + your saved recordings that have an expected.txt (build/dev-recordings)
#   NOBUILD=1 …                        use the existing build/Mowa.app
#   CLEANUP=off|light|smart  cleanup level (default smart)
#   SPEECH=<model id> MODEL=<model id> other speech / cleanup model than the ones selected in Mowa
#                                      (downloaded if missing, e.g. MODEL=mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit)
#   PROMPT_LOOKUP=0 …                  without prompt-lookup decoding (speed comparison)
#   STREAMING=0 …                      long clips transcribed only after release (no pieces while talking)
#   FASTPATH=0 …                       short clean dictations still go through the cleanup model
#   CONTEXT=0 …                        text before the caret not used for spelling / Whisper context
#   LM=1 [LM_WEIGHT=0.3 LM_GAP=1.5] …  Parakeet language-model fusion on (files downloaded on first use)
#   RUCHECK=always …                   Whisper re-checks every Russian dictation (the pre-2026-10-26 default)
#   TECH=0 …                           no built-in English software terms in vocabulary boosting
#   PARALLEL=0 …                       cleanup waits for Whisper's safety-net check (no parallel cleanup)
#
# Report: build/eval/report.txt (summary, tables per language/category/audio/length, slowest runs,
# every FAIL and DIFF), build/eval/results.jsonl, build/eval/summary.json (+ summary.prev.json).
# The eval uses a fixed profile passed as command-line defaults — your Mowa settings, vocabulary
# and history are not changed. Quit Mowa first for clean timings (both would use the GPU).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/eval"; mkdir -p "$OUT"
LOG="$OUT/run.log"; : > "$LOG"
say_() { echo "$*" | tee -a "$LOG"; }
[ -f "$OUT/summary.json" ] && mv -f "$OUT/summary.json" "$OUT/summary.prev.json"

say_ "== 1/4 unit tests"
if swift test --filter MowaCoreTests > "$OUT/unittests.log" 2>&1; then
  say_ "ok: $(grep -Eo 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$OUT/unittests.log" | tail -1)"
else
  say_ "FAIL: unit tests (build/eval/unittests.log):"
  grep -E "error:|failed" "$OUT/unittests.log" | head -60 | tee -a "$LOG"
fi

say_ "== 2/4 build"
if [ "${NOBUILD:-0}" = 1 ] && [ -x build/Mowa.app/Contents/MacOS/Mowa ]; then
  say_ "ok: using existing build/Mowa.app"
elif bash scripts/build.sh > /dev/null 2>&1; then
  say_ "ok: built"
else
  say_ "FAIL: build (build/summary.txt)"; cat build/summary.txt | tee -a "$LOG"; exit 1
fi

say_ "== 3/4 test audio (macOS voices)"
ARGS=()
[ -n "${ONLY:-}" ] && ARGS+=(--only "$ONLY")
[ -n "${CAT:-}" ] && ARGS+=(--cat "$CAT")
[ "${QUICK:-0}" = 1 ] && ARGS+=(--quick)
python3 scripts/eval_audio.py Tests/eval/cases "$OUT/audio" ${ARGS[@]+"${ARGS[@]}"} 2>&1 | tee -a "$LOG"

say_ "== 4/4 pipeline"
pgrep -x Mowa >/dev/null && say_ "note: Mowa is running — quit it for clean timings"
# Mowa's own options; --quick last (Foundation reads "-name value" pairs from the arguments too,
# so the profile goes first and nothing follows a flag that has no value).
RUNARGS=()
[ -n "${ONLY:-}" ] && RUNARGS+=(--only "$ONLY")
[ -n "${CAT:-}" ] && RUNARGS+=(--cat "$CAT")
if [ "${REAL:-0}" = 1 ]; then
  REALDIR="$ROOT/build/dev-recordings"
  NREAL=$(ls "$REALDIR"/*/expected.txt 2>/dev/null | wc -l | tr -d ' ')
  if [ "$NREAL" = 0 ]; then
    say_ "note: REAL=1 but no labelled recordings in build/dev-recordings — build with --dev, turn on"
    say_ "      Settings → General → Save recordings for testing, dictate, then python3 scripts/label-recordings.py"
  else
    say_ "real recordings: $NREAL labelled"
  fi
  RUNARGS+=(--real "$REALDIR")
fi
[ "${QUICK:-0}" = 1 ] && RUNARGS+=(--quick)
# Fixed profile (NSArgumentDomain: read by Mowa, never saved to its settings).
PROFILE=(-enabledLanguages '(en, pl, ru, es, de, fr, pt, it)' -fixedLanguage '' -acceptOtherLanguages YES
         -cleanupLevel "${CLEANUP:-smart}" -contextAwareStyle YES -useScreenContext NO -writeInKeyboardLanguage NO
         -voiceFilter NO -noiseReduction YES -learnLanguages NO -learnCorrections NO -customInstructions ''
         -smartSpacing YES -writingStyle.personal casual -writingStyle.work casual
         -writingStyle.email formal -writingStyle.other formal)
[ -n "${SPEECH:-}" ] && PROFILE+=(-speechModelID "$SPEECH")
[ -n "${MODEL:-}" ] && PROFILE+=(-fastModelID "$MODEL")
[ "${PROMPT_LOOKUP:-1}" = 0 ] && PROFILE+=(-promptLookup NO)
[ "${STREAMING:-1}" = 0 ] && PROFILE+=(-streaming NO)
[ "${FASTPATH:-1}" = 0 ] && PROFILE+=(-fastPath NO)
[ "${CONTEXT:-1}" = 0 ] && PROFILE+=(-fieldContext NO)
[ "${LM:-0}" = 1 ] && PROFILE+=(-languageModel YES)
[ -n "${LM_WEIGHT:-}" ] && PROFILE+=(-languageModelWeight "$LM_WEIGHT")
[ -n "${LM_GAP:-}" ] && PROFILE+=(-languageModelGap "$LM_GAP")
[ "${RUCHECK:-smart}" = always ] && PROFILE+=(-parakeetAlwaysCheck ru)
[ "${TECH:-1}" = 0 ] && PROFILE+=(-techTerms NO)
[ "${PARALLEL:-1}" = 0 ] && PROFILE+=(-parallelCleanup NO)
build/Mowa.app/Contents/MacOS/Mowa "${PROFILE[@]}" --eval "$ROOT/Tests/eval/cases" "$OUT/audio" "$OUT" ${RUNARGS[@]+"${RUNARGS[@]}"} 2>>"$LOG" \
  | tee -a "$LOG" | grep -E "^\[[0-9]+/[0-9]+\]" | awk '{ printf "\r%-110s", substr($0, 1, 110) } END { print "" }'
say_ ""
if [ -s "$OUT/report.txt" ] && [ "$OUT/report.txt" -nt "$OUT/unittests.log" ]; then
  sed -n '1,/^== slowest/p' "$OUT/report.txt" | sed '$d' | tee -a "$LOG"
else
  say_ "FAIL: the eval did not finish — end of build/eval/run.log:"; tail -30 "$LOG"
fi
# Every run is kept, so runs with different models / settings can be compared later.
if [ -s "$OUT/summary.json" ]; then
  mkdir -p "$OUT/history"
  TAG="$(date +%Y%m%d-%H%M%S)_$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("cleanup_model","").split("/")[-1])' "$OUT/summary.json" 2>/dev/null)"
  cp "$OUT/report.txt" "$OUT/history/$TAG.report.txt"; cp "$OUT/summary.json" "$OUT/history/$TAG.summary.json"
  cp "$OUT/results.jsonl" "$OUT/history/$TAG.results.jsonl"
fi
say_ "Report: build/eval/report.txt"
