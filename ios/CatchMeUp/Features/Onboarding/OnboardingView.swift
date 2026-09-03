import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                pane(
                    symbol: "waveform.badge.mic",
                    title: "Missed the meeting?\nMissed the lecture?",
                    body: "CatchMeUp turns a recording into clean notes — the TL;DR, the decisions, the action items, or the study checklist.",
                    tint: .brand
                ).tag(0)

                pane(
                    symbol: "lock.iphone",
                    title: "Your audio stays\non this iPhone",
                    body: "Transcription runs on device with Apple Speech. Only the text is used to write the notes — and in Demo or On-device mode, nothing leaves your phone at all.",
                    tint: .brandDeep
                ).tag(1)

                pane(
                    symbol: "sparkles",
                    title: "Pick who writes\nthe notes",
                    body: "Start in Demo mode to look around. Later, switch to Apple's on-device model (free) or paste an API key from Anthropic, OpenAI, Gemini, and more.",
                    tint: Color(red: 0.60, green: 0.36, blue: 0.10)
                ).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                settings.hasOnboarded = true
                dismiss()
            } label: {
                Text(page == 2 ? "Get started" : "Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.brand.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .simultaneousGesture(TapGesture().onEnded {
                if page < 2 { withAnimation { page += 1 } }
            })
        }
        .background(Color.groupBG)
    }

    private func pane(symbol: String, title: String, body: String, tint: Color) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 72, weight: .regular))
                .foregroundStyle(tint.gradient)
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
        .padding()
    }
}
