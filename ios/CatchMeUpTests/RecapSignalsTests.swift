import XCTest
@testable import CatchMeUp

final class RecapSignalsTests: XCTestCase {

    func testLectureCuesWinOverAMeetingPrior() {
        let transcript = """
        [00:00:00] Today in lecture we cover the definition of a slice.
        [00:02:00] For example, this will be on the exam and the midterm.
        [00:04:00] The professor assigned a homework and a quiz.
        """
        let verdict = RecapSignals.classify(transcript, prior: .meeting)
        XCTAssertEqual(verdict.dominant, .lecture)
        XCTAssertFalse(verdict.mixed)
    }

    func testStandupCuesStayAMeeting() {
        let transcript = """
        [00:00:00] Standup. Blockers first, then next steps.
        [00:01:00] We decided I'll take the retro notes. Action item: ship by Friday.
        [00:02:00] Assigned to Jordan. Deadline is Monday.
        """
        let verdict = RecapSignals.classify(transcript, prior: .lecture)
        XCTAssertEqual(verdict.dominant, .meeting)
        XCTAssertFalse(verdict.mixed)
    }

    func testOfficeHoursCountAsMixed() {
        let transcript = """
        [00:00:00] This is office hours after lecture. The definition of a slice is on the exam.
        [00:02:00] For example, homework problem 3. We decided I'll take the follow-up.
        [00:03:00] Action item: finish the problem set by Friday. Next steps after the quiz.
        """
        let verdict = RecapSignals.classify(transcript, prior: .lecture)
        XCTAssertTrue(verdict.mixed, "office hours teach and assign work")
        XCTAssertEqual(verdict.dominant, .lecture, "prior holds when both jobs are present")
    }

    func testSilenceKeepsThePrior() {
        let verdict = RecapSignals.classify("[00:00:00] Okay. Yeah. Um.", prior: .meeting)
        XCTAssertEqual(verdict.dominant, .meeting)
        XCTAssertFalse(verdict.mixed)
    }
}

final class RecapLayoutTests: XCTestCase {

    func testAlsoSummaryIsNilWhenTheOtherJobIsEmpty() {
        let lecture = Recap(tldr: ["Slicing"], terms: [Term(term: "s", definition: "d")])
        XCTAssertNil(RecapLayout.alsoSummary(lecture, dominant: .lecture))

        let meeting = Recap(tldr: ["Shipped"], actionItems: ["Do the thing"])
        XCTAssertNil(RecapLayout.alsoSummary(meeting, dominant: .meeting))
    }

    func testAlsoSummaryNamesFollowUpsOnALecture() {
        let recap = Recap(tldr: ["Slicing"],
                          actionItems: ["Finish pset 3", "Book office hours"],
                          terms: [Term(term: "slice", definition: "range")])
        XCTAssertEqual(RecapLayout.alsoSummary(recap, dominant: .lecture), "2 follow-ups")
    }

    func testAlsoSummaryNamesGlossaryOnAMeeting() {
        let recap = Recap(actionItems: ["Ship it"],
                          terms: [Term(term: "SLA", definition: "uptime")])
        XCTAssertEqual(RecapLayout.alsoSummary(recap, dominant: .meeting), "Glossary · 1 term")
        XCTAssertEqual(RecapLayout.alsoSummary(recap, dominant: .lecture), "1 follow-up")
    }
}

final class WeekPulseTests: XCTestCase {

    func testEmptyWhenNothingIsOpen() {
        XCTAssertTrue(WeekPulse.lines(from: []).isEmpty)
    }

    func testPrefersOpenActionsThenStudy() {
        let now = Date()
        var meeting = Recording(title: "Sync", mode: .meeting, recap: Recap(actionItems: ["Send the changelog"]))
        meeting.createdAt = now
        var lecture = Recording(title: "Lec", mode: .lecture, recap: Recap(study: ["Practice slicing"]))
        lecture.createdAt = now

        let lines = WeekPulse.lines(from: [meeting, lecture], now: now)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "Send the changelog")
        XCTAssertEqual(lines[1].text, "Practice slicing")
    }

    func testCompletedActionsAreSkipped() {
        let now = Date()
        var rec = Recording(title: "Sync", mode: .meeting,
                            recap: Recap(actionItems: ["Done already", "Still open"]))
        rec.createdAt = now
        rec.completedActions = [0]
        let lines = WeekPulse.lines(from: [rec], now: now)
        XCTAssertEqual(lines.first?.text, "Still open")
    }

    func testOldRecapsDoNotAppear() {
        var rec = Recording(title: "Sync", mode: .meeting, recap: Recap(actionItems: ["Ancient"]))
        rec.createdAt = Date().addingTimeInterval(-8 * 24 * 3600)
        XCTAssertTrue(WeekPulse.lines(from: [rec]).isEmpty)
    }
}
