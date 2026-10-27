#!/bin/bash
# Bigger / other Whisper models on the languages that fail most (Polish, Portuguese) — one command:
#   bash scripts/whisper-compare.sh
# dev build → for each candidate model and language: the full eval of that language (all audio
# variants; the model is downloaded the first time) → build/whisper-compare/report.md, compared
# with the current default (the Whisper half of the last parakeet-check run).
# Quit Mowa first. Override: MODELS="id1 id2" LANGS="pl pt ru" bash scripts/whisper-compare.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT=build/whisper-compare; mkdir -p "$OUT"
LOG="$OUT/log.txt"; : > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
# Full-precision v3 turbo (1.6 GB, in Settings), classic large-v3 (all 32 decoder layers; slower,
# often better on Polish), and large-v3 with WhisperKit's turbo decoder.
MODELS="${MODELS:-openai_whisper-large-v3-v20240930_turbo openai_whisper-large-v3_947MB openai_whisper-large-v3_turbo_954MB}"
LANGS="${LANGS:-pl pt}"
osascript -e 'quit app "Mowa"' >/dev/null 2>&1; killall Mowa >/dev/null 2>&1

say "== Whisper compare $(date '+%Y-%m-%d %H:%M')  models: $MODELS  languages: $LANGS"
if bash scripts/build.sh --dev >> "$LOG" 2>&1; then say "ok: built"; else say "FAIL: build"; exit 1; fi
for m in $MODELS; do
  for l in $LANGS; do
    say "-- $m / $l"
    rm -f build/eval/results.jsonl build/eval/summary.json build/eval/report.txt
    if env NOBUILD=1 ONLY="$l" SPEECH="$m" bash scripts/eval.sh >> "$LOG" 2>&1 && [ -s build/eval/results.jsonl ]; then
      cp build/eval/results.jsonl "$OUT/$m.$l.jsonl"; say "ok"
    else say "FAIL: eval (see $LOG)"; fi
  done
done
python3 - "$OUT" build/parakeet-whisper.results.jsonl $LANGS <<'PY' | tee "$OUT/report.md" | tee -a "$LOG"
import json, sys, glob, os, statistics
out, base, langs = sys.argv[1], sys.argv[2], sys.argv[3:]
def stats(rows):
    n = len(rows); fail = sum(r["grade"] == "FAIL" for r in rows); diff = sum(r["grade"] == "DIFF" for r in rows)
    t = [r["total"] for r in rows if isinstance(r.get("total"), (int, float))]
    return n, fail, diff, (statistics.median(t) if t else 0)
print("| model | lang | runs | FAIL | DIFF | release → text p50 |\n|---|---|---|---|---|---|")
if os.path.exists(base):
    rows = [json.loads(l) for l in open(base)]
    for l in langs:
        n, f, d, p = stats([r for r in rows if r["id"].startswith(l + ".")])
        if n: print(f"| current (v3 turbo 632 MB) | {l} | {n} | {f} ({f/n:.1%}) | {d} ({d/n:.1%}) | {p:.2f}s |")
for path in sorted(glob.glob(os.path.join(out, "*.jsonl"))):
    m, l = os.path.basename(path)[:-6].rsplit(".", 1)
    n, f, d, p = stats([json.loads(x) for x in open(path)])
    if n: print(f"| {m} | {l} | {n} | {f} ({f/n:.1%}) | {d} ({d/n:.1%}) | {p:.2f}s |")
PY
say "Done: $OUT/report.md"
