import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Pane {
        let symbol: String?
        let title: String
        let body: String
        let tint: Color
    }

    private let panes: [Pane] = [
        Pane(symbol: nil,
             title: "Missed the meeting?\nMissed the lecture?",
             body: "CatchMeUp turns a recording into clean notes — the gist, the decisions, the action items, or the study checklist.",
             tint: .brand),
        Pane(symbol: "lock.iphone",
             title: "Your audio stays\non this iPhone",
             body: "Transcription runs on device with Apple Speech. Only the text is used to write the notes — and in Demo or On-device mode, nothing leaves your phone at all.",
             tint: .brandDeep),
        // The pane that says what this app is *for*. Notes are the input; the
        // product is what happens to them afterwards, and a first-time user who
        // never learns that just has another transcription app.
        Pane(symbol: "brain.head.profile",
             title: "Then it asks you\nabout them",
             body: "Every recap becomes questions. You get them back on the day you're about to forget — a few minutes, not a cram session. Reading feels like learning; being asked is learning.",
             tint: .mint),
        Pane(symbol: "sparkles",
             title: "Pick who writes\nthe notes",
             body: "Start in Demo mode to look around. Later, switch to Apple's on-device model (free) or paste an API key from Anthropic, OpenAI, Gemini, and more.",
             tint: .amber),
    ]

    /// The intro panes are tags `0..<panes.count`; sign-in and the tour offer
    /// are two extra pages after that, each with its own buttons instead of
    /// Next/Get started.
    private var currentTint: Color { page < panes.count ? panes[page].tint : .brand }
    private var tourOfferTag: Int { panes.count + 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { finish() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            TabView(selection: $page) {
                ForEach(Array(panes.enumerated()), id: \.offset) { idx, pane in
                    paneView(pane).tag(idx)
                }
                signInPane.tag(panes.count)
                tourOfferPane.tag(tourOfferTag)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            dots
                .padding(.bottom, 26)

            if page < panes.count {
                Button {
                    Haptics.tap()
                    withAnimation(.quick) { page += 1 }
                } label: {
                    Text(page == panes.count - 1 ? "Continue" : "Next")
                }
                .buttonStyle(.prominent(panes[page].tint))
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .animation(.quick, value: page)
            }
        }
        .background(AmbientBackground(tint: currentTint, intensity: 1.2))
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0..<(panes.count + 2), id: \.self) { i in
                Capsule()
                    .fill(i == page ? currentTint : Color.secondary.opacity(0.25))
                    .frame(width: i == page ? 22 : 7, height: 7)
                    .animation(.quick, value: page)
            }
        }
    }

    private var signInPane: some View {
        AuthWelcomeView(
            headline: "Save your spot",
            message: "Sign in so your name shows up here on this iPhone. Everything still stays local and syncs through your own iCloud — this is just personalization.",
            skipTitle: "Not now",
            onDone: { withAnimation(.quick) { page += 1 } },
            onSkip: { withAnimation(.quick) { page += 1 } }
        )
    }

    private var tourOfferPane: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 62, weight: .regular))
                .foregroundStyle(Color.brand.gradient)
                .frame(height: 120)
                .symbolEffect(.bounce, value: page)
            VStack(spacing: 12) {
                Text("Want a quick look\naround first?")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text("Take a five-minute tour through a sample account — recordings, study practice, and connected notes already filled in. Nothing you do there touches your real library.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            VStack(spacing: 12) {
                Button("Take the tour", action: startTour)
                    .buttonStyle(.prominent(.brand))
                Button("Skip, start using the app") { finish() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
        .padding()
    }

    private func startTour() {
        finish()
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            ShowcaseSession.shared.enter()
        }
    }

    private func paneView(_ pane: Pane) -> some View {
        VStack(spacing: 24) {
            Spacer()
            if let symbol = pane.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 62, weight: .regular))
                    .foregroundStyle(pane.tint.gradient)
                    .frame(height: 120)
                    .symbolEffect(.bounce, value: page)
            } else {
                BrandMark(size: 120, animated: true)
                    .frame(height: 120)
            }
            VStack(spacing: 12) {
                Text(pane.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(pane.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            Spacer()
        }
        .padding()
    }

    private func finish() {
        settings.hasOnboarded = true
        dismiss()
    }
}
