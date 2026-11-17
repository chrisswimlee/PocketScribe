import XCTest
@testable import PocketScribeCore

// DeveloperToolsSupport (pulled in with SwiftUI) also has a LibraryItem.
private typealias LibraryItem = PocketScribeCore.LibraryItem

final class ConnectionsTests: XCTestCase {
    private func item(_ title: String, _ summary: String, daysAgo: Double = 0, names: [Int: String]? = nil,
                      tags: [String]? = nil, note: Bool = false) -> LibraryItem {
        var i = LibraryItem(title: title, createdAt: Date().addingTimeInterval(-daysAgo * 86_400),
                            audioFileName: "a.caf", status: .ready)
        i.summary = summary
        i.speakerNames = names
        i.tags = tags
        if note { i.noteKind = .idea }
        return i
    }

    private let planning = """
    ## TL;DR
    The beta build crashes on older iPhones. The free tier gets 20 summaries a month and pricing is set.

    ## Action items
    - [ ] Maria: review the beta crash fix by Thursday [00:10]
    - [ ] David: submit the build on Nov 14 [01:58]
    """

    private let launch = """
    ## TL;DR
    Pricing for the free tier and the paid tier is final. Support gets a shared inbox before launch, and the beta build ships first.

    ## Action items
    - [ ] Maria: set up the shared inbox [02:20]
    """

    func testActionLinesForSummaryAndNote() {
        XCTAssertEqual(item("Planning", planning).actionLines.count, 2)
        let n = item("Errands", "Buy milk\n- [ ] Call the dentist\n- [ ] Book the car service", note: true)
        XCTAssertEqual(n.actionLines, ["Call the dentist", "Book the car service"])
    }

    func testTasksAcrossLibrarySkipDoneAndDeleted() {
        var a = item("Planning", planning, daysAgo: 1)
        a.checkedActions = [1]
        let b = item("Launch", launch)
        var gone = item("Old", launch, daysAgo: 3)
        gone.deletedAt = Date()

        let groups = LibraryTasks.groups(in: [a, b, gone], includeDone: false)
        XCTAssertEqual(groups.map(\.item.title), ["Launch", "Planning"], "newest note first, deleted left out")
        XCTAssertEqual(groups[1].tasks.map(\.index), [0], "the ticked task is hidden")
        XCTAssertEqual(groups[1].tasks.first?.seconds, 10)
        XCTAssertFalse(groups[1].tasks.first?.title.contains("[00:10]") ?? true)
        XCTAssertEqual(LibraryTasks.openCount(in: [a, b, gone]), 2)

        let kept = LibraryTasks.groups(in: [a], includeDone: false, keeping: ["\(a.id.uuidString)-1"])
        XCTAssertEqual(kept.first?.tasks.map(\.index), [0, 1], "a task just ticked stays until the list is left")
        XCTAssertEqual(LibraryTasks.groups(in: [a], includeDone: true).first?.tasks.count, 2)
    }

    func testRelatedBySharedPersonAndWords() {
        let a = item("Weekly planning", planning, names: [1: "Maria", 2: "David"])
        let b = item("Launch and support", launch, daysAgo: 1, names: [1: "Maria"])
        let c = item("Grocery list", "Eggs, bread and coffee for the weekend.", note: true)
        let related = Connections.related(to: a, in: [a, b, c])
        XCTAssertEqual(related.map(\.id), [b.id])
        XCTAssertTrue(related[0].reason.contains("Also with Maria"), related[0].reason)
    }

    /// The two launch meetings, with no names given: shared words alone relate them.
    func testMeetingsRelateByWordsAlone() {
        let a = item("Weekly planning", planning)
        let b = item("Launch and support", launch, daysAgo: 1)
        let r = Connections.related(to: a, in: [a, b])
        XCTAssertEqual(r.map(\.id), [b.id])
        XCTAssertTrue(r.first?.reason.hasPrefix("Both mention ") == true, r.first?.reason ?? "none")
    }

    func testUnnamedSpeakerIsLeftOffTasks() {
        let a = item("Sync", "## Action items\n- [ ] Speaker 3: review the font code [00:10]")
        XCTAssertEqual(LibraryTasks.groups(in: [a], includeDone: false).first?.tasks.first?.title, "Review the font code")
    }

    /// When the word-type model is missing, plain words still give the topic.
    func testPlainWordFallback() {
        let words = Connections.plainKeywords(in: "Pricing for the launch. The pricing page should launch before Friday with the shared inbox.")
        XCTAssertEqual(Array(words.prefix(2)), ["launch", "pricing"])
        XCTAssertFalse(words.contains("should"))
        XCTAssertFalse(words.contains("before"))
        XCTAssertFalse(Connections.plainKeywords(in: "Ship in November, November launch").contains("november"))
    }

    func testDisplayRenamesTLDRAndDropsFiller() {
        let md = "## TL;DR\nShip Friday.\n\n## Action items\n- [ ] Send the build\nNo more tasks.\n- None"
        let out = SummaryLayout.forDisplay(md)
        XCTAssertTrue(out.hasPrefix("## In short\nShip Friday."))
        XCTAssertFalse(out.contains("No more tasks"))
        XCTAssertFalse(out.contains("- None"))
        XCTAssertTrue(out.contains("- [ ] Send the build"))
    }

    func testOneSharedWordIsNotEnough() {
        let a = item("Launch", "We talked about the launch.")
        let b = item("Party", "The launch party needs balloons.")
        XCTAssertTrue(Connections.related(to: a, in: [a, b]).isEmpty)
    }

    func testSharedTagCounts() {
        let a = item("Idea one", "Cap the free tier by summaries.", tags: ["pricing"], note: true)
        let b = item("Idea two", "Competitors charge monthly with a trial.", tags: ["pricing"], note: true)
        let r = Connections.related(to: a, in: [a, b])
        XCTAssertEqual(r.first?.reason, "Both tagged #pricing")
    }

    func testPeopleSkipUnnamedSpeakers() {
        let a = item("Sync", planning, names: [1: "Maria", 2: "Speaker 2"])
        XCTAssertEqual(Connections.people(of: a), ["Maria"])
    }

    func testKeywordsIgnoreTimestampsAndFillerWords() {
        let words = Connections.keywords(in: "## TL;DR\nPricing, pricing and the shared inbox [01:20](seek://80). Meeting notes.")
        XCTAssertEqual(words.first, "pricing")
        XCTAssertFalse(words.contains("meeting"))
        XCTAssertFalse(words.contains { $0.contains("seek") })
    }

    func testSearchFindsPeople() {
        let a = item("Sync", planning, names: [1: "Maria"])
        XCTAssertTrue(LibrarySearch.matches(a, "mari"))
        XCTAssertFalse(LibrarySearch.matches(a, "Zed"))
    }
}
