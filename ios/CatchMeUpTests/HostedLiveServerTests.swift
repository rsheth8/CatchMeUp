import XCTest
@testable import CatchMeUp

/// Runs the real client against a real local Worker (`npm run dev:harness` in
/// backend/). Skipped unless the harness address is given:
///
///   TEST_RUNNER_HOSTED_HARNESS=1 xcodebuild test ... -only-testing:CatchMeUpTests/HostedLiveServerTests
///
/// The model behind it is a stub and Apple's key server is faked, so it costs
/// nothing and touches no real account.
@MainActor
final class HostedLiveServerTests: XCTestCase {
    private let worker = URL(string: "http://127.0.0.1:8787")!
    private let tokenURL = URL(string: "http://127.0.0.1:8788/dev/token")!

    private func makeSession() throws -> HostedSession {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOSTED_HARNESS"] == "1", "needs the local harness")
        let api = HostedAPI(baseURL: worker)
        return HostedSession(store: MemoryTokenStore(), apiProvider: { api })
    }

    private func signIn(_ session: HostedSession) async throws {
        let (data, _) = try await URLSession.shared.data(from: tokenURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        try await session.signIn(.apple, idToken: try XCTUnwrap(json["idToken"] as? String),
                                 nonce: try XCTUnwrap(json["nonce"] as? String))
    }

    func testAFreeUserGetsThreeRecapsThenTheLimitAndAReplayedNonceIsRefused() async throws {
        let session = try makeSession()

        // The nonce comes from the server, and works once.
        let (data, _) = try await URLSession.shared.data(from: tokenURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let idToken = try XCTUnwrap(json["idToken"] as? String), nonce = try XCTUnwrap(json["nonce"] as? String)
        try await session.signIn(.apple, idToken: idToken, nonce: nonce)
        XCTAssertTrue(session.isSignedIn)
        XCTAssertEqual(session.quota, HostedQuota(plan: "free", recapsRemaining: 3, resetsAt: session.quota?.resetsAt))
        let replay = makeSessionIgnoringSkip()
        do { try await replay.signIn(.apple, idToken: idToken, nonce: nonce); XCTFail("a replayed sign-in must be refused") }
        catch { XCTAssertEqual(error as? HostedError, .unauthorized) }

        // Three recordings through the real engine, each with its own recording id.
        let engine = HostedRecapEngine(session: session)
        var left: [Int] = []
        for _ in 0..<3 {
            let id = UUID().uuidString
            let recap = try await HostedCall.$jobID.withValue(id) {
                try await engine.makeRecap(transcript: "[00:00:01] Speaker 1: Ship the fix on Thursday.", mode: .meeting) { _ in }
            }
            XCTAssertEqual(recap.title, "Stub recap from the local harness")
            left.append(try XCTUnwrap(session.quota?.recapsRemaining))
        }
        XCTAssertEqual(left, [2, 1, 0])
        XCTAssertNil(session.limit)

        // The fourth is refused by the server and opens the paywall.
        do {
            _ = try await HostedCall.$jobID.withValue(UUID().uuidString) {
                try await engine.makeRecap(transcript: "[00:00:01] Speaker 1: One more.", mode: .meeting) { _ in }
            }
            XCTFail("the fourth recap should be refused")
        } catch {
            guard case HostedError.quotaExceeded(let plan, let resets)? = error as? HostedError else { return XCTFail("\(error)") }
            XCTAssertEqual(plan, "free")
            XCTAssertNotNil(resets)
        }
        XCTAssertEqual(session.limit?.plan, "free")

        // Signing out revokes the refresh token on the server.
        await session.signOut()
        XCTAssertFalse(session.isSignedIn)
    }

    private func makeSessionIgnoringSkip() -> HostedSession {
        let api = HostedAPI(baseURL: worker)
        return HostedSession(store: MemoryTokenStore(), apiProvider: { api })
    }
}
