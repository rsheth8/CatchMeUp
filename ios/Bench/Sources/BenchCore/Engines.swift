import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - What gets compared

/// One contestant. `label` is the stable name used in file names and the report.
struct EngineSpec: Hashable, Codable {
    enum Backend: Hashable, Codable {
        case apple
        case anthropic(model: String)
    }

    var label: String
    var backend: Backend

    var modelName: String {
        switch backend {
        case .apple: return "apple-foundation-model (on-device)"
        case .anthropic(let model): return model
        }
    }

    var isCloud: Bool {
        if case .anthropic = backend { return true }
        return false
    }
}

/// The three roles in the comparison. Models are overridable on the command
/// line so the same harness can be pointed at a newer Haiku or a cheaper
/// "strong" model without code changes.
enum Contestants {
    /// The app's current default (`Providers.all[0].defaultModel`).
    static let defaultHaiku = "claude-haiku-4-5-20251001"
    /// A stronger model to show what the ceiling looks like.
    static let defaultStrong = "claude-sonnet-5-5"
    /// Judge is deliberately stronger than every contestant.
    static let defaultJudge = "claude-opus-5-5"

    static func specs(labels: [String], haiku: String, strong: String) throws -> [EngineSpec] {
        try labels.map { label in
            switch label {
            case "apple": return EngineSpec(label: "apple", backend: .apple)
            case "haiku": return EngineSpec(label: "haiku", backend: .anthropic(model: haiku))
            case "strong": return EngineSpec(label: "strong", backend: .anthropic(model: strong))
            default: throw BenchError.usage("Unknown engine '\(label)'. Use apple, haiku, strong.")
            }
        }
    }
}

// MARK: - Cloud engine with metering

/// The app's `CloudRecapEngine` goes through `LLMClient`, which returns only the
/// text. A benchmark also needs token counts for cost, so this engine speaks to
/// the same endpoint and plugs into the same shared pipeline (chunking, prompt
/// assembly, lenient JSON parse, retry, merge) by conforming to `RecapEngine`
/// and implementing only `respond`.
struct MeteredAnthropicEngine: RecapEngine {
    let model: String
    let apiKey: String
    let effort: String?
    let meter: UsageMeter

    var recapBudget: RecapBudget { .cloud }
    var contextBudget: Int { RecapBudget.cloudContext }

    func respond(system: String, user: String, maxTokens: Int) async throws -> String {
        let reply = try await AnthropicHTTP.message(
            model: model, system: system, user: user, maxTokens: maxTokens,
            effort: effort, apiKey: apiKey
        )
        meter.add(model: model, input: reply.inputTokens, output: reply.outputTokens)
        return reply.text
    }
}

// MARK: - Factory

struct EngineHandle {
    let engine: RecapEngine
    let meter: UsageMeter
}

enum EngineFactory {
    static func appleAvailability() -> (available: Bool, detail: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return (true, "available")
            case .unavailable(let reason):
                return (false, "unavailable: \(reason)")
            }
        }
        #endif
        return (false, "FoundationModels needs macOS 26 or later")
    }

    static func make(_ spec: EngineSpec, apiKey: String, effort: String?) throws -> EngineHandle {
        let meter = UsageMeter()
        switch spec.backend {
        case .apple:
            let status = appleAvailability()
            guard status.available else { throw BenchError.appleUnavailable(status.detail) }
            if #available(macOS 26.0, *) {
                return EngineHandle(engine: AppleOnDeviceEngine(), meter: meter)
            }
            throw BenchError.appleUnavailable("FoundationModels needs macOS 26 or later")
        case .anthropic(let model):
            guard !apiKey.isEmpty else { throw BenchError.missingKey }
            return EngineHandle(
                engine: MeteredAnthropicEngine(model: model, apiKey: apiKey, effort: effort, meter: meter),
                meter: meter
            )
        }
    }
}
