import XCTest
@testable import CatchMeUp

/// An exam used to outlive its brain. It stayed on the Study tab, and with no
/// brains left the Exams screen had no way to remove it.
@MainActor
final class BrainDeletionExamTests: XCTestCase {

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

    private func addBrain(_ name: String, to store: LibraryStore? = nil) -> Brain {
        let brain = Brain(name: name)
        (store ?? library).upsert(brain)
        return brain
    }

    private func addExam(_ title: String, on brainID: UUID) {
        study.upsert(ExamPlan(brainID: brainID, title: title,
                              date: Date().addingTimeInterval(86_400 * 14)))
    }

    private var examTitles: [String] { study.plans.map(\.title).sorted() }

    func testDeletingABrainDeletesOnlyItsOwnExams() {
        let history = addBrain("History")
        let biology = addBrain("Biology")
        addExam("History midterm", on: history.id)
        addExam("History final", on: history.id)
        addExam("Biology final", on: biology.id)

        library.delete(history)

        XCTAssertEqual(examTitles, ["Biology final"])
        XCTAssertNil(study.nextExam.flatMap { $0.brainID == history.id ? $0 : nil })
    }

    func testTheDeletedExamStaysGoneAfterARestart() {
        let history = addBrain("History")
        addExam("History final", on: history.id)

        library.delete(history)

        let reopened = StudyStore(root: root, isShowcase: true)
        XCTAssertTrue(reopened.plans.isEmpty)
        XCTAssertEqual(reopened.examPlans.filter(\.deleted).count, 1,
                       "kept as a tombstone so other devices drop it too")
    }

    func testAnExamOrphanedByAnEarlierVersionIsCleared() {
        let history = addBrain("History")
        addExam("History final", on: history.id)
        library.studySink = nil
        library.delete(history)
        XCTAssertEqual(examTitles, ["History final"], "the state older versions left behind")

        library.studySink = study
        library.retireExamPlansForDeletedBrains()

        XCTAssertTrue(study.plans.isEmpty)
    }

    func testAnExamThatArrivesBeforeItsBrainIsKept() {
        addExam("Synced ahead of its brain", on: UUID())

        library.retireExamPlansForDeletedBrains()

        XCTAssertEqual(examTitles, ["Synced ahead of its brain"])
    }

    func testABrainDeletedOnAnotherDeviceTakesItsExamWithIt() async throws {
        let history = addBrain("History")
        addExam("History final", on: history.id)
        let otherDevice = LibraryStore(root: root, isShowcase: true)

        // Saved dates keep whole seconds, and a merge keeps the newer copy, so
        // the remote delete has to land in a later second than the local edit.
        try await Task.sleep(for: .seconds(1.1))
        otherDevice.delete(history)
        library.mergeFromDisk()

        XCTAssertTrue(library.visibleBrains.isEmpty)
        XCTAssertTrue(study.plans.isEmpty)
    }
}
