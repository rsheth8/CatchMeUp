import SwiftUI

struct ExamView: View {
    let recordings: [Recording]
    var accent: Color = .amber
    var brainName: String = "this brain"

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var questions: [ExamQuestion] = []
    @State private var index = 0
    @State private var typed = ""
    @State private var grade: ExamGrade?
    @State private var grades: [ExamGrade] = []
    @State private var finished = false
    @State private var player = AudioPlayer()
    @State private var clipError: String?

    var body: some View {
        NavigationStack {
            Group {
                if finished {
                    results
                } else if questions.isEmpty {
                    EmptyState(symbol: "graduationcap",
                               title: "Not enough material yet",
                               message: "Add a few lecture recaps with terms or key moments, then try again.")
                } else {
                    questionCard
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(AmbientBackground(tint: accent))
            .navigationTitle("Practice exam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                if questions.isEmpty {
                    questions = ExamBuilder.build(from: recordings, count: 8)
                }
            }
            .onDisappear { player.stop() }
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

    @ViewBuilder
    private var questionCard: some View {
        let q = questions[index]
        VStack(alignment: .leading, spacing: 16) {
            Text("Question \(index + 1) of \(questions.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(q.prompt)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text(q.source)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Your answer", text: $typed, axis: .vertical)
                .lineLimit(3...8)
                .padding(12)
                .background(Color.cardBG, in: RoundedRectangle(cornerRadius: Metric.tile, style: .continuous))
                .disabled(grade != nil)

            if let grade {
                Card(tint: grade.verdict == .pass ? .brand : .orange) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(grade.verdict.title)
                            .font(.subheadline.weight(.semibold))
                        if !grade.because.isEmpty {
                            Text(grade.because)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("From the lecture")
                            .font(.caption.weight(.semibold))
                            .padding(.top, 4)
                        Text(q.answer)
                            .font(.subheadline)
                    }
                }
            }

            HStack(spacing: 10) {
                if grade == nil {
                    Button("Check") { submit() }
                        .buttonStyle(.prominent(accent))
                        .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if index + 1 < questions.count {
                    Button("Next") { advance() }
                        .buttonStyle(.prominent(accent))
                } else {
                    Button("See score") { finished = true }
                        .buttonStyle(.prominent(accent))
                }
            }
            if !q.timestamp.isEmpty {
                Button {
                    Task { await hear(q) }
                } label: {
                    Label("Hear it", systemImage: "waveform")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var results: some View {
        let passed = grades.filter { $0.verdict == .pass }.count
        return VStack(spacing: 18) {
            IconTile(symbol: "graduationcap", tint: accent, size: 56, filled: true)
            Text("\(passed) of \(grades.count)")
                .font(.largeTitle.weight(.semibold))
            Text("from \(brainName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try another set") {
                questions = ExamBuilder.build(from: recordings, count: 8)
                index = 0
                typed = ""
                grade = nil
                grades = []
                finished = false
            }
            .buttonStyle(.prominent(accent))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private func submit() {
        guard questions.indices.contains(index) else { return }
        Haptics.tap()
        let g = ExamBuilder.grade(questions[index], typed: typed)
        grade = g
        grades.append(g)
    }

    private func advance() {
        index += 1
        typed = ""
        grade = nil
        player.stop()
    }

    private func hear(_ q: ExamQuestion) async {
        let hit = ClipSearch.find(query: q.concept.isEmpty ? q.prompt : q.concept, in: recordings)
            ?? recordings.compactMap { rec -> ClipHit? in
                guard let bm = rec.recap?.bookmarks?.first(where: { $0.timestamp == q.timestamp }) else {
                    return nil
                }
                return ClipHit(
                    recordingID: rec.id,
                    title: rec.displayTitle,
                    heading: bm.heading,
                    insight: bm.insight,
                    timestamp: bm.timestamp,
                    start: bm.seconds ?? 0,
                    score: 1,
                    hasAudio: rec.hasAudio
                )
            }.first
        guard let hit, let rec = store.recording(hit.recordingID), rec.hasAudio else {
            clipError = "No audio for that moment."
            return
        }
        do {
            player.load(try await store.audio.ensureLocal(for: rec))
            store.markPlayed(rec.id)
            player.play(from: hit.start)
        } catch {
            clipError = error.localizedDescription
        }
    }
}
