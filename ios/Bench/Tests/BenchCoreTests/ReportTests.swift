import XCTest
@testable import BenchCore

final class ReportTests: XCTestCase {

    private let item = CorpusItem(
        id: "r1", mode: .meeting, title: "r1",
        transcript: "[00:00:05] Speaker 1: Launch is June 17.\n[00:01:00] Speaker 2: Price is 99.",
        gold: Gold(facts: [GoldFact(id: "date", anyOf: ["june 17"]), GoldFact(id: "price", anyOf: ["99"])])
    )

    private func recap(date: Bool, price: Bool, stamp: String = "00:00:05", name: String = "") -> Recap {
        var r = Recap()
        r.tldr = [(date ? "Launch is June 17. " : "") + (price ? "Price is 99." : "Notes.")]
        r.detailedNotes = [DetailNote(heading: "h", content: "c")]
        r.bookmarks = [Bookmark(timestamp: stamp, heading: "h", insight: "i")]
        if !name.isEmpty { r.speakers = [SpeakerNote(label: "Speaker 1", name: name, said: "x")] }
        return r
    }

    private func run(_ engine: String, ok: Bool = true, recap: Recap?, seconds: Double = 5, cost: Double? = nil) -> RunRecord {
        RunRecord(transcriptId: "r1", engine: engine, model: "m-\(engine)", ok: ok, error: ok ? nil : "boom",
                  seconds: seconds, chunks: 1, calls: 1, inputTokens: 10, outputTokens: 10,
                  costUSD: cost, recap: recap, finishedAt: Date())
    }

    private func report(_ runs: [RunRecord], abs: [AbsoluteJudgment] = [], pairs: [PairJudgment] = [],
                        criteria: Criteria = Criteria()) -> Report {
        Report(runs: runs, absolute: abs, pairsJudged: pairs, corpus: [item], criteria: criteria)
    }

    private func judgment(_ engine: String, _ score: Int) -> AbsoluteJudgment {
        AbsoluteJudgment(transcriptId: "r1", engine: engine, judgeModel: "j",
                         faithfulness: score, completeness: score, usefulness: score,
                         unsupportedClaims: [], missingKeyPoints: [], notes: "")
    }

    // MARK: Verdict

    func testAGoodCandidatePassesEveryCriterion() {
        let good = recap(date: true, price: true)
        let r = report(
            [run("apple", recap: good), run("haiku", recap: good, cost: 0.01)],
            abs: [judgment("apple", 4), judgment("haiku", 4)],
            pairs: [PairJudgment(transcriptId: "r1", first: "apple", second: "haiku", judgeModel: "j", winner: "tie", reason: ""),
                    PairJudgment(transcriptId: "r1", first: "haiku", second: "apple", judgeModel: "j", winner: "tie", reason: "")]
        )
        XCTAssertEqual(r.verdict.pass, true, r.verdict.text)
    }

    func testAFailedRunCountsAgainstTheFailureRate() {
        let r = report([run("apple", ok: false, recap: nil), run("haiku", recap: recap(date: true, price: true))])
        let failure = r.evaluate().first { $0.name == "Failure rate" }
        XCTAssertEqual(failure?.passed, false)
        XCTAssertEqual(r.verdict.pass, false)
    }

    func testOneInventedNameFailsTheRun() {
        let r = report([
            run("apple", recap: recap(date: true, price: true, name: "Priya")),
            run("haiku", recap: recap(date: true, price: true)),
        ])
        XCTAssertEqual(r.evaluate().first { $0.name == "Invented names" }?.passed, false)
    }

    func testBookmarksPastTheEndFailTheGroundingCriterion() {
        let r = report([run("apple", recap: recap(date: true, price: true, stamp: "01:30:00")),
                        run("haiku", recap: recap(date: true, price: true))])
        XCTAssertEqual(r.evaluate().first { $0.name == "Bookmarks land on a real moment" }?.passed, false)
    }

    func testLowerFactCoverageThanBaselineFails() {
        let r = report([run("apple", recap: recap(date: false, price: false)),
                        run("haiku", recap: recap(date: true, price: true))])
        XCTAssertEqual(r.evaluate().first { $0.name.hasPrefix("Fact coverage") }?.passed, false)
    }

    func testWithoutJudgingTheVerdictIsInconclusiveNotPass() {
        let good = recap(date: true, price: true)
        let r = report([run("apple", recap: good), run("haiku", recap: good)])
        XCTAssertNil(r.verdict.pass)
    }

    func testJudgeDeficitBeyondTheLimitFails() {
        let good = recap(date: true, price: true)
        let r = report([run("apple", recap: good), run("haiku", recap: good)],
                       abs: [judgment("apple", 2), judgment("haiku", 4)])
        XCTAssertEqual(r.evaluate().first { $0.name.hasPrefix("Judge score") }?.passed, false)
    }

    // MARK: Pairwise

    func testAWinnerMustWinInBothOrders() {
        let good = recap(date: true, price: true)
        func pair(_ first: String, _ second: String, _ winner: String) -> PairJudgment {
            PairJudgment(transcriptId: "r1", first: first, second: second, judgeModel: "j", winner: winner, reason: "")
        }
        // haiku wins both orders: a real win.
        var r = report([run("apple", recap: good), run("haiku", recap: good)],
                       pairs: [pair("apple", "haiku", "second"), pair("haiku", "apple", "first")])
        XCTAssertEqual(r.pairs.first?.bWins, 1)
        XCTAssertEqual(r.pairs.first?.aScore, 0)

        // Whoever is shown first wins: position bias, so it is a tie.
        r = report([run("apple", recap: good), run("haiku", recap: good)],
                   pairs: [pair("apple", "haiku", "first"), pair("haiku", "apple", "first")])
        XCTAssertEqual(r.pairs.first?.ties, 1)
        XCTAssertEqual(r.pairs.first?.aScore, 0.5)
    }

    // MARK: Output

    func testMarkdownNamesEveryEngineAndShowsCostOnlyForCloud() {
        let good = recap(date: true, price: true)
        let md = report([run("apple", recap: good), run("haiku", recap: good, cost: 0.0123)]).markdown()
        XCTAssertTrue(md.contains("| apple |"))
        XCTAssertTrue(md.contains("| haiku |"))
        XCTAssertTrue(md.contains("$0.0123"))
        XCTAssertTrue(md.contains("free"))
        XCTAssertTrue(md.contains("Reading this fairly"))
    }

    func testCriteriaFileRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var c = Criteria()
        c.maxFailureRate = 0.2
        try JSONEncoder().encode(c).write(to: url)
        XCTAssertEqual(try Criteria.load(from: url), c)
    }

    func testTheShippedCriteriaFileMatchesTheDefaults() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("criteria.json")
        XCTAssertEqual(try Criteria.load(from: url), Criteria())
    }

    func testRunRecordSurvivesDiskRoundTrip() throws {
        let original = run("apple", recap: recap(date: true, price: true), cost: nil)
        let data = try ResultStore.encoder.encode(original)
        let back = try ResultStore.decoder.decode(RunRecord.self, from: data)
        // Row ids (UUIDs) are deliberately not persisted by the app's models, so
        // compare the content that is.
        XCTAssertEqual(back.recap?.tldr, original.recap?.tldr)
        XCTAssertEqual(back.recap?.bookmarks?.map(\.timestamp), original.recap?.bookmarks?.map(\.timestamp))
        XCTAssertEqual(back.recap?.detailedNotes?.map(\.content), original.recap?.detailedNotes?.map(\.content))
        XCTAssertEqual(back.engine, "apple")
    }
}
