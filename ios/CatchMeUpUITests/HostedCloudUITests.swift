import XCTest

/// Drives the real app against a real local Worker. Needs `npm run dev:harness`
/// running in backend/, and is skipped otherwise:
///
///   TEST_RUNNER_HOSTED_HARNESS=1 xcodebuild test ... -only-testing:CatchMeUpUITests/HostedCloudUITests
final class HostedCloudUITests: XCTestCase {
    func testSignedInSettingsShowTheAllowanceAndThePlusScreenOpens() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOSTED_HARNESS"] == "1", "needs the local harness")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-hostedBaseURL", "http://127.0.0.1:8787",
            "-engineKind", "hosted",
            "-hostedDevSignIn", "http://127.0.0.1:8788/dev/token",
        ]
        app.launch()

        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 5) { skip.tap() }
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()

        // The dev sign-in ran against the real Worker: a new account has 3 free recaps.
        let quota = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '3 recaps left this month'")).firstMatch
        for _ in 0..<8 where !quota.exists { app.swipeUp() }
        XCTAssertTrue(quota.waitForExistence(timeout: 10), "the quota line from the server should show")
        snapshot(app, "Settings - Free plan, 3 left")

        let plus = app.buttons["See CatchMeUp Plus"]
        for _ in 0..<4 where !plus.isHittable { app.swipeUp() }
        plus.tap()

        XCTAssertTrue(app.staticTexts["CatchMeUp Plus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Plus is coming soon"].exists)
        snapshot(app, "Plus screen")
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
