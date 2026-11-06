import Foundation

/// A local text-generation backend.
public protocol SummaryEngine: Sendable {
    var displayName: String { get }
    /// How much transcript text (in characters) fits in one request, leaving room for instructions and output.
    var maxChunkCharacters: Int { get }
    func complete(system: String, prompt: String) async throws -> String
}

public enum SummaryProgress: Sendable {
    case summarizingChunk(Int, of: Int)
    case combining
}

/// Map-reduce summarizer: short transcripts go in one pass; long ones are split
/// into chunks, each chunk is condensed into notes, then the notes are merged.
public struct Summarizer: Sendable {
    public let engine: SummaryEngine
    public init(engine: SummaryEngine) { self.engine = engine }

    static let system = """
    You turn raw speech-to-text transcripts into clear, faithful notes. \
    Transcripts may contain recognition errors, filler words and missing punctuation; \
    infer meaning sensibly but never invent facts, names or numbers that are not in the transcript. \
    Lines start with [mm:ss] timestamps. Write in the same language as the transcript.
    """

    static func finalPrompt(_ material: String, isNotes: Bool) -> String {
        """
        \(isNotes ? "Below are notes taken from consecutive parts of one recording." : "Below is the transcript of a recording.")
        Write a summary in Markdown with exactly these sections (omit a section only if it would be empty):

        ## TL;DR
        Two or three sentences.

        ## Key points
        Bullet list of the most important ideas, in order.

        ## Decisions
        Bullet list of anything that was decided or agreed.

        ## Action items
        Bullet list as "- [ ] Owner (if known): task (deadline if mentioned)".

        ## Notable moments
        Bullet list of up to 6 moments worth revisiting, each starting with its [mm:ss] timestamp.

        ---
        \(material)
        """
    }

    static func chunkPrompt(_ chunk: String, index: Int, total: Int) -> String {
        """
        This is part \(index) of \(total) of a longer transcript. \
        Write concise bullet-point notes covering every topic, fact, decision, number and action item in this part. \
        Keep the [mm:ss] timestamp of where each point is discussed. Do not add an introduction.

        ---
        \(chunk)
        """
    }

    public func summarize(
        _ transcript: Transcript,
        progress: (@Sendable (SummaryProgress) -> Void)? = nil
    ) async throws -> String {
        let lines = transcript.timestampedText.components(separatedBy: "\n")
        return try await reduce(lines: lines, isNotes: false, progress: progress)
    }

    private func reduce(
        lines: [String], isNotes: Bool, depth: Int = 0,
        progress: (@Sendable (SummaryProgress) -> Void)?
    ) async throws -> String {
        let full = lines.joined(separator: "\n")
        if full.count <= engine.maxChunkCharacters || depth >= 3 {
            progress?(.combining)
            let clipped = String(full.prefix(engine.maxChunkCharacters))
            return try await engine.complete(system: Self.system, prompt: Self.finalPrompt(clipped, isNotes: isNotes))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let chunks = Self.chunk(lines: lines, limit: engine.maxChunkCharacters)
        var notes: [String] = []
        for (i, chunk) in chunks.enumerated() {
            progress?(.summarizingChunk(i + 1, of: chunks.count))
            let n = try await engine.complete(
                system: Self.system, prompt: Self.chunkPrompt(chunk, index: i + 1, total: chunks.count))
            notes.append(n.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let noteLines = notes.joined(separator: "\n\n").components(separatedBy: "\n")
        return try await reduce(lines: noteLines, isNotes: true, depth: depth + 1, progress: progress)
    }

    /// Splits on line boundaries so no sentence is cut in half.
    static func chunk(lines: [String], limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in lines {
            if !current.isEmpty, current.count + line.count + 1 > limit {
                chunks.append(current)
                current = ""
            }
            if line.count > limit {
                // A single enormous line (e.g. no timings): hard-split it.
                var rest = Substring(line)
                while rest.count > limit {
                    chunks.append(String(rest.prefix(limit)))
                    rest = rest.dropFirst(limit)
                }
                current = String(rest)
            } else {
                current += current.isEmpty ? line : "\n" + line
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
