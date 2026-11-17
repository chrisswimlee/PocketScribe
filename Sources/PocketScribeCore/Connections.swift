import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

// What ties the library together: every open to-do across notes, the people in a note,
// and which other notes are about the same things. All computed on device from what is
// already saved; nothing here calls a model or the network.

// MARK: - To-dos across the library

extension LibraryItem {
    /// Action item lines, in the order `checkedActions` counts them: a voice note's "- [ ]" tasks,
    /// or a summary's "Action items" section (with owners named as on screen).
    public var actionLines: [String] {
        guard let s = summary else { return [] }
        if noteKind != nil {
            return SummaryLayout.noteBlocks(s).compactMap { if case .task(_, let t) = $0 { return t } else { return nil } }
        }
        return SummaryLayout.splitActions(displaySummary ?? s).actions
    }
}

/// One to-do from one note.
public struct LibraryTask: Identifiable, Sendable, Equatable {
    public var id: String { "\(itemID.uuidString)-\(index)" }
    public let itemID: UUID
    /// Position in the item's `actionLines`, the index `checkedActions` uses.
    public let index: Int
    /// The task without timestamps, links or the deadline in brackets.
    public let title: String
    public let due: Date?
    public let dueHasTime: Bool
    /// Where it was said, from the first [mm:ss] in the line.
    public let seconds: TimeInterval?
    public let done: Bool
}

/// The to-dos of one note, for a section in the To-dos list.
public struct LibraryTaskGroup: Identifiable, Sendable {
    public let item: LibraryItem
    public let tasks: [LibraryTask]
    public var id: UUID { item.id }
}

public enum LibraryTasks {
    /// To-dos grouped by note, newest note first. Done ones are left out unless `includeDone`,
    /// except those in `keeping` (just ticked, so they don't vanish under the finger).
    public static func groups(in items: [LibraryItem], includeDone: Bool, keeping: Set<String> = [],
                              now: Date = Date()) -> [LibraryTaskGroup] {
        items
            .filter { $0.deletedAt == nil && $0.status == .ready }
            .sorted { $0.createdAt > $1.createdAt }
            .compactMap { item in
                let tasks = item.actionLines.enumerated().compactMap { i, line -> LibraryTask? in
                    let done = item.checkedActions.contains(i)
                    let task = LibraryTask(item: item, index: i, line: line, done: done, now: now)
                    return (!done || includeDone || keeping.contains(task.id)) ? task : nil
                }
                return tasks.isEmpty ? nil : LibraryTaskGroup(item: item, tasks: tasks)
            }
    }

    /// How many to-dos are still open, for a badge. Cheap: no date parsing.
    public static func openCount(in items: [LibraryItem]) -> Int {
        items.reduce(0) { sum, item in
            guard item.deletedAt == nil, item.status == .ready else { return sum }
            let n = item.actionLines.count
            return sum + n - item.checkedActions.filter { $0 < n }.count
        }
    }

    /// Seconds of the first "[mm:ss]" or "[h:mm:ss]" in a line.
    static func firstTimestamp(in line: String) -> TimeInterval? {
        guard let r = line.range(of: #"\[((?:\d{1,2}:)?\d{1,2}:\d{2})\]"#, options: .regularExpression) else { return nil }
        let inner = line[r].dropFirst().dropLast()
        return TimeInterval(inner.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 })
    }
}

extension LibraryTask {
    init(item: LibraryItem, index: Int, line: String, done: Bool, now: Date) {
        let parsed = ActionItem(line, speakerNames: item.speakerNames, now: now)
        // "Speaker 3: send the build" says nothing about who; show just the task.
        var title = parsed.title.replacingOccurrences(of: #"^Speaker \d+:\s*"#, with: "", options: .regularExpression)
        if title.isEmpty { title = parsed.title }
        title = title.prefix(1).uppercased() + title.dropFirst()
        self.init(itemID: item.id, index: index, title: title, due: parsed.due, dueHasTime: parsed.dueHasTime,
                  seconds: LibraryTasks.firstTimestamp(in: line), done: done)
    }
}

// MARK: - People and related notes

/// Another note that shares people, tags or subject matter with this one.
public struct RelatedNote: Identifiable, Sendable, Equatable {
    public let id: UUID
    /// Why, in words: "Also with Maria", "Both mention pricing and launch".
    public let reason: String
    public let score: Int
}

public enum Connections {
    /// Names of the people in a recording: the names the user gave, then names guessed from the
    /// recording that the user hasn't waved away. "Speaker 2" is not a name.
    public static func people(of item: LibraryItem) -> [String] {
        var names: [String] = []
        let given = item.speakerNames ?? [:]
        for (_, n) in given.sorted(by: { $0.key < $1.key }) where !names.contains(n) { names.append(n) }
        if item.nameSuggestionsDismissed != true {
            for (k, n) in item.suggestedSpeakerNames.sorted(by: { $0.key < $1.key })
            where given[k] == nil && !names.contains(n) { names.append(n) }
        }
        return names.filter { !$0.isEmpty && !$0.hasPrefix("Speaker ") }
    }

    /// Up to `limit` other notes about the same things, strongest first. A shared person or tag
    /// counts 3 and each shared key word 1; at least 3 is needed, so two notes that only both
    /// say "launch" aren't called related.
    public static func related(to item: LibraryItem, in items: [LibraryItem], limit: Int = 3) -> [RelatedNote] {
        guard item.summary?.isEmpty == false else { return [] }
        let myPeople = Set(people(of: item).map { $0.lowercased() })
        let myTags = Set((item.tags ?? []).map { $0.lowercased() })
        let myWords = KeywordCache.shared.keywords(for: item)
        // How many notes use each word: rarer shared words say more about why two notes go together.
        var notesWith: [String: Int] = [:]
        for other in items where other.deletedAt == nil {
            for w in Set(KeywordCache.shared.keywords(for: other).map(\.key)) { notesWith[w, default: 0] += 1 }
        }
        var found: [(note: RelatedNote, date: Date)] = []
        for other in items where other.id != item.id && other.deletedAt == nil && other.status == .ready
            && other.summary?.isEmpty == false {
            let people = Self.people(of: other).filter { myPeople.contains($0.lowercased()) }
            let tags = (other.tags ?? []).filter { myTags.contains($0.lowercased()) }
            let theirWords = Set(KeywordCache.shared.keywords(for: other).map(\.key))
            let lowerPeople = Set(people.map { $0.lowercased() })
            // Words in either title or tag list first, then the rarer ones.
            let headline = (item.title + " " + other.title + " " + (item.tags ?? []).joined(separator: " ")
                            + " " + (other.tags ?? []).joined(separator: " ")).lowercased()
            func rank(_ w: (offset: Int, element: (key: String, shown: String))) -> (Int, Int, Int) {
                let inHeadline = headline.contains(w.element.key) || headline.contains(w.element.shown)
                return (inHeadline ? 0 : 1, notesWith[w.element.key] ?? 0, w.offset)
            }
            let words = myWords.enumerated()
                .filter { theirWords.contains($0.element.key) && !lowerPeople.contains($0.element.key) }
                .sorted { rank($0) < rank($1) }
                .map(\.element.shown)
            let score = 3 * people.count + 3 * tags.count + words.count
            guard score >= 3 else { continue }
            var reasons: [String] = []
            if !people.isEmpty { reasons.append("Also with " + list(Array(people.prefix(2)))) }
            if !tags.isEmpty { reasons.append("Both tagged " + list(tags.prefix(2).map { "#" + $0 })) }
            if words.count >= 2 || reasons.isEmpty, !words.isEmpty {
                reasons.append("Both mention " + list(Array(words.prefix(2))))
            }
            found.append((RelatedNote(id: other.id, reason: reasons.prefix(2).joined(separator: " · "), score: score),
                          other.createdAt))
        }
        return found
            .sorted { $0.note.score != $1.note.score ? $0.note.score > $1.note.score : $0.date > $1.date }
            .prefix(limit).map(\.note)
    }

    /// Everyone named across the library, most frequent first.
    public static func allPeople(in items: [LibraryItem]) -> [String] {
        var counts: [String: Int] = [:]
        for item in items where item.deletedAt == nil {
            for p in people(of: item) { counts[p, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    static func list(_ s: [String]) -> String {
        s.count == 2 ? "\(s[0]) and \(s[1])" : s.joined(separator: ", ")
    }

    static let stopwords: Set<String> = [
        "meeting", "meetings", "note", "notes", "summary", "speaker", "speakers", "item", "items", "action",
        "actions", "thing", "things", "time", "times", "today", "tomorrow", "yesterday", "week", "weeks", "month",
        "months", "year", "years", "minute", "minutes", "people", "person", "team", "point", "points", "discussion",
        "recording", "call", "idea", "ideas", "part", "parts", "moment", "moments", "lecture", "slide", "slides",
        "page", "pages", "document", "transcript", "something", "anything", "everything", "someone", "question",
        "questions", "need", "needs", "plan", "plans", "work", "step", "steps", "update", "updates", "topic", "topics",
        "decision", "decisions", "detail", "details", "overview", "next", "user", "users", "lot", "kind", "number",
        "place", "case", "fact", "group", "area", "end", "example", "morning", "afternoon", "evening", "monday",
        "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "anyone", "everyone", "nothing", "way",
        "takeaway", "takeaways", "tl;dr", "conversation", "sync", "session", "voice", "january", "february",
        "march", "april", "june", "july", "august", "september", "october", "november", "december",
    ]

    /// The most-used nouns of a note's title and summary (not its transcript), as written
    /// ("pricing"). Words are matched by dictionary form, so "prices" and "price" count together.
    static func keywords(in text: String, limit: Int = 15) -> [String] {
        keywordPairs(in: text, limit: limit).map(\.shown)
    }

    /// Each key word's dictionary form (for matching) and its most common spelling in the text (for showing).
    static func keywordPairs(in text: String, limit: Int = 15) -> [(key: String, shown: String)] {
        var t = text.replacingOccurrences(of: #"\]\([^)]*\)"#, with: "]", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[[^\]]*\d:\d\d[^\]]*\]"#, with: " ", options: .regularExpression)
        var counts: [String: Int] = [:]
        var spellings: [String: [String: Int]] = [:]
        func add(_ root: String, _ word: String) {
            // Which words count is decided by the dictionary form alone; the spelling is only for showing.
            let k = root.lowercased(), w = word.lowercased()
            guard k.count >= 4, k.allSatisfy(\.isLetter), !stopwords.contains(k) else { return }
            counts[k, default: 0] += 1
            spellings[k, default: [:]][w, default: 0] += 1
        }
        #if canImport(NaturalLanguage)
        var tagged = false
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = t
        tagger.enumerateTags(in: t.startIndex..<t.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitPunctuation, .omitWhitespace, .omitOther]) { tag, r in
            guard tag == .noun else { return true }
            tagged = true
            let word = String(t[r])
            let lemma = tagger.tag(at: r.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            add(lemma.flatMap { $0.isEmpty ? nil : $0 } ?? word, word)
            return true
        }
        // The word-type model can be missing (seen on an iOS 27 simulator: every word "OtherWord"),
        // so with no nouns at all fall back to plain words.
        if !tagged { plainWords(t, add) }
        #else
        plainWords(t, add)
        #endif
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { entry -> (key: String, shown: String) in
                let k = entry.key
                let shown = spellings[k]?.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? k
                return (key: k, shown: shown)
            }
    }
}

extension Connections {
    /// Words of 5 or more letters that aren't common filler, for when nouns can't be told apart.
    static func plainWords(_ text: String, _ add: (String, String) -> Void) {
        for w in text.split(whereSeparator: { !$0.isLetter }) where w.count >= 5 {
            let s = String(w)
            if !functionWords.contains(s.lowercased()) { add(s, s) }
        }
    }

    static let functionWords: Set<String> = [
        "about", "above", "after", "again", "against", "along", "already", "also", "although", "among", "another", "around",
        "because", "before", "being", "below", "between", "both", "could", "doing", "during", "either", "every", "first",
        "going", "great", "having", "into", "itself", "later", "least", "maybe", "might", "never", "other", "others",
        "ought", "really", "right", "since", "should", "still", "their", "theirs", "them", "themselves", "there", "these",
        "they", "thing", "think", "those", "though", "through", "under", "until", "using", "where", "which", "while",
        "whole", "whose", "would", "yours", "agreed", "asked", "based", "check", "make", "makes", "needs", "needed",
        "start", "started", "takes", "talked", "thanks", "today", "agree", "within", "without", "shall",
        "older", "newer", "latest", "earlier", "afternoons", "mornings", "evenings", "weekly", "daily", "quick",
    ]

    /// Key words as the fallback finds them, for tests.
    static func plainKeywords(in text: String) -> [String] {
        var counts: [String: Int] = [:]
        plainWords(text) { root, _ in
            let k = root.lowercased()
            if !stopwords.contains(k) { counts[k, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

/// Key words per note, worked out once per version of its text.
final class KeywordCache: @unchecked Sendable {
    static let shared = KeywordCache()
    private let lock = NSLock()
    private var store: [UUID: (stamp: Int, words: [(key: String, shown: String)])] = [:]

    func keywords(for item: LibraryItem) -> [(key: String, shown: String)] {
        var h = Hasher()
        h.combine(item.title)
        h.combine(item.summary)
        let stamp = h.finalize()
        lock.lock()
        if let hit = store[item.id], hit.stamp == stamp { lock.unlock(); return hit.words }
        lock.unlock()
        let words = Connections.keywordPairs(in: item.title + "\n" + (item.summary ?? ""))
        lock.lock(); store[item.id] = (stamp, words); lock.unlock()
        return words
    }
}

// MARK: - Search

public enum LibrarySearch {
    /// True when the title, summary, transcript, document text, a tag or a person's name contains the query.
    public static func matches(_ item: LibraryItem, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let tagQuery = q.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return item.title.localizedCaseInsensitiveContains(q)
            || (item.summary ?? "").localizedCaseInsensitiveContains(q)
            || (item.transcript?.text ?? "").localizedCaseInsensitiveContains(q)
            || (item.document?.text ?? "").localizedCaseInsensitiveContains(q)
            || (item.tags ?? []).contains { $0.localizedCaseInsensitiveContains(tagQuery) }
            || Connections.people(of: item).contains { $0.localizedCaseInsensitiveContains(q) }
    }
}
