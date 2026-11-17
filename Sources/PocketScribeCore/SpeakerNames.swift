import Foundation
import NaturalLanguage

extension Speakers {
    /// Guesses who "Speaker 1", "Speaker 2"… are from what people say: someone who says
    /// "I'm Maria" is Maria; "thanks, Tom" thanks the person who just spoke; "David, can you…"
    /// asks the person who answers. Only confident guesses are returned (one name per speaker,
    /// each name once), so the app can offer them for the user to accept.
    public static func suggestedNames(in transcript: Transcript) -> [Int: String] {
        let segs = transcript.segments
        guard Set(segs.compactMap(\.speaker)).count > 1 else { return [:] }
        var votes: [Int: [String: Int]] = [:]
        func vote(_ speaker: Int?, _ name: String, _ weight: Int) {
            guard let speaker else { return }
            votes[speaker, default: [:]][name, default: 0] += weight
        }
        // Whole turns (consecutive sentences by one speaker), so "Good point, David." followed by
        // "Can you check the screenshots?" is read together.
        var turns: [(speaker: Int, text: String)] = []
        for seg in segs {
            guard let s = seg.speaker else { continue }
            if let last = turns.last, last.speaker == s { turns[turns.count - 1].text += " " + seg.text }
            else { turns.append((s, seg.text)) }
        }
        for (i, turn) in turns.enumerated() {
            let me = turn.speaker, text = turn.text
            // The name recognizer runs at most once per turn, and only if a pattern matched.
            let people = PeopleInText(text)
            func isName(_ word: String, in _: String, strict: Bool) -> Bool { Speakers.isName(word, in: people, strict: strict) }
            let previous = i > 0 ? turns[i - 1].speaker : nil
            let next = i + 1 < turns.count ? turns[i + 1].speaker : nil

            for m in matches(NamePatterns.introduction, in: text) where isName(m.name, in: text, strict: false) {
                vote(me, m.name, 5)
            }
            for m in matches(NamePatterns.introductionLoose, in: text) where isName(m.name, in: text, strict: true) {
                vote(me, m.name, 5)
            }
            // Someone addressed by name: a question or request after the name is for the person
            // who answers; otherwise ("Thanks, Maria.") it's for the person who just spoke.
            var addressed: [String] = []
            var seen = Set<String.Index>()
            func asksNext(after end: String.Index) -> Bool {
                let rest = text[end...].lowercased()
                return rest.contains("?") || ["can you", "could you", "would you", "please"].contains { rest.contains($0) }
            }
            for m in matches(NamePatterns.thanks, in: text) where isName(m.name, in: text, strict: true) {
                vote(asksNext(after: m.end) ? next : previous, m.name, 2); addressed.append(m.name); seen.insert(m.nameStart)
            }
            for m in matches(NamePatterns.leadingVocative, in: text) where isName(m.name, in: text, strict: true) {
                vote(next, m.name, 2); addressed.append(m.name); seen.insert(m.nameStart)
            }
            for m in matches(NamePatterns.trailingVocative, in: text)
            where !seen.contains(m.nameStart) && isName(m.name, in: text, strict: true) {
                if asksNext(after: m.nameStart) { vote(next, m.name, 2) } else { vote(previous, m.name, 1); vote(next, m.name, 1) }
                addressed.append(m.name)
            }
            // Whoever you're talking to isn't you.
            for name in addressed { vote(me, name, -3) }
        }

        var result: [Int: String] = [:]
        var used = Set<String>()
        var undecided = Set(votes.keys)
        let ranked = votes.flatMap { s, d in d.map { (speaker: s, name: $0.key, score: $0.value) } }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.speaker < $1.speaker }
        for c in ranked where c.score >= 2 && undecided.contains(c.speaker) && !used.contains(c.name) {
            // Two names tied for one speaker: don't guess.
            let tied = votes[c.speaker]!.contains { $0.key != c.name && $0.value == c.score && !used.contains($0.key) }
            undecided.remove(c.speaker)
            if tied { continue }
            result[c.speaker] = c.name
            used.insert(c.name)
        }
        return result
    }

    /// The suggestions for speakers the user hasn't named yet.
    public static func pendingSuggestions(in transcript: Transcript?, names: [Int: String]?) -> [Int: String] {
        guard let transcript else { return [:] }
        return pending(suggestedNames(in: transcript), names: names)
    }

    /// `suggestions` without the speakers the user already named (or whose name is taken).
    public static func pending(_ suggestions: [Int: String], names: [Int: String]?) -> [Int: String] {
        suggestions.filter { s, n in
            let current = names?[s]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return current.isEmpty && !(names ?? [:]).values.contains(n)
        }
    }

    /// "Speaker 1 might be Maria and Speaker 2 might be Tom."
    public static func suggestionSentence(_ s: [Int: String]) -> String {
        let parts = s.sorted { $0.key < $1.key }.map { "\(defaultName($0.key)) might be \($0.value)" }
        switch parts.count {
        case 0: return ""
        case 1: return parts[0] + "."
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts.last! + "."
        }
    }

    /// Owners written as names ("- [ ] Maria: …") become the speaker label the name belongs to
    /// ("- [ ] Speaker 1: …"), so every action item uses the same kind of owner and a rename
    /// (or accepting a suggested name) shows up everywhere.
    public static func labelOwners(_ md: String, names: [Int: String]) -> String {
        guard !names.isEmpty else { return md }
        let byName = Dictionary(names.map { ($0.value.lowercased(), $0.key) }, uniquingKeysWith: { a, _ in a })
        return md.components(separatedBy: "\n").map { line in
            guard let box = ["- [ ] ", "- [x] "].first(where: { line.hasPrefix($0) }) else { return line }
            let rest = line.dropFirst(box.count)
            guard let colon = rest.firstIndex(of: ":") else { return line }
            let owner = rest[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " *_"))
            guard let n = byName[owner.lowercased()] else { return line }
            return box + defaultName(n) + rest[colon...]
        }.joined(separator: "\n")
    }

    /// The reverse of `labelOwners` for display: an action item owned by "Speaker 1" shows the
    /// name guessed from the recording ("Maria") while the user hasn't named Speaker 1, so
    /// waving the suggestions away ("Not now") doesn't leave owners as bare labels.
    /// Only owners change; "Speaker 1" elsewhere in the text is left for `apply`.
    public static func nameOwners(_ md: String, suggestions: [Int: String], names: [Int: String]?) -> String {
        let fallback = pending(suggestions, names: names)
        guard !fallback.isEmpty, let re = try? NSRegularExpression(pattern: #"^(- \[[ xX]\] )Speaker (\d+):"#) else { return md }
        return md.components(separatedBy: "\n").map { line in
            guard let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let box = Range(m.range(at: 1), in: line), let num = Range(m.range(at: 2), in: line),
                  let whole = Range(m.range, in: line), let n = Int(line[num]), let name = fallback[n] else { return line }
            return line[box] + name + ":" + line[whole.upperBound...]
        }.joined(separator: "\n")
    }

    // MARK: Matching

    private enum NamePatterns {
        static let name = #"(\p{Lu}\p{Ll}+(?:[-'’]\p{Lu}?\p{Ll}+)?)"#
        static let introduction = re(#"\b(?i:my name is|my name's|i'm called|call me)\s+"# + name)
        static let introductionLoose = re(#"(?:^|[.!?]\s+|,\s+)(?:(?i:hi|hello|hey|so|and|okay|ok),?\s+)*(?:(?i:i'm|i am|this is|it's))\s+"# + name + #"(?:\s+(?i:here))?\b"#)
        static let thanks = re(#"\b(?i:thanks|thank you|good point|great point|good question|great question|fair point|agreed|exactly|nice one),?\s+"# + name + #"\b"#)
        static let leadingVocative = re(#"(?:^|[.!?]\s+)(?:(?i:so|okay|ok|and|well|hey|right|now|great),?\s+)?"# + name + #",\s+\p{Ll}"#)
        static let trailingVocative = re(#",\s+"# + name + #"\s*(?:[?.!]|$)"#)
        static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    }

    private struct NameMatch { let name: String; let nameStart: String.Index; let end: String.Index }

    private static func matches(_ re: NSRegularExpression, in text: String) -> [NameMatch] {
        re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let r = Range(m.range(at: 1), in: text), let whole = Range(m.range, in: text) else { return nil }
            return NameMatch(name: String(text[r]), nameStart: r.lowerBound, end: whole.upperBound)
        }
    }

    /// Capitalized words that start sentences or are said a lot but aren't names.
    private static let notNames: Set<String> = [
        "I", "Okay", "Ok", "Yes", "Yeah", "No", "So", "And", "But", "Well", "Right", "Sure", "Thanks",
        "Thank", "Great", "Good", "Fine", "Sorry", "Everyone", "Everybody", "Guys", "All", "Team", "Folks",
        "Here", "There", "Now", "Then", "Today", "Tomorrow", "Monday", "Tuesday", "Wednesday", "Thursday",
        "Friday", "Saturday", "Sunday", "Just", "Also", "Actually", "Really", "Not", "Going", "Glad",
        "Happy", "Excited", "Back", "Done", "Ready", "Agreed", "Exactly", "Perfect", "Cool", "Nice",
        "Hi", "Hello", "Hey", "Please", "What", "Why", "How", "When", "Where", "Who", "Let", "Can", "Could",
        "Would", "Will", "The", "This", "That", "It", "We", "You", "They", "He", "She", "My", "Our",
    ]

    /// True when `word` reads as a person's name in `text`. `strict` asks the system's name
    /// recognizer to agree, or for the word to be capitalized in the middle of a sentence
    /// (the recognizer misses short phrases like "Thanks Maria." and may be missing on some
    /// devices); otherwise only obvious non-names are rejected.
    static func isName(_ word: String, in people: PeopleInText, strict: Bool) -> Bool {
        guard word.count >= 2, !notNames.contains(word) else { return false }
        if !strict { return true }
        if people.names.contains(word) { return true }
        let midSentence = #"[\p{Ll},;]\s+"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#
        return people.text.range(of: midSentence, options: .regularExpression) != nil
    }

    static func isName(_ word: String, in text: String, strict: Bool) -> Bool {
        isName(word, in: PeopleInText(text), strict: strict)
    }
}

/// The words the system's name recognizer tags as people's names in a piece of text,
/// worked out the first time they're needed and then reused.
final class PeopleInText {
    let text: String
    init(_ text: String) { self.text = text }

    lazy var names: Set<String> = {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found = Set<String>()
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName { text[range].split(separator: " ").forEach { found.insert(String($0)) } }
            return true
        }
        return found
    }()
}

/// Remembers each library item's suggested speaker names, so screens that redraw often don't
/// run the name recognizer over a long transcript every time.
public final class SpeakerSuggestionCache: @unchecked Sendable {
    public static let shared = SpeakerSuggestionCache()
    private let lock = NSLock()
    private var store: [UUID: (stamp: Int, names: [Int: String])] = [:]

    public func suggestions(for id: UUID, transcript: Transcript) -> [Int: String] {
        var h = Hasher()
        h.combine(transcript.segments.count)
        h.combine(transcript.audioDuration)
        h.combine(transcript.segments.first?.text)
        h.combine(transcript.segments.last?.text)
        h.combine(transcript.segments.compactMap(\.speaker))
        let stamp = h.finalize()
        lock.lock()
        if let hit = store[id], hit.stamp == stamp { lock.unlock(); return hit.names }
        lock.unlock()
        let names = Speakers.suggestedNames(in: transcript)
        lock.lock(); store[id] = (stamp, names); lock.unlock()
        return names
    }
}
