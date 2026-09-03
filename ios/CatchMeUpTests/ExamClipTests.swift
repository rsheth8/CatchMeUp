import XCTest
@testable import CatchMeUp

final class ClipSearchTests: XCTestCase {
    private func recap(_ title: String, heading: String, insight: String, term: String, definition: String) -> Recording {
        Recording(
            title: title,
            mode: .lecture,
            recap: Recap(
                title: title,
                bookmarks: [Bookmark(timestamp: "00:12:40", heading: heading, insight: insight)],
                terms: [Term(term: term, definition: definition)]
            )
        )
    }

    func testFindsMutexByHeading() {
        let rec = recap("Week 3", heading: "mutex acquire", insight: "Always acquire before touching shared state.",
                         term: "mutex", definition: "A lock that only one thread can hold at a time.")
        let hit = ClipSearch.find(query: "mutex", in: [rec])
        XCTAssertEqual(hit?.heading, "mutex acquire")
        XCTAssertEqual(hit?.start, 12 * 60 + 40)
    }

    func testIgnoresUnrelatedQuery() {
        let rec = recap("Week 3", heading: "mutex", insight: "A lock.",
                         term: "mutex", definition: "A lock that only one thread can hold.")
        XCTAssertNil(ClipSearch.find(query: "photosynthesis", in: [rec]))
    }

    func testRanksExactHeadingAbovePartial() {
        let mutex = recap("A", heading: "mutex", insight: "A lock.", term: "lock", definition: "same idea as a mutex in this lecture")
        let other = recap("B", heading: "environment diagrams", insight: "Draw the frame.",
                           term: "frame", definition: "A call's local bindings.")
        let hits = ClipSearch.list(query: "mutex", in: [mutex, other])
        XCTAssertEqual(hits.first?.heading, "mutex")
    }
}

final class ExamBuilderTests: XCTestCase {
    private func lecture() -> Recording {
        Recording(
            title: "Week 3: Mutexes",
            mode: .lecture,
            recap: Recap(
                title: "Week 3: Mutexes",
                bookmarks: [Bookmark(timestamp: "00:12:40", heading: "mutex acquire",
                                      insight: "Always acquire the lock before you touch the shared counter.")],
                detailedNotes: [DetailNote(heading: "Mutexes",
                                           content: "A mutex has acquire and release. Only one thread holds it at a time.")],
                terms: [Term(term: "mutex",
                             definition: "A lock that only one thread can hold at a time while others wait.")],
                study: ["Draw what happens if two threads increment without a mutex."]
            )
        )
    }

    func testBuildsQuestionsFromTermsAndMoments() {
        let qs = ExamBuilder.build(from: [lecture()], count: 6)
        XCTAssertFalse(qs.isEmpty)
        XCTAssertTrue(qs.contains { $0.kind == .term })
    }

    func testGradesACorrectParaphrase() {
        let q = ExamQuestion(
            prompt: "What is a mutex?",
            answer: "A lock that only one thread can hold at a time.",
            kind: .term,
            source: "Week 3",
            timestamp: "",
            concept: "mutex",
            keys: ["lock", "thread", "hold"]
        )
        let grade = ExamBuilder.grade(q, typed: "It's a lock so only one thread can hold it")
        XCTAssertEqual(grade.verdict, .pass)
    }

    func testBlankIsBlank() {
        let q = ExamQuestion(prompt: "What is a mutex?", answer: "A lock.", kind: .term,
                             source: "W", timestamp: "", concept: "mutex", keys: ["lock"])
        XCTAssertEqual(ExamBuilder.grade(q, typed: "   ").verdict, .blank)
    }

    func testEmptyBrainYieldsNoExam() {
        XCTAssertTrue(ExamBuilder.build(from: [Recording(title: "Empty", mode: .lecture)], count: 8).isEmpty)
    }
}
