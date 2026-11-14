import XCTest
@testable import PocketScribeCore

final class StyleAndNamesTests: XCTestCase {
    private func seg(_ start: Double, _ speaker: Int?, _ text: String) -> TranscriptSegment {
        .init(start: start, end: start + 4, text: text, speaker: speaker)
    }

    /// The 2:51 three-person meeting from the UI review, shortened.
    private var shortMeeting: Transcript {
        let segs = [
            seg(0, 1, "Hi everyone, I'm Maria and I'll run this quick sync about the support launch next week."),
            seg(6, 2, "Thanks Maria. The help center articles are drafted and ready for review by Thursday."),
            seg(14, 3, "Good point, Tom. I still need to set up the shared inbox and the routing rules for it."),
            seg(22, 1, "Great. David, can you send the build to Tom by Wednesday so he can test it before launch?"),
            seg(30, 3, "Yes, I'll send the build to Tom on Wednesday morning and set up the shared inbox."),
            seg(38, 2, "Perfect, I will review the articles and the inbox setup once the build arrives, Maria."),
        ]
        return Transcript(text: segs.map(\.text).joined(separator: " "), segments: segs, audioDuration: 171, processingTime: 1)
    }

    func testShortConversationIsAMeeting() {
        XCTAssertEqual(shortMeeting.conversationSpeakerCount, 3)
        XCTAssertEqual(Summarizer.automaticStyle(for: shortMeeting), .meeting)
    }

    func testShortMonologueIsANote() {
        let t = Transcript(text: "Buy milk and call the dentist tomorrow morning.",
                           segments: [seg(0, nil, "Buy milk and call the dentist tomorrow morning.")],
                           audioDuration: 20, processingTime: 0)
        XCTAssertEqual(Summarizer.automaticStyle(for: t), .note)
        var long = t
        long.audioDuration = 600
        XCTAssertEqual(Summarizer.automaticStyle(for: long), .meeting)
    }

    func testABlipFromASecondVoiceIsStillANote() {
        let words = Array(repeating: "word", count: 60).joined(separator: " ")
        let t = Transcript(text: words, segments: [seg(0, 1, words), seg(30, 2, "Mm hm.")], audioDuration: 45, processingTime: 0)
        XCTAssertEqual(t.conversationSpeakerCount, 1)
        XCTAssertEqual(Summarizer.automaticStyle(for: t), .note)
    }

    func testSuggestsNamesFromIntroductionsAndAddresses() {
        let names = Speakers.suggestedNames(in: shortMeeting)
        XCTAssertEqual(names[1], "Maria")
        XCTAssertEqual(names[2], "Tom")
        XCTAssertEqual(names[3], "David")
    }

    /// What the diarizer actually produced for the review's test meeting (Samantha = Maria,
    /// Daniel = David, Fred = Tom), including its mistake of splitting "thank you / Tom."
    func testReviewMeetingNames() {
        let lines: [(Int, String)] = [
            (1, "Okay, let's get started."), (1, "I'm Maria, and I'll run through the agenda quickly."),
            (2, "Thanks Maria."), (2, "Before we start, I want to flag that the beta build is still crashing."),
            (1, "Good to know."), (1, "How bad is it?"),
            (3, "I wrote most of the font code, so it's probably my fault anyway."),
            (3, "Great, thank you"), (1, "Tom."), (1, "Can you have a fix ready by Thursday?"),
            (3, "Thursday should be fine."), (3, "I'll send a bill to David for testing on Thursday afternoon."),
            (2, "Perfect."), (3, "One more thing on pricing."),
            (1, "Good point, David."), (1, "Can you check the screenshots?"),
            (2, "Sure."), (2, "I'll review all the screenshots this week."),
        ]
        let segs = lines.enumerated().map { seg(Double($0.offset) * 5, $0.element.0, $0.element.1) }
        let t = Transcript(text: "", segments: segs, audioDuration: 171, processingTime: 0)
        let names = Speakers.suggestedNames(in: t)
        XCTAssertEqual(names[1], "Maria")
        XCTAssertEqual(names[2], "David")
        XCTAssertNotEqual(names[3], "David")
    }

    func testNoGuessWithoutEvidence() {
        let t = Transcript(text: "", segments: [seg(0, 1, "Okay, let's start."), seg(5, 2, "Sure, Monday works.")],
                           audioDuration: 60, processingTime: 0)
        XCTAssertEqual(Speakers.suggestedNames(in: t), [:])
    }

    func testPendingSuggestionsSkipNamedSpeakers() {
        let pending = Speakers.pendingSuggestions(in: shortMeeting, names: [1: "Maria R."])
        XCTAssertNil(pending[1])
        XCTAssertEqual(pending[2], "Tom")
        XCTAssertEqual(Speakers.suggestionSentence([1: "Maria", 2: "Tom"]), "Speaker 1 might be Maria and Speaker 2 might be Tom.")
    }

    func testOwnersBecomeLabelsAndDuplicatesMerge() {
        let md = """
        ## TL;DR
        Launch sync.

        ## Action items
        - [ ] Maria: set up the shared inbox [00:14]
        - [ ] Speaker 3: Set up the shared inbox (by Wednesday)
        - [ ] David: send the build to Tom (by Wednesday)
        - [ ] Review the help center articles

        ## Decisions
        - Launch next week.
        """
        let owners = Speakers.labelOwners(md, names: [1: "Maria", 3: "David"])
        XCTAssertTrue(owners.contains("- [ ] Speaker 1: set up the shared inbox [00:14]"))
        XCTAssertTrue(owners.contains("- [ ] Speaker 3: send the build to Tom"))
        let merged = Summarizer.mergeDuplicateActions(owners)
        XCTAssertEqual(SummaryLayout.splitActions(merged).actions, [
            "Speaker 1: set up the shared inbox (by Wednesday) [00:14]",
            "Speaker 3: send the build to Tom (by Wednesday)",
            "Review the help center articles",
        ])
        XCTAssertTrue(merged.contains("## Decisions"))
    }

    // MARK: Follow-ups from the PR 1 review

    private func actions(_ items: [String]) -> [String] {
        let md = "## Action items\n" + items.map { "- [ ] " + $0 }.joined(separator: "\n") + "\n\n## Decisions\n- None."
        return SummaryLayout.splitActions(Summarizer.mergeDuplicateActions(md)).actions
    }

    func testTasksForDifferentPeopleStayApart() {
        XCTAssertEqual(actions([
            "Speaker 3: send the build to Tom Wednesday morning",
            "Speaker 3: send the build to David Wednesday morning",
        ]).count, 2)
    }

    func testSimilarTasksWithDifferentOwnersStayApart() {
        XCTAssertEqual(actions([
            "Speaker 1: review the help center articles",
            "Speaker 2: review the help center articles before launch",
        ]).count, 2)
    }

    func testMergedTaskKeepsALaterOwnerAndDeadline() {
        XCTAssertEqual(actions([
            "Set up the shared inbox [00:14](seek://14)",
            "Speaker 3: set up the shared inbox and routing (by Friday)",
        ]), ["Speaker 3: Set up the shared inbox (by Friday) [00:14](seek://14)"])
    }

    func testSoloMemoSplitIntoTwoVoicesIsANote() {
        // One person thinking aloud for 70 s; the labeler put a few stretches under a second voice.
        let a = "I need to remember to book the venue for the offsite and check the catering budget with finance before Friday"
        let b = "and also the slides for the keynote need another pass before we share them"
        let segs = [seg(0, 1, a), seg(10, 2, b), seg(14, 1, a), seg(24, 2, b), seg(28, 1, a), seg(40, 1, a)]
        let t = Transcript(text: "", segments: segs, audioDuration: 70, processingTime: 0)
        XCTAssertEqual(t.conversationSpeakerCount, 2)
        XCTAssertEqual(Summarizer.automaticStyle(for: t), .note)
        XCTAssertTrue(shortMeeting.hasBackAndForth)
    }

    func testDismissedSuggestionsStillNameOwners() {
        let summary = """
        ## Action items
        - [ ] Speaker 1: run the launch checklist
        - [ ] Speaker 3: send the build to Tom
        Speaker 1 agreed.
        """
        var item = LibraryItem(title: "Sync", audioFileName: "a.caf", status: .ready)
        item.transcript = shortMeeting
        item.summary = summary
        item.nameSuggestionsDismissed = true
        XCTAssertEqual(item.pendingNameSuggestions, [:])
        let shown = item.displaySummary ?? ""
        XCTAssertTrue(shown.contains("- [ ] Maria: run the launch checklist"))
        XCTAssertTrue(shown.contains("- [ ] David: send the build to Tom"))
        XCTAssertTrue(shown.contains("Speaker 1 agreed."))
        // A name the user typed wins over the guess.
        item.speakerNames = [1: "Maria R."]
        XCTAssertTrue((item.displaySummary ?? "").contains("- [ ] Maria R.: run the launch checklist"))
        XCTAssertTrue((item.displaySummary ?? "").contains("Maria R. agreed."))
    }

    func testNameSuggestionsOnAnHourLongMeetingAreQuick() {
        var segs: [TranscriptSegment] = []
        let lines = ["Thanks Maria, that makes sense to me and I agree with the plan.",
                     "Good point, Tom. Let's move on to the next item on the agenda then.",
                     "David, can you share the numbers from last week with everyone here?"]
        for i in 0..<1800 { segs.append(seg(Double(i) * 2, i % 3 + 1, lines[i % 3])) }
        let t = Transcript(text: "", segments: segs, audioDuration: 3600, processingTime: 0)
        let start = Date()
        _ = Speakers.suggestedNames(in: t)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        let id = UUID()
        let first = SpeakerSuggestionCache.shared.suggestions(for: id, transcript: t)
        let again = Date()
        XCTAssertEqual(SpeakerSuggestionCache.shared.suggestions(for: id, transcript: t), first)
        XCTAssertLessThan(Date().timeIntervalSince(again), 0.05)
    }
}
