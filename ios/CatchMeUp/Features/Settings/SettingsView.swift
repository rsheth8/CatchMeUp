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
                    .disabled(store.migration.isRunning)

                    if store.migration.isRunning {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(store.migration.text)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    if case .finished(let report) = store.migration {
                        Label(report.summary,
                              systemImage: report.isProblem ? "exclamationmark.icloud" : "checkmark.icloud")
                            .font(.footnote)
                            .foregroundStyle(report.isProblem ? .orange : .secondary)
                    } else {
                        Label(store.syncStatus.text, systemImage: store.syncStatus.symbolName)
                            .font(.footnote)
                            .foregroundStyle(store.syncStatus.isProblem ? .orange : .secondary)
                    }
                }

                Section {
                    NavigationLink {
                        StorageView()
                    } label: {
                        LabeledContent {
                            Text(byteText(store.estimatedAudioBytes))
                                .monospacedDigit()
                        } label: {
                            Label("Storage", systemImage: "internaldrive")
                        }
                    }
                } footer: {
                    Text("See what your audio is using, make existing recordings smaller, export a backup, or free up space.")
                }

                Section {
                    LabeledContent {
                        Text("Automatic")
                    } label: {
                        Label("Spotlight Search", systemImage: "magnifyingglass")
                    }
                    LabeledContent {
                        Text("3 actions")
                    } label: {
                        Label("Siri & Shortcuts", systemImage: "mic.badge.plus")
                    }
                    LabeledContent {
                        Text("On")
                    } label: {
                        Label("Live Activities", systemImage: "waveform.badge.mic")
                    }
                    LabeledContent {
                        Text("On")
                    } label: {
                        Label("Background Recording", systemImage: "lock.iphone")
                    }
                    Link(destination: URL(string: "shortcuts://")!) {
                        Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                    }
                } header: {
                    Text("Apple integrations")
                } footer: {
                    Text("Find recaps from the Home Screen, record while your iPhone is locked, start with Siri, follow progress on the Lock Screen or Dynamic Island, and continue a recap on another Apple device.")
                }

                studySection

                Section {
                    Picker(selection: $settings.defaultMode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("Start recordings as", systemImage: "slider.horizontal.3")
                    }
                    .pickerStyle(.menu)

                    NavigationLink {
                        StorageView()
                    } label: {
                        LabeledContent {
                            Text(settings.recordingQuality.title)
                        } label: {
                            Label("Quality", systemImage: "waveform")
                        }
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    Text("You can still switch mode on the recording screen before you hit record. \(settings.recordingQuality.title) records mono AAC at about \(settings.recordingQuality.sizeEstimate.replacingOccurrences(of: "≈", with: "")).")
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
                    LabeledContent("Version", value: appVersion)
                } header: {
                    Text("About")
                } footer: {
                    Text("CatchMeUp turns a meeting or lecture recording into notes. Audio is transcribed on your iPhone and never uploaded.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Study
    //
    // The scheduler's trade-offs stated out loud rather than tuned in secret.
    // A higher retention target isn't "better" — it's more reviews for the same
    // material, and someone choosing it should see that in the same breath.

    @ViewBuilder
    private var studySection: some View {
        @Bindable var settings = settings

        Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent {
                    Text(retentionText).monospacedDigit()
                } label: {
                    Label("Target recall", systemImage: "target")
                }
                Slider(value: $settings.desiredRetention, in: 0.80...0.97, step: 0.01)
                    .tint(.brand)
                    .accessibilityValue(retentionText)
            }
            .padding(.vertical, 2)

            Stepper(value: $settings.dailyNewLimit, in: 0...50, step: 2) {
                LabeledContent {
                    Text("\(settings.dailyNewLimit)").monospacedDigit()
                } label: {
                    Label("New per day", systemImage: "sparkles")
                }
            }

            Stepper(value: $settings.dailyReviewLimit, in: 20...400, step: 10) {
                LabeledContent {
                    Text("\(settings.dailyReviewLimit)").monospacedDigit()
                } label: {
                    Label("Reviews per day", systemImage: "checkmark.circle")
                }
            }
        } header: {
            Text("Study")
        } footer: {
            Text(retentionFooter)
        }

        Section {
            Toggle(isOn: $settings.modelGrading) {
                Label("Check answers with the model", systemImage: "text.magnifyingglass")
            }
            .disabled(settings.engineKind != .apiKey)
        } footer: {
            Text(gradingFooter)
        }

        Section {
            Stepper(value: $settings.focusMinutes, in: 10...60, step: 5) {
                LabeledContent {
                    Text("\(settings.focusMinutes) min").monospacedDigit()
                } label: {
                    Label("Focus block", systemImage: "timer")
                }
            }
            Stepper(value: $settings.breakMinutes, in: 3...20, step: 1) {
                LabeledContent {
                    Text("\(settings.breakMinutes) min").monospacedDigit()
                } label: {
                    Label("Break", systemImage: "cup.and.saucer")
                }
            }
        } header: {
            Text("Focus sessions")
        } footer: {
            Text("The break isn't padding — stopping is when what you just retrieved settles.")
        }
    }

    private var retentionText: String {
        "\(Int((settings.desiredRetention * 100).rounded()))%"
    }

    /// Says what the number costs, not just what it is.
    private var retentionFooter: String {
        let base = "How likely you want to be to recall something when it comes back. "
        switch settings.desiredRetention {
        case ..<0.85:
            return base + "Below 90% means noticeably fewer reviews, and more things you'll have forgotten by the time you see them. Good for wide reading, risky before an exam."
        case 0.85..<0.93:
            return base + "90% is the setting most of the evidence is built on — close to the least work for the most retained."
        default:
            return base + "Above 93% the reviews climb steeply for a small gain. Worth it for a licensing exam, wasteful for a survey course. An exam date already raises this on its own as the day approaches."
        }
    }

    private var gradingFooter: String {
        switch settings.engineKind {
        case .apiKey:
            return settings.modelGrading
                ? "When keyword matching can't tell whether a paraphrase counts, one short call settles it. Only for answers that are genuinely ambiguous, so sessions stay fast and mostly offline."
                : "Answers are marked by keyword matching alone. Fast and fully offline, but it will mark down a correct answer worded differently."
        default:
            return "Needs your own API key — switch the engine above. Without it, answers are marked by keyword matching, which works offline but is stricter about wording."
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
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
