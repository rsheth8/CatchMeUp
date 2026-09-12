import SwiftUI

// MARK: - TranscriptionView
//
// Everything about turning audio into text, on one screen, because the choice
// has consequences the user should see together: an engine, a model with a real
// download size, and whether to spend a second model on labelling speakers.
//
// Deliberately *not* merged into the "Who writes the notes" section. Speech and
// recaps are separate pipelines — a Claude key does not transcribe anything,
// and Apple Speech does not need one — and one combined picker has repeatedly
// been read as "my audio goes to Anthropic", which is exactly wrong.

struct TranscriptionView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProcessingQueue.self) private var queue
    @State private var models = WhisperModelStore.shared
    @State private var confirmingDelete: WhisperVariant?

    /// Switching engine or model mid-job would leave a recording half-processed
    /// by one engine and finished by another.
    private var isBusy: Bool { queue.jobs.contains { $0.phase.isActive } }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                ForEach(SpeechEngineKind.allCases) { kind in
                    SpeechOption(kind: kind, isOn: settings.speechEngine == kind) {
                        Haptics.tap()
                        withAnimation(.quick) { settings.speechEngine = kind }
                    }
                    .disabled(isBusy)
                }
            } header: {
                Text("Engine")
            } footer: {
                Text(isBusy
                     ? "Finish the recording that's processing before changing engines."
                     : "Both run entirely on this iPhone. Audio is never uploaded, whichever you pick.")
            }

            if settings.speechEngine == .whisper {
                modelSection
                speakerSection
            } else {
                Section {
                    Label("Apple Speech cannot label speakers", systemImage: "person.2.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Apple's speech APIs return text and timings, but no speaker identity. Switch to Whisper if you want “who said what” in meeting transcripts.")
                }
            }
        }
        .navigationTitle("Transcription")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.groupBG)
        .confirmationDialog(
            "Delete this model?",
            isPresented: Binding(get: { confirmingDelete != nil },
                                 set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let variant = confirmingDelete { models.delete(variant) }
                confirmingDelete = nil
            }
            Button("Keep", role: .cancel) { confirmingDelete = nil }
        } message: {
            if let variant = confirmingDelete {
                Text("Frees about \(variant.approximateMB) MB. Existing transcripts are untouched; the model downloads again next time you need it.")
            }
        }
    }

    // MARK: Model

    private var modelSection: some View {
        Section {
            ForEach(WhisperVariant.supportedOnThisDevice) { variant in
                ModelRow(
                    variant: variant,
                    isChosen: settings.whisperVariant == variant,
                    state: models.state(variant),
                    choose: {
                        Haptics.tap()
                        withAnimation(.quick) { settings.whisperVariant = variant }
                    },
                    download: { Task { try? await models.ensure(variant) } },
                    cancel: { models.cancelDownload(variant) },
                    delete: { confirmingDelete = variant }
                )
                .disabled(isBusy)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Downloaded once over Wi-Fi and reused offline. A recording transcribes with whichever model is selected when it starts; if that one isn't on the device yet, it downloads first.")
        }
    }

    // MARK: Speakers

    private var speakerSection: some View {
        @Bindable var settings = settings

        return Section {
            Toggle(isOn: $settings.diarizeSpeakers) {
                Label("Label who spoke", systemImage: "person.2.wave.2")
            }
            .disabled(isBusy)
        } header: {
            Text("Speakers")
        } footer: {
            Text("Meetings only — a lecture is one voice. Adds a second on-device model (about 25 MB) and roughly a third more processing time. Lines come back as “Speaker 1”, “Speaker 2”; rename them from the transcript, and the names carry into your notes and exports.")
        }
    }
}

// MARK: - SpeechOption

private struct SpeechOption: View {
    let kind: SpeechEngineKind
    let isOn: Bool
    let action: () -> Void

    private var symbol: String {
        switch kind {
        case .apple: return "waveform"
        case .whisper: return "waveform.badge.magnifyingglass"
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
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ModelRow

private struct ModelRow: View {
    let variant: WhisperVariant
    let isChosen: Bool
    let state: WhisperModelStore.State
    let choose: () -> Void
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: choose) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isChosen ? Color.brand : Color.secondary.opacity(0.4))
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(variant.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(variant.sizeLabel)
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(variant.blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            statusRow
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch state {
        case .absent:
            Button("Download", action: download)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
        case .downloading(let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                Text("\(Int(fraction * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel", action: cancel)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        case .ready:
            HStack(spacing: 10) {
                Label("On this iPhone", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer(minLength: 0)
                Button("Delete", role: .destructive, action: delete)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again", action: download)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
    }
}
