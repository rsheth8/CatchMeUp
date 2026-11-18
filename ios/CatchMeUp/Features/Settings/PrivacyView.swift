import SwiftUI

// MARK: - PrivacyView
//
// Written for a person, not a legal department, and specific enough to be
// checkable: every claim here corresponds to something in the code, and where
// data does leave the phone it says exactly what leaves and to whom.
//
// It also has to be honest about the parts people get wrong: audio is copied to
// iCloud when sync is on, and an allowed AI provider receives text from several
// places in the app, not just transcripts. Keep this in step with
// `ProviderConsentView`.

struct PrivacyView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                section("Your recordings", "waveform") {
                    para("Audio is recorded on this iPhone and transcribed here by Apple's on-device speech recognizer. CatchMeUp never sends audio to an AI provider, and we have no server to receive it.")
                    para("If you turn on iCloud sync, your recordings, including the audio, and your notes and questions are stored in **your** iCloud Drive. They leave this iPhone for Apple's servers, under your iCloud account and Apple's terms.")
                    para(signInLine)
                }

                section("What the model sees", "sparkles") {
                    para("Notes are written by whichever engine you pick in Settings:")
                    bullet("**Demo:** nothing leaves the phone. The notes are built-in sample text.")
                    bullet("**Apple on-device:** nothing leaves the phone. The model runs locally.")
                    bullet("**API key:** nothing is sent until you allow that provider in Settings. After that, CatchMeUp sends text using your key: transcripts, notes and titles, text from documents and scans you add, meeting agendas, your questions and brain instructions, and study answers when answer checking is on. The provider handles it under its own terms. Audio files are not sent.")
                    para(currentEngineLine)
                }

                section("Your study data", "graduationcap") {
                    para("Questions, answers you type, review times and the schedule live on the phone, and in your iCloud Drive if sync is on. They are used to work out when to show you something again, and nothing else.")
                    para("Answers are graded on the phone by keyword matching. If you've allowed an AI provider and \"Check answers with the model\" is on, an ambiguous answer is sent to that provider to be re-marked, along with the question and the expected answer.")
                }

                section("What we collect", "eye.slash") {
                    para("Nothing reaches us. There is no CatchMeUp server, analytics SDK, crash reporter, advertising identifier or tracking. The app connects to the internet for things you turn on or start: your AI provider, iCloud sync, and \(signInServices). iOS may also download Apple's speech and language models.")
                    para("Recap titles and text are added to this iPhone's Spotlight index so you can search for them.")
                    para("Bug reports only happen when you tap Send feedback and choose where the report goes. It carries version numbers, your device model, your engine and provider choice, a few settings and counts, never your notes, transcripts, answers or key.")
                }

                section("Deleting it", "trash") {
                    para("Deleting a recap deletes its notes, transcript, audio and questions, on this device and on any other device signed into the same iCloud account. Settings ▸ Storage can remove audio while keeping notes.")
                    para("Deleting the app removes its files from this iPhone. Copies in your iCloud Drive stay until you delete them there, and text already sent to a provider stays under that provider's terms.")
                    para("API keys are stored separately for each provider in this device's Keychain, and clearing one in Settings removes it right away. iOS can keep Keychain items after an app is deleted, so CatchMeUp erases its keys, name and email the next time it is installed. If you're finished with a key, revoke it with the provider too.")
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
            Text("The short version: there is no CatchMeUp server or analytics, and audio is transcribed on this iPhone. Your content leaves it only if you turn on iCloud sync or allow an AI provider you chose.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private var signInServices: String {
        GoogleSignInConfiguration.isAvailable ? "signing in with Apple or Google" : "signing in with Apple"
    }

    private var signInLine: String {
        let base = "Signing in only shows your name here on this iPhone. It doesn't create an account with us or unlock anything. Your name, your email and Apple's sign-in identifier are stored in this device's Keychain and aren't sent to us. If you stop using Apple sign-in for CatchMeUp in your Apple account settings, the app removes them."
        return GoogleSignInConfiguration.isAvailable
            ? base + " If you use Google, Google handles that sign-in under its own terms."
            : base
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
            let name = settings.sharingRecipient
            return settings.hasSharingConsent
                ? "You've allowed **\(name)**, so your text is sent there when the app writes notes, answers or questions."
                : "You've chosen **\(name)**, but sharing isn't allowed yet, so nothing is being sent."
        }
    }

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.5)
            Link("Read the full privacy policy", destination: LegalLinks.privacyPolicy)
                .font(.footnote.weight(.semibold))
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
