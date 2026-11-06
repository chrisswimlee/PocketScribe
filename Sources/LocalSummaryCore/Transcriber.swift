import FluidAudio
import Foundation

/// A timestamped stretch of speech (roughly one sentence).
public struct TranscriptSegment: Codable, Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
}

public struct Transcript: Codable, Sendable, Equatable {
    public var text: String
    public var segments: [TranscriptSegment]
    public var audioDuration: TimeInterval
    public var processingTime: TimeInterval

    /// Transcript as "[mm:ss] sentence" lines, which is what the summarizer reads.
    public var timestampedText: String {
        if segments.isEmpty { return text }
        return segments.map { "[\(formatTimestamp($0.start))] \($0.text)" }.joined(separator: "\n")
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
            case .compiling: what = "Optimizing speech model for this Mac…"
            }
            progress?(p.fractionCompleted, what)
        }
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
        loadedModel = model
    }

    public func transcribe(fileAt url: URL, model: ASRModelChoice = .multilingual) async throws -> Transcript {
        try await prepare(model: model)
        guard let manager else { throw LocalSummaryError.asrNotReady }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &state)
        let words = buildWordTimings(from: result.tokenTimings ?? [])
        return Transcript(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: Self.sentences(from: words),
            audioDuration: result.duration,
            processingTime: result.processingTime
        )
    }

    /// Groups words into sentence-ish segments: split on terminal punctuation,
    /// on pauses longer than 1.5 s, or after ~40 words.
    static func sentences(from words: [WordTiming]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [WordTiming] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map { $0.word.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(.init(start: first.startTime, end: last.endTime, text: text)) }
            current.removeAll()
        }
        for w in words {
            if let prev = current.last, w.startTime - prev.endTime > 1.5 { flush() }
            current.append(w)
            let trimmed = w.word.trimmingCharacters(in: .whitespaces)
            if let c = trimmed.last, ".?!".contains(c) { flush() } else if current.count >= 40 { flush() }
        }
        flush()
        return out
    }
}

public enum LocalSummaryError: LocalizedError {
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
