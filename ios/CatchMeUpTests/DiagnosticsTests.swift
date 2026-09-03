import XCTest
@testable import CatchMeUp

/// A bug report leaves the phone, so what it contains is a privacy question,
/// not a formatting one. These tests are the guarantee the Settings footer
/// makes: version, device and counts — never content, never the key.
final class DiagnosticsTests: XCTestCase {

    private func sample() -> Diagnostics {
        Diagnostics(
            appVersion: "1.0", build: "1", system: "iOS 26.0", device: "iPhone17,1",
            engine: "apiKey", provider: "anthropic", syncEnabled: true,
            recordings: 12, brains: 2, unprocessed: 0, failed: 0,
            studyItems: 140, reviews: 63, prequestions: true, reminderHour: 18
        )
    }

    func testReportCarriesTheThingsThatIdentifyABuild() {
        let report = sample().report
        for expected in ["1.0", "(1)", "iOS 26.0", "iPhone17,1", "apiKey", "anthropic"] {
            XCTAssertTrue(report.contains(expected), "missing \(expected) from:\n\(report)")
        }
    }

    func testReportCountsTheLibraryWithoutNamingAnyOfIt() {
        let report = sample().report
        XCTAssertTrue(report.contains("12 recaps"))
        XCTAssertTrue(report.contains("2 brains"))
        XCTAssertTrue(report.contains("140 questions"))
    }

    /// The one that matters. Nothing the user wrote or recorded may appear.
    func testReportNeverCarriesContentOrCredentials() {
        let report = sample().report.lowercased()
        for forbidden in ["sk-", "api-key", "bearer", "transcript", "\""] {
            XCTAssertFalse(report.contains(forbidden), "\(forbidden) has no business in a bug report")
        }
    }

    func testPendingWorkIsMentionedOnlyWhenThereIsSome() {
        var quiet = sample()
        XCTAssertFalse(quiet.report.contains("Pending"))

        quiet.failed = 2
        XCTAssertTrue(quiet.report.contains("Pending"), "a stuck recap is the most useful line in the report")
        XCTAssertTrue(quiet.report.contains("2 failed"))
    }

    func testSettingsThatChangeBehaviourAreStated() {
        var off = sample()
        off.prequestions = false
        off.reminderHour = nil
        XCTAssertTrue(off.report.contains("Prequestions: off"))
        XCTAssertTrue(off.report.contains("Reminder: off"))
    }

    func testNoProviderIsNamedWhenNoKeyIsInUse() {
        var local = sample()
        local.engine = "onDevice"
        local.provider = nil
        XCTAssertFalse(local.report.contains("anthropic"))
        XCTAssertTrue(local.report.contains("onDevice"))
    }

    /// The tester should find somewhere to type before they find the facts.
    func testShareTextLeavesRoomForTheHumanPart() {
        let text = sample().shareText
        XCTAssertTrue(text.hasPrefix("What happened:"))
        XCTAssertTrue(text.contains("What I expected:"))
        XCTAssertTrue(text.contains(sample().report))
    }

    func testHardwareIdentifierIsNotEmpty() {
        XCTAssertFalse(Diagnostics.hardwareIdentifier().isEmpty)
    }
}
