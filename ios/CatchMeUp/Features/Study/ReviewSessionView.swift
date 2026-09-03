import SwiftUI

// MARK: - ReviewSessionView
//
// The loop the whole product is built around, in the order the research says
// it works:
//
//   1. See the question, commit to an answer   — retrieval, not recognition
//   2. Rate your confidence *before* the reveal — calibration (Koriat & Bjork)
//   3. See the answer and how you did          — feedback
//   4. Hear the moment it was taught           — elaborated feedback
//   5. Grade it, and FSRS picks the next date  — spacing
//
// Step 2 is the one every other study app skips. It costs one tap and it's the
// only way a student ever finds out that feeling fluent isn't knowing.

struct ReviewSessionView: View {
    let mode: StudyMode
    let brainID: UUID?
    /// Set when a session was started from one recap, to practise just that.
    var recordingID: UUID? = nil
    var limit: Int = 20

    @Environment(LibraryStore.self) private var store
    @Environment(StudyStore.self) private var study
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var queue: [StudyItem] = []
    @State private var index = 0
    @State private var phase: Phase = .asking
    @State private var typed = ""
    @State private var confidence: Confidence?
    @State private var pickedChoice: Int?
    @State private var result: Grading.Result?
    @State private var isCheckingWithModel = false
    @State private var startedAt = Date()

    @State private var sessionID = UUID()
    @State private var answered = 0
    @State private var correct = 0
    @State private var missed: [UUID] = []
    @State private var calibrationErrors: [Double] = []
    @State private var summary: SessionSummary?

    @State private var player = AudioPlayer()
    @State private var isFetchingAudio = false

    @FocusState private var answerFocused: Bool

    private enum Phase { case asking, revealed }

    private var current: StudyItem? { queue.indices.contains(index) ? queue[index] : nil }
    private var tint: Color { current?.brainID != nil ? .amber : .brand }

    var body: some View {
        NavigationStack {
            Group {
                if let summary {
                    SessionSummaryView(summary: summary, brainID: brainID) { dismiss() }
                } else if let item = current {
                    card(item)
                } else {
                    EmptyState(symbol: "checkmark.circle",
                               title: "Nothing due",
                               message: "You're caught up here. New questions appear as you add recaps.",
                               tint: .brand)
                }
            }
            .background(AmbientBackground(tint: tint))
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { finish() }
                }
                ToolbarItem(placement: .principal) {
                    if !queue.isEmpty && summary == nil {
                        ProgressPips(total: queue.count, done: index, tint: tint)
                    }
                }
            }
            .task { build() }
            .onDisappear { player.stop() }
        }
    }

    // MARK: - Card

    @ViewBuilder
    private func card(_ item: StudyItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                promptCard(item)

                if phase == .asking {
                    answerArea(item)
                } else {
                    revealArea(item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .animation(.gentle, value: phase)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { bottomBar(item) }
    }

    private func promptCard(_ item: StudyItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Chip(text: item.kind.title, symbol: item.kind.symbol, tint: tint)
                if item.isNew { Chip(text: "New", symbol: "sparkles", tint: .mint, filled: true) }
                Spacer(minLength: 0)
            }

            MarkdownText(item.prompt, style: promptStyle)

            if !item.sourceTitle.isEmpty {
                Label(item.sourceTitle, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                .fill(Color.cardBG)
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                        .strokeBorder(Color.hairline)
                }
                .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
        }
        .padding(.top, 8)
    }

    private var promptStyle: MarkdownStyle {
        var style = MarkdownStyle.note
        style.tint = tint
        return style
    }

    // MARK: Asking

    @ViewBuilder
    private func answerArea(_ item: StudyItem) -> some View {
        if item.kind == .choice {
            VStack(spacing: 9) {
                ForEach(Array(item.choices.enumerated()), id: \.offset) { i, choice in
                    Button {
                        Haptics.tap()
                        pickedChoice = i
                    } label: {
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: pickedChoice == i ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(pickedChoice == i ? tint : Color.secondary.opacity(0.5))
                            Text(md: choice)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.cardBG)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(pickedChoice == i ? tint.opacity(0.6) : Color.hairline)
                                }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                SectionHeader("Your answer", symbol: "pencil")
                ZStack(alignment: .topLeading) {
                    if typed.isEmpty {
                        Text("Say it in your own words — no need to match the wording.")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $typed)
                        .font(.subheadline)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 108)
                        .focused($answerFocused)
                }
                .padding(9)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.cardBG)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(answerFocused ? tint.opacity(0.5) : Color.hairline)
                        }
                }
            }
        }

        confidenceRow
    }

    /// Asked before the reveal, always. A prediction made after seeing the
    /// answer measures nothing.
    private var confidenceRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader("How sure are you?", symbol: "gauge.with.needle")
            HStack(spacing: 7) {
                ForEach(Confidence.allCases) { level in
                    Button {
                        Haptics.tap(.soft)
                        withAnimation(.quick) { confidence = level }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: level.symbol).font(.subheadline.weight(.semibold))
                            Text(level.title)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .foregroundStyle(confidence == level ? .white : Color.primary.opacity(0.75))
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(confidence == level
                                      ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.cardBG))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(confidence == level ? .clear : Color.hairline)
                                }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Revealed

    @ViewBuilder
    private func revealArea(_ item: StudyItem) -> some View {
        if let result {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    Image(systemName: result.verdict.symbol)
                        .font(.title3)
                        .foregroundStyle(verdictColor(result.verdict))
                    Text(result.verdict.title)
                        .font(.headline)
                        .foregroundStyle(verdictColor(result.verdict))
                    if isCheckingWithModel {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 0)
                    if let c = confidence {
                        calibrationBadge(predicted: c, correct: result.verdict.isRecall)
                    }
                }

                if !result.because.isEmpty {
                    Text(result.because)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("From your lecture", symbol: "text.quote")
                    MarkdownText(item.revealText, style: promptStyle)
                }

                if !typed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader("You wrote", symbol: "pencil")
                        Text(typed)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if item.timestamp != nil { hearItButton(item) }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                    .fill(Color.cardBG)
                    .overlay {
                        RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                            .strokeBorder(verdictColor(result.verdict).opacity(0.30))
                    }
            }
        }
    }

    /// The single most distinctive thing this app can do with a wrong answer:
    /// play the seconds where it was taught, in the professor's own voice.
    private func hearItButton(_ item: StudyItem) -> some View {
        Button {
            Haptics.tap()
            playMoment(item)
        } label: {
            HStack(spacing: 11) {
                IconTile(symbol: player.isPlaying ? "pause.fill" : "play.fill",
                         tint: tint, size: 36, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.isPlaying ? "Playing the moment" : "Hear this moment")
                        .font(.subheadline.weight(.semibold))
                    Text(item.timestamp.map { "From \(Segment.hms($0)) in \(item.sourceTitle)" }
                         ?? item.sourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isFetchingAudio { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.10))
            }
        }
        .buttonStyle(.plain)
        .disabled(isFetchingAudio)
    }

    private func calibrationBadge(predicted: Confidence, correct: Bool) -> some View {
        let overconfident = predicted.predictedRecall > 0.6 && !correct
        let underconfident = predicted.predictedRecall < 0.5 && correct
        return Group {
            if overconfident {
                Chip(text: "Felt sure", symbol: "exclamationmark.triangle.fill", tint: .orange)
            } else if underconfident {
                Chip(text: "Knew it", symbol: "sparkles", tint: .mint)
            }
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private func bottomBar(_ item: StudyItem) -> some View {
        FloatingControlShelf(contentPadding: 11) {
            if phase == .asking {
                VStack(spacing: 8) {
                    Button(item.kind == .choice ? "Check answer" : "Show answer") {
                        reveal(item)
                    }
                    .buttonStyle(.prominent(tint))
                    .disabled(item.kind == .choice && pickedChoice == nil)

                    if confidence == nil {
                        Text("Pick how sure you are first — it's how you learn to trust yourself.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                gradeButtons(item)
            }
        }
    }

    /// Four buttons, each showing when the item will actually come back.
    private func gradeButtons(_ item: StudyItem) -> some View {
        let params = study.parameters(for: item, base: settings.fsrsParameters)
        let preview = FSRS.preview(item.memory, params: params)
        let suggested = result.map { FSRS.Grade.suggested(fromVerdict: $0.verdict) } ?? .good

        return VStack(spacing: 8) {
            HStack(spacing: 7) {
                ForEach(FSRS.Grade.allCases) { grade in
                    Button {
                        Haptics.tap(grade == .again ? .medium : .light)
                        commit(item, grade: grade)
                    } label: {
                        VStack(spacing: 3) {
                            Text(grade.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if let due = preview[grade] {
                                Text(FSRS.intervalText(from: .now, to: due))
                                    .font(.caption2.monospacedDigit())
                                    .opacity(0.85)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .foregroundStyle(grade == suggested ? .white : Color.primary.opacity(0.8))
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(grade == suggested
                                      ? AnyShapeStyle(gradeColor(grade).gradient)
                                      : AnyShapeStyle(Color.cardBG))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(grade == suggested ? .clear : Color.hairline)
                                }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if mode == .practiceExam {
                Text("Practice run — this doesn't change your review schedule.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func gradeColor(_ grade: FSRS.Grade) -> Color {
        switch grade {
        case .again: return .orange
        case .hard:  return .amber
        case .good:  return .brand
        case .easy:  return .mint
        }
    }

    private func verdictColor(_ verdict: Grading.Verdict) -> Color {
        switch verdict {
        case .pass:    return .brand
        case .partial: return .amber
        case .miss:    return .orange
        case .blank:   return .secondary
        }
    }

    // MARK: - Flow

    private func build() {
        guard queue.isEmpty else { return }
        study.mintOffline(for: store.sortedRecordings)
        queue = study.queue(mode: mode, brainID: brainID, recordingID: recordingID,
                            limit: limit, newLimit: settings.dailyNewLimit)
        startedAt = Date()
    }

    private func reveal(_ item: StudyItem) {
        answerFocused = false
        let graded: Grading.Result
        if item.kind == .choice, let picked = pickedChoice {
            graded = Grading.choice(item, picked: picked)
        } else {
            graded = Grading.offline(item, typed: typed)
        }
        result = graded
        phase = .revealed
        Haptics.tap(graded.verdict.isRecall ? .light : .medium)

        // A paraphrase that keyword matching marked down is worth one call —
        // and only that case, so a session stays fast and mostly offline.
        if settings.usesModelGrading, item.kind != .choice,
           Grading.wantsModelCheck(graded, typed: typed) {
            isCheckingWithModel = true
            let config = settings.providerConfig
            Task {
                let better = await Grading.model(item, typed: typed, config: config)
                await MainActor.run {
                    isCheckingWithModel = false
                    if let better, better.verdict != graded.verdict { result = better }
                }
            }
        }
    }

    private func commit(_ item: StudyItem, grade: FSRS.Grade) {
        let seconds = Date().timeIntervalSince(startedAt)
        let wasCorrect = result?.verdict.isRecall ?? grade.isRecall

        study.record(item.id, grade: grade, confidence: confidence, correct: wasCorrect,
                     seconds: seconds, typed: typed, sessionID: sessionID,
                     params: study.parameters(for: item, base: settings.fsrsParameters),
                     updatesSchedule: mode.updatesSchedule)

        answered += 1
        if wasCorrect { correct += 1 } else { missed.append(item.id) }
        if let c = confidence {
            calibrationErrors.append(abs(c.predictedRecall - (wasCorrect ? 1 : 0)))
        }

        // "Again" means it isn't learned — put it back near the end of this
        // session rather than waiting for tomorrow.
        if grade == .again, mode.updatesSchedule, queue.count - index > 1 {
            queue.append(item)
        }

        advance()
    }

    private func advance() {
        player.stop()
        typed = ""
        confidence = nil
        pickedChoice = nil
        result = nil
        phase = .asking
        startedAt = Date()
        index += 1
        if index >= queue.count { finish() }
    }

    private func finish() {
        guard summary == nil else { dismiss(); return }
        guard answered > 0 else { dismiss(); return }
        let error = calibrationErrors.isEmpty
            ? nil : calibrationErrors.reduce(0, +) / Double(calibrationErrors.count)
        summary = SessionSummary(mode: mode, answered: answered, correct: correct,
                                 seconds: Date().timeIntervalSince(startedAt),
                                 missedItemIDs: missed, calibrationError: error)
        Haptics.success()
    }

    private func playMoment(_ item: StudyItem) {
        guard let seconds = item.timestamp else { return }
        if player.isPlaying { player.pause(); return }
        guard let recording = store.recording(item.recordingID), recording.hasAudio else { return }

        Task {
            isFetchingAudio = true
            defer { isFetchingAudio = false }
            if !player.isLoaded {
                guard let url = try? await store.audio.ensureLocal(for: recording) else { return }
                player.load(url)
            }
            store.markPlayed(recording.id)
            // Start a little before the moment — a bookmark timestamp lands on
            // the sentence, and the setup for it is what makes it make sense.
            player.play(from: max(0, seconds - 4))
        }
    }
}

// MARK: - Progress pips

struct ProgressPips: View {
    let total: Int
    let done: Int
    var tint: Color = .brand

    var body: some View {
        HStack(spacing: 3) {
            if total <= 24 {
                ForEach(0..<total, id: \.self) { i in
                    Capsule()
                        .fill(i < done ? tint : Color.primary.opacity(0.14))
                        .frame(width: i == done ? 10 : 5, height: 5)
                }
            } else {
                Text("\(min(done + 1, total)) / \(total)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.quick, value: done)
    }
}
