import XCTest
@testable import CatchMeUp

/// The delete alerts promise the content is gone. A deleted record has to stay
/// behind so other devices learn about the delete, but it must not keep the
/// words. These tests read the real files, because that is what syncs.
@MainActor
final class DeletionErasureTests: XCTestCase {

    private let canary = "ZEBRACANARY"

    private var root: URL!
    private var library: LibraryStore!
    private var study: StudyStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = LibraryStore(root: root, isShowcase: true)
        study = StudyStore(root: root, isShowcase: true)
        library.studySink = study
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func makeRecap(audioFilename: String? = nil) -> Recording {
        Recording(title: "\(canary) title", mode: .lecture, audioFilename: audioFilename,
                  segments: [Segment(start: 0, text: "\(canary) transcript")],
                  recap: Recap(title: "\(canary) recap", tldr: ["\(canary) summary"]))
    }

    @discardableResult
    private func addRecap(audioFilename: String? = nil) -> Recording {
        let recording = makeRecap(audioFilename: audioFilename)
        library.upsert(recording)
        return recording
    }

    private func makeQuestion(for recording: Recording) -> StudyItem {
        StudyItem(recordingID: recording.id, brainID: nil, sourceTitle: "\(canary) source",
                  kind: .term, prompt: "\(canary) prompt", answer: "\(canary) answer",
                  keys: ["\(canary) key"], choices: ["\(canary) choice"])
    }

    /// Every file the stores wrote, as text.
    private func textOnDisk() throws -> String {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        return try files.filter { !$0.hasDirectoryPath }
            .map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
            .joined(separator: "\n")
    }

    private func assertContentIsGone(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try textOnDisk().contains(canary), "deleted content is still on disk",
                       file: file, line: line)
    }

    private func write<T: Encodable>(_ value: T, to name: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(value).write(to: root.appendingPathComponent(name))
    }

    private func audioFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: library.audio.localDirectory.path)
            .filter { !$0.hasPrefix(".") }
    }

    // MARK: - Content

    func testDeletingARecapLeavesNoneOfItsContentOnDisk() throws {
        let recording = addRecap()
        let question = makeQuestion(for: recording)
        study.add([question])
        study.record(question.id, grade: .good, confidence: nil, correct: true, seconds: 1,
                     typed: "\(canary) typed answer", sessionID: nil, params: FSRS.Parameters())
        XCTAssertTrue(try textOnDisk().contains(canary), "the test needs content to start with")

        library.delete(recording)

        try assertContentIsGone()
        let reopened = LibraryStore(root: root, isShowcase: true)
        XCTAssertNil(reopened.recording(recording.id))
        XCTAssertEqual(reopened.recordings.filter(\.deleted).map(\.id), [recording.id],
                       "kept so other devices learn about the delete")
        XCTAssertEqual(StudyStore(root: root, isShowcase: true).logs.count, 1,
                       "streaks and stats still count the review")
    }

    func testDeletingACourseAndItsExamErasesTheirNames() throws {
        let brain = Brain(name: "\(canary) course", persona: "\(canary) persona")
        library.upsert(brain)
        study.upsert(ExamPlan(brainID: brain.id, title: "\(canary) exam", date: .now))

        library.delete(brain)

        try assertContentIsGone()
    }

    func testDeletingAMaterialErasesItsText() throws {
        let material = SupplementalMaterial(
            name: "\(canary) deck", kind: .slides, originalFilename: "\(canary).pptx",
            pages: [MaterialPage(number: 1, text: "\(canary) slide")], summary: "\(canary) summary"
        )
        try write([material], to: "materials.json")
        let store = MaterialStore(root: root, isShowcase: true)

        store.delete(material)

        try assertContentIsGone()
    }

    func testRecordsDeletedByEarlierVersionsAreErasedAtLaunch() throws {
        var recording = makeRecap()
        recording.deleted = true
        var question = makeQuestion(for: recording)
        question.deleted = true
        var log = ReviewLog(itemID: question.id, brainID: nil, grade: .good, confidence: nil,
                            correct: true, secondsSpent: 1, typed: "\(canary) typed",
                            sessionID: nil, wasNew: true)
        log.secondsSpent = 2
        try write([recording], to: "recordings.json")
        try write([question], to: "study-items.json")
        try write([log], to: "study-log.json")

        _ = LibraryStore(root: root, isShowcase: true)
        _ = StudyStore(root: root, isShowcase: true)

        try assertContentIsGone()
    }

    // MARK: - Staying deleted

    func testALaterEditOnAnotherDeviceCannotBringADeletedRecapBack() async throws {
        let recording = addRecap()
        let otherDevice = LibraryStore(root: root, isShowcase: true)
        library.delete(recording)

        // Saved dates keep whole seconds, so this edit is clearly the newer one.
        try await Task.sleep(for: .seconds(1.1))
        otherDevice.rename(recording.id, to: "\(canary) renamed elsewhere")
        library.mergeFromDisk()

        XCTAssertNil(library.recording(recording.id))
        try assertContentIsGone()
    }

    func testADeleteFromAnotherDeviceErasesTheCopyHere() throws {
        let recording = addRecap()
        study.add([makeQuestion(for: recording)])
        let otherDevice = LibraryStore(root: root, isShowcase: true)

        otherDevice.delete(recording)
        library.mergeFromDisk()

        XCTAssertNil(library.recording(recording.id))
        XCTAssertTrue(study.liveItems.isEmpty)
        try assertContentIsGone()
    }

    func testAProcessingJobThatFinishesLateCannotBringADeletedRecapBack() throws {
        let recording = addRecap()
        library.delete(recording)

        library.upsert(recording)

        XCTAssertNil(library.recording(recording.id))
        try assertContentIsGone()
    }

    func testAQuestionAnsweredElsewhereSurvivesARewriteRetiringIt() {
        var retired = makeQuestion(for: makeRecap())
        var answered = retired
        retired.deleted = true
        retired.updatedAt = Date(timeIntervalSince1970: 100)
        answered.updatedAt = Date(timeIntervalSince1970: 200)

        let merge = Tombstones.merge(local: [retired], remote: [answered], deletionWins: false)

        XCTAssertEqual(merge.records, [answered])
        XCTAssertFalse(merge.remoteHoldsDeletedContent)
    }

    func testAMergedDeleteCarriesTheLaterDateForOlderAppVersions() {
        var deleted = makeRecap()
        var edited = deleted
        deleted.deleted = true
        deleted.updatedAt = Date(timeIntervalSince1970: 100)
        edited.updatedAt = Date(timeIntervalSince1970: 200)

        let merge = Tombstones.merge(local: [deleted], remote: [edited], deletionWins: true)

        XCTAssertEqual(merge.records.map(\.deleted), [true])
        XCTAssertEqual(merge.records.first?.updatedAt, edited.updatedAt)
        XCTAssertEqual(merge.records.first?.title, "")
        XCTAssertTrue(merge.remoteHoldsDeletedContent, "the file still has the words")
    }

    func testTheCopyLeftInAnotherFolderIsErasedToo() throws {
        let recording = addRecap()
        let survivor = addRecap()
        let otherFolder = root.appendingPathComponent("EarlierCopy", isDirectory: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("recordings.json"),
                                         to: otherFolder.appendingPathComponent("recordings.json"))

        library.delete(recording)
        library.eraseDeleted(fromCopyIn: otherFolder)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let copy = try decoder.decode(
            [Recording].self,
            from: Data(contentsOf: otherFolder.appendingPathComponent("recordings.json"))
        )
        XCTAssertEqual(copy.first { $0.id == recording.id }?.title, "")
        XCTAssertEqual(copy.first { $0.id == survivor.id }?.title, survivor.title,
                       "records that weren't deleted are left alone")
    }

    // MARK: - Audio

    func testDeleteRemovesTheAudioFileThatExistsNowNotTheOneTheAlertSaw() throws {
        let directory = library.audio.localDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: directory.appendingPathComponent("talk.mp3"))
        let seenByAlert = addRecap(audioFilename: "talk.mp3")

        // The optimizer finishes while the alert is on screen.
        let converted = root.appendingPathComponent("converted.\(AudioQuality.fileExtension)")
        try Data("converted".utf8).write(to: converted)
        var current = try XCTUnwrap(library.recording(seenByAlert.id))
        current.audioFilename = try library.audio.replaceAudio(for: current, with: converted)
        library.upsert(current)
        XCTAssertEqual(try audioFiles(), ["talk.\(AudioQuality.fileExtension)"])

        library.delete(seenByAlert)

        XCTAssertEqual(try audioFiles(), [])
    }
}
