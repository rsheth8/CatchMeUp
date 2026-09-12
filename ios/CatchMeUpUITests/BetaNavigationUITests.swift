import XCTest

/// A real-device-style lap through the populated app. This intentionally taps
/// controls instead of only asserting model state, so clipped controls, broken
/// routes, stuck sheets, and bottom-bar collisions show up before a beta build.
final class BetaNavigationUITests: XCTestCase {
    func testPrimaryScreensPassAccessibilityAudit() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-showShowcase"]
        app.launch()

        XCTAssertTrue(app.buttons["showcase.tour"].waitForExistence(timeout: 30))
        let audits: XCUIAccessibilityAuditType = [
            .hitRegion,
            .sufficientElementDescription,
            .trait,
        ]
        func audit() throws { try app.performAccessibilityAudit(for: audits) }

        try audit()
        for destination in ["Study", "Brains", "Settings"] {
            tab(app, destination).tap()
            try audit()
        }
    }

    func testCoreStudentAndWorkJourneys() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-showShowcase"]
        app.launch()

        XCTAssertTrue(app.buttons["showcase.tour"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.navigationBars["Recaps"].exists)

        // Work recap: every segmented workspace and its attached source.
        app.buttons["Meetings"].tap()
        let meeting = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Billing migration: launch readiness'")
        ).firstMatch
        for _ in 0..<8 where !meeting.exists { app.swipeUp() }
        XCTAssertTrue(meeting.waitForExistence(timeout: 10))
        scrollToHittable(meeting, in: app)
        meeting.tap()
        XCTAssertTrue(app.segmentedControls.buttons["Summary"].waitForExistence(timeout: 5))
        for section in ["Findings", "Follow-ups", "Materials", "Summary"] {
            app.segmentedControls.buttons[section].tap()
            XCTAssertTrue(app.segmentedControls.buttons[section].isSelected)
        }
        snapshot(app, "Meeting workspace")
        back(app)

        // Student tools: a real flashcard interaction, including dismissal.
        tab(app, "Study").tap()
        let flashcards = app.staticTexts["Flashcards"]
        XCTAssertTrue(flashcards.waitForExistence(timeout: 5))
        flashcards.tap()
        XCTAssertTrue(app.navigationBars["Flashcards"].waitForExistence(timeout: 5))
        let turnCard = app.otherElements["flashcard.card"]
        XCTAssertTrue(turnCard.waitForExistence(timeout: 5))
        turnCard.tap()
        XCTAssertTrue(app.buttons["Got it"].isEnabled)
        snapshot(app, "Flashcards")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Study"].waitForExistence(timeout: 5))

        // Knowledge: open a brain, manipulate the graph, and close it cleanly.
        tab(app, "Brains").tap()
        let computerScience = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Computer Science'")
        ).firstMatch
        XCTAssertTrue(computerScience.waitForExistence(timeout: 5))
        computerScience.tap()
        XCTAssertTrue(app.navigationBars["Computer Science"].waitForExistence(timeout: 5))
        let neuralMap = app.staticTexts["Neural map"]
        XCTAssertTrue(neuralMap.waitForExistence(timeout: 5))
        neuralMap.tap()
        XCTAssertTrue(app.navigationBars["Neural map"].waitForExistence(timeout: 5))
        let graph = app.otherElements["Interactive neural map"]
        XCTAssertTrue(graph.waitForExistence(timeout: 5))
        graph.pinch(withScale: 1.25, velocity: 1.0)
        let start = graph.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45))
        let finish = graph.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.55))
        start.press(forDuration: 0.15, thenDragTo: finish)
        app.buttons["Recenter map"].tap()
        snapshot(app, "Interactive neural map")
        app.buttons["Done"].tap()
        back(app)

        // Settings: two deep routes that tend to expose Form/navigation issues.
        tab(app, "Settings").tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let storage = app.staticTexts["Storage"]
        scrollToHittable(storage, in: app)
        storage.tap()
        XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout: 5))
        snapshot(app, "Storage")
        back(app)

        let privacy = app.buttons["Privacy"]
        scrollToHittable(privacy, in: app)
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy"].waitForExistence(timeout: 5))
        snapshot(app, "Privacy")
        back(app)
        XCTAssertTrue(app.buttons["showcase.exit"].exists)
    }

    func testGuidedTourPlayAKeyMoment() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-showShowcase"]
        app.launch()

        XCTAssertTrue(app.buttons["showcase.tour"].waitForExistence(timeout: 30))
        app.buttons["showcase.tour"].tap()
        let start = app.buttons["tour.start.Play a key moment"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        // Step 1: the tour navigated to Library and spotlighted the real row;
        // this taps the actual control, not a copy of it.
        XCTAssertTrue(app.navigationBars["Recaps"].waitForExistence(timeout: 5))
        let recording = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Midterm review: choosing the right abstraction'")
        ).firstMatch
        XCTAssertTrue(recording.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tour.skip"].exists)
        recording.tap()

        // Step 2: the spotlighted playback control.
        let playback = app.buttons["recap.playback"]
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        playback.tap()

        // Both steps complete -> the driver stops and the overlay is gone.
        let skipGone = expectation(for: NSPredicate(format: "exists == 0"), evaluatedWith: app.buttons["tour.skip"])
        wait(for: [skipGone], timeout: 5)
    }

    func testGuidedTourPracticeForAnExam() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-showShowcase"]
        app.launch()

        XCTAssertTrue(app.buttons["showcase.tour"].waitForExistence(timeout: 30))
        app.buttons["showcase.tour"].tap()
        let start = app.buttons["tour.start.Practice for an exam"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        // Step 1: landed on Study, scoped to Computer Science; tap the real tile.
        XCTAssertTrue(app.navigationBars["Study"].waitForExistence(timeout: 5))
        let flashcards = app.staticTexts["Flashcards"]
        XCTAssertTrue(flashcards.waitForExistence(timeout: 5))
        flashcards.tap()

        // Step 2: flip the real card.
        XCTAssertTrue(app.navigationBars["Flashcards"].waitForExistence(timeout: 5))
        let card = app.otherElements["flashcard.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()

        // Step 3: grade it with the real "Got it" control.
        let gotIt = app.buttons["Got it"]
        XCTAssertTrue(gotIt.waitForExistence(timeout: 5))
        gotIt.tap()

        let skipGone = expectation(for: NSPredicate(format: "exists == 0"), evaluatedWith: app.buttons["tour.skip"])
        wait(for: [skipGone], timeout: 5)
    }

    func testGuidedTourExploreConnectedIdeas() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-showShowcase"]
        app.launch()

        XCTAssertTrue(app.buttons["showcase.tour"].waitForExistence(timeout: 30))
        app.buttons["showcase.tour"].tap()
        let start = app.buttons["tour.start.Explore connected ideas"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        // Step 1: landed on Brains; tap the real Computer Science card.
        XCTAssertTrue(app.navigationBars["Brains"].waitForExistence(timeout: 5))
        let computerScience = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Computer Science'")
        ).firstMatch
        XCTAssertTrue(computerScience.waitForExistence(timeout: 5))
        computerScience.tap()

        // Step 2: the tour opens the neural map itself; tap the real recenter control.
        let recenter = app.buttons["Recenter map"]
        XCTAssertTrue(recenter.waitForExistence(timeout: 5))
        recenter.tap()

        let skipGone = expectation(for: NSPredicate(format: "exists == 0"), evaluatedWith: app.buttons["tour.skip"])
        wait(for: [skipGone], timeout: 5)
    }

    func testGuidedTourRunAMeeting() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-showShowcase"]
        app.launch()

        XCTAssertTrue(app.buttons["showcase.tour"].waitForExistence(timeout: 30))
        app.buttons["showcase.tour"].tap()
        let start = app.buttons["tour.start.Run a meeting"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        // Step 1: landed on Library; tap the real meeting row.
        XCTAssertTrue(app.navigationBars["Recaps"].waitForExistence(timeout: 5))
        let meeting = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Cutover review: owners and open questions'")
        ).firstMatch
        XCTAssertTrue(meeting.waitForExistence(timeout: 5))
        meeting.tap()

        // Steps 2-5: tap each real segmented-control section in the tour's order.
        for section in ["Findings", "Follow-ups", "Materials", "Summary"] {
            let button = app.segmentedControls.buttons[section]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
        }

        let skipGone = expectation(for: NSPredicate(format: "exists == 0"), evaluatedWith: app.buttons["tour.skip"])
        wait(for: [skipGone], timeout: 5)
    }

    private func tab(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
