import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Each engine only has to answer one question: given a system prompt and a
/// user prompt, what does the model say? Chunking, JSON repair, retries and
/// prompt assembly are shared, so the on-device path and a hosted model behave
/// the same way apart from how much they can read at once.
protocol RecapEngine {
    /// How much transcript fits in one recap request.
    var recapBudget: RecapBudget { get }
    /// How much retrieved context fits in one ask.
    var contextBudget: Int { get }

    func respond(system: String, user: String, maxTokens: Int) async throws -> String

    /// One window of transcript in, one partial recap out.
    ///
    /// Overridable because the on-device model doesn't go via JSON text at all
    /// — it generates a `Recap` under a schema the framework enforces.
    func recapPass(mode: Mode, transcript: String, part: Int, of total: Int) async throws -> Recap

    func makeRecap(
        transcript: String, mode: Mode, progress: @escaping (Double) -> Void
    ) async throws -> Recap

    func answer(question: String, persona: String, context: RetrievedContext) async throws -> String
    func extractMeeting(transcript: String, documents: String, agenda: String) async throws -> MeetingExtraction
}

extension RecapEngine {

    /// Walks the transcript in windows the model can actually hold and merges
    /// the results, reporting progress per window.
    ///
    /// The old behaviour was `transcript.prefix(9000)`: an hour of lecture came
    /// back as notes on the first ten minutes, with nothing to say it had
    /// happened.
    func makeRecap(
        transcript: String, mode: Mode, progress: @escaping (Double) -> Void
    ) async throws -> Recap {
        let chunks = TranscriptChunker.chunks(
            transcript, maxCharacters: recapBudget.charactersPerRequest
        )
        guard !chunks.isEmpty else { throw EngineError.emptyTranscript }

        var parts: [Recap] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            parts.append(try await recapPass(
                mode: mode, transcript: chunk, part: index + 1, of: chunks.count
            ))
            progress(Double(index + 1) / Double(chunks.count))
        }
        return RecapMerge.combine(parts)
    }

    func answer(question: String, persona: String, context: RetrievedContext) async throws -> String {
        try await respond(
            system: persona.isEmpty ? "You answer questions about recap notes." : persona,
            user: Prompts.askPrompt(
                question: question,
                persona: persona,
                context: String(context.text.prefix(contextBudget)),
                sources: context.sourceTitles
            ),
            maxTokens: 1500
        )
    }

    func recapPass(mode: Mode, transcript: String, part: Int, of total: Int) async throws -> Recap {
        try await jsonRecapPass(mode: mode, transcript: transcript, part: part, of: total)
    }

    /// Asks for JSON in a string and parses it leniently, with a single
    /// stricter retry. Models drift out of JSON often enough that failing a
    /// whole recording on one stray sentence would be the wrong trade — a retry
    /// costs seconds against re-recording a lecture.
    ///
    /// Kept separately callable so the on-device engine can fall back to it
    /// when a device won't honour its generation guides.
    func jsonRecapPass(mode: Mode, transcript: String, part: Int, of total: Int) async throws -> Recap {
        let prompt = Prompts.recapPrompt(transcript: transcript, mode: mode, part: part, of: total)
        let system = mode.roleInstruction + "\nReturn only JSON."
        do {
            return try Recap.parse(await respond(system: system, user: prompt, maxTokens: 8000))
        } catch EngineError.badResponse {
            try Task.checkCancellation()
            let stricter = prompt + """


            Your previous reply could not be read as JSON. Reply with the JSON object \
            and nothing else — no explanation, no code fences, no trailing commas.
            """
            return try Recap.parse(await respond(system: system, user: stricter, maxTokens: 8000))
        }
    }
}

enum RecapEngineFactory {
    @MainActor
    static func make(_ settings: AppSettings) -> RecapEngine {
        switch settings.engineKind {
        case .demo:
            return MockRecapEngine()
        case .onDevice:
            if #available(iOS 26.0, *) { return AppleOnDeviceEngine() }
            return MockRecapEngine()
        case .apiKey:
            return CloudRecapEngine(client: LLMClient(config: settings.providerConfig))
        }
    }
}

// MARK: - Cloud

struct CloudRecapEngine: RecapEngine {
    let client: LLMClient

    var recapBudget: RecapBudget { .cloud }
    var contextBudget: Int { RecapBudget.cloudContext }

    func respond(system: String, user: String, maxTokens: Int) async throws -> String {
        try await client.complete(system: system, user: user, maxTokens: maxTokens)
    }
}

// MARK: - Demo

struct MockRecapEngine: RecapEngine {
    var recapBudget: RecapBudget { .cloud }
    var contextBudget: Int { RecapBudget.cloudContext }

    func respond(system: String, user: String, maxTokens: Int) async throws -> String {
        throw EngineError.onDeviceUnavailable("Demo mode doesn't call a model.")
    }

    /// Walks the same progress curve a real run does, so the processing UI can
    /// be developed and demoed without a key.
    func makeRecap(
        transcript: String, mode: Mode, progress: @escaping (Double) -> Void
    ) async throws -> Recap {
        for step in 1...4 {
            try await Task.sleep(nanoseconds: 250_000_000)
            progress(Double(step) / 4)
        }
        return mode == .lecture ? SampleData.lectureRecap : SampleData.meetingRecap
    }

    /// Written as Markdown so Demo mode shows the real answer layout.
    func answer(question: String, persona: String, context: RetrievedContext) async throws -> String {
        try await Task.sleep(nanoseconds: 1_400_000_000)
        return """
        Demo mode doesn't call a model, so here's what a real answer looks like.

        ## Where answers come from
        - **Your recaps only** — the model sees passages retrieved from this brain, nothing else.
        - **Ranked, not the first twelve** — the notes and transcript lines closest to your \
        question are the ones that get sent.
        - **Cited** — every answer names the recaps it leaned on, and you can tap through to them.

        ## Turning it on
        Open **Settings ▸ Recap engine** and pick either:

        1. *On-device* — Apple's model, needs iOS 26 and Apple Intelligence.
        2. *Your API key* — Anthropic or any OpenAI-compatible endpoint.

        > Audio and transcripts never leave the device on the on-device path.
        """
    }
}

// MARK: - Apple on-device (iOS 26 Foundation Models)

enum FoundationBridge {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    static var availabilityText: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
                ? "Ready — Apple's on-device model."
                : "On-device model isn't available on this device right now (needs Apple Intelligence enabled)."
        }
        #endif
        return "Needs iOS 26. Use Demo or an API key on this device."
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
struct AppleOnDeviceEngine: RecapEngine {
    var recapBudget: RecapBudget { .onDevice }
    var contextBudget: Int { RecapBudget.onDeviceContext }

    /// A fresh session per request on purpose. `LanguageModelSession` keeps its
    /// own transcript, so reusing one across chunks would grow the prompt with
    /// every window until it overran the context it was chunked to fit.
    func respond(system: String, user: String, maxTokens: Int) async throws -> String {
        let session = try makeSession(instructions: system)
        do {
            return try await session.respond(to: user).content
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.translate(error)
        }
    }

    /// Classifies once, then walks the windows. A mixed recording runs both
    /// guided types per window and merges — one bloated `@Generable` type would
    /// spend the small context window on fields that window doesn't use.
    func makeRecap(
        transcript: String, mode: Mode, progress: @escaping (Double) -> Void
    ) async throws -> Recap {
        let chunks = TranscriptChunker.chunks(
            transcript, maxCharacters: recapBudget.charactersPerRequest
        )
        guard !chunks.isEmpty else { throw EngineError.emptyTranscript }

        let verdict = RecapSignals.classify(transcript, prior: mode)
        let passes: [Mode] = verdict.mixed ? [verdict.dominant, verdict.dominant == .lecture ? .meeting : .lecture] : [verdict.dominant]
        let totalWork = Double(chunks.count * passes.count)
        var done = 0.0
        var parts: [Recap] = []

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            var window: [Recap] = []
            for pass in passes {
                window.append(try await recapPass(
                    mode: pass, transcript: chunk, part: index + 1, of: chunks.count
                ))
                done += 1
                progress(done / totalWork)
            }
            parts.append(RecapMerge.combine(window))
        }
        return RecapMerge.combine(parts)
    }

    /// Guided generation instead of "return only JSON".
    ///
    /// The shape is enforced by the framework while the model decodes, so
    /// there's no code fence to strip, no preamble to skip past and no missing
    /// brace to repair — the failure mode the lenient parser and the retry in
    /// `jsonRecapPass` exist to absorb.
    func recapPass(mode: Mode, transcript: String, part: Int, of total: Int) async throws -> Recap {
        let prompt = Prompts.recapPrompt(
            transcript: transcript, mode: mode, part: part, of: total, includeSchema: false
        )
        let session = try makeSession(instructions: mode.roleInstruction)

        do {
            switch mode {
            case .meeting:
                return try await session
                    .respond(to: prompt, generating: GeneratedMeetingRecap.self)
                    .content.recap
            case .lecture:
                return try await session
                    .respond(to: prompt, generating: GeneratedLectureRecap.self)
                    .content.recap
            }
        } catch let error as LanguageModelSession.GenerationError {
            // A device that won't honour the guides can still be asked for JSON
            // the old way, so this stays a slower path rather than a dead end.
            if case .unsupportedGuide = error {
                return try await jsonRecapPass(mode: mode, transcript: transcript, part: part, of: total)
            }
            throw Self.translate(error)
        }
    }

    func extractMeeting(transcript: String, documents: String, agenda: String) async throws -> MeetingExtraction {
        let session = try makeSession(instructions: MeetingAnalysis.instructions)
        do {
            return try await session.respond(
                to: "AGENDA (planned only):\n\(agenda)\nTRANSCRIPT:\n\(transcript)\nPROVIDED DOCUMENTS:\n\(documents)",
                generating: GeneratedMeetingAnalysis.self
            ).content.extraction
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.translate(error)
        }
    }

    private func makeSession(instructions: String) throws -> LanguageModelSession {
        guard SystemLanguageModel.default.isAvailable else {
            throw EngineError.onDeviceUnavailable(FoundationBridge.availabilityText)
        }
        return LanguageModelSession(instructions: instructions)
    }

    /// The framework's own messages are written for developers. These say what
    /// the user can do about it, and they surface on the recap card and in the
    /// notification, so vagueness costs a support conversation.
    private static func translate(_ error: LanguageModelSession.GenerationError) -> EngineError {
        switch error {
        case .assetsUnavailable:
            return .onDeviceUnavailable(
                "Apple Intelligence is still setting up on this iPhone. Try again once it has finished, or switch to Demo or an API key."
            )
        case .guardrailViolation, .refusal:
            return .onDeviceUnavailable(
                "Apple's on-device model declined to write notes for this recording. Your own API key will handle it."
            )
        case .unsupportedLanguageOrLocale:
            return .onDeviceUnavailable(
                "Apple's on-device model doesn't support this language yet. Use an API key for this recording."
            )
        case .exceededContextWindowSize:
            return .onDeviceUnavailable(
                "This recording is too dense for the on-device model, even split into parts. Use an API key for it."
            )
        case .rateLimited, .concurrentRequests:
            return .onDeviceUnavailable(
                "The on-device model is busy. Open the recap again in a moment to pick up where this left off."
            )
        case .decodingFailure, .unsupportedGuide:
            return .badResponse
        @unknown default:
            return .onDeviceUnavailable(error.localizedDescription)
        }
    }
}
#else
struct AppleOnDeviceEngine: RecapEngine {
    var recapBudget: RecapBudget { .onDevice }
    var contextBudget: Int { RecapBudget.onDeviceContext }

    func respond(system: String, user: String, maxTokens: Int) async throws -> String {
        throw EngineError.onDeviceUnavailable(FoundationBridge.availabilityText)
    }
}
#endif
