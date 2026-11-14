import Foundation

/// How a recording is written up: a cleaned-up note in the speaker's own voice, or a
/// meeting summary with action items, decisions and links to the moments they came from.
public enum SummaryStyle: String, Codable, Sendable, CaseIterable {
    case note, meeting
}

/// What `Summarizer.write` produced for a recording.
public enum WrittenSummary: Sendable {
    case note(VoiceNote)
    case meeting(String)
}

extension Transcript {
    /// How many people really take part: speakers who say at least 10% of the words
    /// (and at least 15 words). A one-sentence blip or a misheard cough doesn't count.
    public var conversationSpeakerCount: Int {
        var words: [Int: Int] = [:]
        var total = 0
        for seg in segments {
            let n = seg.text.split(whereSeparator: \.isWhitespace).count
            total += n
            if let s = seg.speaker { words[s, default: 0] += n }
        }
        guard total > 0 else { return 0 }
        return words.values.filter { $0 >= 15 && Double($0) >= 0.1 * Double(total) }.count
    }
}

extension Summarizer {
    /// Picks note or meeting from what was recorded, not only from how long it is:
    /// two or more people talking is a meeting however short it is, and a long recording is
    /// summarized like a meeting even when one person talks (a lecture, a long memo).
    public static func automaticStyle(for transcript: Transcript) -> SummaryStyle {
        if transcript.audioDuration >= voiceNoteMaxDuration { return .meeting }
        if transcript.conversationSpeakerCount >= 2 { return .meeting }
        return .note
    }

    /// Writes up a recording as a note or a meeting summary.
    /// - Parameter style: the user's choice; nil picks one automatically. When picked
    ///   automatically, a short recording the note writer recognizes as a meeting is
    ///   summarized as one after all.
    public func write(
        _ transcript: Transcript, style: SummaryStyle? = nil,
        progress: (@Sendable (SummaryProgress) -> Void)? = nil
    ) async throws -> WrittenSummary {
        if transcript.text.isEmpty { return .meeting("_No speech detected._") }
        let chosen = style ?? Self.automaticStyle(for: transcript)
        if chosen == .note {
            let note = try await voiceNote(from: transcript)
            let looksLikeMeeting = note.kind == .meeting && transcript.audioDuration >= 60
            if style != nil || !looksLikeMeeting { return .note(note) }
            try Task.checkCancellation()
        }
        return .meeting(try await summarize(transcript, progress: progress))
    }
}
