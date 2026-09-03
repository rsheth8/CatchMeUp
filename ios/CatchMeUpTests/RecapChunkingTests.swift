import XCTest
@testable import CatchMeUp

/// The bug these exist for: an hour of lecture used to be handed to the model
/// as `transcript.prefix(9000)`, so the notes covered the first ten minutes and
/// nothing said so.
final class TranscriptChunkerTests: XCTestCase {

    /// A transcript that fits is passed through untouched — a single-chunk run
    /// has to stay byte-identical to what the old code sent.
    func testShortTranscriptIsNotSplit() {
        let transcript = "[00:00:00] Hello.\n[00:00:18] Goodbye."
        let chunks = TranscriptChunker.chunks(transcript, maxCharacters: 5_000)
        XCTAssertEqual(chunks, [transcript])
    }

    func testEmptyTranscriptProducesNoChunks() {
        XCTAssertTrue(TranscriptChunker.chunks("", maxCharacters: 5_000).isEmpty)
    }

    /// Nothing is dropped: every line of an hour-long transcript appears in at
    /// least one chunk, including the last one.
    func testEveryLineSurvivesChunking() {
        let lines = (0..<400).map { "[\(Segment.hms(Double($0 * 9)))] Line number \($0) of the transcript." }
        let transcript = lines.joined(separator: "\n")
        XCTAssertGreaterThan(transcript.count, 9_000, "fixture must exceed the old truncation point")

        let chunks = TranscriptChunker.chunks(transcript, maxCharacters: 5_000)
        XCTAssertGreaterThan(chunks.count, 1)

        let combined = chunks.joined(separator: "\n")
        for line in lines {
            XCTAssertTrue(combined.contains(line), "lost \(line)")
        }
    }

    func testChunksStayNearTheBudget() {
        let lines = (0..<400).map { "[\(Segment.hms(Double($0 * 9)))] Line number \($0) of the transcript." }
        let budget = 5_000
        let chunks = TranscriptChunker.chunks(lines.joined(separator: "\n"), maxCharacters: budget)

        for chunk in chunks {
            // One line may push a chunk marginally over; a chunk twice the
            // budget would mean the split isn't working.
            XCTAssertLessThan(chunk.count, budget * 2)
        }
    }

    /// Consecutive chunks share a little context so a worked example doesn't
    /// lose its setup at the seam.
    func testChunksOverlapAtTheSeam() {
        let lines = (0..<200).map { "[\(Segment.hms(Double($0 * 9)))] Sentence \($0) with enough text to add up." }
        let chunks = TranscriptChunker.chunks(lines.joined(separator: "\n"), maxCharacters: 2_000)
        XCTAssertGreaterThan(chunks.count, 2)

        let firstChunkLines = chunks[0].components(separatedBy: "\n")
        let secondChunkLines = chunks[1].components(separatedBy: "\n")
        XCTAssertTrue(secondChunkLines.contains(firstChunkLines.last!),
                      "the seam should carry the previous line forward")
    }

    /// A single segment longer than the whole budget can't be split further.
    /// It should get its own chunk rather than spinning or being dropped.
    func testOversizedSingleLineTerminates() {
        let monster = "[00:00:00] " + String(repeating: "word ", count: 3_000)
        let transcript = monster + "\n[01:00:00] The end."
        let chunks = TranscriptChunker.chunks(transcript, maxCharacters: 1_000)

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.joined(separator: "\n").contains("The end."))
    }
}

final class RecapMergeTests: XCTestCase {

    /// A single part is returned as-is, so nothing about a normal-length
    /// recording changes.
    func testSinglePartPassesThrough() {
        let only = Recap(title: "Only", tldr: ["a", "a"])
        let merged = RecapMerge.combine([only])
        XCTAssertEqual(merged.title, "Only")
        XCTAssertEqual(merged.tldr, ["a", "a"], "single-part merging must not rewrite the model's output")
    }

    func testTitleComesFromTheFirstPartThatHasOne() {
        let parts = [
            Recap(title: "", tldr: ["x"]),
            Recap(title: "Lecture 12 — Strings", tldr: ["y"]),
        ]
        XCTAssertEqual(RecapMerge.combine(parts).title, "Lecture 12 — Strings")
    }

    /// Chunks overlap, so the same bullet arriving twice is expected.
    func testDuplicateBulletsAreCollapsed() {
        let parts = [
            Recap(tldr: ["Slicing uses start:stop:step", "Strings are immutable"]),
            Recap(tldr: ["Strings are immutable!", "Loops can walk a string"]),
        ]
        let merged = RecapMerge.combine(parts)
        XCTAssertEqual(merged.tldr?.count, 3, "punctuation shouldn't defeat the dedupe")
    }

    func testSameHeadingBecomesOneSection() {
        let parts = [
            Recap(detailedNotes: [DetailNote(heading: "Slicing", content: "First half.")]),
            Recap(detailedNotes: [DetailNote(heading: "Slicing", content: "Second half.")]),
        ]
        let merged = RecapMerge.combine(parts)
        XCTAssertEqual(merged.detailedNotes?.count, 1)
        XCTAssertTrue(merged.detailedNotes?.first?.content.contains("First half.") == true)
        XCTAssertTrue(merged.detailedNotes?.first?.content.contains("Second half.") == true)
    }

    func testBookmarksEndUpInTimeOrder() {
        let parts = [
            Recap(bookmarks: [Bookmark(timestamp: "00:40:00", heading: "Late", insight: "l")]),
            Recap(bookmarks: [Bookmark(timestamp: "00:02:00", heading: "Early", insight: "e")]),
        ]
        let merged = RecapMerge.combine(parts)
        XCTAssertEqual(merged.bookmarks?.map(\.heading), ["Early", "Late"])
    }

    /// A speaker named halfway through keeps the name across the whole recap.
    func testSpeakerNamesPropagateAcrossParts() {
        let parts = [
            Recap(speakers: [SpeakerNote(label: "Speaker 1", name: "", said: "opened the meeting")]),
            Recap(speakers: [SpeakerNote(label: "Speaker 1", name: "Jordan", said: "")]),
        ]
        let merged = RecapMerge.combine(parts)
        XCTAssertEqual(merged.speakers?.count, 1)
        XCTAssertEqual(merged.speakers?.first?.name, "Jordan")
        XCTAssertEqual(merged.speakers?.first?.said, "opened the meeting")
    }

    /// Empty sections must come back nil, because the UI renders an empty array
    /// as a heading with nothing under it.
    func testEmptySectionsAreNilNotEmpty() {
        let merged = RecapMerge.combine([Recap(tldr: ["a"]), Recap(tldr: ["b"])])
        XCTAssertNil(merged.terms)
        XCTAssertNil(merged.study)
        XCTAssertNil(merged.actionItems)
    }

    /// Dual on-device passes (meeting schema + lecture schema) have to become
    /// one recap with both jobs, which is what the Also-in-this-recording row
    /// is keyed off.
    func testMeetingAndLecturePartsMergeBothJobs() {
        let meeting = Recap(title: "Lab section",
                            tldr: ["Shipped the homework walkthrough"],
                            actionItems: ["Finish problem 3 by Friday"],
                            speakers: [SpeakerNote(label: "Speaker 1", name: "TA", said: "ran section")])
        let lecture = Recap(title: "",
                            tldr: ["Slicing is start:stop:step"],
                            terms: [Term(term: "slice", definition: "a copy of a range")],
                            study: ["Write a reverse slice"])
        let merged = RecapMerge.combine([meeting, lecture])
        XCTAssertEqual(merged.title, "Lab section")
        XCTAssertEqual(merged.actionItems, ["Finish problem 3 by Friday"])
        XCTAssertEqual(merged.terms?.first?.term, "slice")
        XCTAssertEqual(merged.study?.count, 1)
        XCTAssertTrue(merged.hasCommitments)
        XCTAssertTrue(merged.hasKnowledge)
        XCTAssertTrue(merged.hasSecondaryJob(dominant: .lecture))
        XCTAssertTrue(merged.hasSecondaryJob(dominant: .meeting))
    }
}

final class RecapParsingTests: XCTestCase {

    func testParsesFencedJSON() throws {
        let raw = """
        ```json
        {"title": "Fenced", "tldr": ["one"]}
        ```
        """
        XCTAssertEqual(try Recap.parse(raw).title, "Fenced")
    }

    func testParsesJSONWrappedInProse() throws {
        let raw = "Sure! Here are your notes:\n{\"title\": \"Wrapped\"}\nHope that helps."
        XCTAssertEqual(try Recap.parse(raw).title, "Wrapped")
    }

    func testSnakeCaseMapsToCamelCase() throws {
        let recap = try Recap.parse(#"{"action_items": ["ship it"], "detailed_notes": [{"heading": "h", "content": "c"}]}"#)
        XCTAssertEqual(recap.actionItems, ["ship it"])
        XCTAssertEqual(recap.detailedNotes?.first?.heading, "h")
    }

    func testUnionJSONKeepsBothJobs() throws {
        let recap = try Recap.parse("""
        {
          "title": "Office hours",
          "tldr": ["Went over slicing"],
          "action_items": ["Finish problem 3"],
          "terms": [{"term": "slice", "definition": "a copy of a range"}],
          "study": ["Reverse a string"]
        }
        """)
        XCTAssertEqual(recap.title, "Office hours")
        XCTAssertEqual(recap.actionItems, ["Finish problem 3"])
        XCTAssertEqual(recap.terms?.first?.term, "slice")
        XCTAssertEqual(recap.study, ["Reverse a string"])
    }

    /// The retry path keys off `badResponse`, so a decoding failure must never
    /// surface as a `DecodingError`.
    func testUnreadableOutputThrowsBadResponse() {
        do {
            _ = try Recap.parse("I'm afraid I can't help with that.")
            XCTFail("expected a throw")
        } catch EngineError.badResponse {
            // expected
        } catch {
            XCTFail("expected badResponse, got \(error)")
        }
    }

    func testTruncatedJSONThrowsBadResponse() {
        do {
            _ = try Recap.parse(#"{"title": "cut off", "tldr": ["a", "#)
            XCTFail("expected a throw")
        } catch EngineError.badResponse {
            // expected
        } catch {
            XCTFail("expected badResponse, got \(error)")
        }
    }
}
