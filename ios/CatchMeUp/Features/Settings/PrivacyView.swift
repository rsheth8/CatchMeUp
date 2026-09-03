import SwiftUI

// MARK: - PrivacyView
//
// Written for a person, not a legal department, and specific enough to be
// checkable: every claim here corresponds to something in the code, and where
// data does leave the phone it says exactly what leaves and to whom.
//
// It also has to be honest about the part people get wrong: audio never leaves
// the device, but with an API key the *transcript* does. Burying that would be
// the one genuinely dishonest thing this screen could do.

struct PrivacyView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                section("Your recordings", "waveform") {
                    para("Audio is recorded on this iPhone and transcribed on this iPhone, by Apple's on-device speech recogniser. The audio file itself is never uploaded to us or to anyone else.")
                    para("If iCloud sync is on, your recordings, notes and questions are stored in **your** iCloud Drive — your account, your storage, under Apple's terms. We have no server and no account to sign into, so there is nowhere else for them to go.")
                }

                section("What the model sees", "sparkles") {
                    para("Notes are written by whichever engine you pick in Settings:")
                    bullet("**Demo** — nothing leaves the phone. The notes are built-in sample text.")
                    bullet("**Apple on-device** — nothing leaves the phone. The model runs locally.")
                    bullet("**API key** — the *transcript text* is sent to the provider you chose, using your own key, under their privacy terms. Not the audio, and nothing else from the app.")
                    para(currentEngineLine)
                }

                section("Your study data", "graduationcap") {
                    para("Questions, answers you type, review times and the schedule live on the phone, and in your iCloud Drive if sync is on. They are used to work out when to show you something again, and nothing else.")
                    para("Answers are graded on the phone by keyword matching. If you turn on \"Check answers with the model\", one ambiguous answer at a time is sent to your provider to be re-marked — the question, the expected answer and what you typed.")
                }

                section("What we collect", "eye.slash") {
                    para("Nothing. There is no analytics SDK, no crash reporter, no advertising identifier, no tracking, and no account. The app makes no network request except the ones you cause: writing notes with your own API key, and iCloud sync.")
                    para("Bug reports are the one exception, and they only happen when you tap Send feedback and choose where it goes. That report carries version numbers and counts — never your notes, transcripts, answers or key.")
                }

                section("Deleting it", "trash") {
                    para("Deleting a recap deletes its notes, transcript, audio and questions, on this device and on any other device signed into the same iCloud account. Settings ▸ Storage can remove audio while keeping notes, and deleting the app removes everything it holds locally.")
                    para("Your API key is stored in the iPhone's Keychain, not with the rest of the data, and is cleared when you remove it in Settings or delete the app.")
                }

                section("Beta builds", "hammer") {
                    para("While CatchMeUp is in TestFlight, Apple gives the developer the standard TestFlight information — install counts, crash logs, and whatever you write in TestFlight feedback. That comes from Apple, not from anything inside this app.")
                }

                footerNote
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 34)
        }
        .background(AmbientBackground(tint: .brand))
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconTile(symbol: "lock.shield", tint: .brand, size: 46)
            Text("Your recordings stay yours")
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("The short version: the audio never leaves this iPhone, there is no account and no analytics, and the only thing that can be sent anywhere is transcript text — to a provider you chose, with a key you supplied.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    /// Says what is true *right now*, rather than making the reader work out
    /// which of the three cases above applies to them.
    private var currentEngineLine: String {
        switch settings.engineKind {
        case .demo:
            return "You're in **Demo** mode, so nothing is leaving this phone."
        case .onDevice:
            return "You're on **Apple's on-device model**, so nothing is leaving this phone."
        case .apiKey:
            let name = Providers.by(settings.providerID).label
            return "You're using **\(name)**, so transcripts are sent there when a recap is written."
        }
    }

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.5)
            Text("Sync is currently \(store.syncEnabled ? "on" : "off"). Last updated with version \(appVersion).")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    // MARK: Pieces

    private func section(_ title: String, _ symbol: String,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(title, symbol: symbol)
            VStack(alignment: .leading, spacing: 9) { content() }
        }
    }

    private func para(_ text: String) -> some View {
        Text(md: text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle().fill(Color.brand).frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { _ in 5 }
            Text(md: text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
