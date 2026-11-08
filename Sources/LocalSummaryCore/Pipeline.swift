import Foundation

public enum PipelineStage: Sendable, Equatable {
    case loadingSpeechModel
    case transcribing
    case summarizing(String)
    case done
}

public struct SummaryResult: Codable, Sendable {
    public var sourceName: String
    public var createdAt: Date
    public var transcript: Transcript
    public var summary: String
    public var engineName: String

    public var markdown: String {
        """
        # \(sourceName)

        _\(createdAt.formatted(date: .abbreviated, time: .shortened)) · \
        \(formatTimestamp(transcript.audioDuration)) of audio · summarized by \(engineName)_

        \(summary)

        ---

        ## Transcript

        \(transcript.timestampedText)
        """
    }
}

/// audio file → transcript → summary, all on this Mac.
public struct Pipeline: Sendable {
    public let transcriber: Transcriber
    public let summarizer: Summarizer
    public let asrModel: ASRModelChoice
    public let labelSpeakers: Bool

    public init(
        transcriber: Transcriber = Transcriber(), engine: SummaryEngine, asrModel: ASRModelChoice = .multilingual,
        labelSpeakers: Bool = true
    ) {
        self.transcriber = transcriber
        self.summarizer = Summarizer(engine: engine)
        self.asrModel = asrModel
        self.labelSpeakers = labelSpeakers
    }

    public func run(audio url: URL, stage: (@Sendable (PipelineStage) -> Void)? = nil) async throws -> SummaryResult {
        stage?(.loadingSpeechModel)
        try await transcriber.prepare(model: asrModel)
        stage?(.transcribing)
        let transcript = try await transcriber.transcribe(fileAt: url, model: asrModel, labelSpeakers: labelSpeakers)
        stage?(.summarizing("Summarizing…"))
        let summary: String
        if transcript.text.isEmpty {
            summary = "_No speech detected._"
        } else {
            summary = try await summarizer.summarize(transcript) { p in
                switch p {
                case .summarizingChunk(let i, let n): stage?(.summarizing("Reading part \(i) of \(n)…"))
                case .combining: stage?(.summarizing("Writing summary…"))
                }
            }
        }
        stage?(.done)
        return SummaryResult(
            sourceName: url.deletingPathExtension().lastPathComponent,
            createdAt: Date(), transcript: transcript, summary: summary,
            engineName: summarizer.engine.displayName)
    }
}
