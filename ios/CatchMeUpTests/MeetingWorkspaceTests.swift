import XCTest
@testable import CatchMeUp

final class MeetingWorkspaceTests: XCTestCase {
    private let transcript = "[00:00:10] Priya will send the test report by Friday.\n[00:01:00] We could move the release to Monday."

    private func extraction(evidence: String = "Priya will send the test report by Friday.", stamp: String = "00:00:10") -> MeetingExtraction {
        .init(actions: [.init(task: "Send the test report", owner: "Priya", deadline: "by Friday", timestamp: stamp, evidence: evidence)],
              outcomes: [.init(kind: "proposal", text: "Move the release to Monday", timestamp: "00:01:00", evidence: "We could move the release to Monday.")], context: [])
    }

    func testLegacyRecordingStillDecodesWithoutMeetingWorkspace() throws {
        let original = Recording(title: "Old meeting", mode: .meeting, recap: Recap(actionItems: ["Send notes"]))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Recording.self, from: data)
        XCTAssertNil(decoded.meeting)
        XCTAssertEqual(decoded.recap?.actionItems, ["Send notes"])
    }

    func testStandaloneMaterialRoundTripAndLegacyBrainID() throws {
        var material = SupplementalMaterial(name: "Agenda", kind: .pdf, brainID: nil, originalFilename: "agenda.pdf")
        material.recordingIDs = [UUID()]
        let decoded = try JSONDecoder().decode(SupplementalMaterial.self, from: JSONEncoder().encode(material))
        XCTAssertNil(decoded.brainID)
        XCTAssertEqual(decoded.recordingIDs, material.recordingIDs)
        material.brainID = UUID()
        XCTAssertEqual(try JSONDecoder().decode(SupplementalMaterial.self, from: JSONEncoder().encode(material)).brainID, material.brainID)
    }

    func testMeetingDocumentsDoNotAutomaticallyCreateStudyCards() {
        let material = SupplementalMaterial(name: "Agenda", kind: .pdf, brainID: nil, usageMode: .meeting,
            originalFilename: "agenda.pdf", state: .ready,
            pages: [MaterialPage(number: 1, title: "Budget", text: String(repeating: "Review the quarterly budget and follow up with the team. ", count: 5))],
            concepts: [MaterialConcept(name: "Budget", pageNumbers: [1])])
        XCTAssertTrue(QuestionMint.items(for: material).isEmpty)
    }

    func testLegacyCompletedActionsSurviveMigration() {
        var recording = Recording(title: "Old meeting", mode: .meeting,
                                  recap: Recap(actionItems: ["Send notes", "Review budget"]))
        recording.completedActions = [0]
        let workspace = MeetingWorkspace.existing(for: recording)
        XCTAssertEqual(workspace.followUps.map(\.status), [.done, .open])
        XCTAssertTrue(workspace.followUps[0].editedByUser)
        XCTAssertTrue(workspace.followUps[1].needsReview)
    }

    func testVerifiedFollowUpDoesNotGuessCalendarDateAndProposalStaysProposal() {
        var workspace = MeetingWorkspace()
        workspace.merge(extraction(), transcript: transcript, materials: [])
        XCTAssertEqual(workspace.followUps.count, 1)
        XCTAssertEqual(workspace.followUps.first?.owner, "Priya")
        XCTAssertEqual(workspace.followUps.first?.timestamp, "00:00:10")
        XCTAssertNil(workspace.followUps.first?.dueDate)
        XCTAssertEqual(workspace.followUps.first?.needsReview, true)
        XCTAssertEqual(workspace.outcomes.first?.kind, .proposal)
    }

    func testInventedAndPunctuationOnlyEvidenceIsRejected() {
        var workspace = MeetingWorkspace()
        workspace.merge(extraction(evidence: "Alex promised to send a contract."), transcript: transcript, materials: [])
        workspace.merge(extraction(evidence: "..."), transcript: transcript, materials: [])
        XCTAssertTrue(workspace.followUps.isEmpty)
    }

    func testTimestampMustPointToTheQuotedLine() {
        var workspace = MeetingWorkspace()
        workspace.merge(extraction(stamp: "00:01:00"), transcript: transcript, materials: [])
        XCTAssertEqual(workspace.followUps.first?.timestamp, "")
    }

    func testSameTaskForDifferentOwnersIsNotCollapsed() {
        let source = "[00:00:10] Priya will send a report.\n[00:00:20] Marcus will send a report."
        let result = MeetingExtraction(actions: [
            .init(task: "Send report", owner: "Priya", deadline: "", timestamp: "00:00:10", evidence: "Priya will send a report."),
            .init(task: "Send report", owner: "Marcus", deadline: "", timestamp: "00:00:20", evidence: "Marcus will send a report.")
        ], outcomes: [], context: [])
        var workspace = MeetingWorkspace()
        workspace.merge(result, transcript: source, materials: [])
        XCTAssertEqual(workspace.followUps.count, 2)
    }

    func testRegenerationKeepsReviewedTaskAndReminderIdentity() {
        var workspace = MeetingWorkspace()
        workspace.merge(extraction(), transcript: transcript, materials: [])
        workspace.followUps[0].title = "Send the QA report"
        workspace.followUps[0].owner = "Priya (QA)"
        workspace.followUps[0].status = .done
        workspace.followUps[0].editedByUser = true
        workspace.followUps[0].reminderID = "reminder-123"
        let id = workspace.followUps[0].id
        workspace.merge(extraction(), transcript: transcript, materials: [])
        XCTAssertEqual(workspace.followUps.count, 1)
        XCTAssertEqual(workspace.followUps[0].id, id)
        XCTAssertEqual(workspace.followUps[0].reminderID, "reminder-123")
        XCTAssertEqual(workspace.followUps[0].status, .done)
    }

    func testConcurrentEditsWinOverAnalysisSnapshot() {
        var result = MeetingWorkspace()
        result.merge(extraction(), transcript: transcript, materials: [])
        var edited = result
        edited.agenda = "Updated agenda"
        edited.followUps[0].status = .inProgress
        edited.followUps[0].editedByUser = true
        result.preserveUserChanges(from: edited)
        XCTAssertEqual(result.followUps[0].status, .inProgress)
        XCTAssertEqual(result.agenda, "Updated agenda")
    }

    func testDocumentCitationsMustResolveToRealAttachedPage() {
        let material = SupplementalMaterial(name: "Agenda", kind: .pdf, brainID: nil, originalFilename: "agenda.pdf",
                                            state: .ready, pages: [MaterialPage(number: 3, text: "Budget is capped at 200.")])
        var result = extraction()
        result.context = [
            .init(materialID: material.id.uuidString, page: 3, summary: "Budget cap is 200."),
            .init(materialID: material.id.uuidString, page: 9, summary: "Invented page"),
            .init(materialID: UUID().uuidString, page: 3, summary: "Invented source")
        ]
        var workspace = MeetingWorkspace()
        workspace.merge(result, transcript: transcript, materials: [material])
        XCTAssertEqual(workspace.documentNotes.count, 1)
        XCTAssertEqual(workspace.documentNotes[0].pageNumber, 3)
    }

    func testLongDocumentPageUsesRelevantExcerptWithinBudget() {
        let material = SupplementalMaterial(name: "Plan", kind: .pdf, brainID: nil, originalFilename: "plan.pdf",
            state: .ready, pages: [MaterialPage(number: 7, text: String(repeating: "Background. ", count: 500) + " Launch budget contingency is approved.")])
        let result = MeetingAnalysis.materialContext([material], query: "launch budget contingency", budget: 1000)
        XCTAssertLessThanOrEqual(result.count, 1000)
        XCTAssertTrue(result.contains("Launch budget contingency"))
        XCTAssertTrue(result.contains("page: 7"))
    }

    func testOversizedTranscriptSegmentStaysWithinPhoneBudget() {
        let text = "[00:00:10] " + String(repeating: "Budget discussion. ", count: 1000) + "FINAL COMMITMENT"
        let windows = MeetingAnalysis.transcriptWindows(text, limit: 2800)
        XCTAssertGreaterThan(windows.count, 1)
        XCTAssertTrue(windows.allSatisfy { $0.count <= 2800 })
        XCTAssertTrue(windows.allSatisfy { $0.hasPrefix("[00:00:10]") })
        XCTAssertTrue(windows.last?.contains("FINAL COMMITMENT") == true)
    }

    func testPreparationDoesNotMixStandaloneMeetingsOrOtherBrains() {
        let first = Recording(title: "Client A", mode: .meeting, brainID: UUID())
        let other = Recording(title: "Client B", createdAt: .distantPast, mode: .meeting, brainID: UUID())
        XCTAssertTrue(MeetingPreparation.previous(for: first, in: [other]).isEmpty)
        let standalone = Recording(title: "Private", mode: .meeting)
        XCTAssertTrue(MeetingPreparation.previous(for: standalone, in: [first, other]).isEmpty)
    }

    func testNewerCompletionSuppressesOlderRepeatedCommitment() {
        let brain = UUID()
        var old = Recording(title: "Monday", createdAt: Date(timeIntervalSince1970: 100), mode: .meeting, brainID: brain)
        old.meeting = MeetingWorkspace(followUps: [MeetingFollowUp(title: "Send report")])
        var recent = Recording(title: "Tuesday", createdAt: Date(timeIntervalSince1970: 200), mode: .meeting, brainID: brain)
        recent.meeting = MeetingWorkspace(followUps: [MeetingFollowUp(title: "Send report", status: .done)])
        let next = Recording(title: "Wednesday", mode: .meeting, brainID: brain)
        XCTAssertFalse(MeetingPreparation.brief(for: next, in: [old, recent]).contains("Follow up: Send report"))
    }

    func testWorkspaceRoundTripPreservesIDsDatesAndReminderLinks() throws {
        var workspace = MeetingWorkspace()
        var task = MeetingFollowUp(title: "Report")
        task.dueDate = Date(timeIntervalSince1970: 1000)
        task.reminderID = "stable-link"
        workspace.followUps = [task]
        XCTAssertEqual(try JSONDecoder().decode(MeetingWorkspace.self, from: JSONEncoder().encode(workspace)), workspace)
    }

    func testCompletedStructuredTasksDoNotReappearInWeekPulse() {
        var recording = Recording(title: "Sync", mode: .meeting, recap: Recap(actionItems: ["Send report"]))
        recording.meeting = MeetingWorkspace(followUps: [MeetingFollowUp(title: "Send report", status: .done)])
        XCTAssertTrue(WeekPulse.lines(from: [recording]).isEmpty)
    }

    @MainActor
    func testPreparedMeetingIsNotAutomaticallyProcessed() {
        var recording = Recording(title: "Next meeting", mode: .meeting)
        recording.meeting = MeetingWorkspace(agenda: "Review budget")
        XCTAssertTrue(recording.isMeetingPreparation)
        XCTAssertFalse(ProcessingQueue.needsProcessing(recording))
    }

    func testAnalysisPassProducesGroundedMeetingWorkspace() async throws {
        var recording = Recording(title: "Sync", mode: .meeting,
                                  segments: [Segment(start: 10, text: "Priya will send the test report by Friday.")])
        recording.meeting = MeetingWorkspace(agenda: "Test readiness")
        let engine = MeetingStubEngine(response: String(data: try JSONEncoder().encode(extraction()), encoding: .utf8)!)
        let result = try await engine.meetingWorkspace(for: recording, materials: [])
        XCTAssertEqual(result.followUps.count, 1)
        XCTAssertTrue(result.outcomes.isEmpty, "A proposal not present in this transcript must be rejected")
        XCTAssertEqual(result.agenda, "Test readiness")
        XCTAssertNotNil(result.analyzedAt)
    }

    func testInvalidAnalysisDoesNotReplaceExistingUserData() async throws {
        var recording = Recording(title: "Sync", mode: .meeting, segments: [Segment(start: 10, text: "Hello")])
        recording.meeting = MeetingWorkspace(agenda: "Keep this agenda", followUps: [MeetingFollowUp(title: "My task", editedByUser: true)])
        let before = recording
        do {
            _ = try await MeetingStubEngine(response: "not JSON").meetingWorkspace(for: recording, materials: [])
            XCTFail("Invalid analysis must throw instead of returning empty data")
        } catch {
            XCTAssertEqual(recording, before)
        }
    }

    @MainActor
    func testUnreviewedReminderFailsBeforeRequestingPermission() async {
        do {
            _ = try await ReminderExporter.add(task: MeetingFollowUp(title: "Check first"),
                                               recording: Recording(title: "Sync", mode: .meeting))
            XCTFail("Review is required")
        } catch ReminderExporter.ExportError.reviewRequired {
            // No EventKit request should occur for an unreviewed task.
        } catch { XCTFail("Unexpected error: \(error)") }
    }
}

private struct MeetingStubEngine: RecapEngine {
    var response: String
    var recapBudget: RecapBudget { .onDevice }
    var contextBudget: Int { RecapBudget.onDeviceContext }
    func respond(system: String, user: String, maxTokens: Int) async throws -> String { response }
}
