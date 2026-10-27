#!/usr/bin/env python3
"""Compare eval runs written by scripts/parakeet-check.sh → markdown report."""
import json, os, statistics, sys
from collections import defaultdict

build, out = sys.argv[1], sys.argv[2]

def load(label):
    p = os.path.join(build, f"parakeet-{label}.results.jsonl")
    if not os.path.exists(p): return None
    rows = {}
    for line in open(p, encoding="utf-8"):
        line = line.strip()
        if not line: continue
        r = json.loads(line)
        rows[(r.get("id"), r.get("variant"))] = r
    return rows

def pct(n, d): return f"{100*n/d:.1f}%" if d else "–"
def med(xs): return f"{statistics.median(xs):.2f}s" if xs else "–"
def p90(xs):
    if not xs: return "–"
    xs = sorted(xs); return f"{xs[min(len(xs)-1, int(0.9*len(xs)))]:.2f}s"

def stats(rows):
    n = len(rows); g = defaultdict(int)
    for r in rows: g[r.get("grade")] += 1
    # Same rule as the eval report: only where something was heard; not real / mixed-language cases.
    lang = [r for r in rows if r.get("lang") and r.get("detected") and r.get("cat") not in ("mixed-lang", "real")]
    langok = sum(1 for r in lang if r.get("detected") == r.get("lang"))
    asr = [r["asr"] for r in rows if isinstance(r.get("asr"), (int, float)) and r.get("asr", 0) > 0]
    tot = [r["total"] for r in rows if isinstance(r.get("total"), (int, float)) and r.get("total", 0) > 0]
    wer = [r["asr_wer"] for r in rows if isinstance(r.get("asr_wer"), (int, float))]
    return dict(n=n, fail=g["FAIL"], diff=g["DIFF"], ok=g["PASS"] + g["OK"], langok=langok, langn=len(lang),
                asr_p50=med(asr), total_p50=med(tot), total_p90=p90(tot),
                wer=f"{statistics.mean(wer):.3f}" if wer else "–")

lines = ["# Parakeet v3 vs Whisper — eval results", ""]
pairs = [("whisper", "parakeet", "Synthetic eval (all 8 languages, all audio variants)"),
         ("whisper-real", "parakeet-real", "Real recordings (clean audio)")]
for a, b, title in pairs:
    A, B = load(a), load(b)
    lines += [f"## {title}", ""]
    if not A or not B:
        lines += [f"Missing run: {a if not A else b}", ""]; continue
    sa, sb = stats(list(A.values())), stats(list(B.values()))
    lines += ["| | Whisper | Parakeet |", "|---|---|---|"]
    for k, name in [("n", "runs"), ("fail", "FAIL"), ("diff", "DIFF"), ("ok", "PASS+OK")]:
        if k == "n": lines.append(f"| {name} | {sa[k]} | {sb[k]} |")
        else: lines.append(f"| {name} | {sa[k]} ({pct(sa[k], sa['n'])}) | {sb[k]} ({pct(sb[k], sb['n'])}) |")
    lines.append(f"| language right | {pct(sa['langok'], sa['langn'])} | {pct(sb['langok'], sb['langn'])} |")
    lines.append(f"| speech recognition p50 | {sa['asr_p50']} | {sb['asr_p50']} |")
    lines.append(f"| release → text p50 / p90 | {sa['total_p50']} / {sa['total_p90']} | {sb['total_p50']} / {sb['total_p90']} |")
    lines.append(f"| recognition word error rate (mean, rough) | {sa['wer']} | {sb['wer']} |")
    lines.append("")
    # per language
    bylang = defaultdict(lambda: [[], []])
    for k, r in A.items(): bylang[r.get("lang") or "?"][0].append(r)
    for k, r in B.items(): bylang[r.get("lang") or "?"][1].append(r)
    lines += ["| language | n | FAIL Whisper | FAIL Parakeet | lang-ok Whisper | lang-ok Parakeet | p50 Whisper | p50 Parakeet |",
              "|---|---|---|---|---|---|---|---|"]
    for lang in sorted(bylang):
        ra, rb = bylang[lang]; x, y = stats(ra), stats(rb)
        lines.append(f"| {lang} | {x['n']} | {pct(x['fail'], x['n'])} | {pct(y['fail'], y['n'])} | "
                     f"{pct(x['langok'], x['langn'])} | {pct(y['langok'], y['langn'])} | {x['total_p50']} | {y['total_p50']} |")
    lines.append("")
    worse = [k for k in A if k in B and A[k].get("grade") in ("PASS", "OK") and B[k].get("grade") == "FAIL"]
    better = [k for k in A if k in B and A[k].get("grade") == "FAIL" and B[k].get("grade") in ("PASS", "OK")]
    lines += [f"Parakeet fixes {len(better)} Whisper FAILs and breaks {len(worse)} Whisper PASSes.", ""]
    if worse:
        lines += ["Broken by Parakeet (first 40):", ""]
        for k in worse[:40]:
            r = B[k]
            lines.append(f"- `{k[0]}` ({k[1]}): heard «{r.get('whisper','')}» → typed «{r.get('typed','')}»; "
                         f"expected «{(r.get('expect') or [''])[0]}»; problems: {', '.join(r.get('problems') or [])}")
        lines.append("")
open(out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines[:60]))
