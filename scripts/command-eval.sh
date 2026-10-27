#!/bin/bash
# One key for everything: how well Mowa tells edits for selected text ("make it shorter",
# "translate into English, make it more formal and correct the errors") from words that replace it
# ("Thursday."). Runs every set in Tests/eval/commands: classify.json (the set the rules were tuned
# on) and holdout.json (never tuned on — the honest number). Reports: build/eval/command-report-*.txt
#   bash scripts/command-eval.sh     NOBUILD=1 … (existing build)     MODEL=<id> … (other cleanup model)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/eval"; mkdir -p "$OUT"
if [ "${NOBUILD:-0}" != 1 ] || [ ! -x build/Mowa.app/Contents/MacOS/Mowa ]; then
  bash scripts/build.sh > /dev/null 2>&1 || { echo "FAIL: build (build/summary.txt)"; cat build/summary.txt; exit 1; }
fi
PROFILE=(-cleanupLevel smart -customInstructions '')
[ -n "${MODEL:-}" ] && PROFILE+=(-fastModelID "$MODEL")
for SET in "$ROOT"/Tests/eval/commands/*.json; do
  build/Mowa.app/Contents/MacOS/Mowa "${PROFILE[@]}" --command-eval "$SET" "$OUT" 2>>"$OUT/command-run.log" | grep -v "^\["
done
echo "Reports: build/eval/command-report-classify.txt, -holdout.txt, -variants.txt"
