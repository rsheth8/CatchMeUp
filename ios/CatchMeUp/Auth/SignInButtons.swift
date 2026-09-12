import SwiftUI
import AuthenticationServices
import GoogleSignIn
import GoogleSignInSwift

/// Apple and Google's own buttons, wired to `AuthManager`. Used on the last
/// onboarding page and again in Settings for anyone who skipped it there.
struct SignInButtons: View {
    @Environment(AuthManager.self) private var auth
    var onDone: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                guard case .success(let authorization) = result,
                      let credential = authorization.credential as? ASAuthorizationAppleIDCredential
                else { return }
                auth.completeAppleSignIn(credential)
                onDone()
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 46)

            GoogleSignInButton(action: signInWithGoogle)
                .frame(height: 46)
        }
    }

    private func signInWithGoogle() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return }
        GIDSignIn.sharedInstance.signIn(withPresenting: root) { result, error in
            guard error == nil, let user = result?.user else { return }
            auth.completeGoogleSignIn(name: user.profile?.name, email: user.profile?.email)
            onDone()
        }
    }
}
