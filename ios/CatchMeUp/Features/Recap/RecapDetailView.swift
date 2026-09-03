import SwiftUI
import UIKit

struct RecapDetailView: View {
    let recordingID: UUID

    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var pipeline = RecapPipeline()
    @State private var player = AudioPlayer()
    @State private var showTranscript = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private var recording: Recording? { store.recording(recordingID) }

    var body: some View {
        Group {
            if let rec = recording {
                content(rec)
            } else {
                ContentUnavailableView("Recap not found", systemImage: "questionmark.folder")
            }
        }
        .background(AmbientBackground(tint: recording?.mode.accent ?? .brand))
        .navigationTitle(recording?.displayTitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: recordingID) { await maybeProcess() }
        .onAppear { loadAudio() }
        .onDisappear { player.stop() }
        .sheet(isPresented: $showTranscript) {
            if let rec = recording {
                TranscriptView(recording: rec) { seconds in
                    showTranscript = false
                    player.play(from: seconds)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ rec: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero(rec)

                if pipeline.isRunning {
                    ProcessingCard(stage: pipeline.stage, tint: rec.mode.accent)
                        .transition(.opacity)
                } else if let err = rec.processingError, rec.recap == nil {
                    errorCard(err)
                }

                if let recap = rec.recap {
                    if rec.mode == .meeting { meetingBody(rec, recap) } else { lectureBody(recap) }
                }

                if !rec.segments.isEmpty { transcriptButton(rec) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .animation(.gentle, value: rec.recap)
        }
        .safeAreaInset(edge: .bottom) {
            if player.isLoaded { playerBar }
        }
    }

    // MARK: - Hero

    private func hero(_ rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.white.opacity(0.22))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: rec.mode.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(rec.mode.title.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(rec.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.95))
                }
                Spacer(minLength: 0)
                if rec.duration > 0 {
                    Text(durationText(rec.duration))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.white.opacity(0.18), in: Capsule())
                }
            }

            Text(rec.displayTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            if let brain = store.brain(rec.brainID) {
                Label(brain.name, systemImage: "brain")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.white.opacity(0.18), in: Capsule())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(rec.mode.gradient)
                .overlay {
                    // faint echo of the icon's constellation
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(RadialGradient(colors: [.white.opacity(0.18), .clear],
                                             center: .topTrailing, startRadius: 0, endRadius: 260))
                }
                .shadow(color: rec.mode.accent.opacity(0.30), radius: 18, y: 8)
        }
    }

    // MARK: - Meeting

    @ViewBuilder
    private func meetingBody(_ rec: Recording, _ r: Recap) -> some View {
        bulletSection("The gist", "sparkles", r.tldr, tint: rec.mode.accent)

        if let items = r.actionItems, !items.isEmpty {
            section("Action items", "checklist", trailing: "\(items.count - rec.completedActions.count) open") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                        let done = rec.completedActions.contains(idx)
                        Button {
                            Haptics.tap()
                            withAnimation(.quick) { store.toggleAction(rec.id, index: idx) }
                        } label: {
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                    .font(.body)
                                    .foregroundStyle(done ? Color.brand : Color.secondary.opacity(0.5))
                                Text(item)
                                    .font(.subheadline)
                                    .strikethrough(done, color: .secondary)
                                    .foregroundStyle(done ? .secondary : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        if idx < items.count - 1 { Divider().opacity(0.4) }
                    }
                }
            }
        }

        bookmarksSection(r.bookmarks)
        notesSection(r.detailedNotes)

        if let sp = r.speakers, !sp.isEmpty {
            section("Who was there", "person.2") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sp) { s in
                        HStack(alignment: .top, spacing: 11) {
                            Circle()
                                .fill(Color.brand.opacity(0.14))
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Text(initials(s))
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Color.brand)
                                }
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
    }

    // MARK: - Lecture

    @ViewBuilder
    private func lectureBody(_ r: Recap) -> some View {
        bulletSection("What you missed", "sparkles", r.tldr, tint: .amber)
        bookmarksSection(r.bookmarks, title: "Key moments")
        notesSection(r.detailedNotes, title: "Notes by topic")

        if let terms = r.terms, !terms.isEmpty {
            section("Terms", "character.book.closed", trailing: "\(terms.count)") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(terms.enumerated()), id: \.element.id) { idx, t in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.term).font(.subheadline.weight(.semibold)).foregroundStyle(Color.amber)
                            Text(t.definition).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                        if idx < terms.count - 1 { Divider().opacity(0.4) }
                    }
                }
            }
        }

        if let study = r.study, !study.isEmpty {
            section("Study checklist", "checkmark.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(study, id: \.self) { s in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "circle").font(.footnote).foregroundStyle(.tertiary)
                            Text(s).font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Shared pieces

    @ViewBuilder
    private func bulletSection(_ title: String, _ symbol: String, _ items: [String]?, tint: Color) -> some View {
        if let items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                SectionHeader(title, symbol: symbol)
                Card(tint: tint) {
                    VStack(alignment: .leading, spacing: 11) {
                        ForEach(items, id: \.self) { b in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(tint).frame(width: 5, height: 5)
                                Text(b)
                                    .font(.subheadline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bookmarksSection(_ marks: [Bookmark]?, title: String = "Jump back in") -> some View {
        if let marks, !marks.isEmpty {
            section(title, "bookmark") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(marks.enumerated()), id: \.element.id) { idx, m in
                        Button {
                            if let s = m.seconds { Haptics.tap(); player.play(from: s) }
                        } label: {
                            HStack(alignment: .top, spacing: 11) {
                                Text(shortStamp(m.timestamp))
                                    .font(.caption2.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Color.brand)
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(Color.brandSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.heading).font(.subheadline.weight(.semibold))
                                    Text(m.insight).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < marks.count - 1 { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func notesSection(_ notes: [DetailNote]?, title: String = "Detailed notes") -> some View {
        if let notes, !notes.isEmpty {
            section(title, "doc.text") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { idx, n in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(n.heading).font(.subheadline.weight(.semibold))
                            Text(n.content)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 9)
                        if idx < notes.count - 1 { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }

    private func section<C: View>(_ title: String, _ symbol: String, trailing: String? = nil,
                                 @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(title: title, symbol: symbol) {
                if let trailing {
                    Text(trailing).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            Card { content() }
        }
    }

    private func transcriptButton(_ rec: Recording) -> some View {
        Button {
            Haptics.tap()
            showTranscript = true
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: "text.quote", tint: .secondary, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full transcript").font(.subheadline.weight(.semibold))
                    Text(player.isLoaded
                         ? "\(rec.segments.count) lines · tap any line to hear it"
                         : "\(rec.segments.count) lines")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(13)
            .background {
                RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                    .fill(Color.cardBG)
                    .overlay { RoundedRectangle(cornerRadius: Metric.card, style: .continuous).strokeBorder(Color.hairline) }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Player

    private var playerBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 14) {
                Button { player.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title3)
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.tap()
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(recording?.mode.accent ?? .brand)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)

                Button { player.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.title3)
                }
                .buttonStyle(.plain)

                VStack(spacing: 3) {
                    Slider(value: Binding(
                        get: { scrubbing ? scrubValue : player.currentTime },
                        set: { scrubValue = $0 }
                    ), in: 0...max(player.duration, 0.1)) { editing in
                        scrubbing = editing
                        if !editing { player.seek(to: scrubValue) }
                    }
                    .tint(recording?.mode.accent ?? .brand)

                    HStack {
                        Text(durationText(scrubbing ? scrubValue : player.currentTime))
                        Spacer()
                        Text("−" + durationText(max(0, player.duration - (scrubbing ? scrubValue : player.currentTime))))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.hairline) }
        .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private func errorCard(_ msg: String) -> some View {
        Card(tint: .orange) {
            VStack(alignment: .leading, spacing: 11) {
                Label("Couldn't finish the notes", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Text(msg).font(.caption).foregroundStyle(.secondary)
                Button("Try again") { Task { await runPipeline() } }
                    .buttonStyle(.prominent(.orange))
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let rec = recording, let recap = rec.recap {
                ShareLink(item: RecapMarkdown.build(rec, recap)) {
                    Image(systemName: "square.and.arrow.up")
                }
                Menu {
                    Button {
                        UIPasteboard.general.string = RecapMarkdown.build(rec, recap)
                        Haptics.success()
                    } label: { Label("Copy as Markdown", systemImage: "doc.on.doc") }

                    Button {
                        Task { await pipeline.rewrite(recordingID: recordingID, store: store, settings: settings) }
                    } label: { Label("Rewrite notes", systemImage: "arrow.clockwise") }

                    Menu("Add to brain") {
                        Button("None") { store.assign(recordingID, toBrain: nil) }
                        ForEach(store.visibleBrains) { b in
                            Button(b.name) { store.assign(recordingID, toBrain: b.id) }
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        store.delete(rec); dismiss()
                    } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Actions

    private func loadAudio() {
        if let rec = recording, let url = store.audioURL(for: rec) { player.load(url) }
    }

    private func maybeProcess() async {
        guard let rec = recording else { return }
        if rec.recap == nil && rec.processingError == nil && !pipeline.isRunning {
            await runPipeline()
        }
    }

    private func runPipeline() async {
        await pipeline.process(recordingID: recordingID, store: store, settings: settings)
        loadAudio()
        if recording?.recap != nil { Haptics.success() }
    }

    private func initials(_ s: SpeakerNote) -> String {
        let source = s.name.isEmpty ? s.label : s.name
        let parts = source.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    /// `00:12:30` → `12:30`, so the chips stay narrow.
    private func shortStamp(_ stamp: String) -> String {
        let parts = stamp.split(separator: ":")
        if parts.count == 3, parts[0] == "00" { return parts.dropFirst().joined(separator: ":") }
        return stamp
    }
}

// MARK: - Processing card

struct ProcessingCard: View {
    let stage: RecapPipeline.Stage
    var tint: Color = .brand

    private let steps: [(String, String)] = [
        ("Transcribing on device", "waveform"),
        ("Writing your notes", "sparkles"),
    ]

    var body: some View {
        Card(tint: tint) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                    HStack(spacing: 11) {
                        icon(for: idx)
                            .frame(width: 22)
                        Text(step.0)
                            .font(.subheadline.weight(idx == current ? .semibold : .regular))
                            .foregroundStyle(idx <= current ? .primary : .secondary)
                        Spacer()
                        if case .transcribing(let p) = stage, idx == 0 {
                            Text("\(Int(p * 100))%")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(tint)
                        }
                    }
                }

                if case .transcribing(let p) = stage {
                    ProgressView(value: p).tint(tint)
                }

                VStack(alignment: .leading, spacing: 7) {
                    ShimmerLine()
                    ShimmerLine(width: 210)
                    ShimmerLine(width: 150)
                }
                .padding(.top, 2)
            }
        }
    }

    private var current: Int {
        switch stage {
        case .transcribing: return 0
        case .writing: return 1
        case .done: return 2
        default: return 0
        }
    }

    @ViewBuilder
    private func icon(for idx: Int) -> some View {
        if idx < current {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(tint)
        } else if idx == current {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}
