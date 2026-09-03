import XCTest
@testable import CatchMeUp

/// A reminder that fires on days with nothing to do is a reminder people turn
/// off, and then the schedule stops working entirely. The silence is the
/// feature, so it's the thing worth testing.
final class StudyNotifierTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-03-02, 09:00 UTC — a Monday morning, before the 18:00 reminder.
    private var morning: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 9))!
    }

    func testQuietDaysGetNoNotification() {
        let plan = StudyNotifier.plan(from: morning, hour: 18, calendar: calendar) { _ in 0 }
        XCTAssertTrue(plan.isEmpty, "nothing due means nothing to say")
    }

    func testOneNotificationPerDayAcrossTheHorizon() {
        let plan = StudyNotifier.plan(from: morning, hour: 18, calendar: calendar) { _ in 5 }
        XCTAssertEqual(plan.count, StudyNotifier.horizon)
        let days = plan.map { calendar.component(.day, from: $0.fireDate) }
        XCTAssertEqual(days, Array(2...8), "one per day, consecutive, starting today")
    }

    func testTodayIsSkippedOnceItsHourHasPassed() {
        let evening = calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 20))!
        let plan = StudyNotifier.plan(from: evening, hour: 18, calendar: calendar) { _ in 5 }
        let days = plan.map { calendar.component(.day, from: $0.fireDate) }
        XCTAssertEqual(days, Array(3...8), "8pm is past today's 6pm slot — start tomorrow")
    }

    func testEveryNotificationFiresAtTheChosenHour() {
        let plan = StudyNotifier.plan(from: morning, hour: 7, calendar: calendar) { _ in 3 }
        XCTAssertFalse(plan.isEmpty)
        for entry in plan {
            XCTAssertEqual(calendar.component(.hour, from: entry.fireDate), 7)
            XCTAssertEqual(calendar.component(.minute, from: entry.fireDate), 0)
        }
    }

    /// A backlog that clears midweek shouldn't leave stale reminders behind it.
    func testOnlyTheDaysWithWorkAreScheduled() {
        let plan = StudyNotifier.plan(from: morning, hour: 18, calendar: calendar) { date in
            calendar.component(.day, from: date) == 4 ? 7 : 0
        }
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.count, 7)
        XCTAssertEqual(calendar.component(.day, from: plan[0].fireDate), 4)
    }

    func testEveryEntryDeepLinksToStudy() {
        let plan = StudyNotifier.plan(from: morning, hour: 18, calendar: calendar) { _ in 2 }
        for entry in plan {
            let raw = entry.request.content.userInfo["deepLink"] as? String
            XCTAssertEqual(raw, "catchmeup://study")
        }
    }

    // MARK: Wording

    func testBodyMatchesTheStudyTabsEstimate() {
        // 12 items × 15s = 3 minutes, the same arithmetic the Study card shows.
        XCTAssertEqual(StudyNotifier.body(count: 12), "12 questions are waiting — about 3 min.")
    }

    func testBodyIsSingularForOne() {
        XCTAssertEqual(StudyNotifier.body(count: 1), "1 question is waiting — about 1 min.")
    }

    // MARK: The link the notification opens

    @MainActor
    func testStudyLinkSelectsTheStudyTab() {
        let router = AppRouter()
        router.open(CatchMeUpLink.study())
        XCTAssertEqual(router.selectedTab, .study)
        XCTAssertNil(router.studyBrainID)
    }

    @MainActor
    func testStudyLinkCanScopeToOneCourse() {
        let brain = UUID()
        let router = AppRouter()
        router.open(CatchMeUpLink.study(brain: brain))
        XCTAssertEqual(router.selectedTab, .study)
        XCTAssertEqual(router.studyBrainID, brain)
    }
}
