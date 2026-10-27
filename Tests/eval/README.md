# Mowa evaluation suite

End-to-end quality + speed tests: every case is spoken by a macOS voice (`say`), optionally
degraded (noise, quiet, phone-quality mic, fast speech…), run through the **same pipeline the app
uses** (`DictationPipeline`: noise reduction → Whisper → language instruction / command detection →
cleanup model → final-period / inline-fit / spacing) and scored automatically.

    bash scripts/eval.sh                 # everything (≈15–25 min on Apple silicon)
    QUICK=1 bash scripts/eval.sh         # clean audio only, no variants
    ONLY=pl bash scripts/eval.sh         # one language (spoken language of the case)
    CAT=selfcorr bash scripts/eval.sh    # one category
    REAL=1 bash scripts/eval.sh          # + your own saved recordings (build/dev-recordings, see below)

Results: `build/eval/report.txt` (summary + every failure), `build/eval/results.jsonl` (one line
per run), `build/eval/summary.json` (numbers for comparing runs; the previous run is kept as
`summary.prev.json` and the report shows the difference).

The eval runs with a fixed profile, independent of your Mowa settings (passed as command-line
defaults, nothing is saved): all 8 languages enabled, smart cleanup, context-aware style on, screen
names off, keyboard language off, voice filter off, noise reduction on, learning off, your
vocabulary and snippets replaced by the case's own (in memory only). Models: the ones selected in
Mowa (override: `SPEECH=… MODEL=… bash scripts/eval.sh`).

## Grades

| Grade | Meaning |
|---|---|
| `PASS` | output equals one of `expect` (after normalisation: spaces, quotes, NBSP) |
| `OK` | only capitalisation/punctuation differs from an `expect`, and every check passes |
| `DIFF` | every check passes, but the wording differs from all `expect` (meaning probably kept — read it) |
| `FAIL` | a hard check failed: a `must` text is missing, a `mustNot` text is present, wrong list format, wrong output language, text typed where nothing should be (or nothing typed), an error |

Quality = FAIL rate (meaning errors) and PASS+OK rate (exactness). Speed = time from key release to
text (prep + Whisper + cleanup), p50 / p90 / max, per language.

## Case format (`cases/*.json` — a JSON array)

```json
{
  "id": "pl.selfcorr.1",            // unique: <spoken lang>.<category>.<n>
  "lang": "pl",                     // spoken language: en pl ru es de fr pt it
  "cat": "selfcorr",                // category (list below)
  "say": "Yyy, dobra, wyślij mi ten plik jutro rano, a nie, sorry, dzisiaj wieczorem.",
  "expect": ["Dobra, wyślij mi ten plik dzisiaj wieczorem."],
  "must": ["dzisiaj wieczorem"],    // case-insensitive substrings that MUST be in the output
  "mustNot": ["jutro", "yyy"],      // ... that must NOT be in the output
  "format": "numbered",             // optional: numbered | bulleted | list | oneline | paragraphs
  "out": "de",                      // optional: language the output must be in (translations); default = lang
  "mode": "command",                // optional: dictation (default) | command
  "selection": "text",              // optional: selected text (command mode, or dictating over a selection)
  "app": "chat",                    // optional: general (TextEdit, default) | email | chat | slack | code | terminal | search
  "before": "Spotkanie jest ",      // optional: text before the caret (dictating into the middle of a sentence)
  "after": " w sali B.",            // optional: text after the caret
  "vocab": ["Unomage"],             // optional: vocabulary words for this case
  "variants": ["noise", "phone"],   // optional: extra audio versions (clean always runs)
  "voice": 2,                       // optional: use the language's second voice
  "empty": true,                    // optional: nothing must be typed (silence, noise only)
  "note": "why this case exists"
}
```

`say` is what the voice reads — write it the way a person speaks (numbers as words, spoken
punctuation as words when that is what is tested). `[[slnc 500]]` inserts a 500 ms pause.
`expect` is what must be typed, with `\n` for line breaks; give every acceptable variant. Put the
facts that carry the meaning (corrected time, names, numbers, negations) into `must`, and the
wrong alternatives / fillers / instruction words into `mustNot`, so a meaning error is a FAIL and
not just a DIFF. `expect` may be `[]` for long texts where only the checks matter.

Variants: `noise` (fan/street noise, 10 dB SNR), `loudnoise` (3 dB), `quiet` (−24 dB, far from
the mic), `loud` (clipped, too close), `phone` (8 kHz band-limited, like AirPods in call mode),
`echo` (room reverb), `fast` / `slow` (speech rate 250 / 120 wpm), `voice2` (the language's other voice), `noiseonly`
(noise over the clip — for silence cases: nothing may be typed), `cutstart` / `cutend` (first / last
150 ms missing, as when the recorder starts late or stops right at key release).

Categories: `plain short question request fillers selfcorr restart stutter list-numbered
list-announced list-named list-tasks list-steps inline-items punct newline money percent time date phone units bignum
email-url spelling emoji slang swear mixed-lang names brands long verylong diacritics vocab
inline-fit app-chat app-email app-code command translate silence hallucination homophone
negation injection repeat-intent pause acronym numbers-mixed address quote trailing-silence
question-intonation` (the last ten in `cases/robustness.json`).

`must` accepts alternatives: `"don't send||do not send"` passes when either is in the output.

## Your own recordings

A developer build (`bash scripts/build.sh --dev --install`) has **Settings → General → Save
recordings for testing**: every dictation is saved to `build/dev-recordings/<date>_<id>/`
(`audio.wav` exactly as recorded + `meta.json`: what Whisper heard, what was typed, language, app,
timings, and what the field contained 25 s later — your corrections). Release builds don't have
the toggle, don't save anything, and a developer build is never released.

A recording becomes a test case when its folder gets an `expected.txt` (the text that should
have been typed); `REAL=1 bash scripts/eval.sh` then runs them as category `real`.
