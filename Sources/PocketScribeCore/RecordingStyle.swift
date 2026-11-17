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

    /// True when at least two people really take turns: each says at least a fifth of the words
    /// and speaks up at least twice with a full sentence or more. The speaker labeler sometimes
    /// splits one person's voice into two, and that usually gives one dominant "speaker" and a
    /// second with a few stray stretches, so a solo memo doesn't pass this.
    public var hasBackAndForth: Bool {
        var words: [Int: Int] = [:]
        var turns: [Int: Int] = [:]
        var total = 0
        var current: (speaker: Int, words: Int)?
        func closeTurn() {
            if let c = current, c.words >= 5 { turns[c.speaker, default: 0] += 1 }
        }
        for seg in segments {
            let n = seg.text.split(whereSeparator: \.isWhitespace).count
            total += n
            guard let s = seg.speaker else { continue }
            words[s, default: 0] += n
            if current?.speaker == s { current!.words += n } else { closeTurn(); current = (s, n) }
        }
        closeTurn()
        guard total > 0 else { return false }
        return words.filter { s, w in w >= 15 && Double(w) >= 0.2 * Double(total) && (turns[s] ?? 0) >= 2 }.count >= 2
    }
}

extension Summarizer {
    /// Picks note or meeting from what was recorded, not only from how long it is:
    /// - a long recording is summarized like a meeting even when one person talks (a lecture, a long memo);
    /// - a short one is a meeting when people clearly take turns and either three or more of them
    ///   talk, or they introduce or address each other by name.
    /// A short back-and-forth between two unnamed voices could be a real chat or one person's
    /// voice split in two by the speaker labeler, so it starts as a note and `write` lets the
    /// note writer's own reading ("this is a meeting") decide.
    public static func automaticStyle(for transcript: Transcript) -> SummaryStyle {
        if transcript.audioDuration >= voiceNoteMaxDuration { return .meeting }
        guard transcript.conversationSpeakerCount >= 2, transcript.hasBackAndForth else { return .note }
        if transcript.conversationSpeakerCount >= 3 || !Speakers.suggestedNames(in: transcript).isEmpty { return .meeting }
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
            let looksLikeMeeting = note.kind == .meeting && (transcript.audioDuration >= 60 || transcript.hasBackAndForth)
            if style != nil || !looksLikeMeeting { return .note(note) }
            try Task.checkCancellation()
        }
        return .meeting(try await summarize(transcript, progress: progress))
    }
}
