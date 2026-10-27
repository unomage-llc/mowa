#!/usr/bin/env python3
"""Speaks every eval case with a macOS voice (`say`) into <audio-dir>/<id>.wav (16 kHz, 16-bit),
plus <id>@fast.wav / @slow / @voice2 for the cases that list those variants. Cached: a clip is only
regenerated when its text, voice or rate changed. Used by scripts/eval.sh.

    python3 scripts/eval_audio.py Tests/eval/cases build/eval/audio [--only pl] [--cat selfcorr] [--quick]
"""
import concurrent.futures, glob, hashlib, json, os, re, subprocess, sys

# Preferred voices per language (first installed wins); voice2 = a different voice of the language.
VOICES = {
    "en": ["Samantha", "Ava", "Alex", "Allison", "Daniel", "Karen"],
    "pl": ["Zosia", "Krzysztof", "Ewa"],
    "ru": ["Milena", "Yuri", "Katya"],
    "es": ["Mónica", "Monica", "Paulina", "Jorge", "Juan", "Marisol"],
    "de": ["Anna", "Markus", "Petra", "Yannick", "Helena"],
    "fr": ["Thomas", "Amélie", "Audrey", "Aurélie", "Marie"],
    "pt": ["Luciana", "Felipe", "Fernanda", "Joana"],
    "it": ["Alice", "Luca", "Federica", "Paola"],
}
LOCALE = {"en": "en_", "pl": "pl_", "ru": "ru_", "es": "es_", "de": "de_", "fr": "fr_", "pt": "pt_BR", "it": "it_"}
RATES = {"fast": 250, "slow": 120}


def installed():
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    voices = []
    for line in out.splitlines():
        # Long names (Eloquence: "Eddy (German (Germany))") leave only one space before the locale.
        m = re.match(r"^(.+?)\s+([a-z]{2,3}[_-][A-Za-z0-9_]+)\s+#", line)
        if m:
            voices.append((m.group(1).strip(), m.group(2).replace("-", "_")))
    return voices


def pick(lang, voices):
    """(primary, second) voice names for a language, or None."""
    loc = [n for n, l in voices if l.startswith(LOCALE[lang])]
    def best(name):
        # Prefer the higher-quality download of a voice when it is installed.
        for suffix in (" (Premium)", " (Enhanced)", ""):
            if name + suffix in loc:
                return name + suffix
        return None
    ordered = [v for v in (best(n) for n in VOICES[lang]) if v]
    # Any other voice of the language (e.g. the multilingual Eloquence voices) as a last resort.
    novelty = {"Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Good News", "Jester", "Organ",
               "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox", "Albert", "Fred", "Junior", "Kathy", "Ralph"}
    ordered += [n for n in loc if n not in ordered and n.split(" (")[0] not in novelty]
    if not ordered:
        return None, None
    primary = ordered[0]
    base = primary.split(" (")[0]
    second = next((v for v in ordered[1:] if v.split(" (")[0] != base), None)
    return primary, second


def main():
    args = sys.argv[1:]
    cases_dir, audio_dir = args[0], args[1]
    only = args[args.index("--only") + 1] if "--only" in args else ""
    cat = args[args.index("--cat") + 1] if "--cat" in args else ""
    quick = "--quick" in args
    os.makedirs(audio_dir, exist_ok=True)
    voices = installed()
    chosen = {lang: pick(lang, voices) for lang in VOICES}
    for lang, (p, s) in chosen.items():
        print(f"voice {lang}: {p or 'MISSING'}" + (f", second: {s}" if s else ", second: none"))
    jobs, missing = [], []
    for fn in sorted(glob.glob(os.path.join(cases_dir, "*.json"))):
        for c in json.load(open(fn, encoding="utf-8")):
            if only and c["lang"] != only or cat and c["cat"] != cat:
                continue
            primary, second = chosen.get(c["lang"], (None, None))
            want = [("clean", primary if c.get("voice") != 2 else (second or primary), None)]
            if not quick:
                for v in c.get("variants") or []:
                    if v in RATES:
                        want.append((v, primary, RATES[v]))
                    elif v == "voice2":
                        want.append((v, second, None))
            for variant, voice, rate in want:
                name = c["id"] + ("" if variant == "clean" else "@" + variant)
                if not voice:
                    missing.append(name)
                    continue
                jobs.append((name, voice, rate, c["say"]))

    def make(job):
        name, voice, rate, text = job
        wav = os.path.join(audio_dir, name + ".wav")
        key = hashlib.sha1(f"{voice}|{rate}|{text}".encode()).hexdigest()
        keyfile = wav + ".key"
        if os.path.exists(wav) and os.path.exists(keyfile) and open(keyfile).read() == key:
            return None
        txt = wav + ".txt"
        with open(txt, "w", encoding="utf-8") as f:
            f.write(text)
        cmd = ["say", "-v", voice, "-o", wav, "--data-format=LEI16@16000", "-f", txt]
        if rate:
            cmd[1:1] = ["-r", str(rate)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        os.remove(txt)
        if r.returncode != 0 or not os.path.exists(wav):
            return f"{name}: say failed: {r.stderr.strip()[:200]}"
        with open(keyfile, "w") as f:
            f.write(key)
        return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        errors = [e for e in pool.map(make, jobs) if e]
    for e in errors:
        print("FAIL", e)
    print(f"ok: {len(jobs) - len(errors)} clips ready" + (f", {len(missing)} skipped (voice not installed)" if missing else ""))
    if missing:
        langs = sorted({m.split(".")[0] for m in missing})
        print("  install voices in System Settings → Accessibility → Spoken Content → System voice → Manage Voices: " + ", ".join(langs))


if __name__ == "__main__":
    main()
