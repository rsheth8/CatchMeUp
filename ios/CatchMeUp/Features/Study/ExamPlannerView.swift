import SwiftUI

// MARK: - ExamPlannerView
//
// Put a date on the calendar and the schedule changes shape.
//
// Cepeda et al. (2006) found the best gap between study sessions scales with
// how long you need to remember — which means an exam date is a scheduling
// input, not just a countdown. A test five weeks out is served by longer gaps
// and a lower retention target; the same material three days out needs the
// target pushed up, which pulls everything closer together.

struct ExamPlannerView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(StudyStore.self) private var study
    @Environment(\.dismiss) private var dismiss

    @State private var editing: ExamPlan?
    @State private var showingNew = false

    var body: some View {
        NavigationStack {
            Group {
                if store.visibleBrains.isEmpty {
                    EmptyState(symbol: "brain",
                               title: "No courses yet",
                               message: "Exam plans attach to a course. Create one in Brains, then file your lectures into it.",
                               tint: .amber)
                } else {
                    list
                }
            }
            .background(AmbientBackground(tint: .amber))
            .navigationTitle("Exams")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNew = true } label: { Image(systemName: "plus") }
                        .disabled(store.visibleBrains.isEmpty)
                        .accessibilityLabel("Add an exam")
                }
            }
            .sheet(isPresented: $showingNew) {
                ExamEditor(plan: nil)
            }
            .sheet(item: $editing) { plan in
                ExamEditor(plan: plan)
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if study.plans.isEmpty {
                    EmptyState(symbol: "calendar.badge.plus",
                               title: "No exams scheduled",
                               message: "Add a date and CatchMeUp works backward from it — tightening the review schedule as it gets close.",
                               tint: .amber) {
                        Button("Add an exam") { showingNew = true }
                            .buttonStyle(.prominent(.amber))
                            .padding(.horizontal, 30)
                    }
                } else {
                    ForEach(study.plans) { plan in
                        planCard(plan)
                    }
                    explainer
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func planCard(_ plan: ExamPlan) -> some View {
        let brain = store.brain(plan.brainID)
        let items = study.items(inBrain: plan.brainID)
        let mastered = items.filter { $0.memory.state == .review && $0.memory.stability >= 21 }.count
        let progress = items.isEmpty ? 0 : Double(mastered) / Double(items.count)

        return Button {
            Haptics.tap()
            editing = plan
        } label: {
            Card(tint: plan.isPast ? .secondary : (plan.daysAway <= 7 ? .orange : .amber)) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plan.title).font(.headline)
                            Text(brain?.name ?? "Course removed")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(plan.countdownText)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(plan.isPast ? Color.secondary
                                                 : (plan.daysAway <= 7 ? .orange : .amber))
                            Text(plan.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }

                    if !plan.isPast {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: progress)
                                .tint(plan.daysAway <= 7 ? .orange : .amber)
                            HStack {
                                Text("\(mastered) of \(items.count) holding steady")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(study.dailyTarget(for: plan))/day")
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text(scheduleNote(plan))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Says out loud what the date is doing to the schedule.
    private func scheduleNote(_ plan: ExamPlan) -> String {
        let target = Int((plan.suggestedRetention * 100).rounded())
        switch plan.daysAway {
        case 0...3:
            return "Final stretch — aiming for \(target)% recall, so everything shaky comes back daily."
        case 4...10:
            return "Close in — target raised to \(target)% recall, tightening the gaps."
        case 11...28:
            return "Steady spacing at \(target)% recall. The schedule tightens automatically in the last fortnight."
        default:
            return "Plenty of runway — wide gaps at \(target)% recall, which is the cheapest way to hold it."
        }
    }

    private var explainer: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                Label("Why the date matters", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
                Text("The ideal gap between reviews grows with how long you need to hold something. An exam date tells CatchMeUp what that window is, so it can spread the work wide early and close it up as the day approaches — instead of you cramming the night before.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Editor

struct ExamEditor: View {
    let plan: ExamPlan?

    @Environment(LibraryStore.self) private var store
    @Environment(StudyStore.self) private var study
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var brainID: UUID?
    @State private var date = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
    @State private var confirmDelete = false

    private var isNew: Bool { plan == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Midterm 2", text: $title)
                    Picker("Course", selection: $brainID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(store.visibleBrains) { brain in
                            Text(brain.name).tag(UUID?.some(brain.id))
                        }
                    }
                    DatePicker("Date", selection: $date, in: Date.now...,
                               displayedComponents: .date)
                } footer: {
                    Text("Questions from this course get pulled forward as the date approaches.")
                }

                if let brainID {
                    Section("What's in scope") {
                        let items = study.items(inBrain: brainID)
                        LabeledContent("Questions", value: "\(items.count)")
                        LabeledContent("Never studied",
                                       value: "\(items.filter(\.isNew).count)")
                        let days = max(1, Calendar.current.dateComponents(
                            [.day], from: .now, to: date).day ?? 1)
                        LabeledContent("Suggested pace",
                                       value: "\(max(5, Int((Double(items.count) / Double(days)).rounded(.up)))) a day")
                    }
                }

                if !isNew {
                    Section {
                        Button("Delete exam", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "New exam" : "Edit exam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(brainID == nil || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete this exam?", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let plan { study.delete(plan) }
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your questions and schedule stay — only the date and its pacing go.")
            }
            .onAppear(perform: seed)
        }
    }

    private func seed() {
        guard let plan else {
            brainID = store.visibleBrains.first?.id
            return
        }
        title = plan.title
        brainID = plan.brainID
        date = plan.date
    }

    private func save() {
        guard let brainID else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if var existing = plan {
            existing.title = name
            existing.brainID = brainID
            existing.date = date
            study.upsert(existing)
        } else {
            study.upsert(ExamPlan(brainID: brainID, title: name, date: date))
        }
        Haptics.success()
        dismiss()
    }
}
