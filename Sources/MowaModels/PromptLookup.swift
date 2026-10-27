// Prompt-lookup decoding for the MLX cleanup model (Apple silicon only; Intel uses llama.cpp).
#if !MOWA_INTEL
import Foundation
import MLX
import MLXLMCommon

/// Greedy decoding that guesses the next tokens by copying from the prompt and checks the guess
/// in one model pass. A cleaned-up dictation is mostly the transcript copied back, so most guesses
/// are right and several tokens come out of each pass instead of one — long dictations, where the
/// cleanup model's writing time dominates (6–11 s for ~200 words in the eval), get much faster.
///
/// The output is the same as plain greedy decoding (temperature 0): a guessed token is only kept
/// when it is exactly the token the model picks itself. Built on the same calls as mlx-swift-lm's
/// `SpeculativeTokenIterator`, with the prompt as the "draft model".
struct PromptLookupIterator {
    let model: any LanguageModel
    var cache: [KVCache]
    var state: LMOutput.State?
    /// Tokens the model has not processed yet (the prompt's tail at first, then the last token).
    var y: LMInput.Text
    let sampler: LogitSampler
    let maxTokens: Int
    private(set) var tokenCount = 0
    /// Prompt + generated tokens, searched for the continuation of the last few tokens.
    private var history: [Int]
    private var pending: [Int] = []
    private var pendingIndex = 0
    /// Statistics for the log.
    private(set) var passes = 0
    private(set) var drafted = 0
    private(set) var accepted = 0

    static let maxDraft = 10
    static let ngram = [3, 2]

    init(input: LMInput, model: any LanguageModel, cache: [KVCache], parameters: GenerateParameters,
         promptTokens: [Int]) throws {
        self.model = model
        self.cache = cache
        self.sampler = parameters.sampler()
        self.maxTokens = parameters.maxTokens ?? 4096
        self.history = promptTokens
        self.y = input.text
        switch try model.prepare(input, cache: cache, windowSize: parameters.prefillStepSize) {
        case .tokens(let tokens):
            y = tokens
        case .logits(let result):
            let token = sampler.sample(logits: result.logits[0..., -1, 0...])
            state = result.state
            // The first token is known already: hand it out first, then continue from it.
            let t = token.item(Int.self)
            pending = [t]
            history.append(t)
            y = .init(tokens: token.reshaped([1]))
            needsFeed = true
        }
    }

    /// After `.logits` from prepare, `y` holds a token that was sampled but not yet fed.
    private var needsFeed = false

    /// The tokens that followed the most recent earlier occurrence of the last n tokens.
    func lookup() -> [Int] {
        for n in Self.ngram where history.count > n {
            let tail = Array(history.suffix(n))
            var i = history.count - n - 1
            while i >= 0 {
                if history[i] == tail[0] {
                    var match = true
                    for k in 1..<n where history[i + k] != tail[k] { match = false; break }
                    if match {
                        let start = i + n
                        let end = min(history.count, start + Self.maxDraft)
                        if start < end { return Array(history[start..<end]) }
                    }
                }
                i -= 1
            }
        }
        return []
    }

    /// One model pass: the unprocessed token(s) plus a guessed continuation, verified together.
    mutating func round() {
        let remaining = maxTokens - tokenCount
        guard remaining > 0 else { return }
        let draft = Array(lookup().prefix(max(0, remaining - 1)))
        let draftArray = MLXArray(draft.map { Int32($0) }).asType(y.tokens.dtype)
        let verify = draft.isEmpty ? y.tokens : concatenated([y.tokens.reshaped([-1]), draftArray])
        let verifyInput = LMInput.Text(tokens: verify)
        let verifyStart = verify.dim(0) - (draft.count + 1)
        let result = model(verifyInput[text: .newAxis], cache: cache, state: state)
        state = result.state
        let logits = result.logits[0..., verifyStart..., 0...].squeezed(axis: 0)
        let picked = sampler.sample(logits: logits)
        eval(picked)
        let pickedList = picked.asArray(Int.self)
        var ok = 0
        while ok < draft.count, pickedList[ok] == draft[ok] { ok += 1 }
        let out = Array(draft.prefix(ok)) + [pickedList[ok]]
        pending.append(contentsOf: out)
        history.append(contentsOf: out)
        // Drop the rejected guesses from the cache; the last picked token is fed next round.
        if draft.count - ok > 0 { _ = trimPromptCache(cache, numTokens: draft.count - ok) }
        y = .init(tokens: MLXArray([Int32(pickedList[ok])]).asType(y.tokens.dtype))
        passes += 1
        drafted += draft.count
        accepted += ok
    }

    mutating func next() -> Int? {
        if tokenCount >= maxTokens { return nil }
        if pendingIndex < pending.count {
            let t = pending[pendingIndex]
            pendingIndex += 1
            tokenCount += 1
            if pendingIndex == pending.count, needsFeed {
                // The prefill's token was handed out; the next round feeds it.
                needsFeed = false
            }
            return t
        }
        pending.removeAll(keepingCapacity: true)
        pendingIndex = 0
        round()
        guard !pending.isEmpty else { return nil }
        pendingIndex = 1
        tokenCount += 1
        return pending[0]
    }
}
#endif
