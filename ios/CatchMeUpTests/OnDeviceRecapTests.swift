import XCTest
@testable import CatchMeUp

/// Guided generation removes the malformed-JSON failure mode, but it doesn't
/// stop a model filling a required field with nothing. These cover the cleanup
/// between what the schema guarantees and what the recap screen can render.
@available(iOS 26.0, *)
final class OnDeviceRecapConversionTests: XCTestCase {

    // MARK: Timestamps

    /// The pattern guide permits a single-digit hour, and a short recording
    /// tends to come back as MM:SS. `Bookmark.seconds` has to be able to place
    /// every one of them on the audio.
    func testStampsAreNormalisedToHHMMSS() {
        XCTAssertEqual(OnDeviceRecap.stamp("1:02:03"), "01:02:03")
        XCTAssertEqual(OnDeviceRecap.stamp("01:02:03"), "01:02:03")
        XCTAssertEqual(OnDeviceRecap.stamp("5:03"), "00:05:03")
        XCTAssertEqual(OnDeviceRecap.stamp("  12:34:56  "), "12:34:56")
    }

    func testNormalisedStampsAreSeekable() {
        let bookmark = Bookmark(timestamp: OnDeviceRecap.stamp("7:30"), heading: "h", insight: "i")
        XCTAssertEqual(bookmark.seconds, 450)
    }

    /// Something unparseable is passed through rather than replaced with a
    /// wrong-but-tidy zero, which would send the player to the wrong place.
    func testUnparseableStampIsLeftAlone() {
        XCTAssertEqual(OnDeviceRecap.stamp("early on"), "early on")
        XCTAssertEqual(OnDeviceRecap.stamp(""), "")
    }

    // MARK: Empty sections

    /// The recap screen hides a missing section and renders an empty one as a
    /// heading with nothing under it, so empty has to mean nil.
    func testEmptyListsBecomeNil() {
        XCTAssertNil(OnDeviceRecap.list([]))
        XCTAssertNil(OnDeviceRecap.list(["", "   ", "\n"]))
        XCTAssertEqual(OnDeviceRecap.list(["  kept  ", ""]), ["kept"])
    }

    func testEmptyTextBecomesNil() {
        XCTAssertNil(OnDeviceRecap.text("   "))
        XCTAssertEqual(OnDeviceRecap.text("  A title "), "A title")
    }

    // MARK: Lecture

    func testLectureConversionDropsPlaceholders() {
        let generated = GeneratedLectureRecap(
            title: "   ",
            tldr: ["Strings are immutable", "  "],
            bookmarks: [GeneratedMoment(timestamp: "4:05", heading: "Slicing", insight: "Comes up on the exam."),
                        GeneratedMoment(timestamp: "9:00", heading: "  ", insight: "no heading, drop it")],
            detailedNotes: [GeneratedSection(heading: "Slicing", content: "  Start, stop, step.  "),
                            GeneratedSection(heading: "Empty", content: "   ")],
            terms: [GeneratedTerm(term: "immutable", definition: "cannot be changed in place"),
                    GeneratedTerm(term: "half-filled", definition: "  ")],
            study: []
        )

        let recap = generated.recap
        XCTAssertNil(recap.title, "an empty title from a later part must not become a blank heading")
        XCTAssertEqual(recap.tldr, ["Strings are immutable"])
        XCTAssertEqual(recap.bookmarks?.count, 1)
        XCTAssertEqual(recap.bookmarks?.first?.timestamp, "00:04:05")
        XCTAssertEqual(recap.detailedNotes?.count, 1)
        XCTAssertEqual(recap.detailedNotes?.first?.content, "Start, stop, step.")
        XCTAssertEqual(recap.terms?.count, 1)
        XCTAssertNil(recap.study)
    }

    /// A lecture recap has no meeting-only sections at all, rather than empty ones.
    func testLectureConversionLeavesMeetingSectionsUnset() {
        let generated = GeneratedLectureRecap(
            title: "Lecture 12", tldr: ["a"], bookmarks: [], detailedNotes: [], terms: [], study: []
        )
        let recap = generated.recap
        XCTAssertNil(recap.actionItems)
        XCTAssertNil(recap.speakers)
    }

    // MARK: Meeting

    func testMeetingConversionKeepsUnnamedSpeakers() {
        let generated = GeneratedMeetingRecap(
            title: "Weekly sync",
            tldr: ["Shipped the billing fix"],
            actionItems: ["Jordan: send the changelog by Friday", ""],
            speakers: [GeneratedSpeaker(label: "Speaker 1", name: "", said: "ran the standup"),
                       GeneratedSpeaker(label: "  ", name: "  ", said: "nothing usable")],
            bookmarks: [GeneratedMoment(timestamp: "0:00:45", heading: "Decision", insight: "Ship on Friday.")],
            detailedNotes: [GeneratedSection(heading: "Billing", content: "Proration was wrong.")]
        )

        let recap = generated.recap
        XCTAssertEqual(recap.title, "Weekly sync")
        XCTAssertEqual(recap.actionItems, ["Jordan: send the changelog by Friday"])
        XCTAssertEqual(recap.speakers?.count, 1, "a speaker with no label and no name is not a speaker")
        XCTAssertEqual(recap.speakers?.first?.label, "Speaker 1")
        XCTAssertEqual(recap.bookmarks?.first?.timestamp, "00:00:45")
        XCTAssertNil(recap.terms)
        XCTAssertNil(recap.study)
    }

    /// The whole point of chunking: part 1 names the recording, later parts
    /// leave the title empty, and the merge keeps the one real title.
    func testGeneratedPartsMergeIntoOneRecap() {
        let first = GeneratedLectureRecap(
            title: "Lecture 12 — Strings", tldr: ["Strings are immutable"],
            bookmarks: [], detailedNotes: [GeneratedSection(heading: "Basics", content: "Indexing.")],
            terms: [], study: []
        ).recap

        let second = GeneratedLectureRecap(
            title: "", tldr: ["Slicing uses start:stop:step"],
            bookmarks: [], detailedNotes: [GeneratedSection(heading: "Slicing", content: "Step can be negative.")],
            terms: [], study: []
        ).recap

        let merged = RecapMerge.combine([first, second])
        XCTAssertEqual(merged.title, "Lecture 12 — Strings")
        XCTAssertEqual(merged.tldr?.count, 2)
        XCTAssertEqual(merged.detailedNotes?.count, 2)
    }
}

/// Guided generation gets its shape from the framework. Sending our JSON schema
/// as well would spend a window we chunked the transcript to fit, and hand the
/// model two descriptions of the same thing to reconcile.
final class RecapPromptTests: XCTestCase {

    func testGuidedPromptOmitsTheJSONSchema() {
        let prompt = Prompts.recapPrompt(
            transcript: "[00:00:00] Hello.", mode: .lecture, includeSchema: false
        )
        XCTAssertFalse(prompt.contains("Return ONLY valid JSON"))
        XCTAssertFalse(prompt.contains("detailed_notes"))
        XCTAssertTrue(prompt.contains("[00:00:00] Hello."))
        XCTAssertTrue(prompt.contains("quiz"), "the role instruction still has to be there")
    }

    func testTextPromptUsesTheUnionSchema() {
        let lecture = Prompts.recapPrompt(transcript: "[00:00:00] Hello.", mode: .lecture)
        XCTAssertTrue(lecture.contains("Return ONLY valid JSON"))
        XCTAssertTrue(lecture.contains("detailed_notes"))
        XCTAssertTrue(lecture.contains("action_items"), "lectures can have follow-ups")
        XCTAssertTrue(lecture.contains("terms"))

        let meeting = Prompts.recapPrompt(transcript: "[00:00:00] Hello.", mode: .meeting)
        XCTAssertTrue(meeting.contains("terms"), "meetings can teach")
        XCTAssertTrue(meeting.contains("action_items"))
        XCTAssertFalse(lecture.contains("Do not write as if this were a business meeting"))
    }

    /// A single-window recording must not be told it's "part 1 of 1" — that
    /// invites the model to hedge about material that isn't missing.
    func testSingleWindowHasNoPartFraming() {
        let prompt = Prompts.recapPrompt(transcript: "x", mode: .meeting, part: 1, of: 1)
        XCTAssertFalse(prompt.contains("part 1 of 1"))
        XCTAssertTrue(prompt.contains("Transcript (timestamped):"))
    }

    func testChunkedPromptTellsTheModelWhichPartItIs() {
        let first = Prompts.recapPrompt(transcript: "x", mode: .meeting, part: 1, of: 3)
        XCTAssertTrue(first.contains("part 1 of 3"))
        XCTAssertTrue(first.contains("Give the recording a title"))

        let later = Prompts.recapPrompt(transcript: "x", mode: .meeting, part: 2, of: 3)
        XCTAssertTrue(later.contains("part 2 of 3"))
        XCTAssertTrue(later.contains("Leave the title empty"))
    }
}
