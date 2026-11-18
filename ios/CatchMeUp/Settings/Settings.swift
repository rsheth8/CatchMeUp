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
    /// Whether the user has agreed to send content to this destination. Off
    /// unless stated, so a config built anywhere else can't send by accident.
    var sharingAllowed = false
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
        case .demo: return "Explore a populated showcase account: narrated recaps, study practice, meetings, and local source-based answers. No API key needed."
        case .onDevice: return "Apple Intelligence writes the notes right on this iPhone. Free, private, needs iOS 26. Long recordings are covered in several passes, so they take longer."
        case .apiKey: return "Bring a key from Anthropic, OpenAI, Gemini, Groq, Ollama, or any OpenAI-compatible service."
        }
    }
}

// MARK: - AppSettings

@MainActor
@Observable
final class AppSettings {
    /// Shared for the same reason as `LibraryStore.shared`: background work
    /// needs to know which engine to use without a view being on screen.
    private static let personal = AppSettings()
    private static let showcase = AppSettings(defaults: ShowcaseSession.defaults, isShowcase: true)
    static var shared: AppSettings { ShowcaseSession.shared.isActive ? showcase : personal }
    let isShowcase: Bool

    var hasOnboarded: Bool { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }
    var engineKind: EngineKind { didSet { d.set(engineKind.rawValue, forKey: "engineKind") } }
    var providerID: String {
        didSet {
            d.set(providerID, forKey: "providerID")
            reloadKey()
        }
    }
    var model: String { didSet { d.set(model, forKey: "model") } }
    var customBaseURL: String {
        didSet {
            d.set(customBaseURL, forKey: "customBaseURL")
            reloadKey()
        }
    }
    var defaultMode: Mode { didSet { d.set(defaultMode.rawValue, forKey: "defaultMode") } }

    // MARK: Audio storage

    var recordingQuality: AudioQuality {
        didSet { d.set(recordingQuality.rawValue, forKey: "recordingQuality") }
    }
    /// Re-encode oversized imports down to `recordingQuality` in the background.
    var optimizeImports: Bool { didSet { d.set(optimizeImports, forKey: "optimizeImports") } }
    var audioRetention: AudioRetention {
        didSet { d.set(audioRetention.rawValue, forKey: "audioRetention") }
    }
    /// Whether retention is allowed to delete audio this device holds the only
    /// copy of. Off unless the user has been told it can't be undone.
    var allowLocalAudioDeletion: Bool {
        didSet { d.set(allowLocalAudioDeletion, forKey: "allowLocalAudioDeletion") }
    }
    /// With iCloud on, drop local copies of older unpinned recordings.
    var optimizeCloudStorage: Bool {
        didSet { d.set(optimizeCloudStorage, forKey: "optimizeCloudStorage") }
    }

    // MARK: Study

    /// The recall probability the schedule aims for. Higher means more reviews
    /// for the same material — the honest trade, surfaced rather than hidden.
    var desiredRetention: Double { didSet { d.set(desiredRetention, forKey: "desiredRetention") } }
    /// Cap on unfamiliar items introduced per day, so a big import doesn't
    /// bury the user in new material tomorrow.
    var dailyNewLimit: Int { didSet { d.set(dailyNewLimit, forKey: "dailyNewLimit") } }
    var dailyReviewLimit: Int { didSet { d.set(dailyReviewLimit, forKey: "dailyReviewLimit") } }
    /// Spend a model call to re-mark answers keyword matching found ambiguous.
    var modelGrading: Bool { didSet { d.set(modelGrading, forKey: "modelGrading") } }
    /// Focus-session lengths, in minutes.
    var focusMinutes: Int { didSet { d.set(focusMinutes, forKey: "focusMinutes") } }
    var breakMinutes: Int { didSet { d.set(breakMinutes, forKey: "breakMinutes") } }
    /// A daily nudge on the days the schedule actually asks for one. On by
    /// default because a review you're never reminded of is a review you don't
    /// do, and the reminder stays silent when nothing is due.
    var reviewReminder: Bool { didSet { d.set(reviewReminder, forKey: "reviewReminder") } }
    var reviewReminderHour: Int { didSet { d.set(reviewReminderHour, forKey: "reviewReminderHour") } }
    /// Ask two or three questions before a recap is read for the first time.
    /// On by default: it costs about forty seconds and it's one of the largest
    /// free wins in the literature — but it's also the most surprising thing
    /// the app does, so it's a switch.
    var prequestions: Bool { didSet { d.set(prequestions, forKey: "prequestions") } }

    /// The key for the selected provider. Each destination has its own Keychain
    /// entry, so switching providers can never send one company's key to another.
    var apiKey: String {
        get { loadedKey }
        set {
            guard isShowcase || keySlot != nil else { return }
            loadedKey = newValue
            if !isShowcase, let keySlot { Keychain.set(newValue, for: keySlot) }
        }
    }
    private var loadedKey: String

    /// Destinations the user has explicitly agreed to send content to.
    private var sharingConsents: Set<String> {
        didSet { d.set(sharingConsents.sorted(), forKey: Self.sharingConsentsKey) }
    }

    private let d: UserDefaults
    private static let sharingConsentsKey = "aiSharingConsents.v1"
    private static let legacyKeyAccount = "apiKey"

    init(defaults: UserDefaults = .standard, isShowcase: Bool = false) {
        if !isShowcase { Keychain.reconcileInstall() }
        self.isShowcase = isShowcase
        d = defaults
        let dd = defaults
        hasOnboarded = isShowcase || dd.bool(forKey: "hasOnboarded")
        engineKind = isShowcase ? .demo : (EngineKind(rawValue: dd.string(forKey: "engineKind") ?? "") ?? .demo)
        providerID = dd.string(forKey: "providerID") ?? "anthropic"
        model = dd.string(forKey: "model") ?? Providers.by(dd.string(forKey: "providerID") ?? "anthropic").defaultModel
        customBaseURL = dd.string(forKey: "customBaseURL") ?? ""
        defaultMode = Mode(rawValue: dd.string(forKey: "defaultMode") ?? "") ?? .meeting
        recordingQuality = AudioQuality(rawValue: dd.string(forKey: "recordingQuality") ?? "")
            ?? .fallback
        // Absent rather than false on a fresh install — tidying up imports is
        // the behaviour people expect by default.
        optimizeImports = dd.object(forKey: "optimizeImports") as? Bool ?? true
        audioRetention = AudioRetention(rawValue: dd.string(forKey: "audioRetention") ?? "")
            ?? .fallback
        allowLocalAudioDeletion = dd.bool(forKey: "allowLocalAudioDeletion")
        optimizeCloudStorage = dd.bool(forKey: "optimizeCloudStorage")
        // Study defaults are the FSRS/Anki conventions: 90% target retention,
        // a manageable trickle of new material, no daily review ceiling that
        // would silently leave work undone.
        desiredRetention = dd.object(forKey: "desiredRetention") as? Double ?? 0.90
        dailyNewLimit = dd.object(forKey: "dailyNewLimit") as? Int ?? 12
        dailyReviewLimit = dd.object(forKey: "dailyReviewLimit") as? Int ?? 120
        modelGrading = dd.object(forKey: "modelGrading") as? Bool ?? true
        focusMinutes = dd.object(forKey: "focusMinutes") as? Int ?? 25
        breakMinutes = dd.object(forKey: "breakMinutes") as? Int ?? 5
        reviewReminder = dd.object(forKey: "reviewReminder") as? Bool ?? true
        reviewReminderHour = dd.object(forKey: "reviewReminderHour") as? Int ?? 18
        prequestions = dd.object(forKey: "prequestions") as? Bool ?? true
        sharingConsents = Set(dd.stringArray(forKey: Self.sharingConsentsKey) ?? [])

        let storedProvider = Providers.by(dd.string(forKey: "providerID") ?? "anthropic")
        let slot = Self.keySlot(provider: storedProvider, customBaseURL: dd.string(forKey: "customBaseURL") ?? "")
        if isShowcase {
            loadedKey = ""
        } else {
            Self.migrateLegacyKey(to: slot)
            loadedKey = slot.flatMap(Keychain.get) ?? ""
        }
    }

    /// Earlier builds kept one key for every provider. It most likely belongs
    /// to the provider selected now, and nowhere else is safe to assume.
    private static func migrateLegacyKey(to slot: String?) {
        guard let legacy = Keychain.get(legacyKeyAccount) else { return }
        if let slot, Keychain.get(slot) == nil { Keychain.set(legacy, for: slot) }
        Keychain.set("", for: legacyKeyAccount)
    }

    private func reloadKey() {
        guard !isShowcase else { return }
        loadedKey = keySlot.flatMap(Keychain.get) ?? ""
    }

    // MARK: Where content goes

    /// Fixed providers always use their own address. Only the providers that
    /// ask for a base URL ever read the user's.
    private static func baseURL(provider: Provider, customBaseURL: String) -> String? {
        guard provider.needsBaseURL else { return provider.baseURL }
        return customBaseURL.isEmpty ? provider.baseURL : customBaseURL
    }

    /// Identifies who receives content. A custom provider is identified by its
    /// server, because a different server is a different recipient.
    private static func destination(provider: Provider, customBaseURL: String) -> String? {
        guard provider.needsBaseURL else { return provider.id }
        guard let raw = baseURL(provider: provider, customBaseURL: customBaseURL),
              let parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty
        else { return nil }
        let port = parts.port.map { ":\($0)" } ?? ""
        return "\(provider.id)|\(scheme)://\(host)\(port)"
    }

    /// Ollama runs without a key, so it has nowhere to store or send one.
    private static func keySlot(provider: Provider, customBaseURL: String) -> String? {
        guard provider.id != "ollama",
              let destination = destination(provider: provider, customBaseURL: customBaseURL)
        else { return nil }
        return "apiKey.\(destination)"
    }

    private var keySlot: String? { Self.keySlot(provider: provider, customBaseURL: customBaseURL) }

    /// Nil until a provider that needs a base URL has a valid one.
    var sharingDestination: String? {
        Self.destination(provider: provider, customBaseURL: customBaseURL)
    }

    /// The name shown when asking for permission.
    var sharingRecipient: String {
        guard provider.needsBaseURL else { return provider.label }
        let raw = Self.baseURL(provider: provider, customBaseURL: customBaseURL) ?? ""
        return URLComponents(string: raw)?.host ?? provider.label
    }

    var hasSharingConsent: Bool {
        guard !isShowcase, let sharingDestination else { return false }
        return sharingConsents.contains(sharingDestination)
    }

    func grantSharingConsent() {
        guard !isShowcase, let sharingDestination else { return }
        sharingConsents.insert(sharingDestination)
    }

    func revokeSharingConsent() {
        guard let sharingDestination else { return }
        sharingConsents.remove(sharingDestination)
    }

    /// Scheduler configuration assembled from the user's settings.
    var fsrsParameters: FSRS.Parameters {
        var params = FSRS.Parameters.default
        params.desiredRetention = desiredRetention
        return params
    }

    /// Model grading needs both the preference and a provider that can answer.
    var usesModelGrading: Bool {
        guard modelGrading, engineKind == .apiKey else { return false }
        return isReady
    }

    var provider: Provider { Providers.by(providerID) }

    func selectProvider(_ id: String) {
        let p = Providers.by(id)
        // Earlier builds copied the preset's address into this field. Don't
        // let a custom provider inherit it as though the user had typed it.
        if p.needsBaseURL, Providers.all.contains(where: { !$0.needsBaseURL && $0.baseURL == customBaseURL }) {
            customBaseURL = ""
        }
        providerID = id
        model = p.defaultModel
    }

    var providerConfig: ProviderConfig {
        if isShowcase { return ProviderConfig(kind: .anthropic, baseURL: nil, model: "demo", apiKey: "") }
        let p = provider
        return ProviderConfig(kind: p.kind,
                              baseURL: Self.baseURL(provider: p, customBaseURL: customBaseURL),
                              model: model,
                              apiKey: apiKey,
                              sharingAllowed: hasSharingConsent)
    }

    private var needsProviderKey: Bool { providerID != "ollama" && apiKey.isEmpty }

    var isReady: Bool {
        switch engineKind {
        case .demo: return true
        case .onDevice: return true
        case .apiKey:
            if provider.needsBaseURL && customBaseURL.isEmpty { return false }
            if sharingDestination == nil || needsProviderKey { return false }
            return hasSharingConsent
        }
    }

    var readinessHint: String {
        switch engineKind {
        case .demo: return "Ready — narrated samples and local source matching, with no AI request."
        case .onDevice:
            return FoundationBridge.availabilityText
        case .apiKey:
            if provider.needsBaseURL && customBaseURL.isEmpty { return "Add the base URL for \(provider.label)." }
            if sharingDestination == nil { return "Enter a valid base URL for \(provider.label)." }
            if needsProviderKey { return "Paste your \(provider.label) API key." }
            if !hasSharingConsent { return "Allow sharing with \(sharingRecipient) in Settings." }
            return "Ready — \(provider.label), \(model)."
        }
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.catchmeup.app"
    private static let installMarker = "keychainInstallRecorded"
    private static let probeAccount = "install.probe"
    /// Settings any earlier build would have written. Finding one means this
    /// is an update, so the items in the Keychain are still wanted.
    private static let priorInstallKeys = ["hasOnboarded", "engineKind", "providerID"]

    /// iOS can keep Keychain items after an app is deleted, while UserDefaults
    /// goes with it. A first launch with no settings is therefore a new install,
    /// and anything left in the Keychain belongs to a deleted copy of the app.
    ///
    /// Settings can also read as empty while the device is locked, so nothing
    /// is erased or recorded until the Keychain confirms it is unlocked.
    static func reconcileInstall(defaults: UserDefaults = .standard, deviceUnlocked: Bool? = nil) {
        guard !defaults.bool(forKey: installMarker),
              deviceUnlocked ?? isDeviceUnlocked
        else { return }
        let isUpdate = priorInstallKeys.contains { defaults.object(forKey: $0) != nil }
        if !isUpdate { removeAll() }
        defaults.set(true, forKey: installMarker)
    }

    static func removeAll() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }

    private static var isDeviceUnlocked: Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: probeAccount]
        var add = query
        add[kSecValueData as String] = Data()
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    static func set(_ value: String, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
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
