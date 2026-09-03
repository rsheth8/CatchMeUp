import XCTest
@testable import CatchMeUp

/// The bug these exist for: asking a brain a question used to send
/// `recs.prefix(12)` — the twelve most recent recaps regardless of the
/// question — so a brain with thirty lectures had eighteen the model never saw.
final class BrainRetrieverTests: XCTestCase {

    // MARK: Fixtures

    private func recap(_ title: String, notes: [String], terms: [String] = []) -> Recap {
        Recap(
            title: title,
            tldr: ["Gist of \(title)"],
            detailedNotes: notes.enumerated().map { DetailNote(heading: "Topic \($0.offset)", content: $0.element) },
            terms: terms.map { Term(term: $0, definition: "definition of \($0)") }
        )
    }

    private func recording(
        _ title: String, daysAgo: Int, notes: [String], terms: [String] = [], transcript: [String] = []
    ) -> Recording {
        var rec = Recording(
            title: title,
            createdAt: Date().addingTimeInterval(-Double(daysAgo) * 86_400),
            mode: .lecture,
            segments: transcript.enumerated().map { Segment(start: Double($0.offset) * 20, text: $0.element) }
        )
        rec.recap = recap(title, notes: notes, terms: terms)
        return rec
    }

    /// Twenty lectures, newest first, with the answer buried in the oldest.
    private func bigBrain(answerIn oldest: String) -> [Recording] {
        var out: [Recording] = []
        for i in 0..<19 {
            out.append(recording("Lecture \(20 - i)", daysAgo: i,
                                 notes: ["Ordinary material about loops and lists and general programming."]))
        }
        out.append(recording(oldest, daysAgo: 40,
                             notes: ["The Kruskal algorithm builds a minimum spanning tree by adding cheapest edges."],
                             terms: ["Kruskal"]))
        return out
    }

    // MARK: Tests

    /// The old `prefix(12)` could not have found this: it's the twentieth
    /// recap by recency.
    func testFindsTheMatchingRecapEvenWhenItIsTheOldest() {
        let recaps = bigBrain(answerIn: "Lecture 1 — Graphs")
        let result = BrainRetriever.context(
            for: "how does Kruskal's algorithm work?", recaps: recaps, budget: 4_000
        )

        XCTAssertTrue(result.text.contains("Kruskal"), "the matching passage should be in the context")
        XCTAssertEqual(result.recaps.first?.displayTitle, "Lecture 1 — Graphs")
        XCTAssertEqual(result.searchedCount, 20, "every recap in the brain should be searched")
    }

    /// Only recaps that actually contributed may be cited.
    func testSourcesAreLimitedToWhatWasSent() {
        let recaps = bigBrain(answerIn: "Lecture 1 — Graphs")
        let result = BrainRetriever.context(
            for: "how does Kruskal's algorithm work?", recaps: recaps, budget: 4_000
        )

        XCTAssertFalse(result.recaps.isEmpty)
        XCTAssertLessThan(result.recaps.count, recaps.count)
        for recap in result.recaps {
            XCTAssertTrue(result.text.contains(recap.displayTitle))
        }
    }

    /// Detail-level questions were unanswerable before, because only recap
    /// notes went into the context and transcripts never did.
    func testTranscriptLinesAreRetrievable() {
        let rec = recording(
            "Lecture 4", daysAgo: 1,
            notes: ["General notes that do not mention the specific phrase."],
            transcript: ["Remember that the halting problem is undecidable, which we will prove next week.",
                         "Now back to sorting."]
        )
        let result = BrainRetriever.context(for: "what did he say about the halting problem?",
                                            recaps: [rec], budget: 4_000)

        XCTAssertTrue(result.text.contains("halting problem"))
        XCTAssertTrue(result.text.contains("Said ["), "transcript passages should be labelled and timestamped")
    }

    /// A tight budget must still produce something usable, and must admit it
    /// left material behind.
    func testTinyBudgetIsRespectedAndReported() {
        // A question matching nearly every recap, so there is far more relevant
        // material than the budget can carry.
        let recaps = bigBrain(answerIn: "Lecture 1 — Graphs")
        let budget = 900
        let result = BrainRetriever.context(
            for: "summarise the programming loops and lists material", recaps: recaps, budget: budget
        )

        XCTAssertFalse(result.isEmpty)
        XCTAssertLessThanOrEqual(result.text.count, budget)
        XCTAssertTrue(result.clipped, "the caller needs to know the answer is partial")
    }

    /// The flip side: when everything that matched did fit, nothing was lost
    /// and the answer shouldn't be hedged.
    func testNothingIsReportedClippedWhenItAllFits() {
        let recaps = bigBrain(answerIn: "Lecture 1 — Graphs")
        let result = BrainRetriever.context(
            for: "how does Kruskal's algorithm work?", recaps: recaps, budget: 8_000
        )

        XCTAssertTrue(result.text.contains("Kruskal"))
        XCTAssertFalse(result.clipped)
    }

    /// Nothing matching shouldn't mean nothing sent — the model still needs
    /// something to say "the notes don't cover it" about.
    func testUnmatchedQuestionFallsBackToRecentGists() {
        let recaps = bigBrain(answerIn: "Lecture 1 — Graphs")
        let result = BrainRetriever.context(
            for: "zzzz quixotic aardvark", recaps: recaps, budget: 4_000
        )

        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.text.contains("Gist of"))
    }

    func testEmptyBrainReturnsNothingToSend() {
        let result = BrainRetriever.context(for: "anything", recaps: [], budget: 4_000)
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(result.recaps.isEmpty)
    }

    /// A recording still being processed has no notes and no transcript, so it
    /// shouldn't count towards what was searched.
    func testUnprocessedRecordingsAreSkipped() {
        let pending = Recording(title: "Recording from this morning", mode: .lecture)
        let done = recording("Lecture 9", daysAgo: 1, notes: ["Dijkstra finds shortest paths."])
        let result = BrainRetriever.context(for: "shortest paths", recaps: [pending, done], budget: 4_000)

        XCTAssertEqual(result.searchedCount, 1)
        XCTAssertEqual(result.recaps.map(\.id), [done.id])
    }

    /// Light stemming, so asking in the plural finds the singular.
    func testMatchingToleratesPluralsAndCase() {
        let rec = recording("Lecture 7", daysAgo: 1,
                            notes: ["A closure captures the environment it was defined in."])
        let result = BrainRetriever.context(for: "How do CLOSURES capture?", recaps: [rec], budget: 4_000)
        XCTAssertTrue(result.text.contains("closure captures"))
    }

    func testStopwordsAloneDoNotCountAsAQuestion() {
        XCTAssertTrue(BrainRetriever.tokens(in: "what is the and for").isEmpty)
        XCTAssertEqual(BrainRetriever.tokens(in: "what is recursion"), ["recursion"])
    }
}
