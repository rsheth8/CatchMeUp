import SwiftUI

/// The first thing a cold launch shows: the brand mark's signal reaching
/// itself, then it dissolves into the app underneath. Plays once per launch;
/// Reduce Motion skips straight through rather than forcing a timed wait.
struct LaunchSplashView: View {
    var onFinished: () -> Void

    @State private var holding = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AmbientBackground(tint: .brand, intensity: 1.2)
            BrandMark(size: 168, animated: true)
        }
        .opacity(holding ? 1 : 0)
        .scaleEffect(holding ? 1 : 1.06)
        .task {
            guard !reduceMotion else { onFinished(); return }
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(.easeInOut(duration: 0.4)) { holding = false }
            try? await Task.sleep(for: .milliseconds(400))
            onFinished()
        }
    }
}
