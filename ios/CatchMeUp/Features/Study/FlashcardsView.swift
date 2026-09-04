import SwiftUI

// MARK: - FlashcardsView
//
// The familiar deck: a card, a flip, a swipe. Nothing here is novel and that's
// the point — it's the gesture vocabulary students already have.
//
// What it doesn't do is let the flip stand in for the recall. You can't grade a
// card you haven't turned over, because the whole value of a flashcard is the
// few seconds of effort *before* the answer appears — recognising an answer
// feels identical to knowing it and teaches you nothing. Swiping a face-down
// card turns it instead of scoring it.
//
// Every judgement still lands in FSRS: "Still learning" is a lapse and comes
// back inside the session, "Got it" schedules the card forward. So a deck run
// isn't a side activity — it moves the same schedule the review tab does.

struct FlashcardsView: View {
    let brainID: UUID?
    var limit: Int = 20

    @Environment(LibraryStore.self) private var store
    @Environment(StudyStore.self) private var study
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var queue: [StudyItem] = []
    @State private var index = 0
    @State private var flipped = false
    @State private var dragX: CGFloat = 0
    @State private var flyAway: CGFloat = 0

    @State private var sessionID = UUID()
    @State private var startedAt = Date()
    @State private var cardShownAt = Date()
    @State private var graded = 0
    @State private var known = 0
    @State private var stillLearning: [UUID] = []
    @State private var summary: SessionSummary?

    @State private var player = AudioPlayer()
    @State private var isFetchingAudio = false

    /// Past this much horizontal travel, letting go commits the card.
    private let commitDistance: CGFloat = 108

    private var current: StudyItem? { queue.indices.contains(index) ? queue[index] : nil }

    var body: some View {
        NavigationStack {
            Group {
                if let summary {
                    SessionSummaryView(summary: summary, brainID: brainID) { dismiss() }
                } else if let item = current {
                    deck(item)
                } else {
                    EmptyState(symbol: "rectangle.on.rectangle",
                               title: "No cards here",
                               message: "Cards are made from your recaps. Add one, or pick a different course.",
                               tint: .brand)
                }
            }
            .background(AmbientBackground(tint: .brand))
            .navigationTitle("Flashcards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { finish() }
                }
                ToolbarItem(placement: .principal) {
                    if !queue.isEmpty && summary == nil {
                        ProgressPips(total: queue.count, done: index, tint: .brand)
                    }
                }
            }
            .task { build() }
            .onDisappear { player.stop() }
        }
    }

    // MARK: - Deck

    private func deck(_ item: StudyItem) -> some View {
        VStack(spacing: 0) {
            tally
            Spacer(minLength: 8)
            card(item)
            Spacer(minLength: 8)
            controls(item)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    private var tally: some View {
        HStack(spacing: 8) {
            Chip(text: "Still learning \(stillLearning.count)",
                 symbol: "arrow.trianglehead.counterclockwise", tint: .amber)
            Spacer(minLength: 0)
            Chip(text: "Know \(known)", symbol: "checkmark", tint: .mint)
        }
        .animation(.quick, value: known)
        .animation(.quick, value: stillLearning.count)
    }

    // MARK: Card

    private func card(_ item: StudyItem) -> some View {
        ZStack {
            face(front: true, item: item)
                .opacity(flipped ? 0 : 1)
            face(front: false, item: item)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(flipped ? 1 : 0)
        }
        // The faces swap at the halfway point of the turn, so neither is ever
        // visible mirrored.
        .animation(.linear(duration: 0.01).delay(flipDuration / 2), value: flipped)
        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .animation(reduceMotion ? .quick : .easeInOut(duration: flipDuration), value: flipped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(x: dragX + flyAway)
        .rotationEffect(.degrees(Double(dragX + flyAway) / 24))
        .overlay(alignment: .top) { verdictStamp }
        .contentShape(Rectangle())
        .onTapGesture { flip() }
        .gesture(swipe(item))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("flashcard.card")
        .accessibilityLabel(flipped ? "Answer. \(item.revealText)" : "Card. \(item.prompt)")
        .accessibilityHint(flipped ? "Swipe left if still learning, right if you got it"
                                   : "Double tap to turn the card over")
    }

    private var flipDuration: Double { 0.38 }

    private func face(front: Bool, item: StudyItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Chip(text: front ? item.kind.title : "Answer",
                     symbol: front ? item.kind.symbol : "lightbulb",
                     tint: front ? .brand : .mint)
                if front, item.isNew {
                    Chip(text: "New", symbol: "sparkles", tint: .mint, filled: true)
                }
                Spacer(minLength: 0)
            }

            // Short prompts sit in the middle of the card the way a real one
            // would; long ones scroll instead of overflowing.
            GeometryReader { proxy in
                ScrollView {
                    MarkdownText(front ? item.prompt : item.revealText,
                                 style: faceStyle(front: front))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: proxy.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            if !front, item.timestamp != nil {
                hearItButton(item)
            }

            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.caption2)
                Text(item.sourceTitle)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if front {
                    Text("Tap to turn over")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.brand)
                }
            }
            .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                .fill(Color.cardBG)
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                        .strokeBorder(front ? Color.hairline : Color.mint.opacity(0.28))
                }
                .shadow(color: .black.opacity(0.13), radius: 18, y: 8)
        }
    }

    private func faceStyle(front: Bool) -> MarkdownStyle {
        var style = MarkdownStyle.answer
        style.tint = front ? .brand : .mint
        style.bodyFont = .title3
        return style
    }

    /// The one thing a paper card can't do: play the ten seconds where this was
    /// actually taught.
    private func hearItButton(_ item: StudyItem) -> some View {
        Button {
            Haptics.tap()
            playMoment(item)
        } label: {
            HStack(spacing: 10) {
                IconTile(symbol: player.isPlaying ? "pause.fill" : "play.fill",
                         tint: .mint, size: 32, filled: true)
                Text(player.isPlaying ? "Playing the moment" : "Hear this moment")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if isFetchingAudio { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.mint.opacity(0.12))
            }
        }
        .buttonStyle(.plain)
        .disabled(isFetchingAudio)
    }

    /// The drag's own feedback — which way this is about to go.
    @ViewBuilder
    private var verdictStamp: some View {
        let travel = dragX + flyAway
        let strength = min(1, abs(travel) / commitDistance)

        if flipped, abs(travel) > 12 {
            HStack {
                if travel > 0 { Spacer(minLength: 0) }
                Chip(text: travel > 0 ? "Got it" : "Still learning",
                     symbol: travel > 0 ? "checkmark" : "arrow.trianglehead.counterclockwise",
                     tint: travel > 0 ? .mint : .amber,
                     filled: true)
                    .scaleEffect(0.9 + 0.25 * strength)
                    .opacity(Double(strength))
                if travel < 0 { Spacer(minLength: 0) }
            }
            .padding(18)
        }
    }

    // MARK: Controls

    private func controls(_ item: StudyItem) -> some View {
        HStack(spacing: 11) {
            Button {
                commit(item, grade: .again, direction: -1)
            } label: {
                Label("Still learning", systemImage: "arrow.trianglehead.counterclockwise")
            }
            .buttonStyle(.soft(.amber))

            Button {
                commit(item, grade: .good, direction: 1)
            } label: {
                Label("Got it", systemImage: "checkmark")
            }
            .buttonStyle(.prominent(.mint))
        }
        .disabled(!flipped)
        .opacity(flipped ? 1 : 0.4)
        .animation(.quick, value: flipped)
        .overlay(alignment: .top) {
            if !flipped {
                Text("Answer it in your head first — then turn the card.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .offset(y: -20)
            }
        }
        .padding(.top, 22)
    }

    // MARK: - Gestures

    private func swipe(_ item: StudyItem) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard flyAway == 0 else { return }
                dragX = value.translation.width
            }
            .onEnded { value in
                guard flyAway == 0 else { return }
                let travel = value.translation.width
                guard abs(travel) > commitDistance else {
                    withAnimation(.quick) { dragX = 0 }
                    return
                }
                // A face-down card gets turned, not scored. Grading something
                // you haven't tried to recall is the one thing this screen
                // won't help you do.
                guard flipped else {
                    withAnimation(.quick) { dragX = 0 }
                    flip()
                    return
                }
                commit(item, grade: travel > 0 ? .good : .again,
                       direction: travel > 0 ? 1 : -1)
            }
    }

    private func flip() {
        Haptics.tap(.soft)
        flipped.toggle()
    }

    // MARK: - Flow

    private func build() {
        guard queue.isEmpty else { return }
        study.mintOffline(for: store.sortedRecordings)
        queue = study.queue(mode: .flashcards, brainID: brainID, limit: limit,
                            newLimit: settings.dailyNewLimit)
        startedAt = Date()
        cardShownAt = Date()
    }

    private func commit(_ item: StudyItem, grade: FSRS.Grade, direction: CGFloat) {
        guard flyAway == 0 else { return }
        Haptics.tap(grade == .again ? .medium : .light)

        study.record(item.id, grade: grade, confidence: nil,
                     correct: grade != .again,
                     seconds: Date().timeIntervalSince(cardShownAt),
                     typed: "", sessionID: sessionID,
                     params: study.parameters(for: item, base: settings.fsrsParameters),
                     updatesSchedule: StudyMode.flashcards.updatesSchedule)

        graded += 1
        if grade == .again {
            if !stillLearning.contains(item.id) { stillLearning.append(item.id) }
            // Back into the deck rather than tomorrow's pile — a card you just
            // missed is exactly the one worth seeing again this run.
            queue.append(item)
        } else {
            known += 1
        }

        withAnimation(.easeIn(duration: 0.18)) { flyAway = direction * 620 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            advance()
        }
    }

    private func advance() {
        player.stop()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flipped = false
            dragX = 0
            flyAway = 0
            index += 1
        }
        cardShownAt = Date()
        if index >= queue.count { finish() }
    }

    private func finish() {
        guard summary == nil else { dismiss(); return }
        guard graded > 0 else { dismiss(); return }
        summary = SessionSummary(mode: .flashcards,
                                 answered: graded,
                                 correct: known,
                                 seconds: Date().timeIntervalSince(startedAt),
                                 missedItemIDs: stillLearning,
                                 calibrationError: nil)
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
            player.play(from: max(0, seconds - 4))
        }
    }
}
