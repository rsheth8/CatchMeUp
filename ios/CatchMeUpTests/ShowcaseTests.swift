import XCTest
@testable import CatchMeUp

final class ShowcaseTests: XCTestCase {
    func testCatalogHasConnectedStudentAndWorkContent() throws {
        let entries = try ShowcaseCatalog.entries()
        XCTAssertEqual(entries.count, 12)
        XCTAssertEqual(Set(entries.map(\.brain)).count, 4)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        XCTAssertEqual(entries.filter { $0.mode == .lecture }.count, 6)
        XCTAssertEqual(entries.filter { $0.mode == .meeting }.count, 6)
        for entry in entries {
            XCTAssertNotNil(entry.audioURL)
            XCTAssertEqual(entry.starts.count, entry.notes.count)
            XCTAssertEqual(entry.starts, entry.starts.sorted())
            XCTAssertEqual(entry.starts.first, 0)
            XCTAssertTrue(entry.starts.allSatisfy { $0 < entry.duration })
            XCTAssertEqual(entry.recap.bookmarks?.count, entry.segments.count)
            XCTAssertTrue(entry.notes.allSatisfy { $0.count == 2 && !$0[1].isEmpty })
        }
    }

    func testNarrationDurationAndClipOffsetsMatchRealFiles() async throws {
        for entry in try ShowcaseCatalog.entries() {
            let url = try XCTUnwrap(entry.audioURL)
            let facts = await AudioFile.facts(at: url)
            let actual = try XCTUnwrap(facts)
            XCTAssertEqual(actual.duration, entry.duration, accuracy: 0.15)
            XCTAssertGreaterThan(actual.duration, entry.starts.last ?? 0)
        }
    }

    func testDemoAnswerChangesWithQuestionAndKeepsSources() throws {
        let recordings = try ShowcaseCatalog.entries().filter { $0.brain == "cs" }.map { $0.recording() }
        let context = BrainRetriever.context(for: "closures memoization", recaps: recordings, budget: 20_000)
        let closure = DemoResponses.answer(question: "Explain closure", context: context)
        let memo = DemoResponses.answer(question: "Explain memoization", context: context)
        XCTAssertNotEqual(closure, memo)
        XCTAssertTrue(closure.contains("defin"))
        XCTAssertTrue(memo.contains("caches"))
        XCTAssertTrue(memo.contains("Source:"))
        XCTAssertTrue(memo.contains("No API key"))
        XCTAssertFalse(memo.contains("Payments"))
    }

    func testUnknownQuestionDoesNotInventAnAnswer() throws {
        let recordings = try ShowcaseCatalog.entries().filter { $0.brain == "cs" }.map { $0.recording() }
        let context = BrainRetriever.context(for: "penguin submarines", recaps: recordings, budget: 20_000)
        XCTAssertTrue(DemoResponses.answer(question: "penguin submarines", context: context).contains("couldn't match"))
    }

    func testDemoRecapMatchesNarrationAndMode() async throws {
        let engine = MockRecapEngine()
        for mode in Mode.allCases {
            let source = try XCTUnwrap(ShowcaseCatalog.entries().first { $0.mode == mode })
            let recap = try await engine.makeRecap(transcript: source.segments.timestampedText,
                                                   mode: mode, progress: { _ in })
            XCTAssertEqual(recap.title, source.title)
        }
    }

    func testMeetingReanalysisHasGroundedActionsAndOutcomes() async throws {
        let entry = try XCTUnwrap(ShowcaseCatalog.entries().first { $0.key == 7 })
        let extraction = try await MockRecapEngine().extractMeeting(
            transcript: entry.segments.timestampedText, documents: "Unrelated material", agenda: "")
        XCTAssertTrue(extraction.actions.contains { $0.owner == "Priya" })
        XCTAssertTrue(extraction.actions.contains { $0.owner == "Marcus" })
        XCTAssertTrue(extraction.outcomes.contains { $0.kind == "decision" })
        XCTAssertTrue(extraction.actions.allSatisfy { entry.segments.timestampedText.contains($0.evidence) })
        XCTAssertTrue(extraction.context.isEmpty)
    }

    @MainActor func testShowcaseCannotReadCredentialsOrEnableCloud() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "showcase-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults, isShowcase: true)
        XCTAssertEqual(settings.apiKey, "")
        XCTAssertTrue(settings.hasOnboarded)
        XCTAssertEqual(settings.engineKind, .demo)
        settings.apiKey = "not-a-real-key"
        settings.engineKind = .apiKey
        XCTAssertEqual(settings.providerConfig.apiKey, "")
        XCTAssertTrue(RecapEngineFactory.make(settings) is MockRecapEngine)
        let store = LibraryStore(root: root, isShowcase: true)
        store.setSyncEnabled(true)
        XCTAssertFalse(store.syncEnabled)
        XCTAssertNil(store.audio.cloudDirectory)
        store.upsert(Recording(title: "Only in showcase", mode: .lecture))
        XCTAssertEqual(LibraryStore(root: root, isShowcase: true).recordings.count, 1)
        let other = root.appendingPathComponent("other")
        XCTAssertTrue(LibraryStore(root: other, isShowcase: true).recordings.isEmpty)
    }

    @MainActor func testShowcaseHistoryIsIdempotentAndHasDuePractice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let study = StudyStore(root: root, isShowcase: true)
        study.mintOffline(for: try ShowcaseCatalog.entries().map { $0.recording() })
        study.seedShowcaseHistory()
        XCTAssertFalse(study.activeItems.isEmpty)
        XCTAssertEqual(study.logs.count, 56)
        XCTAssertEqual(study.streak, 7)
        study.seedShowcaseHistory()
        XCTAssertEqual(study.logs.count, 56)
        XCTAssertGreaterThan(study.newCount(), 0)
    }
}
