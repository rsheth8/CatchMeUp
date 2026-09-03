import SwiftUI

struct MeetingWorkspaceView: View {
    let recordingID: UUID
    var play: (Double) -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(MaterialStore.self) private var materials
    @Environment(AppSettings.self) private var settings
    @Environment(ProcessingQueue.self) private var queue
    @Environment(AppRouter.self) private var router
    @State private var section = "Summary"
    @State private var editingTask: MeetingFollowUp?
    @State private var editingOutcome: MeetingOutcome?
    @State private var editingAgenda = false
    @State private var agenda = ""
    @State private var refresh = 0
    @State private var analyzing = false
    @State private var confirmAnalysis = false
    @State private var exporting = Set<UUID>()
    @State private var notice: String?
    @State private var selectedMaterial: SupplementalMaterial?
    @State private var selectedPage: Int?

    private var recording: Recording? { library.recording(recordingID) }
    private var workspace: MeetingWorkspace { recording.map(MeetingWorkspace.existing) ?? MeetingWorkspace() }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Meeting section", selection: $section) {
                ForEach(["Summary", "Decisions", "Follow-ups", "Materials"], id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.segmented)

            if let recording {
                switch section {
                case "Decisions": outcomes
                case "Follow-ups": followUps(recording)
                case "Materials": documentSection(recording)
                default: summary(recording)
                }

                if !recording.segments.isEmpty {
                    Button { confirmAnalysis = true } label: {
                        HStack {
                            if analyzing { ProgressView() } else { Image(systemName: "sparkles") }
                            Text(analyzing ? "Reviewing this meeting…" : "Refresh meeting insights")
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .disabled(analyzing || queue.job(for: recordingID) != nil)
                    Text("Uses your selected recap engine. Attachments inform context, never what was said aloud.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = workspace.analysisNotice {
                    Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            if recording?.meeting == nil { library.updateMeeting(recordingID) { _ in } }
        }
        .task(id: refresh) {
            guard refresh > 0, let recording else { return }
            analyzing = true
            defer { analyzing = false }
            guard settings.engineKind != .demo else {
                notice = "Demo mode does not analyze new content. Choose an on-device or API-key engine in Settings."
                return
            }
            do {
                let attached = materials.materials(forRecording: recordingID)
                var result = try await RecapEngineFactory.make(settings).meetingWorkspace(for: recording, materials: attached)
                try Task.checkCancellation()
                if attached.contains(where: { !$0.state.isReady }) {
                    result.analysisNotice = "Some documents aren't ready yet. Refresh again after they finish processing."
                }
                library.updateMeeting(recordingID) { current in
                    result.preserveUserChanges(from: current)
                    current = result
                }
            } catch is CancellationError {
                // A cancelled review leaves all existing notes and edits intact.
            } catch { notice = error.localizedDescription }
        }
        .confirmationDialog("Refresh meeting insights?", isPresented: $confirmAnalysis, titleVisibility: .visible) {
            Button("Analyze meeting and attachments") { refresh += 1 }
        } message: {
            Text(settings.engineKind == .apiKey
                 ? "Relevant transcript and document excerpts will be sent to your configured AI provider. Your edits and completed tasks are kept."
                 : "This uses the selected engine and keeps your edits and completed tasks. Documents are treated as supplied context, not spoken agreement.")
        }
        .sheet(item: $editingTask) { task in
            MeetingFollowUpEditor(task: task) { updated in
                library.updateMeeting(recordingID) { workspace in
                    if let i = workspace.followUps.firstIndex(where: { $0.id == updated.id }) {
                        workspace.followUps[i] = updated
                    } else { workspace.followUps.append(updated) }
                }
            }
        }
        .sheet(item: $editingOutcome) { outcome in
            MeetingOutcomeEditor(outcome: outcome) { updated in
                library.updateMeeting(recordingID) { workspace in
                    if let i = workspace.outcomes.firstIndex(where: { $0.id == updated.id }) {
                        workspace.outcomes[i] = updated
                    } else { workspace.outcomes.append(updated) }
                }
            }
        }
        .sheet(isPresented: $editingAgenda) {
            NavigationStack {
                Form {
                    Section("Agenda & goals") { TextEditor(text: $agenda).frame(minHeight: 180) }
                    Text("Preparation only—not a record of what was agreed.").font(.caption)
                }
                .navigationTitle("Prepare meeting")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingAgenda = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            library.updateMeeting(recordingID) { $0.agenda = agenda }
                            editingAgenda = false
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedMaterial) { material in
            MaterialDetailView(materialID: material.id, tint: .brand, initialPage: selectedPage)
        }
        .alert("Meeting", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func summary(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if recording.isMeetingPreparation {
                Button {
                    router.recorderRecordingID = recording.id
                    router.recorderBrainID = recording.brainID
                    router.recorderMode = .meeting
                } label: { Label("Record this meeting", systemImage: "mic.fill") }
                    .buttonStyle(.borderedProminent)
                Text("Your agenda and attachments are saved, even if you record later.").font(.caption).foregroundStyle(.secondary)
            }
            if let gist = recording.recap?.tldr, !gist.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader("What happened", symbol: "sparkles")
                        ForEach(Array(gist.enumerated()), id: \.offset) { _, line in
                            Text("• " + line).font(.subheadline)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                stat("Open follow-ups", count: workspace.followUps.filter { $0.status != .done }.count)
                stat("Decisions", count: workspace.analyzedAt == nil && workspace.outcomes.isEmpty
                     ? nil : workspace.outcomes.filter { $0.kind == .decision }.count)
            }
            Button {
                agenda = workspace.agenda
                editingAgenda = true
            } label: {
                Label(workspace.agenda.isEmpty ? "Add an agenda or meeting goals" : "Edit agenda", systemImage: "list.bullet.clipboard")
                    .font(.subheadline)
            }
            if !workspace.agenda.isEmpty {
                Text(workspace.agenda).font(.subheadline).foregroundStyle(.secondary)
            }
            if recording.brainID != nil {
                MeetingPreparationCard(recording: recording)
            } else {
                Text("Add this meeting to a Brain to connect it with previous meetings for the same project or client.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Recording notes & key moments") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(recording.recap?.bookmarks ?? []) { mark in
                        Button {
                            if let seconds = mark.seconds { play(seconds) }
                        } label: { Label("\(mark.timestamp) · \(mark.heading)", systemImage: "play.circle") }
                            .disabled(mark.seconds == nil)
                    }
                    ForEach(recording.recap?.detailedNotes ?? []) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(note.heading).font(.headline)
                            Text(note.content).font(.subheadline).textSelection(.enabled)
                        }
                    }
                    ForEach(recording.recap?.speakers ?? []) { speaker in
                        Text("\(speaker.name.isEmpty ? speaker.label : speaker.name): \(speaker.said)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.top, 12)
            }
        }
    }

    private func stat(_ label: String, count: Int?) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(count.map(String.init) ?? "—").font(.title2.bold())
                Text(label).font(.caption).foregroundStyle(.secondary)
                if count == nil { Text("Not analyzed yet").font(.caption2).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
        }
    }

    private func followUps(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review owners and deadlines before adding tasks to Reminders. Nothing is sent automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Button { editingTask = MeetingFollowUp(title: "") } label: { Label("Add follow-up", systemImage: "plus") }
            if workspace.followUps.isEmpty { Text("No follow-ups tracked yet.").foregroundStyle(.secondary) }
            ForEach(workspace.followUps) { task in
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                library.updateMeeting(recordingID) { workspace in
                                    guard let i = workspace.followUps.firstIndex(where: { $0.id == task.id }) else { return }
                                    workspace.followUps[i].status = task.status == .done ? .open : .done
                                    workspace.followUps[i].editedByUser = true
                                }
                            } label: {
                                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel(task.status == .done ? "Reopen follow-up" : "Complete follow-up")
                            Button { editingTask = task } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(task.title).font(.subheadline.weight(.semibold))
                                        .strikethrough(task.status == .done)
                                    Text(task.owner.isEmpty ? "Owner not specified" : task.owner).font(.caption)
                                    if let date = task.dueDate { Text("Due \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption) }
                                    else if !task.deadlineText.isEmpty { Text("As stated: \(task.deadlineText)").font(.caption) }
                                    Text(task.needsReview ? "Needs review" : task.status.title)
                                        .font(.caption.weight(.semibold)).foregroundStyle(task.needsReview ? .orange : .secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                        HStack {
                            if let seconds = task.seconds {
                                Button { play(seconds) } label: { Label(task.timestamp, systemImage: "play.circle") }
                            }
                            Spacer()
                            Button {
                                if task.needsReview { editingTask = task } else { export(task, recording: recording) }
                            } label: {
                                Label(task.needsReview ? "Review" : (task.reminderID == nil ? "Add to Reminders" : "Update reminder"),
                                      systemImage: task.needsReview ? "pencil" : "checklist")
                            }.disabled(exporting.contains(task.id))
                        }.font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private var outcomes: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Proposals are not decisions. Tap a finding to review its evidence or correct its classification.")
                .font(.caption).foregroundStyle(.secondary)
            Button { editingOutcome = MeetingOutcome(kind: .decision, text: "") } label: {
                Label("Add a finding", systemImage: "plus")
            }
            ForEach(MeetingOutcomeKind.allCases) { kind in
                let items = workspace.outcomes.filter { $0.kind == kind }
                if !items.isEmpty {
                    SectionHeader(kind.title, symbol: kind.symbol)
                    ForEach(items) { item in
                        Card(padding: 14) {
                            VStack(alignment: .leading, spacing: 9) {
                                Button { editingOutcome = item } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.text).font(.subheadline.weight(.medium))
                                        Text(item.resolved ? "Resolved / superseded" : (item.reviewed ? "Reviewed" : "AI finding · needs review"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                if let seconds = item.seconds {
                                    Button { play(seconds) } label: { Label("Hear evidence · \(item.timestamp)", systemImage: "play.circle") }
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            if workspace.outcomes.isEmpty {
                Text("Refresh meeting insights to extract decisions, proposals, blockers and open questions.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func documentSection(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            RecapMaterialsCard(recording: recording)
            if !workspace.documentNotes.isEmpty {
                SectionHeader("From the documents—not spoken", symbol: "doc.text.magnifyingglass")
                ForEach(workspace.documentNotes) { note in
                    if let material = materials.material(note.materialID),
                       material.recordingIDs.contains(recordingID) {
                        Card(padding: 14) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(note.summary).font(.subheadline)
                                Button { selectedPage = note.pageNumber; selectedMaterial = material } label: {
                                    Label("\(material.name) · \(material.locationNoun.capitalized) \(note.pageNumber)", systemImage: "doc.text")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func export(_ task: MeetingFollowUp, recording: Recording) {
        exporting.insert(task.id)
        Task { @MainActor in
            defer { exporting.remove(task.id) }
            do {
                let id = try await ReminderExporter.add(task: task, recording: recording)
                library.updateMeeting(recordingID) { workspace in
                    if let i = workspace.followUps.firstIndex(where: { $0.id == task.id }) {
                        workspace.followUps[i].reminderID = id
                    }
                }
                notice = "Saved to Apple Reminders. Future exports update this reminder instead of making a duplicate."
            } catch { notice = error.localizedDescription }
        }
    }
}

struct MeetingFollowUpEditor: View {
    @State var task: MeetingFollowUp
    var save: (MeetingFollowUp) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Follow-up") {
                    TextField("What needs to happen?", text: $task.title, axis: .vertical)
                    TextField("Owner (optional)", text: $task.owner)
                    Picker("Status", selection: $task.status) {
                        ForEach(FollowUpStatus.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Deadline") {
                    if !task.deadlineText.isEmpty { LabeledContent("As stated", value: task.deadlineText) }
                    Toggle("Set a due date", isOn: Binding(get: { task.dueDate != nil }, set: { task.dueDate = $0 ? .now : nil }))
                    if task.dueDate != nil {
                        DatePicker("Due", selection: Binding(get: { task.dueDate ?? .now }, set: { task.dueDate = $0 }), displayedComponents: .date)
                    }
                    Text("Confirm the date yourself, especially for phrases such as ‘next Friday’.").font(.caption)
                }
                if !task.evidence.isEmpty {
                    Section("Transcript evidence · \(task.timestamp)") { Text(task.evidence).textSelection(.enabled) }
                }
            }
            .navigationTitle("Review follow-up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        task.needsReview = false
                        task.editedByUser = true
                        save(task)
                        dismiss()
                    }.disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct MeetingOutcomeEditor: View {
    @State var outcome: MeetingOutcome
    var save: (MeetingOutcome) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Finding") {
                    TextField("What happened?", text: $outcome.text, axis: .vertical)
                    Picker("Kind", selection: $outcome.kind) {
                        ForEach(MeetingOutcomeKind.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Resolved or superseded", isOn: $outcome.resolved)
                }
                if !outcome.evidence.isEmpty {
                    Section("Transcript evidence · \(outcome.timestamp)") { Text(outcome.evidence).textSelection(.enabled) }
                }
                Text("Mark a proposal as a decision only after confirming agreement.").font(.caption)
            }
            .navigationTitle("Review finding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        outcome.reviewed = true
                        save(outcome)
                        dismiss()
                    }.disabled(outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct MeetingPreparationCard: View {
    let recording: Recording
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    var body: some View {
        let previous = MeetingPreparation.previous(for: recording, in: library.sortedRecordings)
        if !previous.isEmpty {
            Card {
                DisclosureGroup("Previous meetings & preparation") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(MeetingPreparation.brief(for: recording, in: library.sortedRecordings))
                            .font(.subheadline).textSelection(.enabled)
                        ShareLink(item: MeetingPreparation.brief(for: recording, in: library.sortedRecordings)) {
                            Label("Share preparation brief", systemImage: "square.and.arrow.up")
                        }
                        SectionHeader("Decision timeline", symbol: "clock.arrow.circlepath")
                        ForEach(Array(previous.prefix(8))) { meeting in
                            VStack(alignment: .leading, spacing: 7) {
                                Button { router.open(CatchMeUpLink.recap(meeting.id)) } label: {
                                    Text("\(meeting.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(meeting.displayTitle)")
                                        .font(.subheadline.weight(.semibold))
                                }
                                ForEach(meeting.meeting?.outcomes.filter { $0.kind == .decision } ?? []) { outcome in
                                    Text("\(outcome.resolved ? "Superseded" : "Decision")\(outcome.reviewed ? "" : " · unreviewed"): \(outcome.text)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("History is grouped by this Brain. A newer statement doesn't automatically replace an earlier decision—review it first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 12)
                }
            }
        }
    }
}

struct MeetingPreparationSheet: View {
    let recordingID: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var agenda = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                if let recording = library.recording(recordingID) {
                    VStack(alignment: .leading, spacing: 20) {
                        TextField("Meeting title", text: $title).font(.title2.weight(.semibold))
                        SectionHeader("Agenda & goals", symbol: "list.bullet.clipboard")
                        TextEditor(text: $agenda).frame(minHeight: 110).padding(8)
                            .background(Color.cardBG, in: RoundedRectangle(cornerRadius: 12))
                        RecapMaterialsCard(recording: recording)
                        MeetingPreparationCard(recording: recording)
                        Text("Saved in Recaps as a prepared meeting. You can return and record later; closing the recorder does not remove these materials.")
                            .font(.caption).foregroundStyle(.secondary)
                        if settings.engineKind == .apiKey {
                            Text("After recording, relevant transcript and attachment excerpts are sent to your configured AI provider to create meeting insights.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(16)
                }
            }
            .background(AmbientBackground())
            .navigationTitle("Prepare meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                title = library.recording(recordingID)?.title ?? ""
                agenda = library.recording(recordingID)?.meeting?.agenda ?? ""
            }
            .onDisappear {
                library.rename(recordingID, to: title)
                library.updateMeeting(recordingID) { $0.agenda = agenda }
            }
        }
    }
}
