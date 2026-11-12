import FluidAudio
import XCTest
@testable import PocketPadCore

final class SpeakersAndActionsTests: XCTestCase {
    func testRenamedSpeakersReplaceLabels() {
        let names = [2: "Maria"]
        XCTAssertEqual(Speakers.apply(names, to: "Speaker 2 and Speaker 1 agreed; Speaker 21 too"),
                       "Maria and Speaker 1 agreed; Speaker 21 too")
        XCTAssertEqual(Speakers.name(1, in: [1: "  "]), "Speaker 1")
    }

    func testTimestampedTextIncludesSpeakers() {
        let t = Transcript(text: "Hi. Hello.", segments: [
            .init(start: 0, end: 1, text: "Hi.", speaker: 1),
            .init(start: 1, end: 2, text: "Hello.", speaker: 2),
        ], audioDuration: 2, processingTime: 0)
        XCTAssertEqual(t.speakers, [1, 2])
        XCTAssertEqual(t.timestampedText(speakerNames: [2: "Tom"]), "[00:00] Speaker 1: Hi.\n[00:01] Tom: Hello.")
    }

    func testOldTranscriptJSONStillDecodes() throws {
        let json = #"{"text":"a","segments":[{"start":0,"end":1,"text":"a"}],"audioDuration":1,"processingTime":0}"#
        let t = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        XCTAssertNil(t.segments[0].speaker)
        XCTAssertEqual(t.speakers, [])
    }

    private func word(_ w: String, _ s: Double) -> WordTiming {
        WordTiming(word: w, startTime: s, endTime: s + 0.3)
    }

    func testSpeakerChangeSplitsSentenceAndBlipsDoNot() {
        let words = ["I", "think", "people", "need", "to", "see", "it."].enumerated().map { word($0.element, Double($0.offset) * 0.4) }
        // Speaker changes for good after "need"; a one-word blip at "think" is ignored.
        let speakers: [Int?] = [1, 2, 1, 1, 2, 2, 2]
        let segs = Transcriber.sentences(from: words, speakers: speakers)
        XCTAssertEqual(segs.map(\.text), ["I think people need", "to see it."])
        XCTAssertEqual(segs.map(\.speaker), [1, 2])
    }

    func testAssignSpeakersNumbersByFirstAppearance() {
        let words = [word("a", 0), word("b", 1), word("c", 2)]
        let turns = [SpeakerTurn(start: 0, end: 1.2, speakerId: "S7"), SpeakerTurn(start: 1.9, end: 3, speakerId: "S3")]
        XCTAssertEqual(Transcriber.assignSpeakers(words: words, turns: turns), [1, 1, 2])
        // One voice only → no labels.
        XCTAssertEqual(Transcriber.assignSpeakers(words: words, turns: [turns[0]]), [nil, nil, nil])
    }

    func testActionItemParsing() {
        let item = ActionItem("Speaker 3: send the budget report (by Friday) [12:30](seek://750)", speakerNames: [3: "Sam"])
        XCTAssertEqual(item.title, "Sam: send the budget report")
        XCTAssertNotNil(item.due)
        XCTAssertFalse(item.dueHasTime)
        XCTAssertEqual(Calendar.current.component(.weekday, from: item.due!), 6)  // Friday

        let timed = ActionItem("Call the bank tomorrow at 3pm")
        XCTAssertTrue(timed.dueHasTime)
        XCTAssertEqual(Calendar.current.component(.hour, from: timed.suggestedEventStart()), 15)

        let afternoon = ActionItem("David: test the build by Thursday afternoon")
        XCTAssertTrue(afternoon.dueHasTime)
        XCTAssertEqual(afternoon.title, "David: test the build by Thursday afternoon")

        let plain = ActionItem("Set up a shared inbox")
        XCTAssertNil(plain.due)
        XCTAssertEqual(plain.title, "Set up a shared inbox")
        XCTAssertEqual(Calendar.current.component(.hour, from: plain.suggestedEventStart()), 9)
    }
}

