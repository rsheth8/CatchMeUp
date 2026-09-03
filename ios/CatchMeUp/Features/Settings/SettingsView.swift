import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    Picker("Who writes the notes", selection: $settings.engineKind) {
                        ForEach(EngineKind.allCases) { Text($0.title).tag($0) }
                    }
                    Text(settings.engineKind.blurb)
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Notes engine")
                } footer: {
                    Label(settings.readinessHint,
                          systemImage: settings.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(settings.isReady ? .green : .orange)
                        .font(.footnote)
                }

                if settings.engineKind == .apiKey {
                    Section("Provider") {
                        Picker("Provider", selection: Binding(
                            get: { settings.providerID },
                            set: { settings.selectProvider($0) }
                        )) {
                            ForEach(Providers.all) { Text($0.label).tag($0.id) }
                        }
                        TextField("Model", text: $settings.model)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if settings.provider.needsBaseURL || settings.providerID == "ollama" {
                            TextField("Base URL", text: $settings.customBaseURL)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .keyboardType(.URL)
                        }
                        if settings.providerID != "ollama" {
                            SecureField("API key", text: $settings.apiKey)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                    if let signup = settings.provider.signup, let url = URL(string: signup) {
                        Section {
                            Link(destination: url) {
                                Label("Get a \(settings.provider.label) key", systemImage: "key")
                            }
                        } footer: {
                            Text("The key is stored in the iOS Keychain on this device. Only the transcript text is sent to the provider you choose.")
                        }
                    }
                }

                Section("Default recap style") {
                    Picker("Style", selection: $settings.defaultMode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Try it") {
                    Button("Load two sample recaps") { store.seedSampleIfEmpty() }
                }

                Section {
                    LabeledContent("Transcription", value: "Apple Speech · on device")
                    LabeledContent("Recaps saved", value: "\(store.recordings.count)")
                    LabeledContent("Version", value: "0.1.0 (beta)")
                } header: {
                    Text("About")
                } footer: {
                    Text("CatchMeUp turns a meeting or lecture recording into notes. Audio is transcribed on your iPhone and never uploaded.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
