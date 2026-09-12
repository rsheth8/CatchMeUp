import Foundation
import Observation
import AuthenticationServices

/// Local identity only — there's no backend, so sign-in doesn't unlock or
/// sync anything. It's a name/email shown back to the user, kept in the
/// Keychain next to the API key.
///
/// Apple only sends `fullName`/`email` on a person's very first Apple sign-in
/// to this app; every sign-in after that leaves them nil. Setters below only
/// overwrite when a value is actually provided, so the first sign-in's name
/// survives every later one.
@MainActor
@Observable
final class AuthManager {
    static let shared = AuthManager()

    private(set) var provider: String?
    private(set) var displayName: String?
    private(set) var email: String?

    var isSignedIn: Bool { provider != nil }

    private init() {
        provider = Keychain.get("auth.provider")
        displayName = Keychain.get("auth.name")
        email = Keychain.get("auth.email")
    }

    func completeAppleSignIn(_ credential: ASAuthorizationAppleIDCredential) {
        provider = "apple"
        Keychain.set("apple", for: "auth.provider")
        if let name = credential.fullName {
            let full = [name.givenName, name.familyName].compactMap { $0 }.joined(separator: " ")
            if !full.isEmpty {
                displayName = full
                Keychain.set(full, for: "auth.name")
            }
        }
        if let email = credential.email {
            self.email = email
            Keychain.set(email, for: "auth.email")
        }
    }

    func completeGoogleSignIn(name: String?, email: String?) {
        provider = "google"
        Keychain.set("google", for: "auth.provider")
        if let name {
            displayName = name
            Keychain.set(name, for: "auth.name")
        }
        if let email {
            self.email = email
            Keychain.set(email, for: "auth.email")
        }
    }

    func signOut() {
        provider = nil
        displayName = nil
        email = nil
        Keychain.set("", for: "auth.provider")
        Keychain.set("", for: "auth.name")
        Keychain.set("", for: "auth.email")
    }
}
