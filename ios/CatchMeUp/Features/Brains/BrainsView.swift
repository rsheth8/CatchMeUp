import SwiftUI

struct BrainsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(MaterialStore.self) private var materials
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
                    brainsGrid
                }
            }
            .background(AmbientBackground())
            .navigationTitle("Brains")
            .navigationDestination(for: UUID.self) { id in
                if store.brain(id) != nil {
                    BrainDetailView(brainID: id)
                } else if store.recording(id) != nil {
                    // This stack carries recap IDs too — pushed after a
                    // recording made from inside a brain.
                    RecapDetailView(recordingID: id)
                } else {
                    // A link that outlived what it pointed at: a notification
                    // or widget for something deleted since. It used to land
                    // on "Recap not found" even when the missing thing was a
                    // brain, which names the wrong noun.
                    ContentUnavailableView("This is no longer here",
                                           systemImage: "questionmark.folder")
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

    @ViewBuilder
    private var brainsGrid: some View {
        let courses = store.visibleBrains.filter { $0.mode == .lecture }
        let work = store.visibleBrains.filter { $0.mode == .meeting }
        let split = !courses.isEmpty && !work.isEmpty

        LazyVGrid(columns: columns, spacing: 12) {
            if split {
                // A header is the only thing LazyVGrid lays out across the full
                // width. Emitting the label as a plain child makes it a cell —
                // it takes the first column and shoves the first card into the
                // second, leaving a hole where a card should be.
                Section {
                    ForEach(courses) { brainCard($0) }
                } header: {
                    sectionLabel(Mode.lecture.brainKindSection)
                }
                Section {
                    ForEach(work) { brainCard($0) }
                } header: {
                    sectionLabel(Mode.meeting.brainKindSection)
                }
            } else {
                ForEach(store.visibleBrains) { brainCard($0) }
            }
        }
        .padding(16)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private func brainCard(_ brain: Brain) -> some View {
        NavigationLink(value: brain.id) {
            BrainCard(brain: brain,
                      recapCount: store.recordings(inBrain: brain.id).count,
                      materialCount: materials.materials(inBrain: brain.id).count)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                withAnimation(.quick) { store.delete(brain) }
            } label: { Label("Delete brain", systemImage: "trash") }
        }
    }

    private var newBrainSheet: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. CS 61A, Acme client, Standups", text: $newName)
                }
                Section("This is") {
                    Picker("Kind", selection: $newMode) {
                        Text("A course").tag(Mode.lecture)
                        Text("Work").tag(Mode.meeting)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("Drop recaps into this brain from any recap's ••• menu, then ask questions that only look inside it. New recordings started here inherit this kind.")
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
    let recapCount: Int
    let materialCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            IconTile(symbol: "brain", tint: brain.mode.accent, size: 40, filled: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(brain.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(sourceCount)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Chip(text: brain.mode.brainKindTitle, symbol: brain.mode.symbol, tint: brain.mode.accent)
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

    private var sourceCount: String {
        let recaps = "\(recapCount) recap\(recapCount == 1 ? "" : "s")"
        guard materialCount > 0 else { return recaps }
        return "\(recaps) · \(materialCount) material\(materialCount == 1 ? "" : "s")"
    }
}

// MARK: - Detail

struct BrainDetailView: View {
    let brainID: UUID

    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(ProcessingQueue.self) private var queue
    @Environment(AppRouter.self) private var router
    @Environment(StudyStore.self) private var study
    @Environment(MaterialStore.self) private var materials

    @State private var question = ""
    @State private var thread: [QAExchange] = []
    @State private var asking = false
    @State private var askError: String?
    @State private var showPersona = false
    @State private var personaDraft = ""
    @State private var showGraph = false
    @State private var showClip = false

    struct QAExchange: Identifiable, Equatable {
        let id = UUID()
        let question: String
        var answer: String?
        var error: String?
        /// The recaps retrieval actually put in front of the model. Citations
        /// are matched against these rather than the whole brain, so a chip
        /// can't point at a recap the model never read.
        var sources: [Recording] = []
        var materialSources: [SupplementalMaterial] = []
        /// The brain held more matching material than the context budget fit.
        var clipped = false
    }

    private var brain: Brain? { store.brain(brainID) }
    private var accent: Color { brain?.mode.accent ?? .brand }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let brain {
                        personaCard(brain)
                        BrainKnowledgeCard(brainID: brain.id, tint: brain.mode.accent)
                        neuralMapCard(brain)
                        if brain.mode == .meeting {
                            MeetingPreparationCard(recording: Recording(title: "Next \(brain.name) meeting", mode: .meeting, brainID: brain.id))
                            Button {
                                question = "How have decisions changed across these meetings? Distinguish proposals from agreed decisions, include dates and sources, and flag unresolved conflicts."
                                Task { await ask() }
                            } label: { Label("Compare decisions across meetings", systemImage: "clock.arrow.circlepath") }
                        } else { studyTools(brain) }

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
                Button {
                    guard let brain else { return }
                    Haptics.tap()
                    router.recorderMode = brain.mode
                    router.recorderBrainID = brain.id
                } label: {
                    Image(systemName: "mic.fill")
                }
                .accessibilityLabel("Record into this brain")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { personaDraft = brain?.persona ?? ""; showPersona = true } label: {
                        Label("Edit persona", systemImage: "theatermasks")
                    }
                    Button { openStudy() } label: {
                        Label("Study this brain", systemImage: "graduationcap")
                    }
                    .disabled(study.items(inBrain: brainID).isEmpty)
                    Button { showClip = true } label: {
                        Label("Hear a concept", systemImage: "waveform")
                    }
                    .disabled(store.recordings(inBrain: brainID).isEmpty)
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
        .sheet(isPresented: $showClip) {
            ClipSheet(recordings: store.recordings(inBrain: brainID), accent: accent)
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
        let graph = BrainGraph.build(from: store.recordings(inBrain: brainID),
                                     materials: materials.materials(inBrain: brainID))
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
                         ? "Add recordings or material to grow this brain"
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

    private func studyTools(_ brain: Brain) -> some View {
        let recs = store.recordings(inBrain: brainID)
        let questions = study.items(inBrain: brainID).count
        return HStack(spacing: 10) {
            // A shortcut, not a second engine: there is one question bank and one
            // schedule, and both live in the Study tab. A brain-local exam that
            // forgot what you got wrong would quietly undo the scheduling — so
            // this hands the brain over to the tab that remembers.
            studyTool(symbol: "graduationcap", title: "Study",
                      subtitle: studySubtitle(questions: questions),
                      enabled: questions > 0) { openStudy() }
            studyTool(symbol: "waveform", title: "Clip",
                      subtitle: recs.isEmpty ? "Needs recaps" : "Jump to the audio",
                      enabled: !recs.isEmpty) { showClip = true }
        }
    }

    private func studySubtitle(questions: Int) -> String {
        guard questions > 0 else { return "Needs recaps" }
        let due = study.todayCount(brainID: brainID, newLimit: settings.dailyNewLimit)
        return due > 0 ? "\(due) waiting" : "\(questions) questions"
    }

    /// Scoped through the same deep link a reminder uses, so the tab lands
    /// filtered to this brain by exactly one code path.
    private func openStudy() {
        router.open(CatchMeUpLink.study(brain: brainID))
    }

    private func studyTool(symbol: String, title: String, subtitle: String,
                           enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                IconTile(symbol: symbol, tint: accent, size: 36)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBG, in: RoundedRectangle(cornerRadius: Metric.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                    .strokeBorder(Color.hairline)
            }
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
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
        var questions: [String]
        if brain.mode == .lecture {
            questions = ["What are the big ideas so far?",
                         "Make me a study plan for what's covered here.",
                         "Which terms keep coming up?"]
            let recs = store.recordings(inBrain: brain.id)
            if recs.contains(where: { $0.recap?.hasCommitments == true }) {
                questions.append("What's still open in this class?")
            }
        } else {
            questions = ["What's still open across these meetings?",
                         "Summarise the decisions we've made.",
                         "What did I commit to?"]
            let recs = store.recordings(inBrain: brain.id)
            if recs.contains(where: { $0.recap?.hasKnowledge == true }) {
                questions.append("What should I remember from the material that came up?")
            }
        }
        return questions
    }

    private var conversation: some View {
        let recaps = store.recordings(inBrain: brainID)

        return VStack(alignment: .leading, spacing: 22) {
            ForEach(thread) { ex in
                VStack(alignment: .leading, spacing: 12) {
                    QuestionBubble(text: ex.question, tint: accent)

                    if let answer = ex.answer {
                        BrainAnswerCard(raw: answer, tint: accent,
                                        recaps: ex.sources, materials: ex.materialSources,
                                        clipped: ex.clipped) {
                            Task { await retry(ex.id) }
                        }
                    } else if let error = ex.error {
                        BrainAnswerErrorCard(message: error) {
                            Task { await retry(ex.id) }
                        }
                    } else {
                        BrainThinkingCard(tint: accent,
                                          recapCount: recaps.count + materials.materials(inBrain: brainID).count)
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
                                 job: queue.job(for: rec.id),
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
                TextField("Ask across this brain…", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.cardBG, in: Capsule())
                    .overlay { Capsule().strokeBorder(Color.hairline) }

                Button {
                    Task { await ask() }
                } label: {
                    ZStack {
                        Circle().fill(accent.gradient)
                        if asking {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(question.trimmingCharacters(in: .whitespaces).isEmpty && !asking ? 0.4 : 1)
                .animation(.quick, value: asking)
            }
        }
    }

    // MARK: Ask

    private func ask() async {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, brain != nil else { return }
        guard !store.recordings(inBrain: brainID).isEmpty || !materials.materials(inBrain: brainID).isEmpty else {
            askError = "This brain has no recordings or material yet."
            Haptics.warning()
            return
        }

        question = ""
        askError = nil
        Haptics.tap()
        let exchange = QAExchange(question: q)
        withAnimation(.quick) { thread.append(exchange) }
        await answer(exchange.id)
    }

    /// Re-runs one exchange in place, so a failure never loses the question.
    private func retry(_ id: UUID) async {
        guard let i = thread.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.quick) {
            thread[i].answer = nil
            thread[i].error = nil
        }
        await answer(id)
    }

    private func answer(_ id: UUID) async {
        guard let brain, let asked = thread.first(where: { $0.id == id })?.question else { return }
        let recs = store.recordings(inBrain: brainID)
        let docs = materials.materials(inBrain: brainID)

        asking = true
        defer { asking = false }

        let engine = RecapEngineFactory.make(settings)
        // Retrieval, not "the first twelve": every note, term, moment and
        // transcript line in the brain is ranked against the question, and the
        // budget is spent on what matched.
        //
        // Off the main actor because a brain holding a few dozen hours of
        // transcript is a few million characters to tokenise, and the composer
        // shouldn't freeze while that happens.
        let budget = engine.contextBudget
        let retrieved = await Task.detached(priority: .userInitiated) {
            // Reserve room for each source family so one very long transcript
            // cannot crowd every relevant slide out of the answer (or vice versa).
            let recapBudget = docs.isEmpty ? budget : Int(Double(budget) * 0.62)
            let materialBudget = recs.isEmpty ? budget : budget - recapBudget
            let recapContext = BrainRetriever.context(for: asked, recaps: recs, budget: recapBudget)
            let materialContext = MaterialRetriever.context(for: asked, materials: docs, budget: materialBudget)
            return RetrievedContext(
                text: [recapContext.text, materialContext.text].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                recaps: recapContext.recaps,
                materials: materialContext.materials,
                searchedCount: recapContext.searchedCount + materialContext.searchedCount,
                clipped: recapContext.clipped || materialContext.clipped
            )
        }.value
        if let i = thread.firstIndex(where: { $0.id == id }) {
            thread[i].sources = retrieved.recaps
            thread[i].materialSources = retrieved.materials
            thread[i].clipped = retrieved.clipped
        }

        guard !retrieved.isEmpty else {
            guard let i = thread.firstIndex(where: { $0.id == id }) else { return }
            withAnimation(.quick) {
                thread[i].error = "None of this brain's recordings or materials are ready to search yet."
            }
            Haptics.warning()
            return
        }

        do {
            let reply = try await engine.answer(question: asked, persona: brain.persona,
                                                context: retrieved)
            guard let i = thread.firstIndex(where: { $0.id == id }) else { return }
            withAnimation(.gentle) { thread[i].answer = reply }
            Haptics.success()
        } catch {
            guard let i = thread.firstIndex(where: { $0.id == id }) else { return }
            withAnimation(.quick) { thread[i].error = error.localizedDescription }
            Haptics.warning()
        }
    }
}
