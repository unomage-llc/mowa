#!/bin/bash
# Parakeet v3 vs Whisper — one command (docs/parakeet-plan.md):
#   bash scripts/parakeet-check.sh
# unit tests → dev build (+ install) → eval with Whisper (your speech model) → eval with Parakeet
# (downloads it, ~480 MB, first time) → both again on your labelled real recordings →
# docs/parakeet-results.md. Quit Mowa first: the eval uses the GPU / Neural Engine too.
# Nothing in your Mowa settings changes (the eval passes the speech model as a launch argument).
# PARAKEET_ONLY=1 re-runs only the Parakeet half and compares with the last Whisper results (~half the time).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOG="$ROOT/build/parakeet-check.log"; mkdir -p build; : > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
PARAKEET=parakeet-tdt-0.6b-v3
# Always named explicitly: the speech model picked in Mowa may be Parakeet (2026-10-22 the "Whisper"
# runs silently ran Parakeet because Parakeet was selected in Settings).
WHISPER=openai_whisper-large-v3-v20240930_turbo_632MB
osascript -e 'quit app "Mowa"' >/dev/null 2>&1; killall Mowa >/dev/null 2>&1

say "== Parakeet check $(date '+%Y-%m-%d %H:%M')"
say "-- dev build"
# Not --install: that launches Mowa, which then runs next to the eval (slower, and it shares the GPU).
if bash scripts/build.sh --dev >> "$LOG" 2>&1; then say "ok: built"; else
  say "FAIL: build"; cat build/summary.txt | tee -a "$LOG"; exit 1; fi

run() {   # $1 = label, rest = env assignments
  local label="$1"; shift
  say "-- eval: $label"
  rm -f build/eval/results.jsonl build/eval/summary.json build/eval/report.txt
  if env NOBUILD=1 "$@" bash scripts/eval.sh >> "$LOG" 2>&1 && [ -s build/eval/summary.json ]; then
    cp build/eval/results.jsonl "build/parakeet-$label.results.jsonl"
    cp build/eval/summary.json "build/parakeet-$label.summary.json"
    say "ok: $(sed -n '4p' build/eval/report.txt)"
  else
    say "FAIL: eval $label did not finish (build/eval/run.log)"
  fi
}
if [ "${PARAKEET_ONLY:-0}" = 1 ] && [ -s build/parakeet-whisper.results.jsonl ] && [ -s build/parakeet-whisper-real.results.jsonl ]; then
  say "-- Whisper: reusing the last results (PARAKEET_ONLY=1)"
else
  run whisper SPEECH=$WHISPER
fi
run parakeet SPEECH=$PARAKEET
[ "${PARAKEET_ONLY:-0}" = 1 ] && [ -s build/parakeet-whisper-real.results.jsonl ] || run whisper-real REAL=1 QUICK=1 SPEECH=$WHISPER
run parakeet-real REAL=1 QUICK=1 SPEECH=$PARAKEET

say "-- comparing"
python3 scripts/parakeet-compare.py build docs/parakeet-results.md 2>&1 | tee -a "$LOG"
say "Done: docs/parakeet-results.md (log: build/parakeet-check.log)"
open build/Mowa.app
