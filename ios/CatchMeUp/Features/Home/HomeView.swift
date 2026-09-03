import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var path: [UUID] = []
    @State private var showRecorder = false
    @State private var showImporter = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 18) {
                    if !settings.isReady {
                        readinessBanner
                    }

                    VStack(spacing: 10) {
                        SectionLabel(text: "New recap as a", symbol: nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ModeSwitch(mode: $settings.defaultMode)
                    }

                    VStack(spacing: 10) {
                        BigActionButton(
                            title: "Record now",
                            subtitle: "Start the mic, stop when it's over",
                            systemImage: "mic.fill",
                            tint: settings.defaultMode.accent
                        ) { showRecorder = true }

                        BigActionButton(
                            title: "Add a file",
                            subtitle: "A recording you already have",
                            systemImage: "tray.and.arrow.down.fill",
                            filled: false
                        ) { showImporter = true }
                    }

                    recentSection
                }
                .padding(16)
            }
            .background(Color.groupBG)
            .navigationTitle("CatchMeUp")
            .navigationDestination(for: UUID.self) { id in
                RecapDetailView(recordingID: id)
            }
            .fullScreenCover(isPresented: $showRecorder) {
                RecordView(mode: settings.defaultMode) { newID in
                    showRecorder = false
                    path.append(newID)
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .mpeg4Movie, .movie, .quickTimeMovie],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
        }
    }

    // MARK: Sections

    private var readinessBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Finish setup in Settings").font(.subheadline.weight(.semibold))
                Text(settings.readinessHint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var recentSection: some View {
        let items = store.sortedRecordings
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Recent", symbol: "clock")
            if items.isEmpty {
                Card {
                    EmptyState(symbol: "waveform",
                               title: "No recaps yet",
                               message: "Record something or add a file. It shows up here with its notes.")
                }
            } else {
                ForEach(items) { rec in
                    Button { path.append(rec.id) } label: {
                        RecordingRow(recording: rec, brainName: store.brain(rec.brainID)?.name)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Import

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard let filename = store.importAudio(from: url, preferredName: url.lastPathComponent) else { return }
        var rec = Recording(title: url.deletingPathExtension().lastPathComponent,
                            mode: Mode.guess(fromFilename: url.lastPathComponent),
                            audioFilename: filename)
        rec.mode = settings.defaultMode == .meeting && Mode.guess(fromFilename: url.lastPathComponent) == .lecture
            ? .lecture : settings.defaultMode
        store.upsert(rec)
        path.append(rec.id)
    }
}

struct RecordingRow: View {
    let recording: Recording
    var brainName: String?

    var body: some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(recording.mode.accent.opacity(0.15))
                    Image(systemName: recording.mode.symbol)
                        .foregroundStyle(recording.mode.accent)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(recording.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(recording.createdAt.relativeShort)
                        if let brainName {
                            Text("· \(brainName)")
                        }
                        if recording.processingError != nil {
                            Text("· needs attention").foregroundStyle(.orange)
                        } else if !recording.isProcessed {
                            Text("· processing…").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
        }
    }
}
