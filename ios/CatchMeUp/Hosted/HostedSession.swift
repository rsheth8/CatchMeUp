import Foundation
import Observation

/// Where the session's tokens live. The app uses the Keychain; tests use memory.
protocol HostedTokenStore {
    func get(_ key: String) -> String?
    func set(_ value: String, for key: String)
}

struct KeychainTokenStore: HostedTokenStore {
    func get(_ key: String) -> String? { Keychain.get(key) }
    // After first unlock, not only while unlocked: recaps can finish in the
    // background with the phone locked, and they still need to refresh a token.
    func set(_ value: String, for key: String) { Keychain.set(value, for: key, afterFirstUnlock: true) }
}

/// Shown when the monthly allowance is used up. `RootView` presents it.
struct HostedLimit: Identifiable, Equatable {
    let id = UUID()
    let plan: String
    let resetsAt: Date?
}

/// The signed-in side of CatchMeUp Cloud: tokens, refreshing, the monthly quota
/// and every call to the service. Views read `quota` and `isSignedIn`; the
/// engine calls `complete`.
@MainActor
@Observable
final class HostedSession {
    static let shared = HostedSession()

    private(set) var isSignedIn: Bool
    private(set) var quota: HostedQuota?
    /// Set when a call is refused for being over the monthly allowance.
    var limit: HostedLimit?
    private(set) var signInError: String?

    private let store: HostedTokenStore
    private let apiProvider: () -> HostedAPI?
    private let now: () -> Date

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var refreshTask: Task<String, Error>?

    private enum Key {
        static let refresh = "hosted.refresh"
    }

    init(
        store: HostedTokenStore = KeychainTokenStore(),
        apiProvider: @escaping () -> HostedAPI? = { HostedConfig.baseURL.map { HostedAPI(baseURL: $0) } },
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.apiProvider = apiProvider
        self.now = now
        isSignedIn = !(store.get(Key.refresh) ?? "").isEmpty
    }

    // MARK: Sign in

    /// A fresh single-use nonce to put in the Apple or Google request. The
    /// service accepts only nonces it issued, once each.
    func fetchNonce() async throws -> String {
        let json = try await api().send("POST", "/v1/auth/nonce", body: [:])
        guard let nonce = json["nonce"] as? String else { throw HostedError.badResponse }
        return nonce
    }

    func signIn(_ provider: HostedProvider, idToken: String, nonce: String) async throws {
        do {
            let json = try await api().send(
                "POST", "/v1/auth/\(provider.rawValue)",
                body: ["idToken": idToken, "nonce": nonce]
            )
            guard let access = json["accessToken"] as? String,
                  let refresh = json["refreshToken"] as? String
            else { throw HostedError.badResponse }
            store.set(refresh, for: Key.refresh)
            accessToken = access
            accessExpiry = now().addingTimeInterval(Self.lifetime(of: json))
            isSignedIn = true
            signInError = nil
            await refreshQuota()
        } catch {
            signInError = (error as? LocalizedError)?.errorDescription ?? "Couldn't sign in to CatchMeUp Cloud."
            throw error
        }
    }

    func clearSignInError() { signInError = nil }

    /// Signs out of the service only. The local profile is `AuthManager`'s.
    func signOut() async {
        if let refresh = store.get(Key.refresh), !refresh.isEmpty, let api = apiProvider() {
            _ = try? await api.send("POST", "/v1/auth/logout", body: ["refreshToken": refresh])
        }
        clearTokens()
    }

    /// Deletes the account on the server (an App Store requirement). Returns
    /// true if a subscription is still running, since only Apple can cancel it.
    func deleteAccount() async throws -> Bool {
        let json = try await authorized { token in
            try await self.api().send("DELETE", "/v1/me", token: token)
        }
        clearTokens()
        return json["subscriptionStillActive"] as? Bool ?? false
    }

    // MARK: Quota

    func refreshQuota() async {
        guard isSignedIn else { return }
        if let json = try? await authorized({ token in try await self.api().send("GET", "/v1/me", token: token) }),
           let fresh = HostedQuota(json: json["quota"]) {
            quota = fresh
        }
    }

    // MARK: Recaps

    /// One model call. `jobID` (the recording's id) is required for recap and
    /// meeting calls: the service counts a recap per recording, not per call.
    func complete(
        purpose: HostedCall.Purpose, jobID: String?,
        system: String, user: String, maxTokens: Int
    ) async throws -> String {
        var body: [String: Any] = ["task": purpose.rawValue, "system": system, "user": user, "maxTokens": maxTokens]
        if purpose.countsAsRecap {
            guard let jobID, !jobID.isEmpty else { throw HostedError.missingJob }
            body["jobId"] = jobID
        }
        do {
            let json = try await authorized { token in
                // Five minutes: a long recording's window can legitimately take that.
                try await self.api().send("POST", "/v1/recap", token: token, body: body, timeout: 300)
            }
            guard let text = json["text"] as? String, !text.isEmpty else { throw HostedError.badResponse }
            if let fresh = HostedQuota(json: json["quota"]) { quota = fresh }
            return text
        } catch let error as HostedError {
            if case .quotaExceeded(let plan, let resetsAt) = error, limit == nil {
                limit = HostedLimit(plan: plan, resetsAt: resetsAt)
                quota = HostedQuota(plan: plan, recapsRemaining: 0, resetsAt: resetsAt)
            }
            throw error
        }
    }

    // MARK: Tokens

    private func api() throws -> HostedAPI {
        guard let api = apiProvider() else { throw HostedError.notConfigured }
        return api
    }

    /// Runs `call` with a valid token. A 401 means the access token was refused
    /// (expired early, or the clock is off), so it refreshes once and retries.
    private func authorized(_ call: @escaping (String) async throws -> [String: Any]) async throws -> [String: Any] {
        guard isSignedIn else { throw HostedError.notSignedIn }
        let token = try await validAccessToken()
        do {
            return try await call(token)
        } catch HostedError.unauthorized {
            let fresh = try await refreshAccessToken()
            do {
                return try await call(fresh)
            } catch HostedError.unauthorized {
                // The account is gone or the session was revoked.
                clearTokens()
                throw HostedError.notSignedIn
            }
        }
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, accessExpiry.timeIntervalSince(now()) > 60 { return accessToken }
        return try await refreshAccessToken()
    }

    /// One refresh at a time: several windows of a recording can ask together.
    private func refreshAccessToken() async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        guard let refresh = store.get(Key.refresh), !refresh.isEmpty else {
            clearTokens()
            throw HostedError.notSignedIn
        }
        let api = try api()
        let task = Task { () throws -> String in
            let json = try await api.send("POST", "/v1/auth/refresh", body: ["refreshToken": refresh])
            guard let access = json["accessToken"] as? String else { throw HostedError.badResponse }
            self.accessToken = access
            self.accessExpiry = self.now().addingTimeInterval(Self.lifetime(of: json))
            return access
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch HostedError.unauthorized {
            clearTokens()
            throw HostedError.notSignedIn
        }
    }

    private func clearTokens() {
        store.set("", for: Key.refresh)
        accessToken = nil
        accessExpiry = .distantPast
        isSignedIn = false
        quota = nil
    }

    private static func lifetime(of json: [String: Any]) -> TimeInterval {
        (json["expiresIn"] as? Double) ?? 3600
    }
}
