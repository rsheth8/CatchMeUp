import Foundation
import Observation
import AuthenticationServices

/// What Apple currently says about a saved Sign in with Apple user.
enum AppleCredentialStatus: Sendable {
    case active
    case gone
    /// Apple couldn't answer. A failed check is not a reason to sign anyone out.
    case unknown
}

/// Local identity only. There's no backend, so sign-in doesn't unlock or sync
/// anything, and nothing here leaves the device. It holds a name and email to
/// show back to the user, plus Apple's identifier for them, in the Keychain
/// next to the API keys.
///
/// The identifier is what lets the app notice a revoked sign-in today, and it
/// is the stable way to recognize this person if accounts are ever added.
/// Sending it anywhere would need the privacy policy and App Privacy answers
/// updated first.
///
/// Apple only sends `fullName`/`email` on a person's very first Apple sign-in
/// to this app; every sign-in after that leaves them nil. Setters below only
/// overwrite when a value is actually provided, so the first sign-in's name
/// survives every later one.
@MainActor
@Observable
final class AuthManager {
    static let shared = AuthManager()

    private static let providerKey = "auth.provider"
    private static let nameKey = "auth.name"
    private static let emailKey = "auth.email"
    private static let appleUserIDKey = "auth.appleUserID"

    private(set) var provider: String?
    private(set) var displayName: String?
    private(set) var email: String?
    private(set) var appleUserID: String?

    var isSignedIn: Bool { provider != nil }

    /// Transient UI state for the post-sign-out gate. Not persisted, and
    /// cleared once the gate is dismissed.
    var isPresentingSignOutGate = false
    var pendingGoodbyeName: String?

    @ObservationIgnored
    private let credentialStatus: @Sendable (String) async -> AppleCredentialStatus

    init(credentialStatus: @escaping @Sendable (String) async -> AppleCredentialStatus
            = AuthManager.liveAppleCredentialStatus) {
        self.credentialStatus = credentialStatus
        Keychain.reconcileInstall()
        provider = Keychain.get(Self.providerKey)
        displayName = Keychain.get(Self.nameKey)
        email = Keychain.get(Self.emailKey)
        appleUserID = Keychain.get(Self.appleUserIDKey)
    }

    func completeAppleSignIn(_ credential: ASAuthorizationAppleIDCredential) {
        completeAppleSignIn(userID: credential.user,
                            fullName: credential.fullName,
                            email: credential.email)
    }

    func completeAppleSignIn(userID: String, fullName: PersonNameComponents?, email: String?) {
        provider = "apple"
        Keychain.set("apple", for: Self.providerKey)
        appleUserID = userID
        Keychain.set(userID, for: Self.appleUserIDKey)
        if let fullName {
            let full = [fullName.givenName, fullName.familyName].compactMap { $0 }.joined(separator: " ")
            if !full.isEmpty {
                displayName = full
                Keychain.set(full, for: Self.nameKey)
            }
        }
        if let email {
            self.email = email
            Keychain.set(email, for: Self.emailKey)
        }
    }

    func completeGoogleSignIn(name: String?, email: String?) {
        provider = "google"
        Keychain.set("google", for: Self.providerKey)
        appleUserID = nil
        Keychain.set("", for: Self.appleUserIDKey)
        if let name {
            displayName = name
            Keychain.set(name, for: Self.nameKey)
        }
        if let email {
            self.email = email
            Keychain.set(email, for: Self.emailKey)
        }
    }

    func signOut() {
        pendingGoodbyeName = displayName ?? email
        clearIdentity()
        isPresentingSignOutGate = true
    }

    /// Asks Apple whether the saved sign-in still stands. If the person stopped
    /// using Apple sign-in for this app, their name and email are removed here
    /// too. Their notes aren't touched, since they never depended on signing in.
    func refreshAppleCredential() async {
        guard provider == "apple", let userID = appleUserID else { return }
        let status = await credentialStatus(userID)
        // The person may have signed out or switched while Apple was answering.
        guard status == .gone, provider == "apple", appleUserID == userID else { return }
        clearIdentity()
    }

    /// Apple's notice that a sign-in was revoked while the app is running.
    func handleAppleCredentialRevoked() {
        guard provider == "apple" else { return }
        clearIdentity()
    }

    private func clearIdentity() {
        provider = nil
        displayName = nil
        email = nil
        appleUserID = nil
        for key in [Self.providerKey, Self.nameKey, Self.emailKey, Self.appleUserIDKey] {
            Keychain.set("", for: key)
        }
    }

    nonisolated static func liveAppleCredentialStatus(_ userID: String) async -> AppleCredentialStatus {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, error in
                guard error == nil else {
                    continuation.resume(returning: .unknown)
                    return
                }
                switch state {
                case .authorized, .transferred:
                    continuation.resume(returning: .active)
                case .revoked, .notFound:
                    continuation.resume(returning: .gone)
                @unknown default:
                    continuation.resume(returning: .unknown)
                }
            }
        }
    }
}
