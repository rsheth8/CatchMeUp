import SwiftUI

/// The full transcript, out of the way of the notes but one tap from them.
/// Searchable, and every line seeks the player.
///
/// When the transcript is diarized it also becomes the place speakers get their
/// real names. That belongs here rather than in Settings: "Speaker 2" only
/// means something while you are looking at what Speaker 2 said.
struct TranscriptView: View {
    let recording: Recording
    let onPlay: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var store
    @State private var query = ""
    @State private var speakerFilter: String?
    @State private var renaming: String?
    @State private var draftName = ""

    /// The live copy, so a rename redraws the list under the sheet that made it.
    private var live: Recording {
        store.sortedRecordings.first { $0.id == recording.id } ?? recording
    }

    /// Distinct speakers in first-appearance order — which is the order a reader
    /// meets them in, and so the order the chips should be in. Alphabetical
    /// would shuffle the row every time someone is renamed.
    private var speakers: [String] {
        var seen = Set<String>()
        return live.segments.compactMap { segment -> String? in
            guard let name = segment.speaker, !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    private var matches: [Segment] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return live.segments.filter { segment in
            if let speakerFilter, segment.speaker != speakerFilter { return false }
            return q.isEmpty || segment.text.localizedCaseInsensitiveContains(q)
        }
    }

    private var emptyMessage: String {
        if let speakerFilter, !query.isEmpty {
            return "\(speakerFilter) doesn't say “\(query)” anywhere in this transcript."
        }
        if let speakerFilter { return "\(speakerFilter) has no lines left in this transcript." }
        return "No line in this transcript mentions “\(query)”."
    }

    var body: some View {
        NavigationStack {
            Group {
                if matches.isEmpty {
                    EmptyState(symbol: "text.magnifyingglass",
                               title: "No matches",
                               message: emptyMessage)
                } else {
                    List(matches) { seg in
                        Button {
                            Haptics.tap()
                            onPlay(seg.start)
                        } label: {
                            HStack(alignment: .top, spacing: 11) {
                                Text(seg.stamp)
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(recording.mode.accent)
                                    .frame(width: 62, alignment: .leading)
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 3) {
                                    if let sp = seg.speaker, !sp.isEmpty {
                                        Text(sp)
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(seg.text)
                                        .font(.subheadline)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            if let sp = seg.speaker, !sp.isEmpty {
                                Button {
                                    startRename(sp)
                                } label: {
                                    Label("Rename \(sp)", systemImage: "person.text.rectangle")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if !speakers.isEmpty { speakerBar }
                    }
                }
            }
            .background(Color.groupBG)
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search this transcript")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename speaker", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $draftName)
                    .textInputAutocapitalization(.words)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                if let renaming {
                    Text("Renames every line attributed to \(renaming). The new name is used in your notes, shares and exports too.")
                }
            }
        }
    }

    // MARK: Speakers

    /// One chip per voice: tap to read only them, long-press to name them.
    private var speakerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // FilterChip supplies its own haptic and animation.
                FilterChip(title: "Everyone", isOn: speakerFilter == nil) {
                    speakerFilter = nil
                }
                ForEach(speakers, id: \.self) { name in
                    FilterChip(title: name, isOn: speakerFilter == name) {
                        speakerFilter = speakerFilter == name ? nil : name
                    }
                    .contextMenu {
                        Button {
                            startRename(name)
                        } label: {
                            Label("Rename", systemImage: "person.text.rectangle")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func startRename(_ name: String) {
        draftName = name
        renaming = name
    }

    private func commitRename() {
        guard let old = renaming else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank name would leave the reader with an unlabelled line and no way
        // back to the label, so it's a no-op rather than a clear.
        if !name.isEmpty, name != old {
            store.renameSpeaker(in: recording.id, from: old, to: name)
            if speakerFilter == old { speakerFilter = name }
            Haptics.tap(.soft)
        }
        renaming = nil
    }
}
