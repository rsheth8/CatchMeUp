import SwiftUI

struct BrainsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var showNew = false
    @State private var newName = ""
    @State private var newMode: Mode = .lecture

    var body: some View {
        NavigationStack {
            Group {
                if store.visibleBrains.isEmpty {
                    ScrollView {
                        Card {
                            EmptyState(symbol: "brain",
                                       title: "No brains yet",
                                       message: "A brain is a folder of related recaps you can ask questions across — a course, a client, a project.")
                        }
                        .padding(16)
                    }
                    .background(Color.groupBG)
                } else {
                    List {
                        ForEach(store.visibleBrains) { brain in
                            NavigationLink(value: brain.id) {
                                BrainRow(brain: brain, count: store.recordings(inBrain: brain.id).count)
                            }
                        }
                        .onDelete { idx in
                            let visible = store.visibleBrains
                            idx.map { visible[$0] }.forEach(store.delete)
                        }
                    }
                }
            }
            .navigationTitle("Brains")
            .navigationDestination(for: UUID.self) { id in
                if let brain = store.brain(id) { BrainDetailView(brainID: brain.id) }
            }
            .toolbar {
                Button { showNew = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showNew) { newBrainSheet }
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
                    Text("You can drop recaps into this brain from any recap's ••• menu, then ask questions that only look inside it.")
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
                        newName = ""; showNew = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct BrainRow: View {
    let brain: Brain
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(brain.mode.accent.opacity(0.15))
                Image(systemName: "brain").foregroundStyle(brain.mode.accent)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(brain.name).font(.body.weight(.semibold))
                Text("\(count) recap\(count == 1 ? "" : "s") · \(brain.mode.title)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Brain detail

struct BrainDetailView: View {
    let brainID: UUID

    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var question = ""
    @State private var answer = ""
    @State private var asking = false
    @State private var askError: String?
    @State private var editingPersona = false
    @State private var personaDraft = ""

    private var brain: Brain? { store.brain(brainID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let brain {
                    askCard(brain)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionLabel(text: "Persona", symbol: "theatermasks")
                            Spacer()
                            Button(editingPersona ? "Done" : "Edit") {
                                if editingPersona {
                                    var b = brain; b.persona = personaDraft; store.upsert(b)
                                }
                                editingPersona.toggle()
                                personaDraft = brain.persona
                            }
                            .font(.caption.weight(.semibold))
                        }
                        Card {
                            if editingPersona {
                                TextField("How should this brain think and answer?",
                                          text: $personaDraft, axis: .vertical)
                                    .lineLimit(3...6)
                            } else {
                                Text(brain.persona.isEmpty ? "No persona set. Tap Edit to give this brain a voice." : brain.persona)
                                    .font(.subheadline)
                                    .foregroundStyle(brain.persona.isEmpty ? .secondary : .primary)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Recaps in this brain", symbol: "tray.full")
                        let recs = store.recordings(inBrain: brainID)
                        if recs.isEmpty {
                            Card {
                                Text("Empty. Open any recap and choose ••• ▸ Add to brain.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(recs) { rec in
                                NavigationLink(value: rec.id) {
                                    RecordingRow(recording: rec, brainName: nil)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color.groupBG)
        .navigationTitle(brain?.name ?? "Brain")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: UUID.self) { id in RecapDetailView(recordingID: id) }
        .onAppear { personaDraft = brain?.persona ?? "" }
    }

    private func askCard(_ brain: Brain) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Ask this brain", symbol: "bubble.left.and.text.bubble.right")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Ask about anything in these recaps…", text: $question, axis: .vertical)
                            .lineLimit(1...4)
                        Button {
                            Task { await ask(brain) }
                        } label: {
                            Image(systemName: asking ? "hourglass" : "arrow.up.circle.fill").font(.title2)
                        }
                        .disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if asking { ProgressView().controlSize(.small) }
                    if let askError {
                        Text(askError).font(.caption).foregroundStyle(.orange)
                    }
                    if !answer.isEmpty {
                        Divider()
                        Text(answer).font(.subheadline).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func ask(_ brain: Brain) async {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        asking = true; askError = nil; answer = ""
        defer { asking = false }

        let recs = store.recordings(inBrain: brainID)
        guard !recs.isEmpty else { askError = "This brain has no recaps yet."; return }

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
            answer = try await engine.answer(question: q, persona: brain.persona, context: String(context.prefix(14000)))
        } catch {
            askError = error.localizedDescription
        }
    }
}
