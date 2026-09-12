import SwiftUI

/// The shared sign-in surface: animated brand mark, headline, Apple/Google
/// buttons, and a skip action. Used both in `OnboardingView` on first launch
/// and as the second phase of `SignOutGateView` — one polished screen
/// instead of two different ones.
struct AuthWelcomeView: View {
    var headline: String
    var message: String
    var skipTitle: String
    var onDone: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            BrandMark(size: 108, animated: true)
            VStack(spacing: 12) {
                Text(headline)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            SignInButtons(onDone: onDone)
                .padding(.horizontal, 32)
            Button(skipTitle, action: onSkip)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Spacer()
        }
        .padding()
    }
}
