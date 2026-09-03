import SwiftUI

struct ClipSheet: View {
    let recordings: [Recording]
    var accent: Color = .amber
    var initialQuery: String = ""

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var player = AudioPlayer()
    @State private var playing: ClipHit?
    @State private var clipError: String?
    @State private var stopTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("mutex, billing, environment diagrams…", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color.cardBG, in: RoundedRectangle(cornerRadius: Metric.tile, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                let hits = ClipSearch.list(query: query, in: recordings)
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    EmptyState(symbol: "waveform",
                               title: "Hear a concept",
                               message: "Type a term from these recaps. CatchMeUp jumps to the moment it was said.")
                        .padding(.top, 24)
                } else if hits.isEmpty {
                    EmptyState(symbol: "magnifyingglass",
                               title: "Nothing matched",
                               message: "Try the heading of a key moment, or a term from the glossary.")
                        .padding(.top, 24)
                } else {
                    List(hits) { hit in
                        Button { Task { await play(hit) } } label: {
                            hitRow(hit)
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(AmbientBackground(tint: accent))
            .navigationTitle("Hear a concept")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if !initialQuery.isEmpty { query = initialQuery }
            }
            .onDisappear {
                stopTask?.cancel()
                player.stop()
            }
            .alert("Couldn't play that moment", isPresented: Binding(
                get: { clipError != nil },
                set: { if !$0 { clipError = nil } }
            )) {
                Button("OK", role: .cancel) { clipError = nil }
            } message: {
                Text(clipError ?? "")
            }
        }
    }

    private func hitRow(_ hit: ClipHit) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: playing?.id == hit.id && player.isPlaying
                  ? "pause.circle.fill" : "play.circle.fill")
                .font(.title2)
                .foregroundStyle(hit.hasAudio ? accent : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.heading)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if !hit.insight.isEmpty {
                    Text(hit.insight)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("\(hit.title) · \(shortStamp(hit.timestamp))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func play(_ hit: ClipHit) async {
        Haptics.tap()
        if playing?.id == hit.id, player.isPlaying {
            player.pause()
            stopTask?.cancel()
            return
        }
        guard let rec = store.recording(hit.recordingID), rec.hasAudio else {
            clipError = "This recap's notes are here, but the original audio wasn't imported."
            return
        }
        do {
            let url = try await store.audio.ensureLocal(for: rec)
            player.load(url)
            store.markPlayed(rec.id)
            player.play(from: hit.start)
            playing = hit
            stopTask?.cancel()
            stopTask = Task {
                try? await Task.sleep(for: .seconds(25))
                if !Task.isCancelled { player.pause() }
            }
        } catch {
            clipError = error.localizedDescription
        }
    }

    private func shortStamp(_ stamp: String) -> String {
        let parts = stamp.split(separator: ":")
        if parts.count == 3, parts[0] == "00" { return parts.dropFirst().joined(separator: ":") }
        return stamp
    }
}
