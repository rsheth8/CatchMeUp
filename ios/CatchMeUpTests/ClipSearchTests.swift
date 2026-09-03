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
