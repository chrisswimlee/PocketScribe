import Foundation

/// Ties every point in a summary back to where it came from: the moment in the recording
/// ("[12:40]") or the page or slide ("(p. 3)", "(slide 7)").
///
/// Small on-device models often forget to cite, or cite the wrong moment. So after the model
/// writes the summary, each bullet is matched against the source text by the words it shares
/// with it. A missing citation is added, and a citation that points somewhere the point
/// isn't discussed is moved to where it is. Points that can't be found anywhere are left
/// without a link, and the app tells the reader to double-check them.
public enum SourceLinker {

    /// Sections whose bullets aren't claims about the source.
    static let skippedSections: Set<String> = ["tl;dr", "key terms"]

    // MARK: Recordings

    public static func link(_ summary: String, transcript: Transcript) -> String {
        let segs = transcript.segments
        guard !segs.isEmpty else { return summary }
        let segTokens = segs.map { tokens($0.text) }
        // A point is often spread over a few short sentences, so match against runs of up to
        // three that start within 30 seconds of each other.
        let runs: [Range<Int>] = segs.indices.map { i in
            var end = i + 1
            while end < min(i + 3, segs.count), segs[end].start < segs[i].start + 30 { end += 1 }
            return i..<end
        }
        let windows: [Set<String>] = runs.map { r in
            segTokens[r].reduce(into: Set<String>()) { $0.formUnion($1) }
        }
        let idf = inverseFrequencies(windows)

        return rewriteBullets(summary) { line in
            let claim = tokens(stripCitations(line))
            guard claim.count >= 2 else { return line }
            guard let best = bestMatch(claim, in: windows, idf: idf) else { return line }
            // Within the best run, cite the sentence that shares the most words.
            let run = runs[best.index]
            let pick = run.max { score(claim, segTokens[$0], idf) < score(claim, segTokens[$1], idf) } ?? best.index
            let time = segs[pick].start

            if let cited = citedTimes(line).first {
                // Keep the model's citation if the point really is discussed near it.
                let near = segs.indices.filter { segs[$0].start >= cited - 20 && segs[$0].start <= cited + 40 }
                let nearScore = near.map { score(claim, windows[$0], idf) }.max() ?? 0
                if nearScore >= best.score * 0.6 { return line }
                return replaceFirstTimestamp(in: line, with: formatTimestamp(time))
            }
            return appendCitation("[\(formatTimestamp(time))]", to: line)
        }
    }

    // MARK: Documents

    public static func link(_ summary: String, document: DocumentText) -> String {
        guard let unit = document.unitName else { return summary }
        let parts = document.parts.filter { !$0.text.isEmpty }
        guard !parts.isEmpty else { return summary }
        let pages = parts.map { tokens($0.text) }
        let idf = inverseFrequencies(pages)
        let short = unit == "Slide" ? "slide" : "p."

        return rewriteBullets(summary) { line in
            let claim = tokens(stripCitations(line))
            guard claim.count >= 2, let best = bestMatch(claim, in: pages, idf: idf) else { return line }
            let number = parts[best.index].number
            let cited = citedPages(line)
            if !cited.isEmpty {
                let citedScore = cited.compactMap { n in parts.firstIndex { $0.number == n } }
                    .map { score(claim, pages[$0], idf) }.max() ?? 0
                if citedScore >= best.score * 0.6 { return line }
                return replaceFirstPage(in: line, with: number)
            }
            return appendCitation("(\(short) \(number))", to: line)
        }
    }

    // MARK: Checking

    /// How many points in the summary link to their source, and how many don't.
    public static func coverage(of summary: String) -> (linked: Int, unlinked: Int) {
        var linked = 0, unlinked = 0
        _ = rewriteBullets(summary) { line in
            let claim = tokens(stripCitations(line))
            if !citedTimes(line).isEmpty || !citedPages(line).isEmpty { linked += 1 }
            else if claim.count >= 2 { unlinked += 1 }
            return line
        }
        return (linked, unlinked)
    }

    // MARK: Rendering

    /// "(p. 3)" → "([p. 3](page://3))", "slide 7" → "[slide 7](page://7)", so a tap opens that page.
    public static func linkPages(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pagePattern, options: [.caseInsensitive]) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: s), let num = Range(m.range(at: 1), in: s) else { continue }
            // Already a link ("[p. 3](page://3)")? Leave it.
            if whole.lowerBound > s.startIndex, s[s.index(before: whole.lowerBound)] == "[" { continue }
            out.replaceSubrange(whole, with: "[\(s[whole])](page://\(s[num]))")
        }
        return out
    }

    /// The page or slide number in a "page://3" link, or nil for any other URL.
    public static func pageNumber(_ url: URL) -> Int? {
        guard url.scheme == "page", let host = url.host() else { return nil }
        return Int(host)
    }

    /// Timestamps become links; page and slide references too when the item is a document.
    public static func linkAll(_ s: String, pages: Bool) -> String {
        let timed = SummaryLayout.linkTimestamps(s)
        return pages ? linkPages(timed) : timed
    }

    // MARK: - Internals

    static let pagePattern = #"\b(?:p\.|pp\.|pages?|slides?)\s?(\d{1,4})\b(?!\]\()"#
    static let timePattern = #"\[((?:\d{1,2}:)?\d{1,2}:\d{2})\]"#

    /// Calls `transform` on each bullet line outside TL;DR and Key terms.
    static func rewriteBullets(_ md: String, _ transform: (String) -> String) -> String {
        var section = ""
        return md.components(separatedBy: "\n").map { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("## ") {
                section = t.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                return line
            }
            guard !skippedSections.contains(section), t.hasPrefix("- ") || t.hasPrefix("* ") else { return line }
            return transform(line)
        }.joined(separator: "\n")
    }

    static func citedTimes(_ line: String) -> [TimeInterval] {
        guard let re = try? NSRegularExpression(pattern: timePattern) else { return [] }
        return re.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { m in
            Range(m.range(at: 1), in: line).map { r in
                Double(line[r].split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 })
            }
        }
    }

    static func citedPages(_ line: String) -> [Int] {
        guard let re = try? NSRegularExpression(pattern: pagePattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { m in
            Range(m.range(at: 1), in: line).flatMap { Int(line[$0]) }
        }
    }

    /// The line without timestamps, page references or link targets, for matching.
    static func stripCitations(_ line: String) -> String {
        var t = line.replacingOccurrences(of: #"\]\([^)]*\)"#, with: "]", options: .regularExpression)
        t = t.replacingOccurrences(of: timePattern, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: pagePattern, with: " ", options: [.regularExpression, .caseInsensitive])
        return t
    }

    static func appendCitation(_ citation: String, to line: String) -> String {
        var trimmed = line
        while trimmed.last?.isWhitespace == true { trimmed.removeLast() }
        return trimmed + " " + citation
    }

    static func replaceFirstTimestamp(in line: String, with stamp: String) -> String {
        guard let r = line.range(of: timePattern, options: .regularExpression) else { return line }
        var out = line
        out.replaceSubrange(r, with: "[\(stamp)]")
        return out
    }

    static func replaceFirstPage(in line: String, with number: Int) -> String {
        guard let re = try? NSRegularExpression(pattern: pagePattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let num = Range(m.range(at: 1), in: line) else { return line }
        var out = line
        out.replaceSubrange(num, with: String(number))
        return out
    }

    // MARK: Matching

    struct Match { let index: Int; let score: Double }

    /// The best-matching window, if it shares enough with the claim to count as its source.
    static func bestMatch(_ claim: Set<String>, in windows: [Set<String>], idf: [String: Double]) -> Match? {
        var best: Match?
        for (i, w) in windows.enumerated() {
            let s = score(claim, w, idf)
            if s > (best?.score ?? 0) { best = Match(index: i, score: s) }
        }
        guard let best else { return nil }
        let shared = claim.intersection(windows[best.index]).count
        // Two shared content words and about a third of what the point says.
        guard shared >= 2, best.score >= 0.3 else { return nil }
        return best
    }

    /// Share of the claim's (rarity-weighted) words that appear in the window.
    static func score(_ claim: Set<String>, _ window: Set<String>, _ idf: [String: Double]) -> Double {
        let total = claim.reduce(0.0) { $0 + (idf[$1] ?? maxIDF(idf)) }
        guard total > 0 else { return 0 }
        let hit = claim.intersection(window).reduce(0.0) { $0 + (idf[$1] ?? 0) }
        return hit / total
    }

    static func maxIDF(_ idf: [String: Double]) -> Double { idf.values.max() ?? 1 }

    static func inverseFrequencies(_ docs: [Set<String>]) -> [String: Double] {
        var df: [String: Int] = [:]
        for d in docs { for t in d { df[t, default: 0] += 1 } }
        let n = Double(docs.count)
        return df.mapValues { log((n + 1) / (Double($0) + 0.5)) + 0.1 }
    }

    /// Lowercased content words, lightly stemmed so "launching" matches "launch".
    static func tokens(_ text: String) -> Set<String> {
        var out = Set<String>()
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var w = String(raw)
            if w.count < 3 && !(w.first?.isNumber ?? false) { continue }
            if stopWords.contains(w) { continue }
            for suffix in ["ing", "ed", "es", "s"] where w.count - suffix.count >= 4 && w.hasSuffix(suffix) {
                w.removeLast(suffix.count)
                break
            }
            out.insert(w)
        }
        return out
    }

    static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one",
        "our", "out", "has", "have", "him", "his", "how", "its", "may", "new", "now", "old", "see", "two",
        "who", "did", "get", "got", "let", "say", "she", "too", "use", "that", "this", "with", "they",
        "them", "then", "than", "there", "their", "these", "those", "what", "when", "where", "which",
        "will", "would", "could", "should", "from", "into", "about", "also", "been", "being", "were",
        "just", "like", "some", "more", "most", "much", "very", "only", "over", "such", "each", "other",
        "your", "yours", "we're", "it's", "okay", "yeah", "really", "think", "going", "gonna", "know",
        "want", "need", "make", "made", "thing", "things", "well", "here", "speaker", "said", "says",
        "discussed", "mentioned", "talked", "noted", "explained", "agreed", "decided", "suggested",
        "because", "so", "if", "is", "it", "to", "of", "in", "on", "at", "by", "an", "or", "as", "be",
    ]
}
