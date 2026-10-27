# FluidAudio (vendored)

- Upstream: https://github.com/FluidInference/FluidAudio, tag v0.17.7 — Apache License 2.0 (LICENSE, ThirdPartyLicenses/).
- Vendored 2026-10-26 so Mowa can add a language-model hook to the Parakeet TDT v3 greedy decoder.
- Mowa's changes (search for "Mowa:"):
  - `Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/Decoder/TdtFusion.swift` (new): `TdtTokenScorer` protocol, the
    `TdtFusion.scorer` task-local, and `TdtFusion.rescore`, which re-picks a non-blank token among the joint's top-64 by
    acoustic logit + weight × language-model log-probability, only for candidates within `maxLogitGap` of the best and
    only among tokens the scorer has an opinion on (nil = none); the new token's score stays a full-vocabulary probability.
    Also `AsrManager.tokenVocabulary` (public read of the vocabulary).
  - `TdtDecoderV3.swift`: top-K is requested when a scorer is set, and `TdtFusion.rescore` runs right before the script
    filter (so the filter and the French blocklist keep the last word) in both the main and the inner (blank-skipping) loop.
- No scorer set (the default) = byte-for-byte upstream behaviour.
- To update: copy the new tag's `Sources/{FluidAudio,FastClusterWrapper,MachTaskSelfWrapper}`, re-apply the two changes.
