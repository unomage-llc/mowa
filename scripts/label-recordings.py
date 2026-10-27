#!/usr/bin/env python3
"""Label saved dev recordings for the eval (REAL=1 bash scripts/eval.sh).

For every recording in build/dev-recordings without an expected.txt, shows what Mowa heard and
typed, then asks what it SHOULD have typed:
  Enter        what Mowa typed was right
  any text     the correct text (written as expected.txt)
  -            nothing should have been typed (noise, accidental press)
  s            skip for now
  q            quit
Usage: python3 scripts/label-recordings.py [recordings dir]
"""
import json, os, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
rec_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "build", "dev-recordings")
if not os.path.isdir(rec_dir):
    sys.exit(f"no recordings folder: {rec_dir}\nbuild with: bash scripts/build.sh --dev --install, "
             "turn on Settings → General → Save recordings for testing, dictate as usual")

folders = sorted(f for f in os.listdir(rec_dir) if os.path.isfile(os.path.join(rec_dir, f, "audio.wav")))
todo = [f for f in folders if not os.path.exists(os.path.join(rec_dir, f, "expected.txt"))]
print(f"{len(folders)} recordings, {len(folders) - len(todo)} labelled, {len(todo)} to go\n")
done = 0
for i, f in enumerate(todo, 1):
    base = os.path.join(rec_dir, f)
    try:
        meta = json.load(open(os.path.join(base, "meta.json"), encoding="utf-8"))
    except Exception:
        meta = {}
    typed = meta.get("typed") or ""
    print(f"[{i}/{len(todo)}] {f}  {meta.get('mode', '')}  {meta.get('whisper_language', '')}  "
          f"{meta.get('audio_seconds', 0):.1f}s  app: {meta.get('start_app', '')}")
    print(f"  heard: {meta.get('whisper_text') or ''}")
    print(f"  typed: {typed}")
    try:
        answer = input("  correct (Enter = typed is right, - = nothing, s = skip, q = quit): ")
    except EOFError:
        break
    if answer == "q":
        break
    if answer == "s":
        continue
    text = "" if answer == "-" else (typed if answer == "" else answer)
    with open(os.path.join(base, "expected.txt"), "w", encoding="utf-8") as out:
        out.write(text + "\n")
    done += 1
    print()
print(f"labelled {done}. Run: REAL=1 bash scripts/eval.sh")
