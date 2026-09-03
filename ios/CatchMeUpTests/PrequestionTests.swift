import XCTest
@testable import CatchMeUp

/// The rules that make a pretest a pretest rather than a quiz in the way: it
/// has to be answerable cold, it has to span the material, and it must not be
/// able to touch the schedule.
final class PrequestionTests: XCTestCase {

    private let recordingID = UUID()

    private func item(_ kind: StudyItemKind, _ prompt: String, concept: String = "") -> StudyItem {
        StudyItem(recordingID: recordingID, brainID: nil, sourceTitle: "Week 3",
                  kind: kind, prompt: prompt, answer: "An answer about \(prompt).",
                  keys: ["answer"], concept: concept)
    }

    // MARK: What gets asked

    func testAsksAtMostThree() {
        let bank = (1...9).map { item(.term, "What is term \($0)?") }
        XCTAssertEqual(Prequestions.pick(from: bank).count, 3)
    }

    /// Fill-in-the-blank with no prior exposure isn't hard, it's impossible;
    /// multiple choice hands over the answer set and turns generation into
    /// recognition. Neither belongs in a warm-up.
    func testSkipsClozeAndMultipleChoice() {
        let bank = [
            item(.cloze, "A mutex is a ____ only one thread can hold."),
            item(.choice, "Which of these is a mutex?"),
        ]
        XCTAssertTrue(Prequestions.pick(from: bank).isEmpty)
    }

    func testSpansKindsRatherThanThreeOfTheSame() {
        let bank = [
            item(.term, "What is a mutex?", concept: "mutex"),
            item(.term, "What is a semaphore?", concept: "semaphore"),
            item(.term, "What is a spinlock?", concept: "spinlock"),
            item(.concept, "Explain deadlock.", concept: "deadlock"),
            item(.moment, "What's the rule about acquiring locks?", concept: "lock order"),
        ]
        let kinds = Set(Prequestions.pick(from: bank).map(\.kind))
        XCTAssertTrue(kinds.contains(.concept), "a three-definition warm-up wastes the recap's other material")
        XCTAssertTrue(kinds.contains(.moment))
    }

    func testNeverAsksTheSameConceptTwice() {
        let bank = [
            item(.term, "What is a mutex?", concept: "mutex"),
            item(.concept, "Explain what a mutex does.", concept: "mutex"),
            item(.moment, "Why acquire before touching shared state?", concept: "lock order"),
        ]
        let picked = Prequestions.pick(from: bank)
        XCTAssertEqual(picked.count, 2)
        XCTAssertEqual(Set(picked.map(\.concept)).count, 2)
    }

    /// The real case this was written for: one recap yielded a detailed note
    /// headed "Graph" and a bookmark headed "What are graphs?", which are two
    /// different concept keys for one topic. Asking both wastes a third of a
    /// three-question warm-up.
    func testTheSameTopicWordedTwoWaysIsAskedOnce() {
        let bank = [
            item(.term, "What is a node? One or two sentences, in your own words.", concept: "node"),
            item(.concept, "What is a Graph?", concept: "Graph"),
            item(.moment, "What are graphs?", concept: "What are graphs?"),
        ]
        let picked = Prequestions.pick(from: bank)
        XCTAssertEqual(picked.count, 2, "'Graph' and 'What are graphs?' are one question")
        XCTAssertTrue(picked.contains { $0.kind == .term })
    }

    /// The dedupe must not go so far that related-but-distinct questions
    /// collapse — sharing a word is not being the same question.
    func testNeighbouringTopicsAreStillBothAsked() {
        let bank = [
            item(.term, "What is lock ordering?", concept: "lock ordering"),
            item(.concept, "Explain lock contention.", concept: "lock contention"),
        ]
        XCTAssertEqual(Prequestions.pick(from: bank).count, 2)
    }

    func testSuspendedAndDeletedItemsStayOut() {
        var suspended = item(.term, "What is a mutex?", concept: "mutex")
        suspended.suspended = true
        var gone = item(.term, "What is a semaphore?", concept: "semaphore")
        gone.deleted = true
        XCTAssertTrue(Prequestions.pick(from: [suspended, gone]).isEmpty)
    }

    /// Stable ordering: backgrounding the app mid-warm-up and coming back has to
    /// return the same questions, not reshuffle them.
    func testPickIsDeterministic() {
        let bank = [
            item(.term, "What is a mutex?", concept: "mutex"),
            item(.concept, "Explain deadlock.", concept: "deadlock"),
            item(.moment, "The rule about lock order.", concept: "lock order"),
            item(.application, "Two threads increment without a lock — what happens?", concept: "race"),
        ]
        XCTAssertEqual(Prequestions.pick(from: bank).map(\.id),
                       Prequestions.pick(from: bank).map(\.id))
    }

    // MARK: When it's worth interrupting

    func testOneQuestionIsNotWorthASheet() {
        XCTAssertFalse(Prequestions.worthAsking([item(.term, "What is a mutex?", concept: "mutex")]))
    }

    func testTwoQuestionsIsEnough() {
        let bank = [
            item(.term, "What is a mutex?", concept: "mutex"),
            item(.concept, "Explain deadlock.", concept: "deadlock"),
        ]
        XCTAssertTrue(Prequestions.worthAsking(bank))
    }

    func testAnUnprocessedRecapHasNothingToAsk() {
        XCTAssertFalse(Prequestions.worthAsking([]))
    }

    // MARK: The schedule stays untouched

    /// The property the whole feature depends on. A pretest answer says nothing
    /// about how long a memory lasts — there is no memory yet — so if this ever
    /// starts writing FSRS state, prequestions would begin intervals on
    /// material the reader hasn't been taught.
    func testWarmUpLeavesEveryItemNew() {
        let bank = [
            item(.term, "What is a mutex?", concept: "mutex"),
            item(.concept, "Explain deadlock.", concept: "deadlock"),
        ]
        let picked = Prequestions.pick(from: bank)
        for chosen in picked {
            _ = Grading.offline(chosen, typed: "no idea at all")
            XCTAssertTrue(chosen.isNew, "grading a warm-up answer must not schedule it")
            XCTAssertEqual(chosen.memory.reps, 0)
        }
    }

    // MARK: Wording

    func testClosingNeverBlamesTheReader() {
        let none = Prequestions.closing(correct: 0, asked: 3)
        XCTAssertFalse(none.lowercased().contains("wrong"))
        XCTAssertFalse(none.contains("0"), "a bare zero reads as a score, and this isn't scored")
    }

    func testClosingCountsWhatLanded() {
        XCTAssertTrue(Prequestions.closing(correct: 1, asked: 3).contains("1 of 3"))
    }

    // MARK: The offer is spent once

    func testPretestIsRecordedOnceAndOnlyOnce() {
        var rec = Recording(title: "Week 3", mode: .lecture)
        XCTAssertFalse(rec.pretestSpent, "a fresh recap hasn't been offered a warm-up yet")

        rec.pretestedAt = Date()
        rec.pretestAsked = 3
        rec.pretestCorrect = 1
        XCTAssertTrue(rec.pretestSpent)

        // Round-trips, so the offer stays spent across a sync.
        let data = try! JSONEncoder().encode(rec)
        let back = try! JSONDecoder().decode(Recording.self, from: data)
        XCTAssertTrue(back.pretestSpent)
        XCTAssertEqual(back.pretestAsked, 3)
        XCTAssertEqual(back.pretestCorrect, 1)
    }

    /// Recaps written before this feature existed decode as un-offered rather
    /// than failing.
    func testOlderRecapsDecodeWithoutPretestFields() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Week 1","createdAt":0,"mode":"lecture"}
        """
        let rec = try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
        XCTAssertFalse(rec.pretestSpent)
        XCTAssertEqual(rec.pretestAsked, 0)
    }
}
