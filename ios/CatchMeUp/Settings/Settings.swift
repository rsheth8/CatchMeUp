import Foundation
import Observation
import Security

// MARK: - Providers (ported from providers.py)

struct Provider: Identifiable, Hashable {
    enum Kind: String { case openai, anthropic }
    var id: String
    var label: String
    var kind: Kind
    var baseURL: String?
    var defaultModel: String
    var needsBaseURL: Bool = false
    var signup: String?
}

enum Providers {
    static let all: [Provider] = [
        .init(id: "anthropic", label: "Anthropic (Claude)", kind: .anthropic, baseURL: nil,
              defaultModel: "claude-haiku-4-5-20251001", signup: "https://console.anthropic.com/settings/keys"),
        .init(id: "openai", label: "OpenAI (GPT)", kind: .openai, baseURL: "https://api.openai.com/v1",
              defaultModel: "gpt-4.1-mini", signup: "https://platform.openai.com/api-keys"),
        .init(id: "gemini", label: "Google (Gemini)", kind: .openai,
              baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
              defaultModel: "gemini-2.5-flash", signup: "https://aistudio.google.com/apikey"),
        .init(id: "groq", label: "Groq", kind: .openai, baseURL: "https://api.groq.com/openai/v1",
              defaultModel: "llama-3.3-70b-versatile", signup: "https://console.groq.com/keys"),
        .init(id: "openrouter", label: "OpenRouter", kind: .openai, baseURL: "https://openrouter.ai/api/v1",
              defaultModel: "anthropic/claude-3.5-sonnet", signup: "https://openrouter.ai/keys"),
        .init(id: "deepseek", label: "DeepSeek", kind: .openai, baseURL: "https://api.deepseek.com",
              defaultModel: "deepseek-chat", signup: "https://platform.deepseek.com/api_keys"),
        .init(id: "mistral", label: "Mistral", kind: .openai, baseURL: "https://api.mistral.ai/v1",
              defaultModel: "mistral-large-latest", signup: "https://console.mistral.ai/api-keys"),
        .init(id: "together", label: "Together AI", kind: .openai, baseURL: "https://api.together.xyz/v1",
              defaultModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo", signup: "https://api.together.ai/settings/api-keys"),
        .init(id: "xai", label: "xAI (Grok)", kind: .openai, baseURL: "https://api.x.ai/v1",
              defaultModel: "grok-2-latest", signup: "https://console.x.ai"),
        .init(id: "ollama", label: "Ollama (on this network)", kind: .openai,
              baseURL: "http://localhost:11434/v1", defaultModel: "llama3.1", needsBaseURL: true),
        .init(id: "custom", label: "Custom (OpenAI-compatible)", kind: .openai, baseURL: nil,
              defaultModel: "", needsBaseURL: true),
    ]

    static func by(_ id: String) -> Provider { all.first { $0.id == id } ?? all[0] }
}

struct ProviderConfig {
    var kind: Provider.Kind
    var baseURL: String?
    var model: String
    var apiKey: String
}

// MARK: - Engine choice

enum EngineKind: String, CaseIterable, Identifiable {
    case demo
    case onDevice
    case apiKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .demo: return "Demo"
        case .onDevice: return "On-device (Apple)"
        case .apiKey: return "Your API key"
        }
    }

    var blurb: String {
        switch self {
        case .demo: return "Uses a built-in sample recap. No account, nothing sent anywhere — good for a first look."
        case .onDevice: return "Apple's on-device model writes the notes. Free, private, needs iOS 26. Shorter recaps."
        case .apiKey: return "Bring a key from Anthropic, OpenAI, Gemini, Groq, Ollama, or any OpenAI-compatible service."
        }
    }
}

// MARK: - AppSettings

@MainActor
@Observable
final class AppSettings {
    var hasOnboarded: Bool { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }
    var engineKind: EngineKind { didSet { d.set(engineKind.rawValue, forKey: "engineKind") } }
    var providerID: String { didSet { d.set(providerID, forKey: "providerID") } }
    var model: String { didSet { d.set(model, forKey: "model") } }
    var customBaseURL: String { didSet { d.set(customBaseURL, forKey: "customBaseURL") } }
    var defaultMode: Mode { didSet { d.set(defaultMode.rawValue, forKey: "defaultMode") } }

    /// Kept in the Keychain, not UserDefaults.
    var apiKey: String {
        didSet { Keychain.set(apiKey, for: "apiKey") }
    }

    private let d = UserDefaults.standard

    init() {
        let dd = UserDefaults.standard
        hasOnboarded = dd.bool(forKey: "hasOnboarded")
        engineKind = EngineKind(rawValue: dd.string(forKey: "engineKind") ?? "") ?? .demo
        providerID = dd.string(forKey: "providerID") ?? "anthropic"
        model = dd.string(forKey: "model") ?? Providers.by(dd.string(forKey: "providerID") ?? "anthropic").defaultModel
        customBaseURL = dd.string(forKey: "customBaseURL") ?? ""
        defaultMode = Mode(rawValue: dd.string(forKey: "defaultMode") ?? "") ?? .meeting
        apiKey = Keychain.get("apiKey") ?? ""
    }

    var provider: Provider { Providers.by(providerID) }

    func selectProvider(_ id: String) {
        providerID = id
        let p = Providers.by(id)
        model = p.defaultModel
        if let b = p.baseURL, !p.needsBaseURL { customBaseURL = b }
    }

    var providerConfig: ProviderConfig {
        let p = provider
        let base = customBaseURL.isEmpty ? p.baseURL : customBaseURL
        return ProviderConfig(kind: p.kind, baseURL: base, model: model, apiKey: apiKey)
    }

    var isReady: Bool {
        switch engineKind {
        case .demo: return true
        case .onDevice: return true
        case .apiKey:
            if provider.needsBaseURL && customBaseURL.isEmpty { return false }
            if providerID == "ollama" { return true }
            return !apiKey.isEmpty
        }
    }

    var readinessHint: String {
        switch engineKind {
        case .demo: return "Ready — recaps use built-in sample text."
        case .onDevice:
            return FoundationBridge.availabilityText
        case .apiKey:
            if provider.needsBaseURL && customBaseURL.isEmpty { return "Add the base URL for \(provider.label)." }
            if !isReady { return "Paste your \(provider.label) API key." }
            return "Ready — \(provider.label), \(model)."
        }
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.catchmeup.app"

    static func set(_ value: String, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = q
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
