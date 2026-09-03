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
        Pane(symbol: "sparkles",
             title: "Pick who writes\nthe notes",
             body: "Start in Demo mode to look around. Later, switch to Apple's on-device model (free) or paste an API key from Anthropic, OpenAI, Gemini, and more.",
             tint: .amber),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { finish() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .opacity(page == panes.count - 1 ? 0 : 1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            TabView(selection: $page) {
                ForEach(Array(panes.enumerated()), id: \.offset) { idx, pane in
                    paneView(pane).tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            dots
                .padding(.bottom, 26)

            Button {
                Haptics.tap()
                if page < panes.count - 1 {
                    withAnimation(.quick) { page += 1 }
                } else {
                    finish()
                }
            } label: {
                Text(page == panes.count - 1 ? "Get started" : "Next")
            }
            .buttonStyle(.prominent(panes[page].tint))
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .animation(.quick, value: page)
        }
        .background(AmbientBackground(tint: panes[page].tint, intensity: 1.2))
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0..<panes.count, id: \.self) { i in
                Capsule()
                    .fill(i == page ? panes[page].tint : Color.secondary.opacity(0.25))
                    .frame(width: i == page ? 22 : 7, height: 7)
                    .animation(.quick, value: page)
            }
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
