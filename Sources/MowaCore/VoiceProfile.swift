import Foundation

/// Each language can have two recordings, made with two different microphones (for example the
/// Mac's own and headphones): a different microphone changes how a voice sounds to the speaker
/// model almost as much as a different person does.
public enum VoiceSlot: String, Codable, Sendable, CaseIterable, Identifiable {
    case first
    case second
    public var id: String { rawValue }
}

/// One enrollment reading: the averaged speaker embedding of a text read aloud.
public struct VoiceSample: Codable, Sendable, Identifiable, Equatable {
    /// nil = recorded by Mowa 1.0.30 or earlier, before recordings had a language.
    public var language: DictationLanguage?
    public var slot: VoiceSlot
    /// The microphone it was recorded with (name shown in Settings, UID to preselect it again).
    public var micName: String?
    public var micUID: String?
    public var vector: [Float]
    public var created: Date
    public var seconds: Double

    public var id: String { "\(language?.rawValue ?? "earlier")-\(slot.rawValue)" }

    public init(language: DictationLanguage?, slot: VoiceSlot, micName: String? = nil, micUID: String? = nil,
                vector: [Float], created: Date = Date(), seconds: Double) {
        self.language = language
        self.slot = slot
        self.micName = micName
        self.micUID = micUID
        self.vector = vector
        self.created = created
        self.seconds = seconds
    }
}

/// The user's voiceprint for "Ignore other people's voices": all their recordings (one per
/// language and microphone). A piece of speech is the user's if it matches any of them.
/// Reads both this format (version 2) and the single-vector one of Mowa 1.0.30 and earlier.
public struct VoiceProfile: Codable, Sendable {
    public static let currentVersion = 2
    public static let vectorSize = 256
    /// Two per language.
    public static let maxSamples = DictationLanguage.allCases.count * VoiceSlot.allCases.count

    public var version = VoiceProfile.currentVersion
    public var model = "wespeaker-resnet34"
    public var samples: [VoiceSample]

    public init(samples: [VoiceSample] = []) {
        self.samples = samples
    }

    public var isEmpty: Bool { samples.isEmpty }

    public func sample(language: DictationLanguage?, slot: VoiceSlot) -> VoiceSample? {
        samples.first { $0.language == language && $0.slot == slot }
    }

    /// Adds a recording, replacing the earlier one in the same language and slot.
    public mutating func upsert(_ sample: VoiceSample) {
        samples.removeAll { $0.language == sample.language && $0.slot == sample.slot }
        samples.append(sample)
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
    }

    public mutating func remove(language: DictationLanguage?, slot: VoiceSlot) {
        samples.removeAll { $0.language == language && $0.slot == slot }
    }

    /// How much a piece of speech sounds like the user: its best match among the recordings.
    public func score(_ embedding: [Float]) -> Float {
        samples.map { VoiceMath.cosine(embedding, $0.vector) }.max() ?? 0
    }

    /// Languages with at least one recording, in Mowa's language order.
    public var languages: [DictationLanguage] {
        DictationLanguage.allCases.filter { lang in samples.contains { $0.language == lang } }
    }

    private enum CodingKeys: String, CodingKey { case version, model, samples, vector, created, seconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = (try? c.decode(String.self, forKey: .model)) ?? "wespeaker-resnet34"
        if let list = try? c.decode([VoiceSample].self, forKey: .samples) {
            samples = list
        } else if let vector = try? c.decode([Float].self, forKey: .vector) {
            // Version 1: a single voiceprint, language and microphone unknown.
            samples = [VoiceSample(language: nil, slot: .first, vector: vector,
                                   created: (try? c.decode(Date.self, forKey: .created)) ?? Date(),
                                   seconds: (try? c.decode(Double.self, forKey: .seconds)) ?? 0)]
        } else {
            samples = []
        }
        samples = samples.filter { $0.vector.count == Self.vectorSize }
        version = Self.currentVersion
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(model, forKey: .model)
        try c.encode(samples, forKey: .samples)
    }
}

public enum VoiceMath {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let norm = (na * nb).squareRoot()
        return norm > 0 ? dot / norm : 0
    }
}
