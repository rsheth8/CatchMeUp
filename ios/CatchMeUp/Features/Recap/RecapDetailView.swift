import SwiftUI

struct RecapDetailView: View {
    let recordingID: UUID

    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var pipeline = RecapPipeline()
    @State private var player = AudioPlayer()
    @State private var showTranscript = false

    private var recording: Recording? { store.recording(recordingID) }

    var body: some View {
        Group {
            if let rec = recording {
                content(rec)
            } else {
                ContentUnavailableView("Recap not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: recordingID) { await maybeProcess() }
        .onAppear {
            if let rec = recording, let url = store.audioURL(for: rec) { player.load(url) }
        }
        .onDisappear { player.stop() }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ rec: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(rec)

                if pipeline.isRunning {
                    ProcessingCard(stage: pipeline.stage)
                } else if let err = rec.processingError, rec.recap == nil {
                    errorCard(err)
                }

                if let recap = rec.recap {
                    if rec.mode == .meeting {
                        meetingBody(recap)
                    } else {
                        lectureBody(recap)
                    }
                }

                if !rec.segments.isEmpty {
                    transcriptDisclosure(rec)
                }
            }
            .padding(16)
        }
        .background(Color.groupBG)
        .safeAreaInset(edge: .bottom) {
            if player.isPlaying { playerBar }
        }
    }

    private func header(_ rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rec.displayTitle).font(.title2.bold())
            HStack(spacing: 8) {
                Pill(text: rec.mode.title, symbol: rec.mode.symbol, tint: rec.mode.accent)
                Text(rec.createdAt.formatted(date: .abbreviated, time: .shortened))
                if rec.duration > 0 { Text("· \(durText(rec.duration))") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Meeting

    @ViewBuilder
    private func meetingBody(_ r: Recap) -> some View {
        bulletCard("TL;DR", "text.line.first.and.arrowtriangle.forward", r.tldr)

        if let items = r.actionItems, !items.isEmpty {
            section("Action items", "checklist") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items, id: \.self) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "square").foregroundStyle(.tertiary)
                            Text(item).font(.subheadline)
                        }
                    }
                }
            }
        }

        bookmarksSection(r.bookmarks)
        notesSection(r.detailedNotes)

        if let sp = r.speakers, !sp.isEmpty {
            section("Who was there", "person.2") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sp) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text([s.label, s.name].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.subheadline.weight(.semibold))
                            Text(s.said).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Lecture

    @ViewBuilder
    private func lectureBody(_ r: Recap) -> some View {
        bulletCard("What you missed", "sparkles", r.tldr)
        bookmarksSection(r.bookmarks, title: "Key moments")
        notesSection(r.detailedNotes, title: "Notes by topic")

        if let terms = r.terms, !terms.isEmpty {
            section("Terms", "character.book.closed") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(terms) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.term).font(.subheadline.weight(.semibold))
                            Text(t.definition).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        if let study = r.study, !study.isEmpty {
            section("Study checklist", "checkmark.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(study, id: \.self) { s in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                            Text(s).font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    // MARK: Shared pieces

    private func bulletCard(_ title: String, _ symbol: String, _ items: [String]?) -> some View {
        Group {
            if let items, !items.isEmpty {
                section(title, symbol) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items, id: \.self) { b in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(Color.brand).frame(width: 5, height: 5).padding(.top, 7)
                                Text(b).font(.subheadline)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bookmarksSection(_ marks: [Bookmark]?, title: String = "Bookmarks") -> some View {
        if let marks, !marks.isEmpty {
            section(title, "bookmark") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(marks) { m in
                        Button {
                            if let s = m.seconds { player.play(from: s) }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text(m.timestamp)
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(Color.brand)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.brandSoft, in: RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.heading).font(.subheadline.weight(.semibold))
                                    Text(m.insight).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "play.circle").foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func notesSection(_ notes: [DetailNote]?, title: String = "Detailed notes") -> some View {
        if let notes, !notes.isEmpty {
            section(title, "doc.text") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(notes) { n in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(n.heading).font(.subheadline.weight(.semibold))
                            Text(n.content).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func section<C: View>(_ title: String, _ symbol: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title, symbol: symbol)
            Card { content() }
        }
    }

    private func transcriptDisclosure(_ rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { showTranscript.toggle() }
            } label: {
                HStack {
                    SectionLabel(text: "Transcript", symbol: "text.quote")
                    Spacer()
                    Image(systemName: showTranscript ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showTranscript {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rec.segments) { seg in
                            Button { player.play(from: seg.start) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text(seg.stamp)
                                        .font(.caption2.monospacedDigit()).foregroundStyle(Color.brand)
                                    Text(seg.speaker.map { "\($0): \(seg.text)" } ?? seg.text)
                                        .font(.caption).foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var playerBar: some View {
        HStack(spacing: 12) {
            Button { player.pause() } label: {
                Image(systemName: "pause.circle.fill").font(.title)
            }
            Text(Segment.hms(player.currentTime)).font(.caption.monospacedDigit())
            ProgressView(value: player.duration > 0 ? player.currentTime / player.duration : 0)
                .tint(.brand)
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func errorCard(_ msg: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Couldn't finish the notes", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Text(msg).font(.caption).foregroundStyle(.secondary)
                Button("Try again") { Task { await runPipeline() } }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let rec = recording, let recap = rec.recap {
                ShareLink(item: RecapMarkdown.build(rec, recap)) {
                    Image(systemName: "square.and.arrow.up")
                }
                Menu {
                    Button {
                        Task { await pipeline.rewrite(recordingID: recordingID, store: store, settings: settings) }
                    } label: { Label("Rewrite notes", systemImage: "arrow.clockwise") }

                    Menu("Add to brain") {
                        Button("None") { store.assign(recordingID, toBrain: nil) }
                        ForEach(store.brains) { b in
                            Button(b.name) { store.assign(recordingID, toBrain: b.id) }
                        }
                    }
                    Button(role: .destructive) {
                        store.delete(rec); dismiss()
                    } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: Actions

    private func maybeProcess() async {
        guard let rec = recording else { return }
        if rec.recap == nil && rec.processingError == nil && !pipeline.isRunning {
            await runPipeline()
        }
    }

    private func runPipeline() async {
        await pipeline.process(recordingID: recordingID, store: store, settings: settings)
        if let rec = recording, let url = store.audioURL(for: rec) { player.load(url) }
    }

    private func durText(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s/3600, (s%3600)/60, s%60)
            : String(format: "%d:%02d", s/60, s%60)
    }
}

// MARK: - Processing card

struct ProcessingCard: View {
    let stage: RecapPipeline.Stage

    private var steps: [(String, String)] {
        [("Transcribing on device", "waveform"), ("Writing your notes", "sparkles")]
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                    HStack(spacing: 10) {
                        icon(for: idx)
                        Text(step.0).font(.subheadline)
                        Spacer()
                        if case .transcribing(let p) = stage, idx == 0 {
                            Text("\(Int(p * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func idxOfStage() -> Int {
        switch stage {
        case .transcribing: return 0
        case .writing: return 1
        case .done: return 2
        default: return 0
        }
    }

    @ViewBuilder
    private func icon(for idx: Int) -> some View {
        let current = idxOfStage()
        if idx < current {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.brand)
        } else if idx == current {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}
