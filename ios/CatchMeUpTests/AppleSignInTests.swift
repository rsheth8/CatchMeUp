import XCTest
@testable import CatchMeUp

@MainActor
final class AppleSignInTests: XCTestCase {
    private let keys = ["auth.provider", "auth.name", "auth.email", "auth.appleUserID"]
    private var saved: [String: String] = [:]

    override func setUp() async throws {
        saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            Keychain.get(key).map { (key, $0) }
        })
        keys.forEach { Keychain.set("", for: $0) }
    }

    override func tearDown() async throws {
        keys.forEach { Keychain.set(saved[$0] ?? "", for: $0) }
    }

    private func manager(_ status: AppleCredentialStatus = .active) -> AuthManager {
        AuthManager(credentialStatus: { _ in status })
    }

    private func signedInManager(_ status: AppleCredentialStatus) -> AuthManager {
        let auth = manager(status)
        auth.completeAppleSignIn(userID: "apple-user-1",
                                 fullName: PersonNameComponents(givenName: "Sam", familyName: "Lee"),
                                 email: "sam@example.com")
        return auth
    }

    private func assertSignedOutEverywhere(_ auth: AuthManager, line: UInt = #line) {
        XCTAssertFalse(auth.isSignedIn, line: line)
        XCTAssertNil(auth.displayName, line: line)
        XCTAssertNil(auth.email, line: line)
        XCTAssertNil(auth.appleUserID, line: line)
        keys.forEach { XCTAssertNil(Keychain.get($0), $0, line: line) }
    }

    func testAppleUserIDIsSavedAndSurvivesRelaunch() {
        _ = signedInManager(.active)

        let relaunched = manager()
        XCTAssertEqual(relaunched.appleUserID, "apple-user-1")
        XCTAssertEqual(relaunched.provider, "apple")
        XCTAssertEqual(relaunched.displayName, "Sam Lee")
        XCTAssertEqual(relaunched.email, "sam@example.com")
    }

    func testLaterSignInKeepsTheNameAppleSentFirst() {
        let auth = signedInManager(.active)
        auth.completeAppleSignIn(userID: "apple-user-1", fullName: nil, email: nil)

        XCTAssertEqual(auth.displayName, "Sam Lee")
        XCTAssertEqual(auth.email, "sam@example.com")
    }

    func testRevokedOrMissingCredentialRemovesIdentity() async {
        let auth = signedInManager(.gone)
        await auth.refreshAppleCredential()

        assertSignedOutEverywhere(auth)
        XCTAssertFalse(auth.isPresentingSignOutGate)
    }

    func testActiveCredentialStaysSignedIn() async {
        let auth = signedInManager(.active)
        await auth.refreshAppleCredential()

        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(auth.appleUserID, "apple-user-1")
    }

    func testFailedCheckDoesNotSignAnyoneOut() async {
        let auth = signedInManager(.unknown)
        await auth.refreshAppleCredential()

        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(Keychain.get("auth.appleUserID"), "apple-user-1")
    }

    func testRevocationNoticeRemovesIdentity() {
        let auth = signedInManager(.active)
        auth.handleAppleCredentialRevoked()

        assertSignedOutEverywhere(auth)
    }

    func testSignOutRemovesAppleUserID() {
        let auth = signedInManager(.active)
        auth.signOut()

        assertSignedOutEverywhere(auth)
        XCTAssertTrue(auth.isPresentingSignOutGate)
        XCTAssertEqual(auth.pendingGoodbyeName, "Sam Lee")
    }

    func testAnswerAboutAPreviousUserIsIgnored() async {
        let gate = CheckGate()
        let auth = AuthManager(credentialStatus: { _ in await gate.wait() })
        auth.completeAppleSignIn(userID: "apple-user-1", fullName: nil, email: nil)

        let check = Task { await auth.refreshAppleCredential() }
        await gate.untilWaiting()
        auth.completeAppleSignIn(userID: "apple-user-2", fullName: nil, email: nil)
        await gate.finish(.gone)
        await check.value

        XCTAssertTrue(auth.isSignedIn, "An answer about the old user must not sign out the new one")
        XCTAssertEqual(auth.appleUserID, "apple-user-2")
    }

    func testSignInWithoutSavedIDSkipsTheCheck() async {
        Keychain.set("apple", for: "auth.provider")
        let auth = AuthManager(credentialStatus: { _ in
            XCTFail("No saved identifier, so there is nothing to check")
            return .gone
        })
        await auth.refreshAppleCredential()

        XCTAssertTrue(auth.isSignedIn)
    }

    func testAppleCheckAnswersForAnUnknownUser() async {
        let status = await AuthManager.liveAppleCredentialStatus("not-a-real-apple-user")
        XCTAssertNotEqual(status, .active)
    }

    func testLegalLinksPointAtThePublicPages() {
        XCTAssertEqual(LegalLinks.privacyPolicy.absoluteString, "https://rsheth8.github.io/CatchMeUp/privacy/")
        XCTAssertEqual(LegalLinks.support.absoluteString, "https://rsheth8.github.io/CatchMeUp/support/")
    }
}

/// Holds a credential check open so a test can act while it is in flight.
private actor CheckGate {
    private var answer: CheckedContinuation<AppleCredentialStatus, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async -> AppleCredentialStatus {
        await withCheckedContinuation { continuation in
            answer = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    func untilWaiting() async {
        guard answer == nil else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func finish(_ status: AppleCredentialStatus) {
        answer?.resume(returning: status)
        answer = nil
    }
}
