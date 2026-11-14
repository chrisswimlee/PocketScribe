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
    Lines start with [mm:ss] timestamps. Some lines then name who is talking, like "Speaker 2:" \
    or a person's name; when they do, say who said or will do what, and refer to each person by \
    that label exactly as written (for example "Speaker 2"), even if their real name comes up; \
    the app shows the right name later. Write in the same language as the transcript.
    """

    static func finalPrompt(_ material: String, isNotes: Bool) -> String {
        """
        \(isNotes ? "Below are notes taken from consecutive parts of one recording." : "Below is the transcript of a recording.")
        Write a summary in Markdown with exactly these sections (omit a section only if it would be empty):

        ## TL;DR
        Two or three sentences.

        ## Action items
        One checkbox line per task, for example:
        - [ ] Speaker 2: send the budget report (by Friday)
        Start with the owner (the label from the transcript, like "Speaker 2", or a name if the \
        person isn't one of the labeled speakers) when it is clear who will do it, and leave it \
        out otherwise. List each task once, even if several people talk about it. \
        Add the deadline in parentheses only if one was given.

        ## Decisions
        Bullet list of anything that was decided or agreed.

        ## Key points
        Bullet list of the most important ideas, in order.

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

    /// The instructions for one kind of source (a recording or a document).
    struct Prompts {
        let system: String
        let final: (String, Bool) -> String
        let chunk: (String, Int, Int) -> String
        /// Lines like "[Page 3]" that say where the text that follows comes from. A chunk that starts
        /// partway through a page gets the last marker repeated, so the model still knows the page.
        var marker: ((String) -> Bool)? = nil
    }

    static let recordingPrompts = Prompts(system: system, final: finalPrompt, chunk: chunkPrompt)

    public func summarize(
        _ transcript: Transcript,
        progress: (@Sendable (SummaryProgress) -> Void)? = nil
    ) async throws -> String {
        let lines = transcript.timestampedText.components(separatedBy: "\n")
        var summary = try await reduce(lines: lines, isNotes: false, prompts: Self.recordingPrompts, progress: progress)
        summary = Speakers.labelOwners(summary, names: Speakers.suggestedNames(in: transcript))
        summary = Self.mergeDuplicateActions(summary)
        return SourceLinker.link(summary, transcript: transcript)
    }

    /// Notes and a summary for a PDF, Word file, slide deck or text file.
    public func summarize(
        document: DocumentText,
        progress: (@Sendable (SummaryProgress) -> Void)? = nil
    ) async throws -> String {
        let lines = document.annotatedText.components(separatedBy: "\n")
        let summary = try await reduce(lines: lines, isNotes: false, prompts: Self.documentPrompts(document), progress: progress)
        return SourceLinker.link(summary, document: document)
    }

    private func reduce(
        lines: [String], isNotes: Bool, prompts: Prompts, depth: Int = 0,
        progress: (@Sendable (SummaryProgress) -> Void)?
    ) async throws -> String {
        let full = lines.joined(separator: "\n")
        if full.count <= engine.maxChunkCharacters || depth >= 3 {
            progress?(.combining)
            let clipped = String(full.prefix(engine.maxChunkCharacters))
            let raw = try await engine.complete(system: prompts.system, prompt: prompts.final(clipped, isNotes))
            return Self.tidy(raw)
        }
        let chunks = Self.chunk(lines: lines, limit: engine.maxChunkCharacters, marker: isNotes ? nil : prompts.marker)
        var notes: [String] = []
        for (i, chunk) in chunks.enumerated() {
            progress?(.summarizingChunk(i + 1, of: chunks.count))
            let n = try await engine.complete(
                system: prompts.system, prompt: prompts.chunk(chunk, i + 1, chunks.count))
            notes.append(n.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let noteLines = notes.joined(separator: "\n\n").components(separatedBy: "\n")
        return try await reduce(lines: noteLines, isNotes: true, prompts: prompts, depth: depth + 1, progress: progress)
    }

    // MARK: Documents

    static func documentPrompts(_ doc: DocumentText) -> Prompts {
        let what: String
        switch doc.kind {
        case .pdf: what = "a PDF"
        case .word: what = "a Word document"
        case .slides: what = "a slide deck"
        case .text: what = "a text document"
        }
        let unit = doc.unitName  // "Page" / "Slide" / nil
        let whereHint = unit.map {
            " Lines like [\($0) 3] mark where each \($0.lowercased()) starts. When you mention a point, add where it is, like (\($0 == "Slide" ? "slide" : "p.") 3)."
        } ?? ""
        let system = """
        You turn documents into clear, faithful notes for someone who hasn't read them. \
        The text was extracted automatically, so headers, footers, page numbers and broken lines may appear; \
        work out the structure sensibly but never invent facts, names or numbers that are not in the text.\(whereHint) \
        Lines starting with # are headings from the document. Write in the same language as the document.
        """
        let final: (String, Bool) -> String = { material, isNotes in
            """
            \(isNotes ? "Below are notes taken from consecutive parts of \(what)." : "Below is the text of \(what).")
            Write notes in Markdown with exactly these sections (omit a section only if it would be empty):

            ## TL;DR
            Two or three sentences: what this is and its main message.

            ## Key points
            Bullet list of the most important ideas, facts and numbers, in order.

            ## Notes
            Structured notes that follow the document's own sections, using ### subheadings and bullets. \
            Keep important names, dates, figures, definitions and conclusions.

            ## Action items
            Only tasks the document says someone should do. One checkbox line per task, for example:
            - [ ] Send the signed contract to legal (by Friday)
            If the document names who will do a task, start the line with that name and a colon. \
            Add the deadline only if the document gives one. Never make up names.

            ## Key terms
            Up to 8 specialist terms, acronyms or names a newcomer might not know, each as "- **Term**: short meaning". \
            Skip everyday words, and omit the section if there are none.

            ---
            \(material)
            """
        }
        let chunk: (String, Int, Int) -> String = { text, i, n in
            """
            This is part \(i) of \(n) of \(what). \
            Write concise bullet-point notes covering every topic, fact, number, definition, conclusion and task in this part.\
            \(unit == nil ? "" : " Note where each point is, like (\(unit == "Slide" ? "slide" : "p.") 3).") Do not add an introduction.

            ---
            \(text)
            """
        }
        return Prompts(system: system, final: final, chunk: chunk, marker: { line in
            guard let unit else { return false }
            return line.hasPrefix("[\(unit) ") && line.hasSuffix("]")
        })
    }

    /// Asks the model for a short human title, e.g. "Payments launch standup".
    public func suggestTitle(for summary: String) async throws -> String {
        let tldr = Self.section("TL;DR", in: summary) ?? String(summary.prefix(1_500))
        let raw = try await engine.complete(
            system: "You write short, specific titles for recordings and documents.",
            prompt: "Write a title of 3 to 7 words for an item with this summary. Reply with the title only, no quotes or punctuation at the end.\n\n\(tldr)")
        let firstLine = raw.split(separator: "\n").first.map(String.init) ?? raw
        return firstLine.trimmingCharacters(in: CharacterSet(charactersIn: " \"'*#.")).prefix(80).description
    }

    /// Body of a "## Heading" section, or nil.
    public static func section(_ heading: String, in md: String) -> String? {
        let lines = md.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == "## \(heading.lowercased())"
        }) else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        return lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Small models sometimes mangle checkbox syntax ("- [- [Maria]: task]"). Normalize it.
    static func tidy(_ md: String) -> String {
        md.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .map { line -> String in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("- ["), !t.hasPrefix("- [ ] "), !t.hasPrefix("- [x] ") else { return line }
                // Leave "[mm:ss]" timestamp bullets alone.
                if let c = t.dropFirst(3).first, c.isNumber { return line }
                var body = String(t.dropFirst(2))
                body = body.replacingOccurrences(of: "[ ]", with: "")
                    .replacingOccurrences(of: "- [", with: "")
                    .replacingOccurrences(of: "[", with: "")
                    .replacingOccurrences(of: "]", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return "- [ ] " + body
            }
            .map { line -> String in
                // Placeholder owners copied from instructions ("- [ ] Owner: task").
                for junk in ["- [ ] Owner: ", "- [ ] owner: ", "- [ ] Name: "] where line.hasPrefix(junk) {
                    return "- [ ] " + line.dropFirst(junk.count)
                }
                return line
            }
            .joined(separator: "\n")
    }

    /// Small models often list one task twice, once per person who mentioned it ("Set up the
    /// shared inbox" under two owners). Merge action items that are the same task:
    /// - tasks that mention different people ("send the build to Tom" / "… to David") are different;
    /// - tasks with two different owners are only merged when their words are the same, so two
    ///   people who each do a similar-sounding task both keep it;
    /// - otherwise items that share most of their words are merged.
    /// The first copy stays where it is and picks up an owner or deadline only a later copy had.
    static func mergeDuplicateActions(_ md: String) -> String {
        var lines = md.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("## action items")
        }) else { return md }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        var kept: [(line: Int, task: ActionTask)] = []
        var drop: [Int] = []
        for i in (start + 1)..<end {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") else { continue }
            let task = ActionTask(t)
            guard task.words.count >= 2 else { continue }
            if let k = kept.firstIndex(where: { $0.task.isSameTask(as: task) }) {
                drop.append(i)
                lines[kept[k].line] = kept[k].task.filledIn(from: task)
                kept[k].task = ActionTask(lines[kept[k].line])
            } else {
                kept.append((i, task))
            }
        }
        for i in drop.reversed() { lines.remove(at: i) }
        return lines.joined(separator: "\n")
    }

    /// One action item line taken apart: checkbox, owner, the task's words, deadline.
    struct ActionTask {
        let line: String
        let box: String
        let owner: String?
        let deadline: String?
        let words: Set<String>
        /// Capitalized words inside the task (people, products), e.g. "Tom".
        let names: Set<String>

        init(_ raw: String) {
            line = raw.trimmingCharacters(in: .whitespaces)
            var t = line
            var box = "- "
            for b in ["- [ ] ", "- [x] ", "- [X] ", "- "] where t.hasPrefix(b) { box = b; t = String(t.dropFirst(b.count)); break }
            self.box = box
            t = t.replacingOccurrences(of: #"\[[^\]]*\](\([^)]*\))?"#, with: " ", options: .regularExpression)
            var owner: String?
            if let colon = t.firstIndex(of: ":"), t[..<colon].split(separator: " ").count <= 3 {
                owner = t[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " *_")).lowercased()
                t = String(t[t.index(after: colon)...])
            }
            self.owner = owner?.isEmpty == true ? nil : owner
            deadline = t.range(of: #"\([^)]*\)"#, options: .regularExpression).map { String(t[$0]) }
            t = t.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            let tokens = t.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            names = Set(tokens.dropFirst().filter { $0.first!.isUppercase && $0.count >= 2 })
            let stop: Set<String> = ["the", "and", "for", "with", "our", "their", "this", "that", "will", "from", "about", "into"]
            words = Set(tokens.map { $0.lowercased() }.filter { $0.count >= 3 && !stop.contains($0) })
        }

        func isSameTask(as other: ActionTask) -> Bool {
            if names != other.names, !names.isEmpty || !other.names.isEmpty { return false }
            if let a = owner, let b = other.owner, a != b { return words == other.words }
            let overlap = Double(words.intersection(other.words).count) / Double(words.union(other.words).count)
            return overlap >= 0.6
        }

        /// This line, with the owner or deadline that only `other` gave.
        func filledIn(from other: ActionTask) -> String {
            var out = line
            if owner == nil, let o = other.owner, let colon = other.line.firstIndex(of: ":") {
                let ownerText = other.line[other.line.index(other.line.startIndex, offsetBy: other.box.count)..<colon]
                out = box + ownerText + ": " + out.dropFirst(box.count)
            }
            if deadline == nil, let d = other.deadline {
                // Before any trailing source link like "[00:14](seek://14)".
                if let link = out.range(of: #"\s*\[[^\]]*\](\([^)]*\))?\s*$"#, options: .regularExpression) {
                    out.replaceSubrange(link, with: " " + d + out[link].replacingOccurrences(of: #"^\s*"#, with: " ", options: .regularExpression))
                } else {
                    out += " " + d
                }
            }
            return out
        }
    }

    /// Splits on line boundaries so no sentence is cut in half.
    static func chunk(lines: [String], limit: Int, marker: ((String) -> Bool)? = nil) -> [String] {
        var chunks: [String] = []
        var current = ""
        var lastMarker: String?
        for line in lines {
            if !current.isEmpty, current.count + line.count + 1 > limit {
                chunks.append(current)
                // Continue mid-page: say which page we're on (unless this line starts a new one).
                current = (lastMarker.map { m in marker?(line) == true ? "" : m }) ?? ""
            }
            if marker?(line) == true { lastMarker = line }
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
