import XCTest
@testable import PocketScribeCore

final class SourceLinksTests: XCTestCase {
    let transcript = Transcript(text: "", segments: [
        .init(start: 0, end: 8, text: "Okay, let's get started with the weekly sync."),
        .init(start: 8, end: 20, text: "First, the payments launch is moving to March because the bank integration slipped."),
        .init(start: 20, end: 35, text: "We need the compliance review signed off before then."),
        .init(start: 75, end: 90, text: "On hiring, we will open two backend engineer roles next week."),
        .init(start: 130, end: 145, text: "Maria will send the updated budget spreadsheet to finance by Friday."),
        .init(start: 145, end: 160, text: "Thanks everyone, see you next Tuesday."),
    ], audioDuration: 160, processingTime: 0)

    func testAddsMissingTimestamps() {
        let summary = """
        ## TL;DR
        The team moved the payments launch and planned hiring.

        ## Key points
        - Payments launch moves to March after the bank integration slipped
        - Two backend engineer roles open next week

        ## Action items
        - [ ] Maria: send the updated budget spreadsheet to finance (by Friday)
        """
        let out = SourceLinker.link(summary, transcript: transcript)
        XCTAssertTrue(out.contains("bank integration slipped [00:08]"), out)
        XCTAssertTrue(out.contains("open next week [01:15]"), out)
        XCTAssertTrue(out.contains("(by Friday) [02:10]"), out)
        // TL;DR isn't a bullet list and stays as written.
        XCTAssertTrue(out.contains("The team moved the payments launch and planned hiring.\n"), out)
        XCTAssertEqual(SourceLinker.coverage(of: out).unlinked, 0)
    }

    func testMovesWrongTimestampAndKeepsRightOne() {
        let summary = """
        ## Key points
        - [00:00] Two backend engineer roles open next week
        - Compliance review must be signed off [00:21]
        """
        let out = SourceLinker.link(summary, transcript: transcript)
        XCTAssertTrue(out.contains("- [01:15] Two backend engineer roles"), out)
        XCTAssertTrue(out.contains("signed off [00:21]"), out)
    }

    func testLeavesUnsupportedPointsUnlinked() {
        let summary = """
        ## Key points
        - Revenue grew forty percent in Europe
        """
        let out = SourceLinker.link(summary, transcript: transcript)
        XCTAssertEqual(out, summary)
        let c = SourceLinker.coverage(of: out)
        XCTAssertEqual(c.linked, 0)
        XCTAssertEqual(c.unlinked, 1)
    }

    func testDocumentPagesAreAddedAndCorrected() {
        let doc = DocumentText(kind: .slides, parts: [
            .init(number: 1, text: "Quarterly review agenda"),
            .init(number: 2, text: "Churn fell to 3.1 percent after the onboarding redesign"),
            .init(number: 3, text: "Next quarter: expand the partner program into Japan and Korea"),
        ])
        let summary = """
        ## Key points
        - Churn fell to 3.1% after the onboarding redesign
        - Partner program expands into Japan and Korea (slide 1)

        ## Key terms
        - **Churn**: customers who leave
        """
        let out = SourceLinker.link(summary, document: doc)
        XCTAssertTrue(out.contains("onboarding redesign (slide 2)"), out)
        XCTAssertTrue(out.contains("Japan and Korea (slide 3)"), out)
        XCTAssertTrue(out.contains("- **Churn**: customers who leave"), out)
    }

    func testPageLinksAndActionItemTitles() {
        XCTAssertEqual(SourceLinker.linkPages("Sign it (p. 4) and slide 7"),
                       "Sign it ([p. 4](page://4)) and [slide 7](page://7)")
        let linked = SourceLinker.linkAll("Do it (p. 4) [01:05]", pages: true)
        XCTAssertEqual(linked, "Do it ([p. 4](page://4)) [01:05](seek://65)")
        XCTAssertEqual(SourceLinker.linkPages(linked), linked)
        XCTAssertEqual(SourceLinker.pageNumber(URL(string: "page://4")!), 4)
        XCTAssertEqual(ActionItem(linked).title, "Do it")
        XCTAssertEqual(ActionItem("Send the contract to legal (p. 3)").title, "Send the contract to legal")
    }
}
