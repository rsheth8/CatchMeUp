import XCTest

final class ShowcaseUITests: XCTestCase {
    func testDemoCaptureProducesPlayableRecapWithoutAPI() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-showShowcase"]
        app.launch()
        XCTAssertTrue(app.buttons["showcase.tour"].waitForExistence(timeout: 30))
        let matches = app.buttons.matching(identifier: "Add a narrated demo")
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10))
        guard let add = matches.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            return XCTFail("No visible demo capture button")
        }
        add.tap()
        let create = app.buttons["Create demo recap"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let play = app.buttons["recap.playback"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForExistence(timeout: 5))
        app.buttons["Pause recording"].tap()
        XCTAssertFalse(app.staticTexts["Couldn't finish the notes"].exists)
        snapshot(app, "Playable demo recap")
    }

    func testBrainAnswersFromDemoSources() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-showShowcase"]
        app.launch()
        XCTAssertTrue(app.buttons["showcase.tour"].waitForExistence(timeout: 30))
        app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Brains'")).firstMatch.tap()
        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Computer Science'")
        ).firstMatch.tap()
        let question = app.textFields["Ask across this brain…"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.tap()
        question.typeText("Explain closure")
        app.buttons["brain.send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'From your sources'")).firstMatch.waitForExistence(timeout: 10))
        snapshot(app, "Source-backed demo answer")
    }

    func testShowcaseTourAndAccountExit() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-showShowcase"]
        app.launch()
        let tour = app.buttons["showcase.tour"]
        XCTAssertTrue(tour.waitForExistence(timeout: 30))
        let exit = app.buttons["showcase.exit"]
        let ready = NSPredicate(format: "isEnabled == true")
        expectation(for: ready, evaluatedWith: exit)
        waitForExpectations(timeout: 60)
        snapshot(app, "Populated showcase")
        tour.tap()
        XCTAssertTrue(app.navigationBars["Meet your showcase"].waitForExistence(timeout: 5))
        app.buttons.containing(.staticText, identifier: "Practice for an exam").firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Study'")).firstMatch.isSelected)
        snapshot(app, "Study showcase")
        tour.tap()
        app.buttons.containing(.staticText, identifier: "Explore connected ideas").firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Computer Science'")
        ).firstMatch.waitForExistence(timeout: 5))
        snapshot(app, "Connected brains")
        exit.tap()
        XCTAssertTrue(tour.waitForNonExistence(timeout: 5))
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
