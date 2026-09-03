import SwiftUI

struct BrainsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var showNew = false
    @State private var newName = ""
    @State private var newMode: Mode = .lecture

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        @Bindable var router = router

        NavigationStack(path: $router.brainPath) {
            ScrollView {
                if store.visibleBrains.isEmpty {
                    EmptyState(symbol: "brain",
                               title: "No brains yet",
                               message: "A brain is a folder of related recaps you can ask questions across — a course, a client, a project.") {
                        Button("Create a brain") { showNew = true }
                            .buttonStyle(.prominent())
                            .frame(maxWidth: 240)
                    }
                    .padding(.top, 30)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.visibleBrains) { brain in
                            NavigationLink(value: brain.id) {
                                BrainCard(brain: brain, count: store.recordings(inBrain: brain.id).count)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    withAnimation(.quick) { store.delete(brain) }
                                } label: { Label("Delete brain", systemImage: "trash") }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .background(AmbientBackground())
            .navigationTitle("Brains")
            .navigationDestination(for: UUID.self) { id in
                if store.brain(id) != nil {
                    BrainDetailView(brainID: id)
                } else {
                    RecapDetailView(recordingID: id)
                }
            }
            .toolbar {
                Button { showNew = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showNew) { newBrainSheet }
            .sheet(isPresented: Binding(
                get: { router.brainGraphID != nil },
                set: { if !$0 { router.brainGraphID = nil } }
            )) {
                if let id = router.brainGraphID, let brain = store.brain(id) {
                    BrainGraphScreen(brain: brain, recordings: store.recordings(inBrain: id))
                }
            }
        }
    }

    private var newBrainSheet: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. CS 61A, Acme client, Standups", text: $newName)
                }
                Section("Recap style") {
                    Picker("Style", selection: $newMode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("Drop recaps into this brain from any recap's ••• menu, then ask questions that only look inside it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New brain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showNew = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        store.upsert(Brain(name: name, mode: newMode))
                        Haptics.success()
                        newName = ""; showNew = false
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Card

struct BrainCard: View {
    let brain: Brain
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            IconTile(symbol: "brain", tint: brain.mode.accent, size: 40, filled: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(brain.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(count) recap\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Chip(text: brain.mode.title, symbol: brain.mode.symbol, tint: brain.mode.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 152, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                .fill(Color.cardBG)
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                        .strokeBorder(Color.hairline)
                }
                .shadow(color: .black.opacity(0.05), radius: 9, y: 4)
        }
    }
}

// MARK: - Detail

struct BrainDetailView: View {
    let brainID: UUID

    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var question = ""
    @State private var thread: [QAExchange] = []
    @State private var asking = false
    @State private var askError: String?
    @State private var showPersona = false
    @State private var personaDraft = ""
    @State private var showGraph = false

    struct QAExchange: Identifiable, Equatable {
        let id = UUID()
        let question: String
        var answer: String?
    }

    private var brain: Brain? { store.brain(brainID) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let brain {
                        personaCard(brain)
                        neuralMapCard(brain)

                        if thread.isEmpty {
                            starters(brain)
                        } else {
                            conversation
                        }

                        recapsSection
                    }
                }
                .padding(16)
                .padding(.bottom, 8)
            }
            .onChange(of: thread) { _, _ in
                withAnimation(.gentle) { proxy.scrollTo(thread.last?.id, anchor: .bottom) }
            }
        }
        .background(AmbientBackground(tint: brain?.mode.accent ?? .brand))
        .navigationTitle(brain?.name ?? "Brain")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { composer }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { personaDraft = brain?.persona ?? ""; showPersona = true } label: {
                        Label("Edit persona", systemImage: "theatermasks")
                    }
                    if !thread.isEmpty {
                        Button(role: .destructive) { withAnimation(.quick) { thread = [] } } label: {
                            Label("Clear conversation", systemImage: "eraser")
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showPersona) { personaSheet }
        .sheet(isPresented: $showGraph) {
            if let brain {
                BrainGraphScreen(brain: brain, recordings: store.recordings(inBrain: brainID))
            }
        }
    }

    // MARK: Persona

    @ViewBuilder
    private func personaCard(_ brain: Brain) -> some View {
        if !brain.persona.isEmpty {
            HStack(alignment: .top, spacing: 11) {
                IconTile(symbol: "theatermasks", tint: brain.mode.accent, size: 34)
                Text(brain.persona)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(brain.mode.accent.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: Metric.tile, style: .continuous))
        }
    }

    private var personaSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("How should this brain think and answer?",
                              text: $personaDraft, axis: .vertical)
                        .lineLimit(4...10)
                } header: {
                    Text("Persona")
                } footer: {
                    Text("Example: “Answer like my TA — short, concrete, and always tie back to the lecture it came from.”")
                }
            }
            .navigationTitle("Persona")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showPersona = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if var b = brain { b.persona = personaDraft; store.upsert(b) }
                        showPersona = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: Conversation

    private func neuralMapCard(_ brain: Brain) -> some View {
        let graph = BrainGraph.build(from: store.recordings(inBrain: brainID))
        return Button {
            Haptics.tap()
            showGraph = true
        } label: {
            HStack(spacing: 13) {
                MiniBrainGraph(graph: graph, tint: brain.mode.accent)
                    .frame(width: 78, height: 58)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Neural map")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(graph.nodes.isEmpty
                         ? "Add recaps to grow this brain"
                         : "\(graph.nodes.count) concepts · \(graph.edges.count) connections")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(13)
            .background(Color.cardBG,
                        in: RoundedRectangle(cornerRadius: Metric.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                    .strokeBorder(Color.hairline)
            }
        }
        .buttonStyle(.plain)
        .disabled(graph.nodes.isEmpty)
    }

    @ViewBuilder
    private func starters(_ brain: Brain) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Try asking", symbol: "sparkles")
            VStack(spacing: 8) {
                ForEach(starterQuestions(brain), id: \.self) { s in
                    Button {
                        question = s
                        Task { await ask() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "text.bubble")
                                .font(.footnote)
                                .foregroundStyle(brain.mode.accent)
                            Text(s).font(.subheadline).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(13)
                        .background(Color.cardBG, in: RoundedRectangle(cornerRadius: Metric.tile, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Metric.tile, style: .continuous)
                                .strokeBorder(Color.hairline)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func starterQuestions(_ brain: Brain) -> [String] {
        brain.mode == .lecture
            ? ["What are the big ideas so far?",
               "Make me a study plan for what's covered here.",
               "Which terms keep coming up?"]
            : ["What's still open across these meetings?",
               "Summarise the decisions we've made.",
               "What did I commit to?"]
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(thread) { ex in
                VStack(alignment: .trailing, spacing: 10) {
                    Text(ex.question)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background((brain?.mode.accent ?? .brand).gradient,
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    if let answer = ex.answer {
                        Card {
                            Text(answer)
                                .font(.subheadline)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                ShimmerLine()
                                ShimmerLine(width: 220)
                                ShimmerLine(width: 160)
                            }
                        }
                    }
                }
                .id(ex.id)
            }

            if let askError {
                Label(askError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Recaps

    private var recapsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let recs = store.recordings(inBrain: brainID)
            SectionHeader(title: "In this brain", symbol: "tray.full") {
                Text("\(recs.count)").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if recs.isEmpty {
                Card {
                    Text("Empty for now. Open any recap and choose ••• ▸ Add to brain.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(recs.enumerated()), id: \.element.id) { idx, rec in
                    NavigationLink(value: rec.id) {
                        RecapRow(recording: rec, brainName: nil,
                                 isFirst: idx == 0, isLast: idx == recs.count - 1)
                    }
                    .buttonStyle(ThreadRowStyle(tint: rec.mode.accent))
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        FloatingControlShelf(contentPadding: 8) {
            HStack(spacing: 9) {
                TextField("Ask across these recaps…", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.cardBG, in: Capsule())
                    .overlay { Capsule().strokeBorder(Color.hairline) }

                Button {
                    Task { await ask() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background((brain?.mode.accent ?? .brand).gradient, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(asking || question.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
            }
        }
    }

    // MARK: Ask

    private func ask() async {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let brain else { return }

        let recs = store.recordings(inBrain: brainID)
        guard !recs.isEmpty else { askError = "This brain has no recaps yet."; return }

        question = ""
        askError = nil
        asking = true
        Haptics.tap()
        let exchange = QAExchange(question: q, answer: nil)
        withAnimation(.quick) { thread.append(exchange) }
        defer { asking = false }

        let context = recs.prefix(12).map { rec -> String in
            var s = "## \(rec.displayTitle)\n"
            if let t = rec.recap?.tldr { s += t.map { "- \($0)" }.joined(separator: "\n") + "\n" }
            if let n = rec.recap?.detailedNotes {
                s += n.map { "\($0.heading): \($0.content)" }.joined(separator: "\n") + "\n"
            }
            return s
        }.joined(separator: "\n\n")

        let engine = RecapEngineFactory.make(settings)
        do {
            let answer = try await engine.answer(question: q, persona: brain.persona,
                                                 context: String(context.prefix(14000)))
            if let i = thread.firstIndex(where: { $0.id == exchange.id }) {
                withAnimation(.gentle) { thread[i].answer = answer }
            }
        } catch {
            thread.removeAll { $0.id == exchange.id }
            askError = error.localizedDescription
            Haptics.warning()
        }
    }
}
