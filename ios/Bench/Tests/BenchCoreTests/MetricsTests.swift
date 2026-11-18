import XCTest
@testable import BenchCore

final class MetricsTests: XCTestCase {

    private let transcript = """
    [00:00:05] Speaker 1: Tomas will ship the fix by Thursday.
    [00:01:00] Speaker 2: The quote is 24,000 dollars, up from 20,000 last year.
    [00:02:30] Speaker 1: Version 3 goes out on June 17.
    """

    private func item(gold: Gold = Gold()) -> CorpusItem {
        CorpusItem(id: "t", mode: .meeting, title: "t", transcript: transcript, gold: gold)
    }

    // MARK: Bookmarks

    func testBookmarksMustBeSeekableAndNearARealLine() {
        var recap = Recap()
        recap.bookmarks = [
            Bookmark(timestamp: "00:01:00", heading: "quote", insight: "i"),   // exact
            Bookmark(timestamp: "00:01:40", heading: "near", insight: "i"),    // 40s from a line: ok
            Bookmark(timestamp: "00:30:00", heading: "far", insight: "i"),     // far past the end
            Bookmark(timestamp: "soon", heading: "garbage", insight: "i"),     // unparseable
        ]
        let m = RecapAnalysis.metrics(for: recap, item: item())
        XCTAssertEqual(m.bookmarks, 4)
        XCTAssertEqual(m.bookmarksSeekable, 3)
        XCTAssertEqual(m.bookmarksGrounded, 2)
        XCTAssertEqual(m.groundedRate, 0.5)
    }

    func testNoBookmarksGivesNoRateRatherThanPerfect() {
        let m = RecapAnalysis.metrics(for: Recap(), item: item())
        XCTAssertNil(m.groundedRate)
        XCTAssertTrue(m.emptyCore)
    }

    // MARK: Names

    func testInventedSpeakerNameIsCaughtAndRealOnesAreNot() {
        var recap = Recap()
        recap.speakers = [
            SpeakerNote(label: "Speaker 1", name: "Tomas", said: "x"),
            SpeakerNote(label: "Speaker 2", name: "Priya", said: "x"),
            SpeakerNote(label: "Speaker 3", name: "", said: "x"),
            SpeakerNote(label: "Speaker 4", name: "Speaker 4", said: "x"),
        ]
        let m = RecapAnalysis.metrics(for: recap, item: item())
        XCTAssertEqual(m.namedSpeakers, 2)
        XCTAssertEqual(m.inventedSpeakerNames, ["Priya"])
    }

    func testOneNameOnTwoSpeakersIsAClashEvenThoughTheNameIsReal() {
        var recap = Recap()
        recap.speakers = [
            SpeakerNote(label: "Speaker 1", name: "Tomas", said: "x"),
            SpeakerNote(label: "Speaker 2", name: "Tomas", said: "x"),
            SpeakerNote(label: "Speaker 1", name: "Tomas", said: "same label twice is fine"),
        ]
        let m = RecapAnalysis.metrics(for: recap, item: item())
        XCTAssertEqual(m.inventedSpeakerNames, [])
        XCTAssertEqual(m.speakerNameClashes, ["tomas"])
    }

    func testForbiddenNamesAreMatchedAsWholeWordsAnywhere() {
        var recap = Recap()
        recap.tldr = ["Sarah will follow up", "Alexander is mentioned"]
        let gold = Gold(forbiddenNames: ["Sarah", "Alex"])
        let m = RecapAnalysis.metrics(for: recap, item: item(gold: gold))
        XCTAssertEqual(m.forbiddenNameHits, ["Sarah"], "Alex must not match inside Alexander")
    }

    // MARK: Numbers

    func testNumbersIgnoreTimestampsCommasAndSingleDigits() {
        var recap = Recap()
        recap.tldr = [
            "Quote is 24,000 versus 20,000 [00:01:00].",   // both in the transcript
            "There are 2 options and 3 steps.",              // single digits are scaffolding
            "Seats drop to 25 from 60.",                     // neither is in the transcript
        ]
        let m = RecapAnalysis.metrics(for: recap, item: item())
        XCTAssertEqual(m.numbersChecked, 4)
        XCTAssertEqual(Set(m.unsupportedNumbers), ["25", "60"])
        XCTAssertEqual(m.unsupportedNumberRate, 0.5)
    }

    func testDecimalsAreCheckedEvenWhenShort() {
        let numbers = RecapAnalysis.numbers(in: "about 1.5 and 7 and 12", filterSmall: true)
        XCTAssertEqual(numbers, ["1.5", "12"])
    }

    // MARK: Gold facts

    func testFactCoverageIgnoresCaseAndPunctuation() {
        var recap = Recap()
        recap.detailedNotes = [DetailNote(heading: "Release", content: "Launch moves to JUNE 17, per the plan.")]
        recap.tldr = ["The fix ships Thursday"]
        let gold = Gold(facts: [
            GoldFact(id: "date", anyOf: ["june 17"]),
            GoldFact(id: "fix", anyOf: ["by thursday", "ships thursday"]),
            GoldFact(id: "price", anyOf: ["$99"]),
        ])
        let m = RecapAnalysis.metrics(for: recap, item: item(gold: gold))
        XCTAssertEqual(m.factsTotal, 3)
        XCTAssertEqual(m.factsFound, 2)
        XCTAssertEqual(m.missingFacts, ["price"])
        XCTAssertEqual(m.factCoverage ?? 0, 2.0 / 3.0, accuracy: 1e-9)
    }

    func testAnEmptyPhraseNeverCountsAsFound() {
        let gold = Gold(facts: [GoldFact(id: "blank", anyOf: ["", "..."])])
        let m = RecapAnalysis.metrics(for: Recap(), item: item(gold: gold))
        XCTAssertEqual(m.factsFound, 0)
    }

    // MARK: Rendering

    func testMarkdownHasEveryPopulatedSectionAndNoEmptyOnes() {
        var recap = Recap()
        recap.title = "Standup"
        recap.tldr = ["Ship Thursday"]
        recap.bookmarks = [Bookmark(timestamp: "00:00:05", heading: "Fix", insight: "ships")]
        let md = RecapAnalysis.markdown(recap)
        XCTAssertTrue(md.contains("# Standup"))
        XCTAssertTrue(md.contains("## Summary"))
        XCTAssertTrue(md.contains("[00:00:05] Fix: ships"))
        XCTAssertFalse(md.contains("## Terms"))
    }
}
