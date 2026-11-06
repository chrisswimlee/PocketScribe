import Foundation

/// A short spoken note turned into a clean written one.
public struct VoiceNote: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case note, idea, todo, journal, meeting
        public var label: String {
            switch self {
            case .note: return "Note"
            case .idea: return "Idea"
            case .todo: return "To-do"
            case .journal: return "Journal"
            case .meeting: return "Meeting"
            }
        }
        public var symbol: String {
            switch self {
            case .note: return "note.text"
            case .idea: return "lightbulb"
            case .todo: return "checklist"
            case .journal: return "book"
            case .meeting: return "person.2"
            }
        }
    }

    public var title: String
    public var kind: Kind
    public var tags: [String]
    /// Markdown body. To-dos are "- [ ] …" lines.
    public var body: String
}

extension Summarizer {
    /// Recordings shorter than this are treated as voice notes (cleaned up, not summarized).
    public static let voiceNoteMaxDuration: TimeInterval = 180

    static let noteSystem = """
    You turn spoken voice memos into clean written notes. The input is a raw speech-to-text \
    transcript: remove filler words, false starts and repetition, fix punctuation and obvious \
    recognition errors, but keep the speaker's meaning, wording and first-person voice. \
    Never add facts that were not said. Write in the same language as the transcript.
    """

    static func notePrompt(_ transcript: String) -> String {
        """
        Rewrite this voice memo as a note. Reply in exactly this format and nothing else:

        Title: <3 to 7 word title>
        Type: <one of: note, idea, todo, journal, meeting>
        Tags: <1 to 3 short lowercase tags, comma separated>
        ---
        <the cleaned-up note in Markdown. Use short paragraphs. Put every task the speaker \
        mentions as a checkbox line like "- [ ] call the dentist". Use bullet points for lists.>

        Transcript:
        \(transcript)
        """
    }

    /// Cleans up a short dictation into a titled, typed, tagged note.
    public func voiceNote(from transcript: Transcript) async throws -> VoiceNote {
        let raw = try await engine.complete(system: Self.noteSystem, prompt: Self.notePrompt(transcript.text))
        return Self.parseNote(raw, fallbackText: transcript.text)
    }

    static func parseNote(_ raw: String, fallbackText: String) -> VoiceNote {
        var title = "", kind = VoiceNote.Kind.note, tags: [String] = []
        var bodyLines: [String] = []
        var inBody = false
        for line in raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if inBody { bodyLines.append(line); continue }
            let lower = t.lowercased().replacingOccurrences(of: "*", with: "")
            if lower.hasPrefix("title:") {
                title = String(t.drop(while: { $0 != ":" }).dropFirst())
            } else if lower.hasPrefix("type:") {
                let v = String(lower.drop(while: { $0 != ":" }).dropFirst()).trimmingCharacters(in: .whitespaces)
                kind = VoiceNote.Kind.allCases.first { v.hasPrefix($0.rawValue) } ?? (v.hasPrefix("to-do") ? .todo : .note)
            } else if lower.hasPrefix("tags:") {
                tags = String(lower.drop(while: { $0 != ":" }).dropFirst())
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " #")) }
                    .filter { !$0.isEmpty }
                    .prefix(3).map { $0 }
            } else if t.hasPrefix("---") {
                inBody = true
            } else {
                // Model skipped the "---" separator: keep non-header lines as the body.
                bodyLines.append(line)
            }
        }
        var body = tidy(bodyLines.joined(separator: "\n"))
            .replacingOccurrences(of: "- • ", with: "- ")
            .replacingOccurrences(of: "\n• ", with: "\n- ")
        if body.isEmpty { body = fallbackText }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \"'*#."))
        return VoiceNote(title: String(title.prefix(80)), kind: kind, tags: tags, body: body)
    }
}
