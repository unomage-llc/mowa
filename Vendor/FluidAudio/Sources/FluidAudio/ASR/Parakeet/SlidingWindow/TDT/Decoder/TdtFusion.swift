import Foundation

// Mowa: language-model hook for the TDT v3 greedy decoder (vendored change, see VENDOR.md).

/// Scores a token the decoder is about to emit, given the tokens it emitted before it in this decode.
public protocol TdtTokenScorer: Sendable {
    /// Natural-log probability of `token` coming next after `history` (vocabulary token IDs);
    /// nil = no opinion (punctuation, digits, inside a word the model doesn't know).
    func logProbability(of token: Int, after history: [Int]) -> Float?
    /// How much the language model counts against the acoustic logit (shallow fusion weight).
    var weight: Float { get }
    /// Only candidates whose logit is at most this far below the chosen token's may replace it,
    /// so the language model can tip close calls but never overrule clear audio.
    var maxLogitGap: Float { get }
}

public enum TdtFusion {
    /// The scorer for decodes run inside `TdtFusion.$scorer.withValue(…) { … }`. A task-local, so a
    /// shared AsrManager serving several callers at once only applies it to the caller that set it.
    @TaskLocal public static var scorer: (any TdtTokenScorer)?

    /// Re-picks a non-blank token among the joint's top-K by logit + weight × log P(token | history).
    /// Blank decisions are never changed (that would add or drop speech), nor tokens the scorer has no
    /// opinion on; candidates without an opinion can't win. Runs before the script filter, so `label`
    /// is the joint's argmax and `score` its full-vocabulary probability.
    static func rescore(
        label: inout Int,
        score: inout Float,
        topKIds: [Int]?,
        topKLogits: [Float]?,
        history: [Int],
        blankId: Int,
        scorer: any TdtTokenScorer
    ) {
        guard label != blankId, let ids = topKIds, let logits = topKLogits else { return }
        let count = min(ids.count, logits.count)
        guard count > 1 else { return }

        var labelLogit = -Float.infinity
        for i in 0..<count where ids[i] == label && logits[i] > labelLogit { labelLogit = logits[i] }
        guard labelLogit.isFinite else { return }

        guard let labelLM = scorer.logProbability(of: label, after: history) else { return }

        var bestIndex = -1
        var bestTotal = -Float.infinity
        for i in 0..<count {
            let id = ids[i]
            let logit = logits[i]
            guard id != blankId, logit.isFinite, labelLogit - logit <= scorer.maxLogitGap else { continue }
            let lmScore: Float? = id == label ? labelLM : scorer.logProbability(of: id, after: history)
            guard let lm = lmScore else { continue }
            let total = logit + scorer.weight * lm
            if total > bestTotal {
                bestTotal = total
                bestIndex = i
            }
        }
        guard bestIndex >= 0, ids[bestIndex] != label else { return }

        // Same scale as every other token's score (full-vocabulary probability): p_new = p_old · e^(Δlogit).
        score = max(0, min(1, score * expf(logits[bestIndex] - labelLogit)))
        label = ids[bestIndex]
    }
}

extension AsrManager {
    /// Mowa: the loaded model's token vocabulary (id → SentencePiece piece), for building a TdtTokenScorer.
    public var tokenVocabulary: [Int: String] { vocabulary }
}
