import SwiftUI

/// Shown full-screen right after sign-out: a brief goodbye, then a gate the
/// user must get past — sign back in, or continue without signing in — to
/// see the app again. Sign-in stays optional even here; this is a moment,
/// not an account wall.
struct SignOutGateView: View {
    @Environment(AuthManager.self) private var auth
    @State private var showGate = false

    var body: some View {
        ZStack {
            AmbientBackground(tint: .brand, intensity: 1.2)
            if showGate {
                AuthWelcomeView(
                    headline: "Welcome back",
                    message: "Sign in again so your name shows up here — or keep going without it. Nothing here needs an account.",
                    skipTitle: "Continue without signing in",
                    onDone: dismiss,
                    onSkip: dismiss
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                goodbye
                    .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { showGate = true }
        }
    }

    private var goodbye: some View {
        VStack(spacing: 20) {
            BrandMark(size: 108, animated: true)
                .opacity(0.55)
            VStack(spacing: 6) {
                Text("Signed out")
                    .font(.title.bold())
                if let name = auth.pendingGoodbyeName {
                    Text("See you soon, \(name).")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func dismiss() {
        auth.pendingGoodbyeName = nil
        auth.isPresentingSignOutGate = false
    }
}
