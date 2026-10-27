#!/bin/bash
# Compares cleanup models on the self-test clips (dictation cleanup in 8 languages + translation
# into each language): same Whisper transcripts, each model's output side by side, with timings.
# Apple silicon only (MLX models). Report: build/compare.txt
#
#   bash scripts/compare-models.sh                 Qwen3 4B/8B, Gemma 3 4B/12B, Bielik 4.5B
#   FULL=1 bash scripts/compare-models.sh          + Qwen3 30B-A3B (17 GB download)
#   GEMMA=0 …                                      without the two Gemma models
#   HF_TOKEN=hf_… …                                Bielik is a gated model: accept its terms on
#                                                  huggingface.co/speakleash/Bielik-4.5B-v3.0-Instruct
#                                                  and pass a read token, or it is skipped
#   MODELS="repo/id /path/to/folder" bash scripts/compare-models.sh   any models
#
# Models are downloaded into Mowa's model folder (~3–8 GB each) and removed again at the end;
# Bielik has no ready MLX version and is converted with mlx-lm (pip) into ~/mowa-models/.
# Your own cleanup model and everything else Mowa had before is left alone.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build"; mkdir -p "$OUT"
REPORT="$OUT/compare.txt"; : > "$REPORT"; : > "$OUT/compare.log"
say_() { echo "$*" | tee -a "$REPORT"; }

say_ "== 1/4 build"
if bash scripts/build.sh > /dev/null 2>&1; then say_ "ok: built"; else say_ "FAIL: build (see build/summary.txt)"; cat "$OUT/summary.txt"; exit 1; fi

say_ "== 2/4 test audio"
AUD="$OUT/selftest-audio"; rm -rf "$AUD"; mkdir -p "$AUD"
VOICES="$(say -v '?' 2>/dev/null)"
mk() { # name "Voice|Fallback voice" "text to speak" "expected result"
  local name="$1" voices="$2" text="$3" expected="$4" voice="" v
  IFS='|' read -ra _mk_voices <<<"$voices"
  for v in "${_mk_voices[@]}"; do grep -q "^$v " <<<"$VOICES" && { voice="$v"; break; }; done
  if [ -z "$voice" ]; then say_ "skip $name: voice '$voices' not installed"; return; fi
  say -v "$voice" -o "$AUD/$name.wav" --data-format=LEI16@16000 "$text" && printf '%s\n' "$expected" > "$AUD/$name.txt"
}
MOWA_CLIPS_ONLY=1 source "$ROOT/scripts/selftest-installed.sh"
mowa_clips
say_ "ok: $(ls "$AUD"/*.wav | wc -l | tr -d ' ') clips"

say_ "== 3/4 models"
# Everything this script downloads is removed at the end (KEEP=1 keeps it): models that weren't
# in Mowa's model folder before, the comparison-only candidates, the converted Bielik, the
# original it was converted from and the Python tools used for the conversion.
MODELS_DIR="$HOME/Library/Application Support/Mowa/Models/Cleanup"
mkdir -p "$MODELS_DIR/.mowa-installed"
BEFORE="$(ls -A "$MODELS_DIR" "$MODELS_DIR/.mowa-installed" 2>/dev/null)"
BIELIK="$HOME/mowa-models/Bielik-4.5B-v3.0-Instruct-4bit"
VENV="$OUT/mlx-venv"
if [ -z "${MODELS:-}" ]; then
  if [ ! -f "$BIELIK/config.json" ]; then
    say_ "-- converting Bielik 4.5B to MLX (one-time, ~5–10 min)"
    PY=""
    for p in python3.12 python3.13 python3.11 python3; do command -v "$p" >/dev/null && { PY="$p"; break; }; done
    # A private virtual environment: Homebrew's Python refuses pip installs into itself (PEP 668).
    if [ -n "$PY" ] && "$PY" -m venv "$VENV" >>"$OUT/compare.log" 2>&1 \
       && "$VENV/bin/pip" install --quiet mlx-lm >>"$OUT/compare.log" 2>&1; then
      mkdir -p "$HOME/mowa-models"
      "$VENV/bin/python" -m mlx_lm convert --hf-path speakleash/Bielik-4.5B-v3.0-Instruct -q --mlx-path "$BIELIK" >>"$OUT/compare.log" 2>&1 \
        || "$VENV/bin/python" -m mlx_lm.convert --hf-path speakleash/Bielik-4.5B-v3.0-Instruct -q --mlx-path "$BIELIK" >>"$OUT/compare.log" 2>&1
    fi
    if [ ! -f "$BIELIK/config.json" ]; then
      if grep -q "GatedRepoError" "$OUT/compare.log" 2>/dev/null; then
        say_ "warn: Bielik is a gated model — accept its terms on Hugging Face and run with HF_TOKEN=… (see the top of this script); compared without it"
      else
        say_ "warn: Bielik conversion failed (see build/compare.log) — compared without it"
      fi
    fi
  fi
  # Gemma 3 4B: the text-only (mlx-lm) conversion — the plain gemma-3-4b-it-4bit is a vision
  # model checkpoint that didn't load.
  MODELS="mlx-community/Qwen3-4B-Instruct-2507-4bit mlx-community/Qwen3-8B-4bit"
  [ "${GEMMA:-1}" = 1 ] && MODELS="$MODELS mlx-community/gemma-3-4b-it-4bit-DWQ mlx-community/gemma-3-12b-it-4bit"
  [ -f "$BIELIK/config.json" ] && MODELS="$MODELS $BIELIK"
  [ "${FULL:-0}" = 1 ] && MODELS="$MODELS mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"
fi
say_ "$MODELS"

say_ "== 4/4 compare"
# shellcheck disable=SC2086
"$OUT/Mowa.app/Contents/MacOS/Mowa" --compare "$AUD" $MODELS 2>/dev/null | tee -a "$REPORT"
say_ "Report: build/compare.txt"

# Why a model failed to load, etc.: the end of Mowa's log.
tail -n 150 "$HOME/Library/Application Support/Mowa/Logs/mowa.log" >>"$OUT/compare.log" 2>/dev/null

if [ "${KEEP:-0}" != 1 ]; then
  for d in "$MODELS_DIR"/models--* "$MODELS_DIR"/.mowa-installed/*; do
    [ -e "$d" ] || continue
    name="${d##*/}"
    case "$name" in
      *gemma-3-4b-it-4bit*|*gemma-3-12b-it-4bit*|local--*) rm -rf "$d"; continue ;;
    esac
    if ! printf '%s\n' "$BEFORE" | grep -qxF "$name"; then rm -rf "$d"; fi
  done
  rm -rf "$HOME/mowa-models" "$HOME/.cache/huggingface/hub/models--speakleash--Bielik-4.5B-v3.0-Instruct" "$VENV"
  say_ "ok: removed the models and tools downloaded for the comparison - KEEP=1 keeps them"
fi
