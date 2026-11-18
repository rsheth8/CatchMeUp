import XCTest
@testable import CatchMeUp

/// Offering the button with bad configuration crashes the app, because
/// `GIDSignIn` raises an exception Swift can't catch.
final class GoogleSignInConfigTests: XCTestCase {

    private func info(clientID: String?, schemes: [String]) -> [String: Any] {
        var info: [String: Any] = [
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["catchmeup"]],
                                 ["CFBundleURLSchemes": schemes]]
        ]
        info["GIDClientID"] = clientID
        return info
    }

    func testTheShippedPlaceholdersAreNotAvailable() {
        XCTAssertFalse(GoogleSignInConfig.isAvailable(info: info(
            clientID: "REPLACE_WITH_GOOGLE_OAUTH_CLIENT_ID.apps.googleusercontent.com",
            schemes: ["REPLACE_WITH_REVERSED_GOOGLE_CLIENT_ID"])))
    }

    func testThisBuildDoesNotOfferGoogleUntilConfigured() {
        XCTAssertFalse(GoogleSignInConfig.isAvailable,
                       "Info.plist still holds placeholders, so the button must stay hidden")
    }

    func testAMissingClientIDIsNotAvailable() {
        XCTAssertFalse(GoogleSignInConfig.isAvailable(info: info(
            clientID: nil, schemes: ["com.googleusercontent.apps.123-abc"])))
    }

    func testARealClientIDWithoutItsSchemeIsNotAvailable() {
        XCTAssertFalse(GoogleSignInConfig.isAvailable(info: info(
            clientID: "123-abc.apps.googleusercontent.com",
            schemes: ["com.googleusercontent.apps.999-other"])))
    }

    func testARealClientIDWithItsSchemeIsAvailable() {
        XCTAssertTrue(GoogleSignInConfig.isAvailable(info: info(
            clientID: "123-ABC.apps.googleusercontent.com",
            schemes: ["com.googleusercontent.apps.123-abc"])))
    }
}
