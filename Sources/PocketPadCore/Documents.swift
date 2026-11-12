import Compression
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Text pulled out of a PDF, Word file, PowerPoint deck or text file, kept per page or slide
/// so summaries can say where each point came from.
public struct DocumentText: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case pdf, word, slides, text }

    /// One page or slide. `number` is 1-based; 0 means the document has no pages (plain text).
    public struct Part: Codable, Sendable, Equatable, Identifiable {
        public var number: Int
        public var text: String
        public var id: Int { number }
        public init(number: Int, text: String) { self.number = number; self.text = text }
    }

    public var kind: Kind
    public var parts: [Part]
    /// Pages whose text came from reading the page image (scanned PDFs).
    public var recognizedPages: [Int]?

    public init(kind: Kind, parts: [Part], recognizedPages: [Int]? = nil) {
        self.kind = kind
        self.parts = parts
        self.recognizedPages = recognizedPages
    }

    public var text: String { parts.map(\.text).joined(separator: "\n\n") }
    public var isEmpty: Bool { parts.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    public var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }

    /// "Page" or "Slide", or nil when the document isn't split into pages.
    public var unitName: String? {
        guard parts.contains(where: { $0.number > 0 }) else { return nil }
        return kind == .slides ? "Slide" : "Page"
    }

    public func label(_ part: Part) -> String? { unitName.map { "\($0) \(part.number)" } }

    /// e.g. "12 pages", "8 slides", "2,300 words".
    public var sizeDescription: String {
        if let unit = unitName?.lowercased() {
            let n = parts.last?.number ?? parts.count
            return "\(n) \(unit)\(n == 1 ? "" : "s")"
        }
        return "\(wordCount.formatted()) words"
    }

    /// What the summarizer reads: each page or slide starts with a "[Page 3]" / "[Slide 3]" line.
    public var annotatedText: String {
        parts.compactMap { p -> String? in
            let body = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return label(p).map { "[\($0)]\n\(body)" } ?? body
        }.joined(separator: "\n\n")
    }
}

public enum DocumentError: LocalizedError {
    case unsupported(String)
    case unreadable(String)
    case empty(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let why), .unreadable(let why), .empty(let why): return why
        }
    }
}

/// Reads documents into `DocumentText`, entirely on this device.
public enum DocumentReader {
    public static let fileExtensions: Set<String> = ["pdf", "docx", "pptx", "txt", "text", "md", "markdown", "rtf"]

    /// File types the import pickers offer, next to audio and video.
    public static let contentTypes: [UTType] = [
        .pdf, .plainText, .rtf,
        UTType("net.daringfireball.markdown"),
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("org.openxmlformats.presentationml.presentation"),
    ].compactMap { $0 }

    /// True for the files this reader handles (decided by extension, which imports keep).
    public static func canRead(fileName: String) -> Bool {
        fileExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// A helpful message for document formats we can't read yet, or nil.
    public static func unsupportedReason(fileName: String) -> String? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "doc": return "\(fileName) is an old Word file (.doc). Save it as .docx in Word or Pages, then add it again."
        case "ppt": return "\(fileName) is an old PowerPoint file (.ppt). Save it as .pptx, then add it again."
        case "key", "pages", "numbers": return "\(fileName) is an iWork file. Export it as PDF from Keynote or Pages, then add it again."
        default: return nil
        }
    }

    public static func read(_ url: URL) throws -> DocumentText {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return try readPDF(url)
        case "docx": return try OfficeText.word(try ZipArchive(url: url))
        case "pptx": return try OfficeText.slides(try ZipArchive(url: url))
        case "rtf": return DocumentText(kind: .text, parts: [.init(number: 0, text: try readRTF(url))])
        case "txt", "text", "md", "markdown":
            return DocumentText(kind: .text, parts: [.init(number: 0, text: try readPlainText(url))])
        default:
            throw DocumentError.unsupported(unsupportedReason(fileName: url.lastPathComponent)
                ?? "\(url.lastPathComponent) isn't a file type that can be read.")
        }
    }

    // MARK: Plain text and RTF

    static func readPlainText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        var used: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &used) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        throw DocumentError.unreadable("Couldn't work out the text encoding of \(url.lastPathComponent).")
    }

    static func readRTF(_ url: URL) throws -> String {
        let s = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                       documentAttributes: nil)
        return s.string
    }

    // MARK: PDF

    static func readPDF(_ url: URL) throws -> DocumentText {
        #if canImport(PDFKit)
        guard let pdf = PDFDocument(url: url) else {
            throw DocumentError.unreadable("\(url.lastPathComponent) couldn't be opened as a PDF.")
        }
        if pdf.isLocked {
            throw DocumentError.unreadable("\(url.lastPathComponent) is password-protected. Unlock it in Preview, then add it again.")
        }
        var parts: [DocumentText.Part] = []
        var recognized: [Int] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Scanned pages have no text layer: read the page image instead.
            if text.count < 20, let ocr = recognizeText(page), ocr.count > text.count {
                text = ocr
                recognized.append(i + 1)
            }
            parts.append(.init(number: i + 1, text: tidyPDFText(text)))
        }
        return DocumentText(kind: .pdf, parts: parts, recognizedPages: recognized.isEmpty ? nil : recognized)
        #else
        throw DocumentError.unsupported("PDFs can't be read on this system.")
        #endif
    }

    /// PDF text often breaks lines mid-sentence and repeats hyphenation. Join those lines back up
    /// so the model sees sentences, but keep real paragraph and list breaks.
    static func tidyPDFText(_ s: String) -> String {
        var out: [String] = []
        for raw in s.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                if out.last != "" { out.append("") }
                continue
            }
            if let last = out.last, !last.isEmpty,
               !line.hasPrefix("•"), !line.hasPrefix("- "), !line.hasPrefix("* "),
               line.first.map({ $0.isLowercase }) == true,
               !last.hasSuffix("."), !last.hasSuffix(":"), !last.hasSuffix("?"), !last.hasSuffix("!") {
                if last.hasSuffix("-") {
                    out[out.count - 1] = String(last.dropLast()) + line
                } else {
                    out[out.count - 1] = last + " " + line
                }
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if canImport(PDFKit)
    /// On-device text recognition (Vision) for a scanned page.
    static func recognizeText(_ page: PDFPage) -> String? {
        #if canImport(Vision)
        guard let cgPage = page.pageRef else { return nil }
        let box = cgPage.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(3, 2_400 / max(box.width, box.height))
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(cgPage)
        guard let image = ctx.makeImage() else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
        #else
        return nil
        #endif
    }
    #endif
}

// MARK: - Word and PowerPoint (Office Open XML)

enum OfficeText {
    static func word(_ zip: ZipArchive) throws -> DocumentText {
        guard let xml = try zip.data(named: "word/document.xml") else {
            throw DocumentError.unreadable("This doesn't look like a Word document.")
        }
        let pages = WordXML.pages(xml)
        // Word only stores page breaks it last rendered; with none, it's one long page.
        let parts = pages.count > 1
            ? pages.enumerated().map { DocumentText.Part(number: $0.offset + 1, text: $0.element) }
            : [DocumentText.Part(number: 0, text: pages.first ?? "")]
        return DocumentText(kind: .word, parts: parts)
    }

    static func slides(_ zip: ZipArchive) throws -> DocumentText {
        let paths = slideOrder(zip)
        guard !paths.isEmpty else { throw DocumentError.unreadable("This doesn't look like a PowerPoint deck.") }
        var parts: [DocumentText.Part] = []
        for (i, path) in paths.enumerated() {
            var text = try zip.data(named: path).map { DrawingXML.text($0) } ?? ""
            if let notesPath = notesPath(forSlide: path, in: zip), let notes = try zip.data(named: notesPath) {
                let n = DrawingXML.text(notes).trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty { text += "\n\nSpeaker notes: " + n }
            }
            parts.append(.init(number: i + 1, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return DocumentText(kind: .slides, parts: parts)
    }

    /// Slides in presentation order (presentation.xml's list), falling back to file numbering.
    static func slideOrder(_ zip: ZipArchive) -> [String] {
        let files = zip.names.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
        if let pres = (try? zip.data(named: "ppt/presentation.xml")).flatMap({ $0 }).flatMap({ String(data: $0, encoding: .utf8) }),
           let rels = (try? zip.data(named: "ppt/_rels/presentation.xml.rels")).flatMap({ $0 }).flatMap({ String(data: $0, encoding: .utf8) }) {
            let targets = relationshipTargets(rels)
            let ids = matches(#"<p:sldId\b[^>]*\br:id="([^"]+)""#, in: pres)
            let ordered = ids.compactMap { targets[$0] }.map { resolve($0, from: "ppt/") }.filter(files.contains)
            if !ordered.isEmpty { return ordered }
        }
        func n(_ s: String) -> Int { Int(s.dropFirst("ppt/slides/slide".count).dropLast(4)) ?? 0 }
        return files.sorted { n($0) < n($1) }
    }

    static func notesPath(forSlide path: String, in zip: ZipArchive) -> String? {
        let file = (path as NSString).lastPathComponent
        guard let rels = (try? zip.data(named: "ppt/slides/_rels/\(file).rels")).flatMap({ $0 })
                .flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        return relationshipTargets(rels).values.first { $0.contains("notesSlide") }.map { resolve($0, from: "ppt/slides/") }
    }

    /// rId → Target from a .rels file.
    static func relationshipTargets(_ rels: String) -> [String: String] {
        var out: [String: String] = [:]
        for tag in matches(#"(<Relationship\b[^>]*>)"#, in: rels) {
            if let id = matches(#"\bId="([^"]+)""#, in: tag).first,
               let target = matches(#"\bTarget="([^"]+)""#, in: tag).first {
                out[id] = target
            }
        }
        return out
    }

    /// "../notesSlides/notesSlide1.xml" relative to "ppt/slides/" → "ppt/notesSlides/notesSlide1.xml".
    static func resolve(_ target: String, from base: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = base.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/") {
            if piece == ".." { _ = parts.popLast() } else if piece != "." { parts.append(String(piece)) }
        }
        return parts.joined(separator: "/")
    }

    static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s).map { String(s[$0]) }
        }
    }
}

/// Walks word/document.xml: paragraphs become lines, headings get "#", list items get "- ",
/// and page breaks Word rendered split the text into pages.
final class WordXML: NSObject, XMLParserDelegate {
    private var pages: [[String]] = [[]]
    private var paragraph = ""
    private var prefix = ""
    private var inText = false
    private var inCell = false
    private var row: [String] = []

    static func pages(_ data: Data) -> [String] {
        let d = WordXML()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        d.endParagraph()
        return d.pages.map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func endParagraph() {
        let t = paragraph.trimmingCharacters(in: .whitespaces)
        if inCell {
            if !t.isEmpty { row.append(t) }
        } else if !t.isEmpty {
            pages[pages.count - 1].append(prefix + t)
        }
        paragraph = ""
        prefix = ""
    }

    /// Text before the break stays on this page; the rest of the paragraph (and its heading or
    /// list style) continues on the next.
    private func pageBreak() {
        let t = paragraph.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, !inCell { pages[pages.count - 1].append(prefix + t); paragraph = "" }
        if !(pages.last?.isEmpty ?? true) { pages.append([]) }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "w:t": inText = true
        case "w:tab": paragraph += "\t"
        case "w:br", "w:cr":
            if attributes["w:type"] == "page" { pageBreak() } else { paragraph += " " }
        case "w:lastRenderedPageBreak": pageBreak()
        case "w:pStyle":
            let style = (attributes["w:val"] ?? "").lowercased()
            if style == "title" { prefix = "# " }
            else if style.hasPrefix("heading"), let level = Int(style.dropFirst("heading".count)) {
                prefix = String(repeating: "#", count: min(level + 1, 6)) + " "
            }
        case "w:numPr": if prefix.isEmpty { prefix = "- " }
        case "w:tc": inCell = true
        case "w:tr": row = []
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "w:t": inText = false
        case "w:p": endParagraph()
        case "w:tc": inCell = false
        case "w:tr":
            if !row.isEmpty { pages[pages.count - 1].append(row.joined(separator: " | ")) }
            row = []
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { paragraph += string }
    }
}

/// Text from DrawingML (slides and their notes): each <a:p> is a line. Slide-number fields are skipped.
final class DrawingXML: NSObject, XMLParserDelegate {
    private var lines: [String] = []
    private var paragraph = ""
    private var inText = false
    private var fieldDepth = 0

    static func text(_ data: Data) -> String {
        let d = DrawingXML()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.lines.joined(separator: "\n")
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "a:t": inText = true
        case "a:br": paragraph += " "
        case "a:fld": if attributes["type"]?.hasPrefix("slidenum") == true { fieldDepth += 1 }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "a:t": inText = false
        case "a:fld": fieldDepth = max(0, fieldDepth - 1)
        case "a:p":
            let t = paragraph.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { lines.append(t) }
            paragraph = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText, fieldDepth == 0 { paragraph += string }
    }
}

// MARK: - Minimal ZIP reader (Office files are ZIP archives of XML)

struct ZipArchive {
    struct Entry { let name: String; let method: Int; let compressedSize: Int; let size: Int; let offset: Int }

    private let bytes: [UInt8]
    private(set) var entries: [String: Entry] = [:]
    var names: [String] { Array(entries.keys) }

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        bytes = [UInt8](data)
        let bad = DocumentError.unreadable("The file is damaged or isn't a Word or PowerPoint file.")
        // End of central directory record: last occurrence of PK\5\6.
        guard bytes.count >= 22 else { throw bad }
        var eocd = -1
        var i = bytes.count - 22
        let stop = max(0, bytes.count - 22 - 65_535)
        while i >= stop {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw bad }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4b50 else { throw bad }
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            guard p + 46 + nameLen <= bytes.count else { throw bad }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            entries[name] = Entry(name: name, method: u16(p + 10), compressedSize: u32(p + 20),
                                  size: u32(p + 24), offset: u32(p + 42))
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    /// The file's bytes, or nil if the archive has no such file.
    func data(named name: String) throws -> Data? {
        guard let e = entries[name] else { return nil }
        let bad = DocumentError.unreadable("Part of the file (\(name)) is damaged.")
        guard e.offset + 30 <= bytes.count, u32(e.offset) == 0x0403_4b50 else { throw bad }
        let start = e.offset + 30 + u16(e.offset + 26) + u16(e.offset + 28)
        guard start + e.compressedSize <= bytes.count else { throw bad }
        let src = Array(bytes[start..<(start + e.compressedSize)])
        switch e.method {
        case 0: return Data(src)
        case 8:
            if e.size == 0 { return Data() }
            var dst = [UInt8](repeating: 0, count: e.size)
            let n = src.withUnsafeBufferPointer { s in
                dst.withUnsafeMutableBufferPointer { d in
                    // COMPRESSION_ZLIB is raw DEFLATE, which is what ZIP stores.
                    compression_decode_buffer(d.baseAddress!, e.size, s.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard n == e.size else { throw bad }
            return Data(dst)
        default:
            throw DocumentError.unsupported("The file uses a compression method that isn't supported.")
        }
    }

    private func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
    private func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
}

extension DocumentText.Kind {
    /// SF Symbol for lists and headers.
    public var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .word: return "doc.text"
        case .slides: return "rectangle.on.rectangle.angled"
        case .text: return "text.alignleft"
        }
    }
    public var label: String {
        switch self {
        case .pdf: return "PDF"
        case .word: return "Word document"
        case .slides: return "Slide deck"
        case .text: return "Text"
        }
    }
}
