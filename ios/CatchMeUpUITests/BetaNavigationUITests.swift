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
        XCTAssertTrue(meeting.waitForExistence(timeout: 10))
        meeting.tap()
        XCTAssertTrue(app.segmentedControls.buttons["Summary"].waitForExistence(timeout: 5))
        for section in ["Decisions", "Follow-ups", "Materials", "Summary"] {
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
