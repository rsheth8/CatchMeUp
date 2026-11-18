import XCTest
@testable import BenchCore

/// Stands in for a model so the runner, the shared chunk/parse pipeline and
/// the metering can be tested without a network or the on-device model.
private struct StubEngine: RecapEngine {
    var recapBudget: RecapBudget { RecapBudget(charactersPerRequest: 200) }
    var contextBudget: Int { 1000 }
    let reply: @Sendable (String) throws -> String
    let meter: UsageMeter

    func respond(system: String, user: String, maxTokens: Int) async throws -> String {
        meter.add(model: "claude-haiku-4-5-20251001", input: 1_000, output: 500)
        return try reply(user)
    }
}

final class EngineTests: XCTestCase {

    private let item = CorpusItem(
        id: "e1", mode: .lecture, title: "e1",
        transcript: (0..<12).map { "[00:00:\(String(format: "%02d", $0 * 5))] line number \($0) about topic" }.joined(separator: "\n"),
        gold: Gold()
    )

    private let goodJSON = #"{"title":"T","tldr":["a"],"detailed_notes":[{"heading":"h","content":"c"}]}"#

    // MARK: Runner

    func testRunnerRecordsSuccessChunksAndCost() async {
        let meter = UsageMeter()
        let handle = EngineHandle(engine: StubEngine(reply: { _ in self.goodJSON }, meter: meter), meter: meter)
        BudgetGuard.shared.configure(limit: 100)
        let spec = EngineSpec(label: "haiku", backend: .anthropic(model: "claude-haiku-4-5-20251001"))

        let record = await Runner.run(spec: spec, item: item, handle: handle)

        XCTAssertTrue(record.ok, record.error ?? "")
        XCTAssertGreaterThan(record.chunks, 1, "a 200-character budget must split this transcript")
        XCTAssertEqual(record.calls, record.chunks)
        // $1 in / $5 out per million tokens: 1,000 in + 500 out per call.
        XCTAssertEqual(record.costUSD ?? 0, Double(record.chunks) * (0.001 + 0.0025), accuracy: 1e-9)
        XCTAssertEqual(record.recap?.title, "T")
    }

    func testRunnerRecordsAThrowingEngineAsAFailureNotACrash() async {
        let meter = UsageMeter()
        let handle = EngineHandle(engine: StubEngine(reply: { _ in throw EngineError.http(500, "down") }, meter: meter), meter: meter)
        let spec = EngineSpec(label: "apple", backend: .apple)

        let record = await Runner.run(spec: spec, item: item, handle: handle)

        XCTAssertFalse(record.ok)
        XCTAssertNil(record.recap)
        XCTAssertNil(record.costUSD, "the on-device engine has no API cost")
        XCTAssertTrue(record.error?.contains("500") == true)
    }

    func testAnEmptyRecapIsAFailureEvenWithoutAnError() async {
        let meter = UsageMeter()
        let handle = EngineHandle(engine: StubEngine(reply: { _ in #"{"title":"T"}"# }, meter: meter), meter: meter)
        let spec = EngineSpec(label: "haiku", backend: .anthropic(model: "claude-haiku-4-5-20251001"))

        let record = await Runner.run(spec: spec, item: item, handle: handle)

        XCTAssertFalse(record.ok)
        XCTAssertTrue(record.error?.contains("Empty recap") == true)
    }

    func testSecondRunStartsFromZeroUsage() async {
        let meter = UsageMeter()
        let handle = EngineHandle(engine: StubEngine(reply: { _ in self.goodJSON }, meter: meter), meter: meter)
        let spec = EngineSpec(label: "haiku", backend: .anthropic(model: "claude-haiku-4-5-20251001"))
        let first = await Runner.run(spec: spec, item: item, handle: handle)
        let second = await Runner.run(spec: spec, item: item, handle: handle)
        XCTAssertEqual(first.calls, second.calls)
    }

    // MARK: Spend guard

    func testBudgetGuardStopsFurtherSpending() throws {
        BudgetGuard.shared.configure(limit: 0.01)
        XCTAssertNoThrow(try BudgetGuard.shared.check())
        BudgetGuard.shared.record(0.02)
        XCTAssertThrowsError(try BudgetGuard.shared.check())
        BudgetGuard.shared.configure(limit: 5)
    }

    // MARK: Pricing

    func testPricingResolvesDatedAndFamilyIdsAndKnowsWhenItDoesNotKnow() {
        XCTAssertEqual(Pricing.rate(for: "claude-haiku-4-5-20251001")?.input, 1)
        XCTAssertEqual(Pricing.rate(for: "claude-sonnet-5-5")?.output, 10)
        XCTAssertEqual(Pricing.rate(for: "claude-opus-5-5")?.input, 4, "5-5 must win over the shorter opus-5 prefix")
        XCTAssertEqual(Pricing.rate(for: "claude-opus-5")?.input, 5)
        XCTAssertNil(Pricing.rate(for: "some-other-model"))
        XCTAssertEqual(Pricing.cost(model: "claude-haiku-4-5", inputTokens: 1_000_000, outputTokens: 1_000_000), 6)
    }

    // MARK: API reply parsing

    func testParseKeepsTextDropsThinkingAndSumsCachedInput() throws {
        let body = #"""
        {"stop_reason":"end_turn",
         "content":[{"type":"thinking","thinking":""},{"type":"text","text":"hello "},{"type":"text","text":"world"}],
         "usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":3,"output_tokens":7}}
        """#
        let reply = try AnthropicHTTP.parse(Data(body.utf8))
        XCTAssertEqual(reply.text, "hello world")
        XCTAssertEqual(reply.inputTokens, 18)
        XCTAssertEqual(reply.outputTokens, 7)
    }

    func testParseTreatsARefusalAsAnErrorNotAnEmptyRecap() {
        let body = #"{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"},"content":[],"usage":{}}"#
        XCTAssertThrowsError(try AnthropicHTTP.parse(Data(body.utf8))) { error in
            XCTAssertTrue("\(error)".contains("cyber") || (error as? LocalizedError)?.errorDescription?.contains("cyber") == true)
        }
    }

    func testParseFlagsAReplyCutOffBeforeAnyText() {
        let body = #"{"stop_reason":"max_tokens","content":[{"type":"thinking","thinking":""}],"usage":{"output_tokens":16000}}"#
        XCTAssertThrowsError(try AnthropicHTTP.parse(Data(body.utf8)))
    }

    func testEffortIsOnlySentToModelsThatTakeIt() {
        XCTAssertTrue(AnthropicHTTP.supportsEffort("claude-opus-5-5"))
        XCTAssertTrue(AnthropicHTTP.supportsEffort("claude-sonnet-5-5"))
        XCTAssertFalse(AnthropicHTTP.supportsEffort("claude-haiku-4-5-20251001"))
    }

    func testMissingKeyIsReportedBeforeAnyRequest() async {
        do {
            _ = try await AnthropicHTTP.message(model: "claude-haiku-4-5", system: "s", user: "u", maxTokens: 10, effort: nil, apiKey: "")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".lowercased().contains("missingkey") || (error as? LocalizedError)?.errorDescription?.contains("ANTHROPIC_API_KEY") == true)
        }
    }

    // MARK: Judge reply parsing

    func testJudgeToleratesAFencedReplyButNotGarbage() throws {
        let fenced = "```json\n{\"winner\":\"A\",\"reason\":\"r\"}\n```"
        XCTAssertEqual(try Judge.object(fenced)["winner"] as? String, "A")
        XCTAssertThrowsError(try Judge.object("I think A is better."))
    }

    func testPairWinnerMapsBackToTheEngineThatWasShownInThatSlot() {
        let p = PairJudgment(transcriptId: "t", first: "haiku", second: "apple", judgeModel: "j", winner: "second", reason: "")
        XCTAssertEqual(p.winnerEngine, "apple")
        XCTAssertNil(PairJudgment(transcriptId: "t", first: "a", second: "b", judgeModel: "j", winner: "tie", reason: "").winnerEngine)
    }
}
