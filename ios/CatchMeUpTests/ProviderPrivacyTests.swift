import XCTest
@testable import CatchMeUp

/// Records outgoing provider requests without touching the network.
private final class ProviderRequestRecorder: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let body = #"{"choices":[{"message":{"content":"ok"}}]}"#.data(using: .utf8)!
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class ProviderPrivacyTests: XCTestCase {
    private var domain = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        domain = "provider-privacy-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        Keychain.removeAll()
        ProviderRequestRecorder.requests = []
        URLProtocol.registerClass(ProviderRequestRecorder.self)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(ProviderRequestRecorder.self)
        defaults.removePersistentDomain(forName: domain)
        Keychain.removeAll()
    }

    private func makeSettings(provider: String = "openai") -> AppSettings {
        let settings = AppSettings(defaults: defaults)
        settings.engineKind = .apiKey
        settings.selectProvider(provider)
        return settings
    }

    // MARK: Keys

    func testKeyStaysWithTheProviderItWasEnteredFor() {
        let settings = makeSettings()
        settings.apiKey = "openai-test-value"

        settings.selectProvider("deepseek")
        XCTAssertEqual(settings.apiKey, "")
        XCTAssertEqual(settings.providerConfig.apiKey, "")

        settings.apiKey = "deepseek-test-value"
        settings.selectProvider("openai")
        XCTAssertEqual(settings.apiKey, "openai-test-value")
        XCTAssertEqual(AppSettings(defaults: defaults).apiKey, "openai-test-value")
    }

    func testCustomProviderKeyIsTiedToItsServer() {
        let settings = makeSettings(provider: "custom")
        settings.customBaseURL = "https://one.example/v1"
        settings.apiKey = "server-one-test-value"

        settings.customBaseURL = "https://two.example/v1"
        XCTAssertEqual(settings.apiKey, "")

        settings.customBaseURL = "https://one.example/v2"
        XCTAssertEqual(settings.apiKey, "server-one-test-value")
    }

    func testCustomProviderDoesNotInheritAPresetAddress() {
        let settings = makeSettings()
        settings.customBaseURL = "https://api.openai.com/v1"
        settings.selectProvider("custom")
        XCTAssertEqual(settings.customBaseURL, "")
        XCTAssertNil(settings.sharingDestination)
    }

    func testFixedProviderIgnoresAStaleCustomAddress() {
        let settings = makeSettings(provider: "custom")
        settings.customBaseURL = "https://other.example/v1"
        settings.selectProvider("groq")
        XCTAssertEqual(settings.providerConfig.baseURL, "https://api.groq.com/openai/v1")
    }

    func testOllamaNeverReceivesAKey() {
        let settings = makeSettings()
        settings.apiKey = "openai-test-value"
        settings.selectProvider("ollama")
        settings.customBaseURL = "http://localhost:11434/v1"
        settings.apiKey = "ignored"
        XCTAssertEqual(settings.providerConfig.apiKey, "")
    }

    func testLegacySharedKeyMovesToTheSelectedProviderOnly() {
        defaults.set("mistral", forKey: "providerID")
        Keychain.set("legacy-test-value", for: "apiKey")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.apiKey, "legacy-test-value")
        XCTAssertNil(Keychain.get("apiKey"))

        settings.selectProvider("openai")
        XCTAssertEqual(settings.apiKey, "")
    }

    // MARK: Reinstall

    func testFreshInstallErasesItemsLeftByADeletedCopy() {
        Keychain.set("left-behind", for: "apiKey.openai")
        Keychain.set("Someone", for: "auth.name")

        Keychain.reconcileInstall(defaults: defaults, deviceUnlocked: true)

        XCTAssertNil(Keychain.get("apiKey.openai"))
        XCTAssertNil(Keychain.get("auth.name"))
    }

    func testUpdateAndLaterLaunchesKeepKeychainItems() {
        defaults.set(true, forKey: "hasOnboarded")
        Keychain.set("still-wanted", for: "apiKey.openai")
        Keychain.reconcileInstall(defaults: defaults, deviceUnlocked: true)
        XCTAssertEqual(Keychain.get("apiKey.openai"), "still-wanted")

        defaults.removeObject(forKey: "hasOnboarded")
        Keychain.reconcileInstall(defaults: defaults, deviceUnlocked: true)
        XCTAssertEqual(Keychain.get("apiKey.openai"), "still-wanted")
    }

    func testLockedDeviceNeverLooksLikeAFreshInstall() {
        Keychain.set("still-wanted", for: "apiKey.openai")
        Keychain.reconcileInstall(defaults: defaults, deviceUnlocked: false)
        XCTAssertEqual(Keychain.get("apiKey.openai"), "still-wanted")
        XCTAssertFalse(defaults.bool(forKey: "keychainInstallRecorded"))
    }

    // MARK: Consent

    func testProviderIsNotReadyUntilSharingIsAllowed() {
        let settings = makeSettings()
        settings.apiKey = "openai-test-value"
        XCTAssertFalse(settings.isReady)
        XCTAssertFalse(settings.providerConfig.sharingAllowed)

        settings.grantSharingConsent()
        XCTAssertTrue(settings.isReady)
        XCTAssertTrue(AppSettings(defaults: defaults).hasSharingConsent)

        settings.revokeSharingConsent()
        XCTAssertFalse(settings.isReady)
    }

    func testConsentDoesNotCarryToAnotherDestination() {
        let settings = makeSettings()
        settings.grantSharingConsent()
        settings.selectProvider("deepseek")
        XCTAssertFalse(settings.hasSharingConsent)

        settings.selectProvider("custom")
        settings.customBaseURL = "https://one.example/v1"
        settings.grantSharingConsent()
        settings.customBaseURL = "https://two.example/v1"
        XCTAssertFalse(settings.hasSharingConsent)
    }

    func testNothingIsSentWithoutConsent() async {
        let settings = makeSettings()
        settings.apiKey = "openai-test-value"

        do {
            _ = try await LLMClient(config: settings.providerConfig).complete(system: "s", user: "private text")
            XCTFail("The request should have been refused")
        } catch EngineError.sharingNotAllowed {
            XCTAssertTrue(ProviderRequestRecorder.requests.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAllowedRequestCarriesOnlyThatProvidersKeyToThatProvider() async throws {
        let settings = makeSettings()
        settings.apiKey = "openai-test-value"
        settings.selectProvider("deepseek")
        settings.apiKey = "deepseek-test-value"
        settings.grantSharingConsent()

        let reply = try await LLMClient(config: settings.providerConfig).complete(system: "s", user: "text")

        XCTAssertEqual(reply, "ok")
        let request = try XCTUnwrap(ProviderRequestRecorder.requests.first)
        XCTAssertEqual(request.url?.host, "api.deepseek.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer deepseek-test-value")
    }

    // MARK: Google sign-in

    func testGoogleSignInNeedsARealClientIDAndItsScheme() {
        let clientID = "123-abc.apps.googleusercontent.com"
        let scheme = "com.googleusercontent.apps.123-abc"
        func urlTypes(_ value: String) -> [[String: Any]] { [["CFBundleURLSchemes": [value]]] }

        XCTAssertTrue(GoogleSignInConfiguration.isUsable(info: ["GIDClientID": clientID, "CFBundleURLTypes": urlTypes(scheme)]))
        XCTAssertFalse(GoogleSignInConfiguration.isUsable(info: ["GIDClientID": clientID, "CFBundleURLTypes": urlTypes("catchmeup")]))
        XCTAssertFalse(GoogleSignInConfiguration.isUsable(info: [
            "GIDClientID": "REPLACE_WITH_GOOGLE_OAUTH_CLIENT_ID.apps.googleusercontent.com",
            "CFBundleURLTypes": urlTypes("com.googleusercontent.apps.replace_with_google_oauth_client_id"),
        ]))
        XCTAssertFalse(GoogleSignInConfiguration.isUsable(info: [:]))
    }

    func testThisBuildHidesUnconfiguredGoogleSignIn() {
        XCTAssertFalse(GoogleSignInConfiguration.isAvailable)
    }
}
