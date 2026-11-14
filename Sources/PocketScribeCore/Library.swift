import Foundation

// Shared by the Mac and iOS apps: the saved library item and the helpers that
// turn a summary into what the detail screen shows. Keeping these here means both
// apps read and write the same JSON and render summaries the same way.

/// One recording or imported file in the library.
public struct LibraryItem: Identifiable, Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case queued, processing, ready, failed }

    public var id: UUID
    public var title: String
    public var titleIsAutomatic: Bool
    public var createdAt: Date
    /// File name inside the app's Audio folder.
    public var audioFileName: String
    public var duration: TimeInterval?
    public var status: Status
    public var errorMessage: String?
    public var transcript: Transcript?
    public var summary: String?
    public var engineName: String?
    /// Indices (within the Action items section, or a voice note's tasks) the user ticked off.
    public var checkedActions: Set<Int>
    /// Set for short recordings that were turned into a voice note (nil = meeting-style summary).
    public var noteKind: VoiceNote.Kind?
    public var tags: [String]?
    /// Names the user gave to "Speaker 1", "Speaker 2"… (keyed by speaker number).
    public var speakerNames: [Int: String]?
    /// Action item indices already sent to Reminders / added to Calendar.
    public var sentToReminders: Set<Int>?
    public var sentToCalendar: Set<Int>?
    /// Text read from an imported PDF, Word file, slide deck or text file (nil for audio).
    public var document: DocumentText?
    /// The imported file's name, e.g. "Q3 plan.pdf".
    public var originalFileName: String?
    /// Note or meeting summary, when the user picked one (nil = chosen automatically).
    public var summaryStyle: SummaryStyle?
    /// The user waved away the suggested speaker names.
    public var nameSuggestionsDismissed: Bool?
    /// When it was moved to Recently Deleted (nil = in the library).
    public var deletedAt: Date?
    /// The AI's version of the summary or note, kept the first time the user edits it so it can be restored.
    public var originalSummary: String?
    /// When the user last edited the summary or note.
    public var editedAt: Date?

    /// PDFs, Word files, slide decks and text files are read, not transcribed.
    public var isDocument: Bool { DocumentReader.canRead(fileName: audioFileName) }
    /// A note typed in the app, with no audio or file behind it.
    public var isWritten: Bool { audioFileName.isEmpty }
    /// Has audio that can be played (not a document or a typed note).
    public var hasAudio: Bool { !isWritten && !isDocument }

    public init(
        id: UUID = UUID(), title: String, titleIsAutomatic: Bool = true, createdAt: Date = Date(),
        audioFileName: String, duration: TimeInterval? = nil, status: Status = .queued
    ) {
        self.id = id
        self.title = title
        self.titleIsAutomatic = titleIsAutomatic
        self.createdAt = createdAt
        self.audioFileName = audioFileName
        self.duration = duration
        self.status = status
        self.checkedActions = []
    }

    public var tldr: String? {
        if noteKind != nil {
            // The first line that says something: not empty, and not a heading that repeats the title.
            let lines = (summary ?? "").split(separator: "\n").map {
                String($0).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "- [ ] ", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            }
            return lines.first { !$0.isEmpty && $0.caseInsensitiveCompare(title) != .orderedSame }
        }
        return summary.flatMap { Summarizer.section("TL;DR", in: $0) }
    }

    public var markdown: String {
        var out = "# \(title)\n\n_\(createdAt.formatted(date: .abbreviated, time: .shortened))"
        if let d = duration { out += " · \(formatTimestamp(d))" }
        if let e = engineName { out += " · summarized by \(e)" }
        out += "_\n\n"
        if let s = summary { out += Speakers.apply(speakerNames, to: s) + "\n\n" }
        if let t = transcript { out += "---\n\n## Transcript\n\n\(t.timestampedText(speakerNames: speakerNames))\n" }
        if let d = document { out += "---\n\n_Notes from \(d.sizeDescription) of \(originalFileName ?? title)._\n" }
        return out
    }

    public static func defaultRecordingTitle(_ date: Date) -> String {
        "Recording, " + date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// Splits summaries and notes into pieces the UI renders differently.
public enum SummaryLayout {
    public enum NoteBlock: Sendable, Equatable { case text(String), task(Int, String) }

    /// A voice note body, with every "- [ ]" line pulled out as a numbered task.
    public static func noteBlocks(_ md: String) -> [NoteBlock] {
        var blocks: [NoteBlock] = []
        var buffer: [String] = []
        var taskIndex = 0
        func flush() {
            let t = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { blocks.append(.text(t)) }
            buffer.removeAll()
        }
        for line in md.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let box = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] "].first(where: { t.hasPrefix($0) }) {
                flush()
                blocks.append(.task(taskIndex, String(t.dropFirst(box.count))))
                taskIndex += 1
            } else {
                buffer.append(line)
            }
        }
        flush()
        return blocks
    }

    /// A meeting summary split around its "## Action items" section.
    public static func splitActions(_ md: String) -> (before: String, actions: [String], after: String) {
        let lines = md.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("## action items")
        }) else { return (md, [], "") }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        let items = lines[(start + 1)..<end].compactMap { line -> String? in
            var t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") || t.hasPrefix("* ") else { return nil }
            t = String(t.dropFirst(2))
            for box in ["[ ] ", "[x] ", "[X] "] where t.hasPrefix(box) { t = String(t.dropFirst(box.count)) }
            return t
        }
        return (lines[..<start].joined(separator: "\n"), items, lines[end...].joined(separator: "\n"))
    }

    /// "[01:23]" → "[01:23](seek://83)", so a tap can play the audio from there.
    public static func linkTimestamps(_ s: String) -> String {
        let pattern = #"\[((?:\d{1,2}:)?\d{1,2}:\d{2})\](?!\()"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: s), let inner = Range(m.range(at: 1), in: s) else { continue }
            let parts = s[inner].split(separator: ":").compactMap { Int($0) }
            let seconds = parts.reduce(0) { $0 * 60 + $1 }
            out.replaceSubrange(whole, with: "[\(s[inner])](seek://\(seconds))")
        }
        return out
    }

    /// The seconds in a "seek://83" link, or nil for any other URL.
    public static func seekSeconds(_ url: URL) -> TimeInterval? {
        guard url.scheme == "seek", let host = url.host(), let s = Double(host) else { return nil }
        return s
    }
}
