import SwiftUI

// MARK: - ProviderConsentView
//
// The permission Apple requires before personal data goes to a third-party AI
// service (App Review Guideline 5.1.2(i)). It names the recipient and lists what
// is sent, and nothing is preselected: `LLMClient` refuses to send until the
// user taps Allow for this exact destination.
//
// Keep the list in step with what the prompts actually include.

struct ProviderConsentView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private let sentItems = [
        "Transcripts of your recordings and imported audio",
        "Recap notes and titles",
        "Text from documents, slides and scans you add",
        "Meeting agendas",
        "Questions you ask a brain, and that brain's instructions",
        "Study questions, expected answers and what you type, when answer checking is on",
    ]

    private var recipient: String { settings.sharingRecipient }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        IconTile(symbol: "hand.raised.fill", tint: .brand, size: 46)
                        Text("Share your content with \(recipient)?")
                            .font(.title2.bold())
                            .fixedSize(horizontal: false, vertical: true)
                        Text("To write notes and answer questions, CatchMeUp sends text from this iPhone to \(recipient) using your API key. \(recipient) is a separate service, and CatchMeUp doesn't control how it handles your data.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        SectionHeader("What is sent", symbol: "arrow.up.doc")
                        ForEach(sentItems, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Circle().fill(Color.brand).frame(width: 5, height: 5)
                                    .alignmentGuide(.firstTextBaseline) { _ in 5 }
                                Text(item)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        SectionHeader("What to know", symbol: "info.circle")
                        note("Your audio files are not sent.")
                        note("\(recipient)'s terms and your account settings decide how long it keeps this text and whether it can use it for training.")
                        note("You can turn this off in Settings at any time. That stops new sharing, but it can't recall text already sent.")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button("Allow Sharing") {
                        settings.grantSharingConsent()
                        dismiss()
                    }
                    .buttonStyle(.prominent(.brand))

                    Button("Not Now") { dismiss() }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .background(AmbientBackground(tint: .brand))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
