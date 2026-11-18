import Foundation

/// What a model call is for, passed down through task-locals so the shared
/// prompt code does not need to know it is talking to CatchMeUp Cloud.
enum HostedCall {
    enum Purpose: String {
        case recap, meeting, answer, other

        /// These write the notes for one recording, which the service counts as a recap.
        var countsAsRecap: Bool { self == .recap || self == .meeting }
    }

    @TaskLocal static var purpose: Purpose = .other
    /// The recording being processed. Every call for one recording shares it.
    @TaskLocal static var jobID: String?
}

/// Writes recaps through CatchMeUp Cloud. Chunking, prompts, JSON repair and
/// retries are the shared engine code; this only changes where `respond` goes.
struct HostedRecapEngine: RecapEngine {
    let session: HostedSession

    var recapBudget: RecapBudget { .cloud }
    var contextBudget: Int { RecapBudget.cloudContext }

    func respond(system: String, user: String, maxTokens: Int) async throws -> String {
        try await session.complete(
            purpose: HostedCall.purpose, jobID: HostedCall.jobID,
            system: system, user: user, maxTokens: maxTokens
        )
    }

    func makeRecap(
        transcript: String, mode: Mode, progress: @escaping (Double) -> Void
    ) async throws -> Recap {
        try await HostedCall.$purpose.withValue(.recap) {
            try await standardMakeRecap(transcript: transcript, mode: mode, progress: progress)
        }
    }

    func answer(question: String, persona: String, context: RetrievedContext) async throws -> String {
        try await HostedCall.$purpose.withValue(.answer) {
            try await standardAnswer(question: question, persona: persona, context: context)
        }
    }

    func extractMeeting(transcript: String, documents: String, agenda: String) async throws -> MeetingExtraction {
        try await HostedCall.$purpose.withValue(.meeting) {
            try await standardExtractMeeting(transcript: transcript, documents: documents, agenda: agenda)
        }
    }
}
