import XCTest
@testable import CatchMeUp

/// The scheduler decides when you see something again, and a wrong interval is
/// invisible — nothing crashes, you just forget things on a schedule the app
/// promised would stop that. So the properties that have to hold are asserted
/// rather than eyeballed.
final class StudyScheduleTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// A card that has just come due: last seen a full interval ago, so
    /// retrievability has actually decayed. Reviewing at the moment of the last
    /// review instead would sit at r = 1, where FSRS's gain term is zero by
    /// construction — see `testReviewingSomethingYouStillKnowPerfectlyAddsNothing`.
    private func learned(days: Double = 10, difficulty: Double = 5) -> FSRS.Memory {
        var m = FSRS.Memory.unseen
        m.state = .review
        m.stability = days
        m.difficulty = difficulty
        m.reps = 3
        m.lastReviewedAt = now.addingTimeInterval(-days * 86_400)
        m.due = now
        return m
    }

    // MARK: Grades move the interval the right way

    func testGradesOrderTheNextInterval() {
        let memory = learned()
        let intervals = FSRS.Grade.allCases.map { grade -> TimeInterval in
            FSRS.schedule(memory, grade: grade, now: now).due.timeIntervalSince(now)
        }
        // .again, .hard, .good, .easy — each should schedule no sooner than the
        // one before it, and "again" much sooner than "good".
        XCTAssertEqual(intervals, intervals.sorted(), "a better grade must never come back sooner")
        XCTAssertLessThan(intervals[0], intervals[2] / 2, "a lapse should return well inside the old interval")
    }

    func testALapseCostsStabilityAndIsCounted() {
        let before = learned(days: 30)
        let after = FSRS.schedule(before, grade: .again, now: now)
        XCTAssertLessThan(after.stability, before.stability, "forgetting has to shorten the interval")
        XCTAssertEqual(after.lapses, before.lapses + 1)
        XCTAssertEqual(after.state, .relearning)
    }

    func testSuccessfulReviewGrowsStability() {
        let before = learned(days: 10)
        let after = FSRS.schedule(before, grade: .good, now: now)
        XCTAssertGreaterThan(after.stability, before.stability)
        XCTAssertEqual(after.reps, before.reps + 1)
    }

    func testHarderMaterialComesBackSooner() {
        let easy = FSRS.schedule(learned(difficulty: 2), grade: .good, now: now)
        let hard = FSRS.schedule(learned(difficulty: 9), grade: .good, now: now)
        XCTAssertLessThan(hard.due, easy.due, "difficulty has to shorten the interval, not just be stored")
    }

    /// Not a quirk — the property that makes cramming pointless. A review at
    /// full retrievability carries no information about how long the memory
    /// lasts, so it can't extend the interval. Anything that "fixed" this would
    /// let a user inflate their schedule by re-reviewing all afternoon.
    func testReviewingSomethingYouStillKnowPerfectlyAddsNothing() {
        var fresh = learned()
        fresh.lastReviewedAt = now
        let after = FSRS.schedule(fresh, grade: .good, now: now)
        XCTAssertEqual(after.stability, fresh.stability, accuracy: 0.001)
    }

    // MARK: The retention setting is a real trade, not a label

    func testHigherRetentionMeansMoreFrequentReviews() {
        var relaxed = FSRS.Parameters.default
        relaxed.desiredRetention = 0.82
        var strict = FSRS.Parameters.default
        strict.desiredRetention = 0.95

        let a = FSRS.schedule(learned(), grade: .good, now: now, params: relaxed)
        let b = FSRS.schedule(learned(), grade: .good, now: now, params: strict)
        XCTAssertLessThan(b.due, a.due, "asking to remember more must cost more reviews — that's the trade Settings claims")
    }

    // MARK: Retrievability

    func testRetrievabilityDecaysAndStartsAtOne() {
        var memory = learned(days: 10)
        memory.lastReviewedAt = now
        XCTAssertEqual(FSRS.retrievability(memory, at: now), 1.0, accuracy: 0.01)
        let week = FSRS.retrievability(memory, at: now.addingTimeInterval(7 * 86_400))
        let month = FSRS.retrievability(memory, at: now.addingTimeInterval(30 * 86_400))
        XCTAssertLessThan(week, 1.0)
        XCTAssertLessThan(month, week)
        XCTAssertGreaterThan(month, 0)
    }

    /// The number the whole schedule is built to hit: at the moment a card
    /// comes due, recall probability should be sitting near the target.
    func testACardIsDueRoughlyWhenItHitsTheRetentionTarget() {
        let scheduled = FSRS.schedule(learned(), grade: .good, now: now)
        let atDue = FSRS.retrievability(scheduled, at: scheduled.due)
        XCTAssertEqual(atDue, FSRS.Parameters.default.desiredRetention, accuracy: 0.03)
    }

    func testUnseenItemIsDue() {
        XCTAssertLessThanOrEqual(FSRS.Memory.unseen.due, now, "a new question has to be offerable")
    }

    // MARK: Preview matches what actually happens

    func testPreviewAgreesWithScheduling() {
        let memory = learned()
        let preview = FSRS.preview(memory, now: now)
        for grade in FSRS.Grade.allCases {
            let actual = FSRS.schedule(memory, grade: grade, now: now).due
            guard let shown = preview[grade] else {
                return XCTFail("no preview for \(grade)")
            }
            XCTAssertEqual(shown.timeIntervalSince1970,
                           actual.timeIntervalSince1970,
                           accuracy: 1,
                           "the buttons promise an interval; scheduling has to keep it")
        }
    }
}
