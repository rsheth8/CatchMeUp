import SwiftUI

/// Demonstrates capture → processing → recap with matching authored audio.
/// Never pretends the user's microphone was transcribed by a mock engine.
struct ShowcaseCaptureView: View {
    let mode: Mode
    let brainID: UUID?
    var onFinish: (UUID) -> Void
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "waveform.circle.fill").font(.system(size: 82)).foregroundStyle(Color.brand)
                Text("Try a demo \(mode.title.lowercased())").font(.title2.bold())
                Text("We'll use a short narrated sample so you can experience processing, notes, and playable key moments. No microphone or API request is used.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                if running { ProgressView("Preparing sample audio…") }
                else {
                    Button("Create demo recap") { Task { await create() } }
                        .buttonStyle(.borderedProminent)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                Spacer()
                Text("For your own recordings, use Apple Intelligence or your API key in your personal account.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(28)
            .navigationTitle("Demo capture")
            .toolbar { Button("Cancel") { dismiss() }.disabled(running) }
            .interactiveDismissDisabled(running)
        }
    }

    @MainActor private func create() async {
        running = true
        defer { running = false }
        do {
            guard let sample = try ShowcaseCatalog.entries().first(where: { $0.mode == mode }),
                  let url = sample.audioURL, let audio = await store.audio.importFile(from: url) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var recording = Recording(title: "Demo · \(sample.title)", mode: mode)
            recording.brainID = brainID
            recording.audioFilename = audio.filename
            recording.duration = sample.duration
            if let facts = audio.facts { recording.apply(facts) }
            store.upsert(recording)
            onFinish(recording.id)
        } catch { self.error = error.localizedDescription }
    }
}
