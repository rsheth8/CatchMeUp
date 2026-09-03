import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                // Readiness, stated once at the top instead of buried in a footer.
                Section {
                    HStack(spacing: 12) {
                        IconTile(symbol: settings.isReady ? "checkmark" : "exclamationmark",
                                 tint: settings.isReady ? .green : .orange, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(settings.isReady ? "Ready to write notes" : "Setup needed")
                                .font(.subheadline.weight(.semibold))
                            Text(settings.readinessHint)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    ForEach(EngineKind.allCases) { kind in
                        EngineOption(kind: kind, isOn: settings.engineKind == kind) {
                            Haptics.tap()
                            withAnimation(.quick) { settings.engineKind = kind }
                        }
                    }
                } header: {
                    Text("Who writes the notes")
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
                                Label("Get a \(settings.provider.label) key", systemImage: "key.fill")
                            }
                        } footer: {
                            Text("The key is stored in the iOS Keychain on this device. Only the transcript text is sent to the provider you choose.")
                        }
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { store.syncEnabled }, set: { store.syncEnabled = $0 })) {
                        Label("Sync with iCloud", systemImage: "icloud")
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Label(store.syncStatus.text, systemImage: store.syncStatus.symbolName)
                        .font(.footnote)
                        .foregroundStyle(store.syncStatus.isProblem ? .orange : .secondary)
                }

                Section {
                    Picker(selection: $settings.defaultMode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("Start recordings as", systemImage: "slider.horizontal.3")
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Recording")
                } footer: {
                    Text("You can still switch mode on the recording screen before you hit record.")
                }

                Section {
                    Button {
                        Haptics.tap()
                        store.seedSampleIfEmpty()
                    } label: {
                        Label("Load two sample recaps", systemImage: "sparkles")
                    }
                    .disabled(!store.sortedRecordings.isEmpty)
                } footer: {
                    if !store.sortedRecordings.isEmpty {
                        Text("Available while your library is empty.")
                    }
                }

                Section {
                    LabeledContent("Transcription", value: "Apple Speech · on device")
                    LabeledContent("Recaps saved", value: "\(store.sortedRecordings.count)")
                    LabeledContent("Brains", value: "\(store.visibleBrains.count)")
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

// MARK: - Engine option row

private struct EngineOption: View {
    let kind: EngineKind
    let isOn: Bool
    let action: () -> Void

    private var symbol: String {
        switch kind {
        case .demo: return "sparkles"
        case .onDevice: return "iphone.gen3"
        case .apiKey: return "key.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: symbol, tint: .brand, size: 34, filled: isOn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(kind.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.brand : Color.secondary.opacity(0.4))
                    .padding(.top, 2)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
