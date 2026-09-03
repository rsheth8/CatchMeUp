import SwiftUI
import UniformTypeIdentifiers

// The library reads as one continuous thread — the same idea as the app icon.
// Each recap is a node on the rail; the newest one is lit, the way the icon's
// middle node marks the moment you're caught up to.

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, meetings, lectures, attention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .meetings: return "Meetings"
        case .lectures: return "Lectures"
        case .attention: return "Needs you"
        }
    }

    var tint: Color {
        switch self {
        case .all, .meetings: return .brand
        case .lectures: return .amber
        case .attention: return .orange
        }
    }

    func matches(_ r: Recording) -> Bool {
        switch self {
        case .all: return true
        case .meetings: return r.mode == .meeting
        case .lectures: return r.mode == .lecture
        case .attention: return r.needsAttention || !r.isProcessed
        }
    }
}

struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var path: [UUID] = []
    @State private var showRecorder = false
    @State private var showImporter = false
    @State private var query = ""
    @State private var filter: LibraryFilter = .all
    @State private var renameTarget: Recording?
    @State private var renameText = ""

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.sortedRecordings.isEmpty {
                    emptyLibrary
                } else {
                    thread
                }
            }
            .background(AmbientBackground())
            .navigationTitle("Recaps")
            .navigationDestination(for: UUID.self) { RecapDetailView(recordingID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        showImporter = true
                    } label: {
                        Image(systemName: "waveform.badge.plus")
                    }
                    .accessibilityLabel("Add a file")
                }
            }
            // Reserve the room first, then paint the scrim + button over the
            // whole bottom edge — so content dissolves rather than colliding.
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 120) }
            .overlay(alignment: .bottom) { bottomBar }
            .fullScreenCover(isPresented: $showRecorder) {
                RecordView(initialMode: settings.defaultMode) { newID in
                    showRecorder = false
                    path.append(newID)
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav,
                                                .mpeg4Movie, .movie, .quickTimeMovie],
                          allowsMultipleSelection: false) { handleImport($0) }
            .alert("Rename recap", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) { renameTarget = nil }
                Button("Save") {
                    if let t = renameTarget { store.rename(t.id, to: renameText) }
                    renameTarget = nil
                }
            }
        }
    }

    // MARK: - The thread

    private var thread: some View {
        List {
            if !settings.isReady { readinessRow }

            headerRow

            if buckets.isEmpty {
                noResults
            } else {
                ForEach(Array(buckets.enumerated()), id: \.element.title) { bucketIdx, bucket in
                    Section {
                        ForEach(bucket.items) { rec in
                            Button { path.append(rec.id) } label: {
                                RecapRow(recording: rec,
                                         brainName: store.brain(rec.brainID)?.name,
                                         isLit: rec.id == latestID,
                                         // first/last of the whole thread, so the
                                         // rail runs unbroken across chapters
                                         isFirst: rec.id == filtered.first?.id,
                                         isLast: rec.id == filtered.last?.id)
                            }
                            .buttonStyle(ThreadRowStyle(tint: rec.mode.accent))
                            .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    withAnimation(.quick) { store.delete(rec) }
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                            .contextMenu { rowMenu(rec) }
                        }
                    } header: {
                        ChapterHeader(title: bucket.title, showsRail: bucketIdx > 0)
                            .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
                    }
                }
            }

            Color.clear
                .frame(height: 6)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .listSectionSpacing(0)          // the chapter header carries its own air
        .scrollContentBackground(.hidden)
        .searchable(text: $query, prompt: "Search titles and notes")
        .animation(.quick, value: filter)
    }

    // MARK: - Header (summary + filters)

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if showsFilters {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(visibleFilters) { f in
                            filterPill(f)
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .padding(.horizontal, -18)
            }
        }
        .padding(.bottom, 4)
        .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 8, trailing: 18))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func filterPill(_ f: LibraryFilter) -> some View {
        let isOn = filter == f
        return Button {
            Haptics.tap()
            withAnimation(.quick) { filter = f }
        } label: {
            Text(f.title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 6.5)
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .background {
                    Capsule().fill(isOn
                                   ? AnyShapeStyle(f.tint.gradient)
                                   : AnyShapeStyle(Color.primary.opacity(0.055)))
                }
        }
        .buttonStyle(.plain)
    }

    private var readinessRow: some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Finish setup").font(.subheadline.weight(.semibold))
                Text(settings.readinessHint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Metric.tile, style: .continuous))
        .listRowInsets(EdgeInsets(top: 2, leading: 18, bottom: 10, trailing: 18))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var noResults: some View {
        EmptyState(symbol: "magnifyingglass",
                   title: "Nothing here",
                   message: query.isEmpty
                        ? "No recaps match this filter yet."
                        : "No recap mentions “\(query)”.")
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var emptyLibrary: some View {
        ScrollView {
            VStack(spacing: 26) {
                BrandMark(size: 116, animated: true)
                    .padding(.top, 40)
                VStack(spacing: 8) {
                    Text("Catch up on what you missed")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("Record a meeting or a lecture — or add a file you already have — and CatchMeUp writes the notes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
                Button("Load two sample recaps") {
                    Haptics.tap()
                    withAnimation(.gentle) { store.seedSampleIfEmpty() }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.top, 2)
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Record button
    //
    // A single floating pill rather than a full-width bar, so it doesn't stack
    // up against the tab bar. The fade above it dissolves scrolling content.

    private var bottomBar: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: Color.groupBG.opacity(0), location: 0),
                    .init(color: Color.groupBG, location: 0.55),
                    .init(color: Color.groupBG, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 140)
            .allowsHitTesting(false)

            recordButton
        }
    }

    private var recordButton: some View {
        Button {
            Haptics.tap(.medium)
            showRecorder = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "mic.fill")
                Text("Record")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 30)
            .frame(height: 54)
            .background(
                LinearGradient(colors: [.brandLight, .brand],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Capsule()
            )
            .shadow(color: Color.brand.opacity(0.38), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 16)
    }

    // MARK: - Row menu

    @ViewBuilder
    private func rowMenu(_ rec: Recording) -> some View {
        Button {
            renameText = rec.displayTitle
            renameTarget = rec
        } label: { Label("Rename", systemImage: "pencil") }

        Menu("Add to brain") {
            Button("None") { store.assign(rec.id, toBrain: nil) }
            ForEach(store.visibleBrains) { b in
                Button(b.name) { store.assign(rec.id, toBrain: b.id) }
            }
        }

        if let recap = rec.recap {
            ShareLink(item: RecapMarkdown.build(rec, recap)) {
                Label("Share notes", systemImage: "square.and.arrow.up")
            }
        }

        Button(role: .destructive) {
            withAnimation(.quick) { store.delete(rec) }
        } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: - Data

    private struct Bucket { let title: String; let items: [Recording] }

    private var filtered: [Recording] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return store.sortedRecordings.filter { rec in
            filter.matches(rec) && (q.isEmpty || rec.searchBlob.localizedCaseInsensitiveContains(q))
        }
    }

    private var latestID: UUID? { store.sortedRecordings.first?.id }

    private var buckets: [Bucket] {
        let cal = Calendar.current
        var today: [Recording] = [], week: [Recording] = [], earlier: [Recording] = []
        let weekAgo = cal.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        for r in filtered {
            if cal.isDateInToday(r.createdAt) { today.append(r) }
            else if r.createdAt > weekAgo { week.append(r) }
            else { earlier.append(r) }
        }
        return [Bucket(title: "Today", items: today),
                Bucket(title: "Past week", items: week),
                Bucket(title: "Earlier", items: earlier)]
            .filter { !$0.items.isEmpty }
    }

    private var summary: String {
        let all = store.sortedRecordings
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        let recent = all.filter { $0.createdAt > weekAgo }.count
        let total = "\(all.count) recap\(all.count == 1 ? "" : "s")"
        return recent > 0 ? "\(total) · \(recent) this week" : total
    }

    private var visibleFilters: [LibraryFilter] {
        LibraryFilter.allCases.filter { f in
            f != .attention || store.sortedRecordings.contains(where: LibraryFilter.attention.matches)
        }
    }

    private var showsFilters: Bool {
        store.sortedRecordings.count > 3 || filter != .all
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard let filename = store.importAudio(from: url, preferredName: url.lastPathComponent) else { return }
        let rec = Recording(title: url.deletingPathExtension().lastPathComponent,
                            mode: Mode.guess(fromFilename: url.lastPathComponent),
                            audioFilename: filename)
        store.upsert(rec)
        Haptics.success()
        path.append(rec.id)
    }
}

// MARK: - Chapter header

struct ChapterHeader: View {
    let title: String
    /// The thread runs on through every chapter break but the first.
    var showsRail: Bool

    var body: some View {
        HStack(spacing: 15) {
            Rectangle()
                .fill(showsRail ? Color.primary.opacity(0.10) : .clear)
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
                .frame(width: 26)

            HStack(spacing: 10) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(.tertiary)
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
            }
        }
        .frame(height: 44)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

// MARK: - Row press feedback

struct ThreadRowStyle: ButtonStyle {
    var tint: Color = .brand

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.09 : 0))
                    .padding(.horizontal, -10)
            }
            .animation(.quick, value: configuration.isPressed)
    }
}

// MARK: - Row

struct RecapRow: View {
    let recording: Recording
    var brainName: String?
    /// The newest recap in the library — drawn as the lit node.
    var isLit = false
    var isFirst = true
    var isLast = true

    @State private var pulse = false

    private var nodeSize: CGFloat { isLit ? 26 : 11 }
    private var railTop: CGFloat { isLit ? 1 : 8 }
    private var rail: Color { Color.primary.opacity(0.10) }

    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            spine
            VStack(alignment: .leading, spacing: 5) {
                titleLine
                secondary
                meta
            }
            .padding(.vertical, 13)
        }
        .contentShape(Rectangle())
    }

    // MARK: Spine

    private var spine: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFirst ? Color.clear : rail)
                .frame(width: 1.5, height: railTop + 13)
            node
            Rectangle()
                .fill(isLast ? Color.clear : rail)
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 26)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var node: some View {
        if isLit {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(recording.mode.gradient)
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: recording.mode.accent.opacity(0.40), radius: 7, y: 2)
        } else if recording.needsAttention {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(Color.orange)
                .frame(width: nodeSize, height: nodeSize)
        } else if !recording.isProcessed {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .strokeBorder(recording.mode.accent, lineWidth: 2)
                .frame(width: nodeSize, height: nodeSize)
                .opacity(pulse ? 0.3 : 1)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
        } else {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(recording.mode.accent.opacity(0.85))
                .frame(width: nodeSize, height: nodeSize)
        }
    }

    // MARK: Content

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(recording.displayTitle)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if recording.duration > 0 {
                Text(durationText(recording.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var secondary: some View {
        if recording.needsAttention {
            Label("Couldn't finish the notes — tap to retry", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .lineLimit(2)
        } else if !recording.isProcessed {
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text("Writing your notes…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let gist = recording.recap?.tldr?.first, !gist.isEmpty {
            Text(gist)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    private var meta: some View {
        HStack(spacing: 5) {
            Text(recording.mode.title)
                .fontWeight(.semibold)
                .foregroundStyle(recording.mode.accent)
            Text("·")
            Text(recording.createdAt.libraryStamp)
            if let brainName {
                Text("·")
                Image(systemName: "brain").imageScale(.small)
                Text(brainName).lineLimit(1)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.top, 1)
    }
}
