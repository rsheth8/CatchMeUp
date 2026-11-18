import XCTest
@testable import BenchCore

final class JudgeBackendTests: XCTestCase {
    func testTheCLIRunsCleanWithNoToolsSettingsOrSavedSession() throws {
        let args = try ClaudeCLI.arguments(model: "claude-opus-5-5", system: "judge", schema: ["type": "object"])
        func value(after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        XCTAssertEqual(args.first, "-p")
        XCTAssertEqual(value(after: "--model"), "claude-opus-5-5")
        XCTAssertEqual(value(after: "--system-prompt"), "judge")
        XCTAssertEqual(value(after: "--tools"), "", "no tools: the judge only reads")
        XCTAssertEqual(value(after: "--setting-sources"), "", "no hooks, memory or user settings")
        XCTAssertEqual(value(after: "--output-format"), "json")
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertTrue(args.contains("--disable-slash-commands"))
        XCTAssertEqual(value(after: "--json-schema"), #"{"type":"object"}"#)
    }

    func testAPIKeyVariablesNeverReachTheCLISoTheSubscriptionIsUsed() {
        let env = ClaudeCLI.environment(from: [
            "ANTHROPIC_API_KEY": "sk-secret", "ANTHROPIC_AUTH_TOKEN": "t", "CLAUDE_CODE_USE_BEDROCK": "1",
            "PATH": "/usr/bin", "HOME": "/Users/x",
        ])
        XCTAssertEqual(env, ["PATH": "/usr/bin", "HOME": "/Users/x"])
    }

    func testReadsTheStructuredAnswer() throws {
        let out = #"{"is_error":false,"result":"{\"winner\":\"A\"}","structured_output":{"winner":"B","reason":"r"}}"#
        let text = try ClaudeCLI.answer(fromOutput: Data(out.utf8))
        let json = try Judge.object(text)
        XCTAssertEqual(json["winner"] as? String, "B")
    }

    func testFallsBackToTheResultText() throws {
        let out = #"{"is_error":false,"result":"{\"winner\":\"tie\",\"reason\":\"same\"}"}"#
        XCTAssertEqual(try Judge.object(try ClaudeCLI.answer(fromOutput: Data(out.utf8)))["winner"] as? String, "tie")
    }

    func testErrorsAndGarbageAreReportedNotParsedAsJudgments() {
        for out in [#"{"is_error":true,"result":"You've hit your usage limit"}"#, "not json", #"{"is_error":false}"#] {
            XCTAssertThrowsError(try ClaudeCLI.answer(fromOutput: Data(out.utf8)), out) { error in
                guard case BenchError.badJudgeReply = error else { return XCTFail("\(error)") }
            }
        }
    }
}
