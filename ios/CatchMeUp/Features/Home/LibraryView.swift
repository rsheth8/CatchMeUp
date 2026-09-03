import SwiftUI
import UniformTypeIdentifiers

// The library is the app's home: your recaps first, one obvious way to make
// another. Mode is chosen when you record, not before.

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

    var symbol: String? {
        switch self {
        case .all: return nil
        case .meetings: return "person.2.wave.2"
        case .lectures: return "graduationcap"
        case .attention: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .all: return .brand
        case .meetings: return .brand
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
                    list
                }
            }
            .background(AmbientBackground())
            .navigationTitle("Recaps")
            .navigationDestination(for: UUID.self) { RecapDetailView(recordingID: $0) }
            .safeAreaInset(edge: .bottom) { actionBar }
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

    // MARK: - List

    private var list: some View {
        List {
            if !settings.isReady { readinessBanner }

            if store.sortedRecordings.count > 3 || filter != .all {
                filterRow
            }

            if buckets.isEmpty {
                noResults
            } else {
                ForEach(buckets, id: \.title) { bucket in
                    Section {
                        ForEach(bucket.items) { rec in
                            Button { path.append(rec.id) } label: {
                                RecapRow(recording: rec, brainName: store.brain(rec.brainID)?.name)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
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
                        Text(bucket.title)
                            .font(.caption.weight(.semibold))
                            .tracking(0.7)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                    .listSectionSeparator(.hidden)
                }
            }

            Color.clear
                .frame(height: 76)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $query, prompt: "Search titles and notes")
        .animation(.quick, value: filter)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { f in
                    if f != .attention || store.sortedRecordings.contains(where: LibraryFilter.attention.matches) {
                        FilterChip(title: f.title, symbol: f.symbol,
                                   isOn: filter == f, tint: f.tint) { filter = f }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var readinessBanner: some View {
        HStack(spacing: 11) {
            IconTile(symbol: "exclamationmark", tint: .orange, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Finish setup").font(.subheadline.weight(.semibold))
                Text(settings.readinessHint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Metric.tile, style: .continuous))
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
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

    // MARK: - Bottom action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.tap()
                showImporter = true
            } label: {
                Image(systemName: "waveform.badge.plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 52, height: 52)
                    .background(.regularMaterial, in: Circle())
                    .overlay { Circle().strokeBorder(Color.hairline) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a file")

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
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    LinearGradient(colors: [.brandLight, .brand],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Capsule()
                )
                .shadow(color: Color.brand.opacity(0.35), radius: 16, y: 7)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background {
            LinearGradient(colors: [Color.groupBG.opacity(0), Color.groupBG.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
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

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard let filename = store.importAudio(from: url, preferredName: url.lastPathComponent) else { return }
        let guessed = Mode.guess(fromFilename: url.lastPathComponent)
        let rec = Recording(title: url.deletingPathExtension().lastPathComponent,
                            mode: guessed,
                            audioFilename: filename)
        store.upsert(rec)
        Haptics.success()
        path.append(rec.id)
    }
}

// MARK: - Row

struct RecapRow: View {
    let recording: Recording
    var brainName: String?

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                IconTile(symbol: recording.mode.symbol, tint: recording.mode.accent, size: 46)
                if !recording.isProcessed && !recording.needsAttention {
                    Circle()
                        .strokeBorder(recording.mode.accent.opacity(0.5), lineWidth: 2)
                        .frame(width: 52, height: 52)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 5) {
                    Text(recording.createdAt.libraryStamp)
                    if recording.duration > 0 {
                        Text("·"); Text(durationText(recording.duration)).monospacedDigit()
                    }
                    if let brainName {
                        Text("·")
                        Label(brainName, systemImage: "brain")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if recording.needsAttention {
                    Chip(text: "Needs attention", symbol: "exclamationmark.triangle.fill", tint: .orange)
                } else if !recording.isProcessed {
                    Chip(text: "Writing notes…", symbol: "sparkles", tint: recording.mode.accent)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(13)
        .background {
            RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                .fill(Color.cardBG)
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                        .strokeBorder(Color.hairline)
                }
                .shadow(color: .black.opacity(0.045), radius: 8, y: 3)
        }
        .contentShape(RoundedRectangle(cornerRadius: Metric.card, style: .continuous))
    }
}
