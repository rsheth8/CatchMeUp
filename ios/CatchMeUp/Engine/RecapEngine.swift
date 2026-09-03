import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

protocol RecapEngine {
    func makeRecap(transcript: String, mode: Mode) async throws -> Recap
    func answer(question: String, persona: String, context: String) async throws -> String
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

    func makeRecap(transcript: String, mode: Mode) async throws -> Recap {
        let raw = try await client.complete(
            system: mode.roleInstruction,
            user: Prompts.userPrompt(transcript: transcript, mode: mode)
        )
        return try Recap.parse(raw)
    }

    func answer(question: String, persona: String, context: String) async throws -> String {
        try await client.complete(
            system: persona.isEmpty ? "You answer questions about recap notes." : persona,
            user: Prompts.askPrompt(question: question, persona: persona, context: context),
            maxTokens: 1500
        )
    }
}

// MARK: - Demo

struct MockRecapEngine: RecapEngine {
    func makeRecap(transcript: String, mode: Mode) async throws -> Recap {
        try? await Task.sleep(nanoseconds: 900_000_000)
        return mode == .lecture ? SampleData.lectureRecap : SampleData.meetingRecap
    }

    func answer(question: String, persona: String, context: String) async throws -> String {
        try? await Task.sleep(nanoseconds: 500_000_000)
        return "Demo mode doesn't call a model. Switch to On-device or your API key in Settings to ask real questions about this brain."
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
    func makeRecap(transcript: String, mode: Mode) async throws -> Recap {
        guard SystemLanguageModel.default.isAvailable else {
            throw EngineError.onDeviceUnavailable(FoundationBridge.availabilityText)
        }
        // The small on-device model does better with a trimmed transcript.
        let trimmed = String(transcript.prefix(9000))
        let session = LanguageModelSession(instructions: mode.roleInstruction + "\nReturn only JSON.")
        let response = try await session.respond(to: Prompts.userPrompt(transcript: trimmed, mode: mode))
        return try Recap.parse(response.content)
    }

    func answer(question: String, persona: String, context: String) async throws -> String {
        guard SystemLanguageModel.default.isAvailable else {
            throw EngineError.onDeviceUnavailable(FoundationBridge.availabilityText)
        }
        let session = LanguageModelSession(
            instructions: persona.isEmpty ? "You answer questions about recap notes." : persona
        )
        let response = try await session.respond(
            to: Prompts.askPrompt(question: question, persona: persona, context: String(context.prefix(9000)))
        )
        return response.content
    }
}
#else
struct AppleOnDeviceEngine: RecapEngine {
    func makeRecap(transcript: String, mode: Mode) async throws -> Recap { throw EngineError.onDeviceUnavailable(FoundationBridge.availabilityText) }
    func answer(question: String, persona: String, context: String) async throws -> String { throw EngineError.onDeviceUnavailable(FoundationBridge.availabilityText) }
}
#endif
