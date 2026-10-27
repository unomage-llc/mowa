import XCTest
@testable import MowaCore

final class WordLanguageModelTests: XCTestCase {
    /// Writes a model in the scripts/build-lm.py format: words with unigram counts, bigrams with counts.
    static func makeModel(_ unigrams: [String: Double], _ bigrams: [(String, String, Double)]) throws -> WordLanguageModel {
        let words = unigrams.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        let index = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })
        let total = unigrams.values.reduce(0, +)
        var data = Data("MOWALM1\0".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func f32(_ v: Double) { var x = Float(v).bitPattern.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func f64(_ v: Double) { var x = v.bitPattern.littleEndian; data.append(Data(bytes: &x, count: 8)) }
        var blob = [UInt8](), offsets = [0]
        for w in words { blob += Array(w.utf8); offsets.append(blob.count) }
        var byCtx: [Int: [(Int, Double)]] = [:]
        var ctxTotal: [Int: Double] = [:]
        for (a, b, c) in bigrams { byCtx[index[a]!, default: []].append((index[b]!, c)); ctxTotal[index[a]!, default: 0] += c }
        var ctxStart = [0], lambdas = [Double](), next = [Int](), pbi = [Double]()
        for i in words.indices {
            let list = (byCtx[i] ?? []).sorted { $0.0 < $1.0 }
            let c = ctxTotal[i] ?? 0
            lambdas.append(c > 0 ? c / (c + Double(list.count)) : 0)
            for (b, n) in list { next.append(b); pbi.append(n / c) }
            ctxStart.append(next.count)
        }
        u32(words.count); u32(next.count); u32(blob.count)
        offsets.forEach(u32); data.append(contentsOf: blob)
        var cum = 0.0
        words.forEach { f32(unigrams[$0]! / total) }
        f64(0); for w in words { cum += unigrams[w]! / total; f64(cum) }
        ctxStart.forEach(u32); lambdas.forEach(f32); next.forEach(u32); pbi.forEach(f32)
        return try WordLanguageModel(data: data)
    }

    func testNormalize() {
        XCTAssertEqual(WordLanguageModel.normalize("Przesyłam,"), "przesyłam")
        XCTAssertEqual(WordLanguageModel.normalize("«Ёжик»"), "ежик")
        XCTAssertEqual(WordLanguageModel.normalize("l’année"), "l'année")
        XCTAssertEqual(WordLanguageModel.normalize("anna@gmail.com"), "")
        XCTAssertEqual(WordLanguageModel.normalize("..."), "")
    }

    func testPrefixMassAndContext() throws {
        let lm = try Self.makeModel(["ale": 10, "może": 30, "morze": 5, "przesyłam": 8, "w": 40, "jest": 7],
                                    [("ale", "morze", 4), ("ale", "jest", 1)])
        XCTAssertEqual(lm.wordCount, 6)
        XCTAssertEqual(lm.mass(prefix: "", context: nil), 1, accuracy: 1e-6)
        XCTAssertEqual(lm.mass(prefix: "mo", context: nil), 35.0 / 100, accuracy: 1e-6)
        XCTAssertEqual(lm.mass(prefix: "może", context: nil, exact: true), 0.3, accuracy: 1e-6)
        XCTAssertEqual(lm.mass(prefix: "przesyłem", context: nil), 0)
        // After "ale", the bigram pulls "morze" up: λ = 5/7, P = λ·0.8 + (1-λ)·0.05.
        XCTAssertEqual(lm.mass(prefix: "morze", context: "ale", exact: true), 5.0 / 7 * 0.8 + 2.0 / 7 * 0.05, accuracy: 1e-5)
        XCTAssertNil(lm.index(of: "mor"))
        XCTAssertNotNil(lm.index(of: "morze"))
        XCTAssertThrowsError(try WordLanguageModel(data: Data("nope".utf8)))
    }

    func testPieceScorerPrefersKnownWordsAndLeavesUnknownWordsAlone() throws {
        let lm = try Self.makeModel(["ale": 10, "może": 30, "morze": 5, "przesyłam": 8, "w": 40, "jest": 7, "kasia": 1],
                                    [("ale", "morze", 4)])
        let pieces = [1: "\u{2581}prze", 2: "sył", 3: "am", 4: "em", 5: "\u{2581}w", 6: ",", 7: "\u{2581}Kub", 8: "rix", 9: "ix"]
        let s = PieceLanguageScorer(model: lm, pieces: pieces, weight: 0.3, maxLogitGap: 1.5)
        let am = try XCTUnwrap(s.logProbability(of: 3, after: [1, 2]))
        let em = try XCTUnwrap(s.logProbability(of: 4, after: [1, 2]))
        XCTAssertGreaterThan(am, em)                      // "przesyłam" known, "przesyłem" not
        XCTAssertEqual(em, -6, accuracy: 1e-6)
        XCTAssertNil(s.logProbability(of: 6, after: [1, 2, 3]))   // punctuation: no opinion
        // Inside a word the model doesn't know ("kub…"), continuations get no opinion: names stay.
        XCTAssertNil(s.logProbability(of: 8, after: [7]))
        XCTAssertNil(s.logProbability(of: 9, after: [7]))
    }
}
