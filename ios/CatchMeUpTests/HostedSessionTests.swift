import XCTest
@testable import CatchMeUp

/// Answers requests from a closure, so the session and engine run against a
/// scripted server and no network.
final class StubProtocol: URLProtocol {
    struct Seen { let method: String; let path: String; let auth: String?; let body: [String: Any] }
    nonisolated(unsafe) static var handler: ((Seen) -> (Int, [String: Any]))?
    nonisolated(unsafe) static var seen: [Seen] = []
    private static let lock = NSLock()

    static func reset(_ handler: @escaping (Seen) -> (Int, [String: Any])) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        seen = []
    }

    static var calls: [Seen] { lock.lock(); defer { lock.unlock() }; return seen }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(buffer, maxLength: 4096)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            buffer.deallocate()
            stream.close()
        } else if let body = request.httpBody {
            data = body
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let seen = Seen(method: request.httpMethod ?? "", path: request.url?.path ?? "",
                        auth: request.value(forHTTPHeaderField: "Authorization"), body: body)
        Self.lock.lock()
        Self.seen.append(seen)
        let handler = Self.handler
        Self.lock.unlock()
        let (status, json) = handler?(seen) ?? (500, [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MemoryTokenStore: HostedTokenStore {
    var values: [String: String] = [:]
    func get(_ key: String) -> String? { values[key] }
    func set(_ value: String, for key: String) { values[key] = value.isEmpty ? nil : value }
}

@MainActor
final class HostedSessionTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var store = MemoryTokenStore()

    private func makeSession(signedIn: Bool = true) -> HostedSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let api = HostedAPI(baseURL: URL(string: "https://api.test")!, session: URLSession(configuration: config))
        if signedIn { store.set("refresh-1", for: "hosted.refresh") }
        return HostedSession(store: store, apiProvider: { api }, now: { self.clock })
    }

    private let quota: [String: Any] = ["plan": "free", "recapsRemaining": 2, "resetsAt": "2026-12-01T00:00:00.000Z"]

    // MARK: Sign in

    func testSignInSendsTheServerNonceAndKeepsTheTokens() async throws {
        StubProtocol.reset { seen in
            switch seen.path {
            case "/v1/auth/nonce": return (200, ["nonce": "abc.123.def", "expiresIn": 600])
            case "/v1/auth/apple": return (200, ["accessToken": "access-1", "refreshToken": "refresh-1", "expiresIn": 3600, "user": ["id": "u1"]])
            default: return (200, ["quota": self.quota])
            }
        }
        let session = makeSession(signedIn: false)
        XCTAssertFalse(session.isSignedIn)

        let nonce = try await session.fetchNonce()
        XCTAssertEqual(nonce, "abc.123.def")
        try await session.signIn(.apple, idToken: "id-token", nonce: nonce)

        let signIn = StubProtocol.calls.first { $0.path == "/v1/auth/apple" }
        XCTAssertEqual(signIn?.body["idToken"] as? String, "id-token")
        XCTAssertEqual(signIn?.body["nonce"] as? String, "abc.123.def")
        XCTAssertTrue(session.isSignedIn)
        XCTAssertEqual(store.get("hosted.refresh"), "refresh-1")
        XCTAssertEqual(session.quota?.recapsRemaining, 2)
    }

    func testAFailedSignInSaysWhyAndStaysSignedOut() async {
        StubProtocol.reset { _ in (401, ["error": ["code": "invalid_token", "message": "secret server wording"]]) }
        let session = makeSession(signedIn: false)
        do { try await session.signIn(.google, idToken: "x", nonce: "n"); XCTFail("should throw") } catch {}
        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(store.get("hosted.refresh"))
        XCTAssertEqual(session.signInError, HostedError.unauthorized.errorDescription)
        XCTAssertFalse(session.signInError?.contains("secret") ?? true)
    }

    // MARK: Recaps

    func testARecapCarriesTheTaskJobAndBearerTokenAndUpdatesTheQuota() async throws {
        StubProtocol.reset { seen in
            switch seen.path {
            case "/v1/auth/refresh": return (200, ["accessToken": "access-1", "expiresIn": 3600])
            default: return (200, ["text": "NOTES", "quota": self.quota])
            }
        }
        let session = makeSession()
        let text = try await session.complete(purpose: .recap, jobID: "recording-1234", system: "sys", user: "usr", maxTokens: 8000)
        XCTAssertEqual(text, "NOTES")

        let call = try XCTUnwrap(StubProtocol.calls.last)
        XCTAssertEqual(call.path, "/v1/recap")
        XCTAssertEqual(call.auth, "Bearer access-1")
        XCTAssertEqual(call.body["task"] as? String, "recap")
        XCTAssertEqual(call.body["jobId"] as? String, "recording-1234")
        XCTAssertEqual(call.body["system"] as? String, "sys")
        XCTAssertEqual(call.body["maxTokens"] as? Int, 8000)
        XCTAssertEqual(session.quota?.recapsRemaining, 2)
        XCTAssertEqual(session.quota?.resetsAt, Date(timeIntervalSince1970: 1_796_083_200)) // 2026-12-01
    }

    func testAnswersCarryNoJobIdAndRecapsWithoutOneNeverReachTheNetwork() async throws {
        StubProtocol.reset { seen in
            seen.path == "/v1/auth/refresh" ? (200, ["accessToken": "a", "expiresIn": 3600]) : (200, ["text": "ok", "quota": self.quota])
        }
        let session = makeSession()
        _ = try await session.complete(purpose: .answer, jobID: "ignored-id-1234", system: "s", user: "u", maxTokens: 100)
        XCTAssertNil(StubProtocol.calls.last?.body["jobId"])
        XCTAssertEqual(StubProtocol.calls.last?.body["task"] as? String, "answer")

        let before = StubProtocol.calls.count
        for purpose in [HostedCall.Purpose.recap, .meeting] {
            do { _ = try await session.complete(purpose: purpose, jobID: nil, system: "s", user: "u", maxTokens: 1); XCTFail() }
            catch { XCTAssertEqual(error as? HostedError, .missingJob) }
        }
        XCTAssertEqual(StubProtocol.calls.count, before)
    }

    func testSignedOutCallsFailWithoutTouchingTheNetwork() async {
        StubProtocol.reset { _ in (200, [:]) }
        let session = makeSession(signedIn: false)
        do { _ = try await session.complete(purpose: .answer, jobID: nil, system: "s", user: "u", maxTokens: 1); XCTFail() }
        catch { XCTAssertEqual(error as? HostedError, .notSignedIn) }
        XCTAssertTrue(StubProtocol.calls.isEmpty)
    }

    // MARK: Tokens

    func testAnExpiredAccessTokenIsRefreshedOnceEvenWhenWindowsRunTogether() async throws {
        StubProtocol.reset { seen in
            seen.path == "/v1/auth/refresh"
                ? (200, ["accessToken": "access-2", "expiresIn": 3600])
                : (200, ["text": "ok", "quota": self.quota])
        }
        let session = makeSession()
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<4 {
                group.addTask { try await session.complete(purpose: .answer, jobID: nil, system: "s", user: "u\(i)", maxTokens: 1) }
            }
            for try await _ in group {}
        }
        XCTAssertEqual(StubProtocol.calls.filter { $0.path == "/v1/auth/refresh" }.count, 1)
        XCTAssertTrue(StubProtocol.calls.filter { $0.path == "/v1/recap" }.allSatisfy { $0.auth == "Bearer access-2" })
    }

    func testATokenNearExpiryIsRefreshedBeforeUse() async throws {
        var refreshes = 0
        StubProtocol.reset { seen in
            if seen.path == "/v1/auth/refresh" { refreshes += 1; return (200, ["accessToken": "access-\(refreshes)", "expiresIn": 3600]) }
            return (200, ["text": "ok", "quota": self.quota])
        }
        let session = makeSession()
        _ = try await session.complete(purpose: .answer, jobID: nil, system: "s", user: "u", maxTokens: 1)
        clock = clock.addingTimeInterval(3_600 - 30) // 30 seconds of life left
        _ = try await session.complete(purpose: .answer, jobID: nil, system: "s", user: "u", maxTokens: 1)
        XCTAssertEqual(refreshes, 2)
    }

    func testARefusedTokenIsRefreshedAndTheCallRetriedOnce() async throws {
        var recapCalls = 0
        StubProtocol.reset { seen in
            if seen.path == "/v1/auth/refresh" { return (200, ["accessToken": "access-new", "expiresIn": 3600]) }
            recapCalls += 1
            return recapCalls == 1 ? (401, ["error": ["code": "unauthorized"]]) : (200, ["text": "ok", "quota": self.quota])
        }
        let session = makeSession()
        let text = try await session.complete(purpose: .answer, jobID: nil, system: "s", user: "u", maxTokens: 1)
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(recapCalls, 2)
    }

    func testARevokedSessionSignsOutInsteadOfLooping() async {
        StubProtocol.reset { _ in (401, ["error": ["code": "unauthorized"]]) }
        let session = makeSession()
        do { _ = try await session.complete(purpose: .answer, jobID: nil, system: "s", user: "u", maxTokens: 1); XCTFail() }
        catch { XCTAssertEqual(error as? HostedError, .notSignedIn) }
        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(store.get("hosted.refresh"))
        XCTAssertLessThanOrEqual(StubProtocol.calls.count, 4)
    }

    func testASlowRefreshCannotBringBackASessionThatWasSignedOut() async throws {
        var releaseRefresh: (() -> Void)?
        StubProtocol.reset { seen in
            if seen.path == "/v1/auth/refresh" {
                let gate = DispatchSemaphore(value: 0)
                releaseRefresh = { gate.signal() }
                _ = gate.wait(timeout: .now() + 3)
                return (200, ["accessToken": "late-token", "expiresIn": 3600])
            }
            return (200, ["text": "ok", "quota": self.quota])
        }
        let session = makeSession()
        let inFlight = Task { try await session.complete(purpose: .answer, jobID: nil, system: "s", user: "u", maxTokens: 1) }
        while StubProtocol.calls.filter({ $0.path == "/v1/auth/refresh" }).isEmpty { try await Task.sleep(for: .milliseconds(5)) }

        await session.signOut()          // while the refresh is still out
        releaseRefresh?()
        _ = try? await inFlight.value

        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(store.get("hosted.refresh"))
        XCTAssertTrue(StubProtocol.calls.filter { $0.path == "/v1/recap" }.isEmpty, "the late token must never be used")
    }

    func testSigningOutClearsLocalStateBeforeTheServerIsTold() async {
        var signedInWhenServerWasTold: Bool?
        var sessionRef: HostedSession?
        StubProtocol.reset { seen in
            if seen.path == "/v1/auth/logout" { DispatchQueue.main.sync { signedInWhenServerWasTold = sessionRef?.isSignedIn } }
            return (200, ["ok": true])
        }
        let session = makeSession()
        sessionRef = session
        await session.signOut()
        XCTAssertEqual(signedInWhenServerWasTold, false)
    }

    // MARK: Errors

    func testTheMonthlyLimitOpensThePaywallOnceAndZeroesTheCount() async {
        StubProtocol.reset { seen in
            seen.path == "/v1/auth/refresh"
                ? (200, ["accessToken": "a", "expiresIn": 3600])
                : (402, ["error": ["code": "quota_exceeded", "plan": "free", "resetsAt": "2026-12-01T00:00:00.000Z"]])
        }
        let session = makeSession()
        for _ in 0..<2 {
            do { _ = try await session.complete(purpose: .recap, jobID: "recording-9999", system: "s", user: "u", maxTokens: 1); XCTFail() }
            catch let error as HostedError {
                guard case .quotaExceeded(let plan, let resets) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(plan, "free")
                XCTAssertNotNil(resets)
            } catch { XCTFail("\(error)") }
        }
        let first = session.limit
        XCTAssertEqual(first?.plan, "free")
        XCTAssertEqual(session.quota?.recapsRemaining, 0)
        XCTAssertEqual(session.limit?.id, first?.id) // the second refusal did not stack another sheet
    }

    func testServerErrorsBecomeSpecificMessagesAndNeverShowServerWording() {
        let cases: [(Int, String, HostedError)] = [
            (429, "rate_limited", .rateLimited),
            (429, "request_in_flight", .inFlight),
            (429, "job_limit", .jobLimit),
            (429, "other_limit", .otherLimit),
            (503, "service_busy", .busy),
            (503, "model_busy", .busy),
            (413, "input_too_large", .tooLong),
            (422, "refused", .refused),
            (500, "misconfigured", .server(status: 500, code: "misconfigured")),
        ]
        for (status, code, expected) in cases {
            let error = HostedError.from(status: status, body: ["error": ["code": code, "message": "SERVER WORDING"]])
            XCTAssertEqual(error, expected, "\(status) \(code)")
            XCTAssertFalse(error.errorDescription?.contains("SERVER WORDING") ?? true)
        }
    }

    func testAnUnreachableServerIsReportedAsOffline() async {
        final class Failing: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
            override func stopLoading() {}
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Failing.self]
        let api = HostedAPI(baseURL: URL(string: "https://api.test")!, session: URLSession(configuration: config))
        store.set("refresh-1", for: "hosted.refresh")
        let session = HostedSession(store: store, apiProvider: { api }, now: { self.clock })
        do { _ = try await session.complete(purpose: .answer, jobID: nil, system: "s", user: "u", maxTokens: 1); XCTFail() }
        catch { XCTAssertEqual(error as? HostedError, .offline) }
        XCTAssertTrue(session.isSignedIn, "going offline must not sign anyone out")
    }

    // MARK: Account

    func testSigningOutRevokesTheTokenAndClearsIt() async {
        StubProtocol.reset { _ in (200, ["ok": true]) }
        let session = makeSession()
        await session.signOut()
        XCTAssertEqual(StubProtocol.calls.last?.path, "/v1/auth/logout")
        XCTAssertEqual(StubProtocol.calls.last?.body["refreshToken"] as? String, "refresh-1")
        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(store.get("hosted.refresh"))
    }

    func testDeletingTheAccountReportsARunningSubscription() async throws {
        StubProtocol.reset { seen in
            switch (seen.method, seen.path) {
            case ("POST", "/v1/auth/refresh"): return (200, ["accessToken": "a", "expiresIn": 3600])
            case ("DELETE", "/v1/me"): return (200, ["deleted": true, "subscriptionStillActive": true])
            default: return (200, [:])
            }
        }
        let session = makeSession()
        let stillActive = try await session.deleteAccount()
        XCTAssertTrue(stillActive)
        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(store.get("hosted.refresh"))
    }

    // MARK: The engine

    func testTheEngineTagsEachKindOfCallAndSharesOneJobAcrossAWholeRecording() async throws {
        StubProtocol.reset { seen in
            if seen.path == "/v1/auth/refresh" { return (200, ["accessToken": "a", "expiresIn": 3600]) }
            let task = seen.body["task"] as? String
            let text = task == "meeting"
                ? #"{"actions":[],"outcomes":[],"context":[]}"#
                : #"{"title":"T","tldr":["x"],"keyPoints":[],"actionItems":[],"decisions":[],"openQuestions":[]}"#
            return (200, ["text": task == "answer" ? "An answer." : text, "quota": self.quota])
        }
        let session = makeSession()
        let engine = HostedRecapEngine(session: session)
        // Two windows: more text than one cloud request holds.
        let transcript = (0..<2).map { _ in String(repeating: "[00:00:01] Speaker 1: " + String(repeating: "word ", count: 2_000) + "\n", count: 7) }.joined()

        _ = try? await HostedCall.$jobID.withValue("recording-abcdef12") {
            try await engine.makeRecap(transcript: transcript, mode: .lecture) { _ in }
        }
        let recapCalls = StubProtocol.calls.filter { $0.path == "/v1/recap" }
        XCTAssertGreaterThanOrEqual(recapCalls.count, 2, "a long transcript is sent in several windows")
        XCTAssertTrue(recapCalls.allSatisfy { $0.body["task"] as? String == "recap" })
        XCTAssertTrue(recapCalls.allSatisfy { $0.body["jobId"] as? String == "recording-abcdef12" })

        let context = RetrievedContext(text: "notes", recaps: [], searchedCount: 0, clipped: false)
        let answer = try await engine.answer(question: "What?", persona: "", context: context)
        XCTAssertEqual(answer, "An answer.")
        let last = try XCTUnwrap(StubProtocol.calls.last)
        XCTAssertEqual(last.body["task"] as? String, "answer")
        XCTAssertNil(last.body["jobId"])

        _ = try? await HostedCall.$jobID.withValue("recording-abcdef12") {
            try await engine.extractMeeting(transcript: "[00:00:01] a", documents: "", agenda: "")
        }
        let meeting = try XCTUnwrap(StubProtocol.calls.last)
        XCTAssertEqual(meeting.body["task"] as? String, "meeting")
        XCTAssertEqual(meeting.body["jobId"] as? String, "recording-abcdef12")
    }
}
