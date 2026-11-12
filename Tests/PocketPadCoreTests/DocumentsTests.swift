import XCTest
@testable import PocketPadCore

final class DocumentsTests: XCTestCase {
    /// Zips `files` with the system zip tool (deflate, like Office does) and returns the archive.
    private func makeZip(_ files: [String: String], ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        for (name, text) in files {
            let url = dir.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let out = dir.appending(path: "doc.\(ext)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-q", "-r", out.path] + files.keys.sorted()
        try p.run()
        p.waitUntilExit()
        return out
    }

    func testWordHeadingsListsTablesAndPages() throws {
        let w = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        let xml = """
        <w:document \(w)><w:body>
        <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Plan</w:t></w:r></w:p>
        <w:p><w:pPr><w:numPr><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Ship by </w:t></w:r><w:r><w:t>March</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:br w:type="page"/><w:t>Risks</w:t></w:r></w:p>
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Marco</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Guide</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        </w:body></w:document>
        """
        let doc = try DocumentReader.read(try makeZip(["word/document.xml": xml], ext: "docx"))
        XCTAssertEqual(doc.kind, .word)
        XCTAssertEqual(doc.parts.map(\.text), ["# Plan\n- Ship by March", "## Risks\nMarco | Guide"])
        XCTAssertEqual(doc.sizeDescription, "2 pages")
        XCTAssertTrue(doc.annotatedText.hasPrefix("[Page 1]\n# Plan"))
    }

    func testSlidesFollowPresentationOrderAndIncludeNotes() throws {
        let ns = #"xmlns:a="a" xmlns:p="p" xmlns:r="r""#
        func slide(_ t: String) -> String {
            "<p:sld \(ns)><a:p><a:r><a:t>\(t)</a:t></a:r></a:p><a:p><a:fld type=\"slidenum\"><a:t>9</a:t></a:fld></a:p></p:sld>"
        }
        let rel = #"<Relationships xmlns="x">"#
        let url = try makeZip([
            "ppt/slides/slide1.xml": slide("Second"),
            "ppt/slides/slide2.xml": slide("First"),
            "ppt/presentation.xml": "<p:presentation \(ns)><p:sldIdLst><p:sldId r:id=\"rId2\"/><p:sldId r:id=\"rId1\"/></p:sldIdLst></p:presentation>",
            "ppt/_rels/presentation.xml.rels": rel + #"<Relationship Id="rId1" Target="slides/slide1.xml"/><Relationship Id="rId2" Target="slides/slide2.xml"/></Relationships>"#,
            "ppt/slides/_rels/slide1.xml.rels": rel + #"<Relationship Id="rId1" Target="../notesSlides/notesSlide4.xml"/></Relationships>"#,
            "ppt/notesSlides/notesSlide4.xml": slide("Say hello"),
        ], ext: "pptx")
        let doc = try DocumentReader.read(url)
        XCTAssertEqual(doc.parts.map(\.text), ["First", "Second\n\nSpeaker notes: Say hello"])
        XCTAssertEqual(doc.unitName, "Slide")
    }

    func testOldFormatsExplainWhatToDo() {
        XCTAssertNotNil(DocumentReader.unsupportedReason(fileName: "old.doc"))
        XCTAssertNotNil(DocumentReader.unsupportedReason(fileName: "deck.key"))
        XCTAssertTrue(DocumentReader.canRead(fileName: "A.PDF"))
        XCTAssertFalse(DocumentReader.canRead(fileName: "talk.m4a"))
    }

    func testPDFLineJoining() {
        XCTAssertEqual(DocumentReader.tidyPDFText("The quick brown\nfox jumps over the\nlazy dog.\n\nNew para-\ngraph here."),
                       "The quick brown fox jumps over the lazy dog.\n\nNew paragraph here.")
        XCTAssertEqual(DocumentReader.tidyPDFText("Goals:\nship it\n• one\n• two"), "Goals:\nship it\n• one\n• two")
    }

    func testChunksRepeatThePageTheyStartIn() {
        let lines = ["[Page 1]", String(repeating: "a", count: 40), String(repeating: "b", count: 40), "[Page 2]", "c"]
        let chunks = Summarizer.chunk(lines: lines, limit: 55) { $0.hasPrefix("[Page ") }
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks[1].hasPrefix("[Page 1]\nbbbb"))
        XCTAssertTrue(chunks[2].hasPrefix("[Page 2]"))
    }

    func testOldLibraryItemsStillDecode() throws {
        let json = #"{"id":"6B1E3F0A-1111-4222-8333-944455556666","title":"Standup","titleIsAutomatic":true,"createdAt":0,"audioFileName":"x.m4a","status":"ready","checkedActions":[]}"#
        let item = try JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8))
        XCTAssertNil(item.document)
        XCTAssertFalse(item.isDocument)
    }
}
