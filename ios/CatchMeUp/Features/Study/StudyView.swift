import SwiftUI

// MARK: - StudyView
//
// The Study tab. One job above the fold: start today's review. Everything
// else — flashcards, practice exams, the exam countdown, calibration — sits
// below it, because a dashboard that makes you choose before you start is a
// dashboard people bounce off.

struct StudyView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(StudyStore.self) private var study
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(ProcessingQueue.self) private var queue

    @State private var session: SessionRequest?
    @State private var showPlanner = false
    @State private var showFocus = false
    @State private var showCards = false
    @State private var pickedBrain: UUID?

    /// Identifies a session to launch, so one cover handles every mode.
    private struct SessionRequest: Identifiable {
        let id = UUID()
        let mode: StudyMode
        let brainID: UUID?
        let limit: Int
    }

    private var dueCount: Int { study.dueCount(brainID: pickedBrain) }
    private var newAvailable: Int {
        min(study.newCount(brainID: pickedBrain),
            max(0, settings.dailyNewLimit - study.newIntroducedToday()))
    }
    private var totalToday: Int {
        study.todayCount(brainID: pickedBrain, newLimit: settings.dailyNewLimit)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if study.liveItems.isEmpty {
                        emptyState
                    } else {
                        todayCard
                        if store.visibleBrains.count > 1 { courseFilter }
                        examCountdown
                        modeGrid
                        progressCard
                        weakSpots
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 26)
            }
            .background(AmbientBackground(tint: .brand))
            .navigationTitle("Study")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPlanner = true } label: {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .accessibilityLabel("Exam planner")
                }
            }
            .task { await prepare() }
            .refreshable { await prepare() }
            // Both, deliberately. A tab the user has already visited is live and
            // sees `onChange`; a tab opened for the first time by the link
            // doesn't exist yet when the value is set, so it has to read it on
            // appear instead.
            .onAppear { consumeRoute() }
            .onChange(of: router.studyBrainID) { _, _ in consumeRoute() }
            .fullScreenCover(item: $session) { request in
                ReviewSessionView(mode: request.mode, brainID: request.brainID, limit: request.limit)
            }
            .fullScreenCover(isPresented: $showCards) {
                FlashcardsView(brainID: pickedBrain, limit: 20)
            }
            .sheet(isPresented: $showPlanner) { ExamPlannerView() }
            .fullScreenCover(isPresented: $showFocus) {
                FocusSessionView(brainID: pickedBrain)
            }
        }
    }

    // MARK: Today

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(totalToday > 0 ? "Due today" : "All caught up")
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.8))
                    Text(totalToday > 0 ? "\(totalToday)" : "0")
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                if study.streak > 0 {
                    VStack(spacing: 2) {
                        Image(systemName: "flame.fill").font(.title3)
                        Text("\(study.streak)").font(.headline.monospacedDigit())
                        Text("days").font(.caption2)
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 13,
                                                                          style: .continuous))
                }
            }

            Text(todayBlurb)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Haptics.tap()
                session = SessionRequest(mode: .review, brainID: pickedBrain,
                                         limit: min(max(totalToday, 1), settings.dailyReviewLimit))
            } label: {
                Label(totalToday > 0 ? "Start reviewing" : "Study ahead",
                      systemImage: "play.fill")
                    .font(.headline)
                    .foregroundStyle(Color.brandDeep)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [.brandLight, .brand],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(RadialGradient(colors: [.white.opacity(0.20), .clear],
                                             center: .topTrailing, startRadius: 0, endRadius: 260))
                }
                .shadow(color: Color.brand.opacity(0.30), radius: 18, y: 8)
        }
        .padding(.top, 6)
    }

    private var todayBlurb: String {
        if totalToday == 0 {
            return study.liveItems.isEmpty
                ? "Add a recap and questions appear here."
                : "Nothing is due. Studying ahead is fine, but the schedule already has you covered."
        }
        let parts = [
            dueCount > 0 ? "\(dueCount) to review" : nil,
            newAvailable > 0 ? "\(newAvailable) new" : nil,
        ].compactMap { $0 }
        return parts.joined(separator: " · ") + " — about \(estimatedMinutes) min."
    }

    /// Rough, but honest: a mixed queue runs around 15 seconds an item.
    private var estimatedMinutes: Int {
        max(1, Int((Double(totalToday) * 15 / 60).rounded()))
    }

    // MARK: Course filter

    private var courseFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "All courses", isOn: pickedBrain == nil) { pickedBrain = nil }
                ForEach(store.visibleBrains) { brain in
                    let count = study.dueCount(brainID: brain.id)
                    FilterChip(title: count > 0 ? "\(brain.name) · \(count)" : brain.name,
                               isOn: pickedBrain == brain.id, tint: .amber) {
                        pickedBrain = pickedBrain == brain.id ? nil : brain.id
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
    }

    // MARK: Exam countdown

    @ViewBuilder
    private var examCountdown: some View {
        if let plan = relevantPlan {
            Button {
                Haptics.tap()
                showPlanner = true
            } label: {
                Card(tint: plan.daysAway <= 7 ? .orange : .amber) {
                    HStack(spacing: 13) {
                        IconTile(symbol: "calendar", tint: plan.daysAway <= 7 ? .orange : .amber,
                                 size: 42, filled: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.title).font(.subheadline.weight(.semibold))
                            Text("\(plan.countdownText) away · \(study.dailyTarget(for: plan)) a day to stay on track")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var relevantPlan: ExamPlan? {
        if let pickedBrain { return study.plan(forBrain: pickedBrain) }
        return study.nextExam
    }

    // MARK: Modes

    private var modeGrid: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader("Other ways to practise", symbol: "square.grid.2x2")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                modeTile(.flashcards, tint: .brand) { showCards = true }
                modeTile(.practiceExam, tint: .amber) {
                    session = SessionRequest(mode: .practiceExam, brainID: pickedBrain, limit: 12)
                }
                modeTile(.drill, tint: .orange) {
                    session = SessionRequest(mode: .drill, brainID: pickedBrain, limit: 10)
                }
                focusTile
            }
        }
    }

    private func modeTile(_ mode: StudyMode, tint: Color, action: @escaping () -> Void) -> some View {
        let available = study.queue(mode: mode, brainID: pickedBrain, limit: 1,
                                    newLimit: settings.dailyNewLimit).isEmpty == false
        return Button {
            Haptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                IconTile(symbol: mode.symbol, tint: tint, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title).font(.subheadline.weight(.semibold))
                    Text(mode.blurb)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.cardBG)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.hairline)
                    }
            }
            .opacity(available ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }

    private var focusTile: some View {
        Button {
            Haptics.tap()
            showFocus = true
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                IconTile(symbol: "timer", tint: .mint, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Focus session").font(.subheadline.weight(.semibold))
                    Text("\(settings.focusMinutes) minutes, one course at a time")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.cardBG)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.hairline)
                    }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Progress

    private var progressCard: some View {
        let days = study.accuracyByDay(days: 14)
        let calibration = study.calibration(brainID: pickedBrain)
        return VStack(alignment: .leading, spacing: 9) {
            SectionHeader("Your two weeks", symbol: "chart.bar")
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    AccuracyBars(days: days)
                        .frame(height: 62)

                    Divider().opacity(0.5)

                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Confidence vs recall")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(calibration.verdict)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if calibration.isMeaningful {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(percent(calibration.predicted))
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Color.amber)
                                Text("felt sure").font(.caption2).foregroundStyle(.secondary)
                                Text(percent(calibration.actual))
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Color.brand)
                                    .padding(.top, 4)
                                Text("recalled").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    // MARK: Weak spots

    @ViewBuilder
    private var weakSpots: some View {
        let weak = study.weakConcepts(limit: 5)
        if !weak.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                SectionHeader("Keeps slipping", symbol: "target")
                Card(tint: .orange) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(weak.enumerated()), id: \.offset) { idx, entry in
                            HStack(spacing: 10) {
                                Text(entry.concept)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text("\(entry.misses)×")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.orange)
                            }
                            .padding(.vertical, 8)
                            if idx < weak.count - 1 { Divider().opacity(0.4) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Empty

    /// An empty Study tab means one of two very different things — nothing to
    /// study, or notes still being written — and telling someone to "record a
    /// lecture" while their lecture is mid-transcription is the kind of wrong
    /// that makes an app feel broken.
    @ViewBuilder
    private var emptyState: some View {
        if let working = queue.summary {
            EmptyState(symbol: "hourglass",
                       title: "Writing the notes",
                       message: "\(working). Questions are minted the moment a recap lands — this tab fills itself.",
                       tint: .brand)
            .padding(.top, 40)
        } else {
            EmptyState(symbol: "graduationcap",
                       title: "No questions yet",
                       message: "Record or import a lecture. CatchMeUp writes the notes, then turns them into questions and schedules them for you.",
                       tint: .brand)
            .padding(.top, 40)
        }
    }

    // MARK: Work

    /// Applies a `catchmeup://study?brain=` scope, then clears it so a manual
    /// filter change afterwards isn't fought over.
    private func consumeRoute() {
        guard let id = router.studyBrainID else { return }
        pickedBrain = id
        router.studyBrainID = nil
    }

    private func prepare() async {
        study.mintOffline(for: store.sortedRecordings)
        if settings.engineKind == .apiKey, settings.isReady {
            await study.enrich(store.sortedRecordings, config: settings.providerConfig)
        }
    }
}

// MARK: - Accuracy bars
//
// Fourteen days of "how much did you get right". Days with no reviews are
// drawn as a flat tick rather than skipped, so a gap in the habit is visible
// instead of smoothed away.

struct AccuracyBars: View {
    let days: [(day: Date, total: Int, correct: Int)]

    var body: some View {
        GeometryReader { geo in
            let count = max(1, days.count)
            let spacing: CGFloat = 4
            let barWidth = max(3, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, entry in
                    let ratio = entry.total > 0
                        ? Double(entry.correct) / Double(entry.total) : 0
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(entry.total > 0
                                  ? AnyShapeStyle(barTint(ratio).gradient)
                                  : AnyShapeStyle(Color.primary.opacity(0.10)))
                            .frame(width: barWidth,
                                   height: entry.total > 0
                                       ? max(6, geo.size.height * CGFloat(ratio)) : 3)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .accessibilityLabel("Daily accuracy over the last two weeks")
    }

    private func barTint(_ ratio: Double) -> Color {
        switch ratio {
        case 0.8...:     return .brand
        case 0.55..<0.8: return .brandLight
        default:         return .amber
        }
    }
}
