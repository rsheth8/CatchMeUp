import SwiftUI

/// The full transcript, out of the way of the notes but one tap from them.
/// Searchable, and every line seeks the player.
struct TranscriptView: View {
    let recording: Recording
    let onPlay: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [Segment] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return recording.segments }
        return recording.segments.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if matches.isEmpty {
                    EmptyState(symbol: "text.magnifyingglass",
                               title: "No matches",
                               message: "No line in this transcript mentions “\(query)”.")
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
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
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
        }
    }
}
