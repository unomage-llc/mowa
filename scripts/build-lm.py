#!/usr/bin/env python3
"""Builds Mowa's word language models (one .mowalm file per dictation language) for Parakeet's
language-model fusion (Sources/MowaModels/WordLanguageModel.swift, ParakeetEngine "languageModel").

  pip install wordfreq            # unigram frequencies (data: CC-BY-SA 4.0, Robyn Speer et al.)
  python3 scripts/build-lm.py OUT_DIR [--corpus DIR]

Unigrams: wordfreq "best" list, top N words. Bigrams: Common Voice sentence files (CC0, the
common-voice/common-voice GitHub repo, server/data/<lang>/sentence-collector.txt, plus wiki.<lang>.txt
where it exists — the first 40 MB). The files are CC-BY-SA 4.0 because of the wordfreq part.

Format (little-endian), read by WordLanguageModel:
  "MOWALM1\\0", u32 nWords, u32 nBigrams, u32 blobBytes,
  u32 offsets[nWords+1], blob (lowercased UTF-8 words, sorted by bytes),
  f32 uni[nWords], f64 uniCum[nWords+1],
  u32 ctxStart[nWords+1], f32 lambda[nWords],
  u32 next[nBigrams], f32 pBi[nBigrams]   (per context sorted by next id)
Word normalisation must match WordLanguageModel.normalize: lowercase, ’→', ё→е, keep letters, digits,
and ' or - inside a word.
"""
import argparse, collections, os, struct, sys, urllib.request

LANGS = ["en", "pl", "ru", "es", "de", "fr", "pt", "it"]
TOP_WORDS = {"pl": 200_000, "ru": 200_000, "de": 200_000}
DEFAULT_TOP = 130_000
MAX_BIGRAMS = 800_000
BASE = "https://raw.githubusercontent.com/common-voice/common-voice/main/server/data"
WIKI_BYTES = 40_000_000


def normalize(token: str) -> str:
    t = token.lower().replace("’", "'").replace("ё", "е")
    # strip leading / trailing characters that are not letters or digits
    i, j = 0, len(t)
    while i < j and not t[i].isalnum():
        i += 1
    while j > i and not t[j - 1].isalnum():
        j -= 1
    t = t[i:j]
    if not t:
        return ""
    if any(not (c.isalnum() or c in "'-") for c in t):
        return ""
    return t


def fetch(url: str, path: str, limit: int | None = None):
    if os.path.exists(path):
        return True
    req = urllib.request.Request(url)
    if limit:
        req.add_header("Range", f"bytes=0-{limit}")
    try:
        with urllib.request.urlopen(req, timeout=300) as r, open(path, "wb") as f:
            f.write(r.read())
        return True
    except Exception as e:  # noqa: BLE001
        print(f"  skip {url}: {e}", file=sys.stderr)
        return False


def sentences(corpus_dir: str, lang: str):
    files = []
    for name, limit in ((f"sentence-collector.txt", None), (f"wiki.{lang}.txt", WIKI_BYTES)):
        path = os.path.join(corpus_dir, f"{lang}_{name}")
        if fetch(f"{BASE}/{lang}/{name}", path, limit):
            files.append(path)
    for path in files:
        with open(path, encoding="utf-8", errors="ignore") as f:
            for line in f:
                yield line.strip().strip('"')


def build(lang: str, out_dir: str, corpus_dir: str):
    import wordfreq
    freqs = wordfreq.get_frequency_dict(lang, "best")
    top = TOP_WORDS.get(lang, DEFAULT_TOP)
    uni = collections.Counter()
    for w, f in freqs.items():
        n = normalize(w)
        if n:
            uni[n] += f
    words = [w for w, _ in uni.most_common(top)]
    words.sort(key=lambda w: w.encode("utf-8"))
    index = {w: i for i, w in enumerate(words)}
    total = sum(uni[w] for w in words)
    uni_p = [uni[w] / total for w in words]

    big = collections.Counter()
    ctx_total = collections.Counter()
    for s in sentences(corpus_dir, lang):
        toks = [normalize(t) for t in s.split()]
        prev = None
        for t in toks:
            i = index.get(t) if t else None
            if prev is not None and i is not None:
                big[(prev, i)] += 1
                ctx_total[prev] += 1
            prev = i
    min_count = 2 if sum(big.values()) > 3_000_000 else 1
    kept = [(k, c) for k, c in big.items() if c >= min_count]
    kept.sort(key=lambda kc: -kc[1])
    kept = kept[:MAX_BIGRAMS]
    by_ctx = collections.defaultdict(list)
    for (a, b), c in kept:
        by_ctx[a].append((b, c))
    distinct = collections.Counter(a for (a, _b) in big.keys())

    blob = bytearray()
    offsets = [0]
    for w in words:
        blob += w.encode("utf-8")
        offsets.append(len(blob))
    cum = [0.0]
    for p in uni_p:
        cum.append(cum[-1] + p)
    ctx_start, lam, nxt, pbi = [0], [], [], []
    for i in range(len(words)):
        lst = sorted(by_ctx.get(i, []))
        c = ctx_total[i]
        t = distinct[i]
        lam.append(c / (c + t) if c > 0 else 0.0)
        for b, n in lst:
            nxt.append(b)
            pbi.append(n / c)
        ctx_start.append(len(nxt))

    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{lang}.mowalm")
    with open(path, "wb") as f:
        f.write(b"MOWALM1\0")
        f.write(struct.pack("<III", len(words), len(nxt), len(blob)))
        f.write(struct.pack(f"<{len(offsets)}I", *offsets))
        f.write(bytes(blob))
        f.write(struct.pack(f"<{len(uni_p)}f", *uni_p))
        f.write(struct.pack(f"<{len(cum)}d", *cum))
        f.write(struct.pack(f"<{len(ctx_start)}I", *ctx_start))
        f.write(struct.pack(f"<{len(lam)}f", *lam))
        f.write(struct.pack(f"<{len(nxt)}I", *nxt))
        f.write(struct.pack(f"<{len(pbi)}f", *pbi))
    print(f"{lang}: {len(words)} words, {len(nxt)} bigrams (min count {min_count}), {os.path.getsize(path) / 1e6:.1f} MB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--corpus", default="build/lm-corpus")
    ap.add_argument("--only", nargs="*", default=LANGS)
    a = ap.parse_args()
    os.makedirs(a.corpus, exist_ok=True)
    for lang in a.only:
        build(lang, a.out, a.corpus)


if __name__ == "__main__":
    main()
