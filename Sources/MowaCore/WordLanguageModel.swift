import Foundation

/// A word bigram language model (interpolated with unigrams, Witten-Bell weights) that can score
/// word *prefixes*: the probability mass of every word starting with a prefix, after a context word.
/// That is what lets a word model guide Parakeet, which emits word pieces (PieceLanguageScorer).
/// Files are built by scripts/build-lm.py (format described there); one per dictation language.
public final class WordLanguageModel: @unchecked Sendable {
    public let wordCount: Int
    public let bigramCount: Int
    private let offsets: [UInt32]
    private let blob: [UInt8]
    private let uniCum: [Double]
    private let ctxStart: [UInt32]
    private let lambda: [Float]
    private let next: [UInt32]
    private let pBi: [Float]

    public enum LoadError: Error { case badFile }

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        var reader = Reader(data: data)
        guard data.count >= 20, reader.bytes(8) == Array("MOWALM1\0".utf8) else { throw LoadError.badFile }
        let n = Int(try reader.u32()), nb = Int(try reader.u32()), blobBytes = Int(try reader.u32())
        offsets = try reader.u32s(n + 1)
        blob = try reader.raw(blobBytes)
        _ = try reader.f32s(n)                 // plain unigram probabilities (uniCum carries them)
        uniCum = try reader.f64s(n + 1)
        ctxStart = try reader.u32s(n + 1)
        lambda = try reader.f32s(n)
        next = try reader.u32s(nb)
        pBi = try reader.f32s(nb)
        guard reader.offset == data.count, offsets.last.map({ Int($0) }) == blobBytes,
              ctxStart.last.map({ Int($0) }) == nb else { throw LoadError.badFile }
        wordCount = n
        bigramCount = nb
    }

    // MARK: Normalisation (must match scripts/build-lm.py `normalize`)

    /// Lowercased, ’ → ', ё → е, letters/digits at both ends, only ' or - inside. "" when not a word.
    public static func normalize(_ token: String) -> String {
        let t = token.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "ё", with: "е")
        var chars = Array(t)
        while let f = chars.first, !(f.isLetter || f.isNumber) { chars.removeFirst() }
        while let l = chars.last, !(l.isLetter || l.isNumber) { chars.removeLast() }
        guard !chars.isEmpty, chars.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" }) else { return "" }
        return String(chars)
    }

    // MARK: Lookup

    /// Index of the exact word, or nil.
    public func index(of word: String) -> Int? {
        let key = Array(word.utf8)
        let i = lowerBound(key)
        guard i < wordCount, compare(i, key) == 0 else { return nil }
        return i
    }

    /// Probability mass of the words starting with `prefix` ("" = all words) after `context`
    /// (nil = no context: unigrams only). With `exact`, only the word `prefix` itself.
    public func mass(prefix: String, context: String?, exact: Bool = false) -> Double {
        let lo: Int, hi: Int
        if exact {
            guard let i = index(of: prefix) else { return 0 }
            (lo, hi) = (i, i + 1)
        } else {
            let key = Array(prefix.utf8)
            lo = lowerBound(key)
            hi = lowerBound(key + [0xFF], from: lo)
        }
        guard hi > lo else { return 0 }
        let uni = uniCum[hi] - uniCum[lo]
        guard let context, let c = index(of: context), lambda[c] > 0 else { return uni }
        let a = Int(ctxStart[c]), b = Int(ctxStart[c + 1])
        var bi = 0.0
        if b > a {
            var i = lowerBoundNext(UInt32(lo), a, b)
            while i < b, next[i] < UInt32(hi) { bi += Double(pBi[i]); i += 1 }
        }
        let l = Double(lambda[c])
        return l * bi + (1 - l) * uni
    }

    private func compare(_ i: Int, _ key: [UInt8]) -> Int {
        let s = Int(offsets[i]), e = Int(offsets[i + 1])
        var j = 0
        while s + j < e, j < key.count {
            let a = blob[s + j], b = key[j]
            if a != b { return a < b ? -1 : 1 }
            j += 1
        }
        let la = e - s
        return la == key.count ? 0 : (la < key.count ? -1 : 1)
    }

    /// First word index whose bytes are >= key.
    private func lowerBound(_ key: [UInt8], from: Int = 0) -> Int {
        var lo = from, hi = wordCount
        while lo < hi {
            let mid = (lo + hi) / 2
            if compare(mid, key) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func lowerBoundNext(_ value: UInt32, _ from: Int, _ to: Int) -> Int {
        var lo = from, hi = to
        while lo < hi {
            let mid = (lo + hi) / 2
            if next[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: Binary reader

    private struct Reader {
        let data: Data
        var offset = 0
        init(data: Data) { self.data = data }

        mutating func bytes(_ n: Int) -> [UInt8] {
            guard offset + n <= data.count else { return [] }
            defer { offset += n }
            return [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + n])
        }
        mutating func raw(_ n: Int) throws -> [UInt8] {
            guard offset + n <= data.count else { throw LoadError.badFile }
            return bytes(n)
        }
        mutating func u32() throws -> UInt32 { try u32s(1)[0] }
        mutating func u32s(_ n: Int) throws -> [UInt32] { try values(n, UInt32.self).map { UInt32(littleEndian: $0) } }
        mutating func f32s(_ n: Int) throws -> [Float] {
            try values(n, UInt32.self).map { Float(bitPattern: UInt32(littleEndian: $0)) }
        }
        mutating func f64s(_ n: Int) throws -> [Double] {
            try values(n, UInt64.self).map { Double(bitPattern: UInt64(littleEndian: $0)) }
        }
        private mutating func values<T: FixedWidthInteger>(_ n: Int, _: T.Type) throws -> [T] {
            let size = n * MemoryLayout<T>.size
            guard n >= 0, offset + size <= data.count else { throw LoadError.badFile }
            var out = [T](repeating: 0, count: n)
            out.withUnsafeMutableBytes { dst in
                data.copyBytes(to: dst, from: data.startIndex + offset ..< data.startIndex + offset + size)
            }
            offset += size
            return out
        }
    }
}

/// Scores Parakeet's next word piece with a WordLanguageModel (shallow fusion, see TdtFusion in the
/// vendored FluidAudio). A piece either continues the current word ("przesył" + "am") — scored
/// log M(prefix+piece) / M(prefix) — or starts a new one ("▁w") — scored as the chance the current
/// word is complete times the mass of the new prefix after it. Inside a word the model doesn't know
/// (a name), continuations get no score (nil), so names are left alone; punctuation and digits get none either
/// (TdtFusion never lets a candidate without a score win, nor rescores a token without one).
public final class PieceLanguageScorer: @unchecked Sendable {
    public let model: WordLanguageModel
    public let weight: Float
    public let maxLogitGap: Float
    private let pieces: [Int: String]
    static let floor: Double = -6
    private let lock = NSLock()
    private var cache: (key: [Int], state: State)?

    public init(model: WordLanguageModel, pieces: [Int: String], weight: Float, maxLogitGap: Float) {
        self.model = model
        self.pieces = pieces
        self.weight = weight
        self.maxLogitGap = maxLogitGap
    }

    struct State {
        var partial: String        // normalised current (unfinished) word, "" at a word boundary
        var partialRaw: String
        var context: String?       // normalised previous word, nil at a sentence start
        var partialMass: Double    // M(partial | context)
    }

    public func logProbability(of token: Int, after history: [Int]) -> Float? {
        guard let piece = pieces[token] else { return nil }
        let startsWord = piece.hasPrefix("\u{2581}")
        let body = piece.replacingOccurrences(of: "\u{2581}", with: "")
        let bodyNorm = body.lowercased().replacingOccurrences(of: "ё", with: "е")
        guard !bodyNorm.isEmpty, bodyNorm.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }),
              bodyNorm.contains(where: \.isLetter) else { return nil }
        let s = state(history)
        var score = 0.0
        if !startsWord {
            guard !s.partial.isEmpty, s.partial == s.partialRaw.lowercased().replacingOccurrences(of: "ё", with: "е"),
                  s.partialMass > 0 else { return nil }
            let m = model.mass(prefix: s.partial + bodyNorm, context: s.context)
            score = m > 0 ? max(Self.floor, log(m / s.partialMass)) : Self.floor
        } else {
            var nextContext = s.context
            if !s.partial.isEmpty, s.partialMass > 0 {
                let whole = model.mass(prefix: s.partial, context: s.context, exact: true)
                score += whole > 0 ? max(Self.floor, log(whole / s.partialMass)) : Self.floor
            }
            if !s.partialRaw.isEmpty {
                nextContext = Self.endsSentence(s.partialRaw) || s.partial.isEmpty ? nil : s.partial
            }
            let m = model.mass(prefix: bodyNorm, context: nextContext)
            score += m > 0 ? max(Self.floor, log(m)) : Self.floor
        }
        return Float(max(2 * Self.floor, score))
    }

    static func endsSentence(_ raw: String) -> Bool {
        guard let last = raw.last else { return false }
        return ".!?…".contains(last)
    }

    private func state(_ history: [Int]) -> State {
        lock.lock(); defer { lock.unlock() }
        let key = Array(history.suffix(24))
        if let cache, cache.key == key { return cache.state }
        let text = key.compactMap { pieces[$0] }.joined().replacingOccurrences(of: "\u{2581}", with: " ")
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // A trailing space means the last piece closed a word: no partial word.
        let partialRaw = words.popLast() ?? ""
        let completed = words.filter { !$0.isEmpty }
        var context: String? = nil
        if let prev = completed.last, !Self.endsSentence(prev) {
            let n = WordLanguageModel.normalize(prev)
            context = n.isEmpty ? nil : n
        }
        let partial = WordLanguageModel.normalize(partialRaw)
        let mass = partial.isEmpty ? 0 : model.mass(prefix: partial, context: context)
        let state = State(partial: partial, partialRaw: partialRaw, context: context, partialMass: mass)
        cache = (key, state)
        return state
    }
}
