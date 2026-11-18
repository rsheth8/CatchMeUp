import SwiftUI
import AuthenticationServices
import CryptoKit
import GoogleSignIn
import GoogleSignInSwift

/// Apple and Google's own buttons, wired to `AuthManager`. Used on the last
/// onboarding page and again in Settings for anyone who skipped it there.
///
/// When CatchMeUp Cloud is available, each sign-in also carries a nonce the
/// service issued, so the identity token can be exchanged for a session there.
/// That exchange is best-effort: the local profile is saved either way.
struct SignInButtons: View {
    @Environment(AuthManager.self) private var auth
    var onDone: () -> Void = {}

    /// A server-issued, single-use nonce, fetched ahead of the tap because
    /// Apple's request is built synchronously.
    @State private var nonce: String?

    var body: some View {
        VStack(spacing: 12) {
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
                // Apple wants the SHA-256 of the nonce; the service accepts that form.
                if let nonce { request.nonce = Self.sha256Hex(nonce) }
            } onCompletion: { result in
                guard case .success(let authorization) = result,
                      let credential = authorization.credential as? ASAuthorizationAppleIDCredential
                else { return }
                auth.completeAppleSignIn(credential)
                if let used = nonce,
                   let data = credential.identityToken,
                   let token = String(data: data, encoding: .utf8) {
                    exchange(.apple, idToken: token, nonce: used)
                }
                onDone()
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 46)

            GoogleSignInButton(action: signInWithGoogle)
                .frame(height: 46)
        }
        .task { await prepareNonce() }
    }

    private func signInWithGoogle() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return }
        let used = nonce
        GIDSignIn.sharedInstance.signIn(
            withPresenting: root, hint: nil, additionalScopes: nil, nonce: used
        ) { result, error in
            guard error == nil, let user = result?.user else { return }
            auth.completeGoogleSignIn(name: user.profile?.name, email: user.profile?.email)
            if let used, let token = user.idToken?.tokenString {
                exchange(.google, idToken: token, nonce: used)
            }
            onDone()
        }
    }

    private func prepareNonce() async {
        guard HostedConfig.isConfigured else { return }
        nonce = try? await HostedSession.shared.fetchNonce()
    }

    /// A nonce works once, so a new one is fetched for the next attempt.
    private func exchange(_ provider: HostedProvider, idToken: String, nonce used: String) {
        nonce = nil
        Task {
            try? await HostedSession.shared.signIn(provider, idToken: idToken, nonce: used)
            await prepareNonce()
        }
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
