import XCTest
@testable import CatchMeUp

/// Renaming a diarized speaker. The rename is a library mutation rather than a
/// view detail because everything downstream — the recap prompt's timestamped
/// text, shares, exports, the synced copy on another device — reads the same
/// segments, and they all have to agree.
@MainActor
final class SpeakerRenameTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seeded(_ store: LibraryStore) -> UUID {
        var recording = Recording(title: "Standup", mode: .meeting)
        recording.segments = [
            Segment(start: 0, text: "Where are we on billing?", speaker: "Speaker 1"),
            Segment(start: 4, text: "Two tickets left.", speaker: "Speaker 2"),
            Segment(start: 9, text: "Good. Ship Thursday.", speaker: "Speaker 1"),
        ]
        store.upsert(recording)
        return recording.id
    }

    func testRenameMovesEveryLineForThatSpeakerAndOnlyThose() throws {
        let store = LibraryStore(root: root)
        let id = seeded(store)

        store.renameSpeaker(in: id, from: "Speaker 1", to: "Dana")

        let saved = try XCTUnwrap(store.recordings.first { $0.id == id })
        XCTAssertEqual(saved.segments.map(\.speaker), ["Dana", "Speaker 2", "Dana"])
    }

    /// The rename has to survive a relaunch, not just live in memory.
    func testRenameIsPersisted() throws {
        let store = LibraryStore(root: root)
        let id = seeded(store)
        store.renameSpeaker(in: id, from: "Speaker 2", to: "Ade")

        let reopened = LibraryStore(root: root)
        let saved = try XCTUnwrap(reopened.recordings.first { $0.id == id })
        XCTAssertEqual(saved.segments.map(\.speaker), ["Speaker 1", "Ade", "Speaker 1"])
    }

    /// What the model reads when it writes the notes.
    func testRenamedSpeakerReachesTheTimestampedText() throws {
        let store = LibraryStore(root: root)
        let id = seeded(store)
        store.renameSpeaker(in: id, from: "Speaker 1", to: "Dana")

        let saved = try XCTUnwrap(store.recordings.first { $0.id == id })
        let text = saved.segments.timestampedText
        XCTAssertTrue(text.contains("Dana: Where are we on billing?"), text)
        XCTAssertFalse(text.contains("Speaker 1"), text)
    }

    /// A rename is an edit like any other, so it has to bump `updatedAt` or the
    /// union-by-newest sync merge will quietly discard it.
    func testRenameBumpsUpdatedAtSoSyncKeepsIt() throws {
        let store = LibraryStore(root: root)
        let id = seeded(store)
        let before = try XCTUnwrap(store.recordings.first { $0.id == id }).updatedAt

        store.renameSpeaker(in: id, from: "Speaker 1", to: "Dana")

        let after = try XCTUnwrap(store.recordings.first { $0.id == id }).updatedAt
        XCTAssertGreaterThan(after, before)
    }

    /// Two speakers merged into one is a legitimate correction: diarization
    /// splits one voice in two more often than it merges two into one.
    func testRenamingOntoAnExistingNameMergesThem() throws {
        let store = LibraryStore(root: root)
        let id = seeded(store)
        store.renameSpeaker(in: id, from: "Speaker 2", to: "Speaker 1")

        let saved = try XCTUnwrap(store.recordings.first { $0.id == id })
        XCTAssertEqual(Set(saved.segments.compactMap(\.speaker)), ["Speaker 1"])
    }

    func testRenamingAnAbsentSpeakerChangesNothing() throws {
        let store = LibraryStore(root: root)
        let id = seeded(store)
        let before = try XCTUnwrap(store.recordings.first { $0.id == id })

        store.renameSpeaker(in: id, from: "Speaker 9", to: "Nobody")

        let after = try XCTUnwrap(store.recordings.first { $0.id == id })
        XCTAssertEqual(after.segments.map(\.speaker), before.segments.map(\.speaker))
        XCTAssertEqual(after.updatedAt, before.updatedAt)
    }

    func testRenamingToTheSameNameIsANoOp() throws {
        let store = LibraryStore(root: root)
        let id = seeded(store)
        let before = try XCTUnwrap(store.recordings.first { $0.id == id }).updatedAt

        store.renameSpeaker(in: id, from: "Speaker 1", to: "Speaker 1")

        XCTAssertEqual(try XCTUnwrap(store.recordings.first { $0.id == id }).updatedAt, before)
    }

    /// A deleted recap is not editable, and a tombstone must not be revived by
    /// an edit arriving after it.
    func testDeletedRecordingIsNotRenamed() throws {
        let store = LibraryStore(root: root)
        let id = seeded(store)
        let recording = try XCTUnwrap(store.recordings.first { $0.id == id })
        store.delete(recording)

        store.renameSpeaker(in: id, from: "Speaker 1", to: "Dana")

        let saved = try XCTUnwrap(store.recordings.first { $0.id == id })
        XCTAssertEqual(saved.segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1"])
    }
}
