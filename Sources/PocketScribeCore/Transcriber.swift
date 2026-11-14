import FluidAudio
import Foundation

/// A timestamped stretch of speech (roughly one sentence).
public struct TranscriptSegment: Codable, Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// 1-based speaker number from speaker diarization, or nil when speakers weren't labeled.
    public var speaker: Int?

    public init(start: TimeInterval, end: TimeInterval, text: String, speaker: Int? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

public struct Transcript: Codable, Sendable, Equatable {
    public var text: String
    public var segments: [TranscriptSegment]
    public var audioDuration: TimeInterval
    public var processingTime: TimeInterval

    public init(text: String, segments: [TranscriptSegment], audioDuration: TimeInterval, processingTime: TimeInterval) {
        self.text = text
        self.segments = segments
        self.audioDuration = audioDuration
        self.processingTime = processingTime
    }

    /// Speaker numbers in the order they first speak (empty when speakers weren't labeled).
    public var speakers: [Int] {
        var seen: [Int] = []
        for s in segments { if let n = s.speaker, !seen.contains(n) { seen.append(n) } }
        return seen
    }

    /// Transcript as "[mm:ss] sentence" lines, which is what the summarizer reads.
    /// With speaker labels: "[mm:ss] Speaker 1: sentence".
    public var timestampedText: String { timestampedText(speakerNames: nil) }

    public func timestampedText(speakerNames: [Int: String]?) -> String {
        if segments.isEmpty { return text }
        return segments.map { seg in
            let who = seg.speaker.map { Speakers.name($0, in: speakerNames) + ": " } ?? ""
            return "[\(formatTimestamp(seg.start))] \(who)\(seg.text)"
        }.joined(separator: "\n")
    }
}

/// Default speaker labels ("Speaker 1") and the user's renames.
public enum Speakers {
    /// Recordings shorter than this are one quick thought, so they skip speaker labeling.
    /// Anything longer is checked, because a short recording can still be a meeting.
    public static let minimumDuration: TimeInterval = 30

    public static func defaultName(_ n: Int) -> String { "Speaker \(n)" }

    public static func name(_ n: Int, in names: [Int: String]?) -> String {
        if let custom = names?[n]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return custom }
        return defaultName(n)
    }

    /// Replaces "Speaker 2" with the name the user gave, e.g. in a summary written before the rename.
    public static func apply(_ names: [Int: String]?, to text: String) -> String {
        guard let names, !names.isEmpty,
              let re = try? NSRegularExpression(pattern: #"\bSpeaker (\d+)\b"#) else { return text }
        var out = text
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(m.range, in: text), let num = Range(m.range(at: 1), in: text),
                  let n = Int(text[num]) else { continue }
            let replacement = name(n, in: names)
            out.replaceSubrange(whole, with: replacement)
        }
        return out
    }
}

public func formatTimestamp(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.down))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}

public enum ASRModelChoice: String, CaseIterable, Sendable, Codable {
    /// Parakeet TDT v3: multilingual (25 European languages). Default.
    case multilingual = "v3"
    /// Parakeet TDT v2: English only, slightly higher recall on English.
    case english = "v2"

    var version: AsrModelVersion { self == .english ? .v2 : .v3 }
}

/// Wraps FluidAudio's Parakeet ASR. Models download once (~500 MB) to
/// ~/Library/Application Support/FluidAudio and run fully offline afterwards.
public actor Transcriber {
    private var manager: AsrManager?
    private var loadedModel: ASRModelChoice?

    public init() {}

    /// Downloads (first run only) and loads the speech model.
    /// `progress` receives a 0...1 fraction and a short description of the phase.
    public func prepare(
        model: ASRModelChoice = .multilingual,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        if manager != nil, loadedModel == model { return }
        let models = try await AsrModels.downloadAndLoad(version: model.version) { p in
            let what: String
            switch p.phase {
            case .listing: what = "Checking speech model…"
            case .downloading(let done, let total): what = "Downloading speech model (\(done)/\(total) files)…"
            case .compiling: what = "Optimizing speech model for this device…"
            }
            progress?(p.fractionCompleted, what)
        }
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
        loadedModel = model
    }

    /// - Parameter labelSpeakers: also work out who spoke when (speaker diarization, on device).
    ///   Only runs for recordings of at least `Speakers.minimumDuration`.
    ///   If it fails, the transcript is returned without labels rather than failing the whole job.
    public func transcribe(
        fileAt url: URL, model: ASRModelChoice = .multilingual, labelSpeakers: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Transcript {
        try await prepare(model: model)
        guard let manager else { throw PocketScribeError.asrNotReady }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &state)
        let words = buildWordTimings(from: result.tokenTimings ?? [])

        var speakerOfWord: [Int?] = Array(repeating: nil, count: words.count)
        if labelSpeakers, result.duration >= Speakers.minimumDuration, !words.isEmpty {
            try Task.checkCancellation()
            progress?("Finding who's speaking…")
            if let turns = try? await diarizer.speakerTurns(fileAt: url) {
                speakerOfWord = Self.assignSpeakers(words: words, turns: turns)
            }
        }
        return Transcript(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: Self.sentences(from: words, speakers: speakerOfWord),
            audioDuration: result.duration,
            processingTime: result.processingTime
        )
    }

    private let diarizer = SpeakerDiarizer()

    /// Gives each word the speaker whose turn overlaps it most (or the nearest turn within 1 s),
    /// numbered 1, 2, 3… in the order people first speak. Returns all nil when only one voice was heard.
    static func assignSpeakers(words: [WordTiming], turns: [SpeakerTurn]) -> [Int?] {
        guard !turns.isEmpty else { return Array(repeating: nil, count: words.count) }
        var raw: [String?] = []
        var previous: String?
        for w in words {
            var best: (id: String, overlap: Double)?
            var nearest: (id: String, distance: Double)?
            for t in turns {
                let overlap = min(w.endTime, t.end) - max(w.startTime, t.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (t.speakerId, overlap) }
                let mid = (w.startTime + w.endTime) / 2
                let distance = mid < t.start ? t.start - mid : (mid > t.end ? mid - t.end : 0)
                if distance < (nearest?.distance ?? .infinity) { nearest = (t.speakerId, distance) }
            }
            let id = best?.id ?? (nearest.flatMap { $0.distance <= 1 ? $0.id : nil }) ?? previous
            raw.append(id)
            if id != nil { previous = id }
        }
        var numbers: [String: Int] = [:]
        for case let id? in raw where numbers[id] == nil { numbers[id] = numbers.count + 1 }
        guard numbers.count > 1 else { return Array(repeating: nil, count: words.count) }
        return raw.map { $0.flatMap { numbers[$0] } }
    }

    /// Groups words into sentence-ish segments: split on terminal punctuation,
    /// on pauses longer than 1.5 s, after ~40 words, or when the speaker changes.
    static func sentences(from words: [WordTiming], speakers: [Int?]? = nil) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [WordTiming] = []
        var currentSpeakers: [Int] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map { $0.word.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            // Majority speaker of the words in this segment.
            let speaker = Dictionary(grouping: currentSpeakers, by: { $0 }).max { $0.value.count < $1.value.count }?.key
            if !text.isEmpty { out.append(.init(start: first.startTime, end: last.endTime, text: text, speaker: speaker)) }
            current.removeAll()
            currentSpeakers.removeAll()
        }
        var lastSpeaker: Int?
        for (i, w) in words.enumerated() {
            let speaker = speakers.flatMap { i < $0.count ? $0[i] : nil }
            if let prev = current.last, w.startTime - prev.endTime > 1.5 { flush() }
            // A new speaker starts a new segment. A one-word blip of another voice doesn't.
            if let s = speaker {
                if let l = lastSpeaker, s != l {
                    let nextSame = speakers.flatMap { i + 1 < $0.count ? $0[i + 1] : nil } == s
                    if nextSame || i + 1 == words.count {
                        flush()
                        lastSpeaker = s
                    }
                } else {
                    lastSpeaker = s
                }
            }
            current.append(w)
            if let s = speaker { currentSpeakers.append(s) }
            let trimmed = w.word.trimmingCharacters(in: .whitespaces)
            if let c = trimmed.last, ".?!".contains(c) { flush() } else if current.count >= 40 { flush() }
        }
        flush()
        return out
    }
}

/// One stretch of audio where a single person is talking.
public struct SpeakerTurn: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var speakerId: String
    public init(start: TimeInterval, end: TimeInterval, speakerId: String) {
        self.start = start
        self.end = end
        self.speakerId = speakerId
    }
}

/// Wraps FluidAudio's offline speaker diarization (pyannote segmentation + WeSpeaker embeddings
/// + VBx clustering on Core ML). Models (~30 MB) download once and then run fully offline.
public actor SpeakerDiarizer {
    private var manager: OfflineDiarizerManager?

    public init() {}

    public func prepare() async throws {
        if manager != nil { return }
        let m = OfflineDiarizerManager(config: .default)
        try await m.prepareModels()
        manager = m
    }

    public func speakerTurns(fileAt url: URL) async throws -> [SpeakerTurn] {
        try await prepare()
        guard let manager else { return [] }
        let result = try await manager.process(url)
        return result.segments.map {
            SpeakerTurn(start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds), speakerId: $0.speakerId)
        }
        .sorted { $0.start < $1.start }
    }
}

public enum PocketScribeError: LocalizedError {
    case asrNotReady
    case engineUnavailable(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .asrNotReady: return "Speech model is not loaded."
        case .engineUnavailable(let why): return "Summarizer unavailable: \(why)"
        case .badResponse(let why): return "Summarizer returned an unexpected response: \(why)"
        }
    }
}
