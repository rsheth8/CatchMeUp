import SwiftUI
import AuthenticationServices
import GoogleSignIn
import GoogleSignInSwift

/// Whether this build can start Google sign-in.
///
/// The SDK raises an uncaught exception, which ends the app, if the client ID's
/// reversed URL scheme isn't registered. So the button only appears when
/// `Info.plist` holds a real client ID and its matching scheme.
enum GoogleSignInConfiguration {
    private static let clientSuffix = ".apps.googleusercontent.com"

    static var isAvailable: Bool { isUsable(info: Bundle.main.infoDictionary ?? [:]) }

    static func isUsable(info: [String: Any]) -> Bool {
        guard let clientID = info["GIDClientID"] as? String,
              clientID.hasSuffix(clientSuffix),
              !clientID.contains("REPLACE_WITH")
        else { return false }

        let identifier = clientID.dropLast(clientSuffix.count)
        guard !identifier.isEmpty else { return false }
        let required = "com.googleusercontent.apps.\(identifier)".lowercased()

        let urlTypes = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return urlTypes
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .contains { $0.lowercased() == required }
    }
}

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

            if GoogleSignInConfiguration.isAvailable {
                GoogleSignInButton(action: signInWithGoogle)
                    .frame(height: 46)
            }
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
