import XCTest
import Observation
@testable import CatchMeUp

/// A card coming due changes no stored value, so nothing told the Study tab or
/// its badge to redraw. They kept showing the old number until something else
/// happened to refresh them.
@MainActor
final class StudyCountFreshnessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store(cardsDue dates: [Date]) -> StudyStore {
        let study = StudyStore(root: root, isShowcase: true)
        study.add(dates.enumerated().map { index, due in
            var item = StudyItem(recordingID: UUID(), brainID: nil, sourceTitle: "Test",
                                 kind: .term, prompt: "Prompt \(index)", answer: "Answer \(index)",
                                 concept: "concept-\(index)")
            item.memory.state = .learning
            item.memory.due = due
            return item
        })
        return study
    }

    func testRefreshingTellsObserversOfTheCountToRedraw() {
        let study = store(cardsDue: [now.addingTimeInterval(60)])
        var redrawRequested = false
        withObservationTracking {
            _ = study.todayCount(newLimit: 10, at: now)
        } onChange: {
            redrawRequested = true
        }

        study.refreshCounts(at: now.addingTimeInterval(61))

        XCTAssertTrue(redrawRequested, "the badge and Study card read this count while drawing")
    }

    func testACardIsCountedOnceItsTimeArrives() {
        let due = now.addingTimeInterval(60)
        let study = store(cardsDue: [due])
        XCTAssertEqual(study.dueCount(at: now), 0)
        XCTAssertEqual(study.dueCount(at: due), 1)
    }

    func testTheNextChangeIsTheSoonestCardStillAhead() {
        let soon = now.addingTimeInterval(60)
        let later = now.addingTimeInterval(600)
        let study = store(cardsDue: [now.addingTimeInterval(-60), later, soon])
        XCTAssertEqual(study.nextCountChange(after: now), soon)
        XCTAssertEqual(study.nextCountChange(after: soon), later)
    }

    func testWithNothingAheadTheNextChangeIsMidnight() {
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        XCTAssertEqual(store(cardsDue: []).nextCountChange(after: now), midnight)
    }
}
