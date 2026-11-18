import XCTest
@testable import BenchCore

/// Intercepts URLSession traffic so the request shape and spend accounting can
/// be checked without a key or a network.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(status: Int, headers: [String: String], body: String)] = []
    nonisolated(unsafe) static var requests: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Self.requests.append(json)
            }
        }
        let next = Self.responses.isEmpty ? (status: 500, headers: [:], body: "{}") : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: next.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HTTPTests: XCTestCase {

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    private let okBody = #"{"stop_reason":"end_turn","content":[{"type":"text","text":"{}"}],"usage":{"input_tokens":1000,"output_tokens":500}}"#

    override func setUp() {
        StubProtocol.responses = []
        StubProtocol.requests = []
        BudgetGuard.shared.configure(limit: 5)
    }

    func testRequestForANewerModelCarriesEffortAndSchemaAndNoSamplingParameters() async throws {
        StubProtocol.responses = [(200, [:], okBody)]
        _ = try await AnthropicHTTP.message(
            model: "claude-opus-5-5", system: "s", user: "u", maxTokens: 2_000, effort: "medium",
            jsonSchema: ["type": "object"], apiKey: "test-key", session: session
        )
        let body = try XCTUnwrap(StubProtocol.requests.first)
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "medium")
        XCTAssertEqual((output["format"] as? [String: Any])?["type"] as? String, "json_schema")
        XCTAssertNil(body["temperature"], "newer models reject non-default sampling parameters")
        XCTAssertNil(body["top_p"])
        XCTAssertNil(body["thinking"], "thinking is left at the model default")
        XCTAssertGreaterThanOrEqual(body["max_tokens"] as? Int ?? 0, 16_000, "thinking shares max_tokens with the answer")
    }

    func testHaikuGetsNoEffortAndKeepsTheRequestedMaxTokens() async throws {
        StubProtocol.responses = [(200, [:], okBody)]
        _ = try await AnthropicHTTP.message(
            model: "claude-haiku-4-5-20251001", system: "s", user: "u", maxTokens: 8_000, effort: "medium",
            apiKey: "test-key", session: session
        )
        let body = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertNil(body["output_config"])
        XCTAssertEqual(body["max_tokens"] as? Int, 8_000)
    }

    func testEveryCallIsChargedToTheSpendGuardIncludingJudgeCalls() async throws {
        StubProtocol.responses = [(200, [:], okBody)]
        _ = try await AnthropicHTTP.message(
            model: "claude-opus-5-5", system: "s", user: "u", maxTokens: 100, effort: nil,
            apiKey: "k", session: session
        )
        // 1,000 input at $4/M plus 500 output at $20/M.
        XCTAssertEqual(BudgetGuard.shared.total, 0.004 + 0.010, accuracy: 1e-9)
    }

    func testTheSpendLimitStopsTheNextCallBeforeItIsSent() async throws {
        BudgetGuard.shared.configure(limit: 0.01)
        StubProtocol.responses = [(200, [:], okBody), (200, [:], okBody)]
        _ = try await AnthropicHTTP.message(
            model: "claude-opus-5-5", system: "s", user: "u", maxTokens: 100, effort: nil,
            apiKey: "k", session: session
        )
        do {
            _ = try await AnthropicHTTP.message(
                model: "claude-opus-5-5", system: "s", user: "u", maxTokens: 100, effort: nil,
                apiKey: "k", session: session
            )
            XCTFail("the second call should have been refused")
        } catch BenchError.budgetExceeded {
            XCTAssertEqual(StubProtocol.requests.count, 1, "the refused call must never reach the network")
        }
    }

    func testARateLimitIsRetriedAndThenSucceeds() async throws {
        StubProtocol.responses = [(429, ["retry-after": "0"], "{}"), (200, [:], okBody)]
        let reply = try await AnthropicHTTP.message(
            model: "claude-haiku-4-5", system: "s", user: "u", maxTokens: 100, effort: nil,
            apiKey: "k", session: session
        )
        XCTAssertEqual(reply.text, "{}")
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testAClientErrorIsNotRetried() async {
        StubProtocol.responses = [(400, [:], #"{"error":"bad"}"#), (200, [:], okBody)]
        do {
            _ = try await AnthropicHTTP.message(
                model: "claude-haiku-4-5", system: "s", user: "u", maxTokens: 100, effort: nil,
                apiKey: "k", session: session
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(StubProtocol.requests.count, 1)
        }
    }

    func testTheKeyIsSentAsAHeaderAndNeverInTheBodyOrErrors() async throws {
        StubProtocol.responses = [(401, [:], #"{"error":"invalid"}"#)]
        do {
            _ = try await AnthropicHTTP.message(
                model: "claude-haiku-4-5", system: "s", user: "u", maxTokens: 100, effort: nil,
                apiKey: "sk-secret-value", session: session
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertFalse("\(error)".contains("sk-secret-value"))
            XCTAssertFalse((error as? LocalizedError)?.errorDescription?.contains("sk-secret-value") ?? false)
        }
        let body = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertFalse(String(describing: body).contains("sk-secret-value"))
    }
}
