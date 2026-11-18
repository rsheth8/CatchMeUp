import XCTest

final class LegalLinksUITests: XCTestCase {
    func testSettingsOpensThePrivacyPolicyInSafari() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-showShowcase"]
        app.launch()
        XCTAssertTrue(app.buttons["showcase.tour"].waitForExistence(timeout: 30))
        app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Settings'")).firstMatch.tap()

        let policy = app.descendants(matching: .any)["legal.privacyPolicy"].firstMatch
        let support = app.descendants(matching: .any)["legal.support"].firstMatch
        let visibleBottom = app.frame.height * 0.8
        for _ in 0..<25 where !(support.exists && support.isHittable && support.frame.maxY < visibleBottom) {
            app.swipeUp()
        }
        XCTAssertTrue(policy.isHittable, "Privacy Policy link should be reachable in Settings")
        XCTAssertTrue(support.isHittable, "Support link should be reachable in Settings")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Settings legal links"
        shot.lifetime = .keepAlways
        add(shot)

        policy.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20), "The link should open in Safari")
    }
}
