import SwiftUI

// MARK: - FocusSessionView
//
// A timer that wraps studying rather than replacing it. The countdown is the
// container; the review session is what happens inside it.
//
// Deliberately not a to-do timer: the point of a fixed block is that it ends,
// and ending is when the break — which is where consolidation happens — gets
// taken instead of skipped.

struct FocusSessionView: View {
    let brainID: UUID?

    @Environment(StudyStore.self) private var study
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var phase: Phase = .idle
    @State private var endsAt: Date?
    @State private var remaining: TimeInterval = 0
    @State private var reviewing = false
    @State private var completedBlocks = 0
    @State private var reviewsAtStart = 0

    private enum Phase { case idle, focusing, resting, finished }

    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var focusLength: TimeInterval { Double(settings.focusMinutes) * 60 }
    private var breakLength: TimeInterval { Double(settings.breakMinutes) * 60 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 26) {
                Spacer(minLength: 0)
                dial
                caption
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 26)
            .background(AmbientBackground(tint: phase == .resting ? .mint : .brand))
            .navigationTitle("Focus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onReceive(tick) { _ in refresh() }
            .onChange(of: scenePhase) { _, newPhase in
                // The countdown is anchored to a wall-clock date, so coming
                // back from the background lands on the right number rather
                // than however many ticks the app happened to receive.
                if newPhase == .active { refresh() }
            }
            .fullScreenCover(isPresented: $reviewing) {
                ReviewSessionView(mode: .review, brainID: brainID, limit: 40)
            }
        }
    }

    // MARK: Dial

    private var dial: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: 16)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(dialTint.gradient, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: progress)

            VStack(spacing: 4) {
                Text(timeText)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(phaseLabel)
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
        }
        .frame(width: 250, height: 250)
    }

    private var dialTint: Color { phase == .resting ? .mint : .brand }

    private var progress: Double {
        let total = phase == .resting ? breakLength : focusLength
        guard total > 0 else { return 0 }
        if phase == .idle { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    private var timeText: String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        if phase == .idle { return "\(settings.focusMinutes):00" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var phaseLabel: String {
        switch phase {
        case .idle:      return "Ready"
        case .focusing:  return "Focus"
        case .resting:   return "Break"
        case .finished:  return "Done"
        }
    }

    // MARK: Caption

    private var caption: some View {
        VStack(spacing: 8) {
            Text(headline)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(blurb)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if completedBlocks > 0 {
                Chip(text: "\(completedBlocks) block\(completedBlocks == 1 ? "" : "s") done",
                     symbol: "checkmark", tint: .brand)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
    }

    private var headline: String {
        switch phase {
        case .idle:     return "\(settings.focusMinutes) minutes, one course"
        case .focusing: return "Reviewing"
        case .resting:  return "Take the break"
        case .finished: return "Block finished"
        }
    }

    private var blurb: String {
        switch phase {
        case .idle:
            let due = study.dueCount(brainID: brainID)
            return due > 0
                ? "\(due) due. Start the timer and work until it ends — no deciding when to stop."
                : "Nothing due right now, but a focus block is a fine way to get ahead."
        case .focusing:
            return "Tap below whenever you want to get back into the questions."
        case .resting:
            return "Actually stop. A short break between blocks is when what you just retrieved settles."
        case .finished:
            return "Start another block, or stop here — finishing on purpose beats trailing off."
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 11) {
            switch phase {
            case .idle:
                Button {
                    Haptics.tap()
                    start(.focusing)
                    reviewing = true
                } label: { Label("Start focus block", systemImage: "play.fill") }
                    .buttonStyle(.prominent(.brand))

            case .focusing:
                Button {
                    Haptics.tap()
                    reviewing = true
                } label: { Label("Back to questions", systemImage: "arrow.right") }
                    .buttonStyle(.prominent(.brand))
                Button("End block early") { finishFocus() }
                    .buttonStyle(.soft())

            case .resting:
                Button {
                    Haptics.tap()
                    start(.focusing)
                    reviewing = true
                } label: { Label("Skip the break", systemImage: "forward.fill") }
                    .buttonStyle(.soft(.mint))

            case .finished:
                Button {
                    Haptics.tap()
                    start(.focusing)
                    reviewing = true
                } label: { Label("Another block", systemImage: "arrow.clockwise") }
                    .buttonStyle(.prominent(.brand))
                Button("Finish for now") { dismiss() }
                    .buttonStyle(.soft())
            }
        }
    }

    // MARK: Timing

    private func start(_ next: Phase) {
        phase = next
        let length = next == .resting ? breakLength : focusLength
        endsAt = Date().addingTimeInterval(length)
        remaining = length
        if next == .focusing { reviewsAtStart = study.reviewsToday() }
    }

    private func refresh() {
        guard let endsAt, phase == .focusing || phase == .resting else { return }
        remaining = max(0, endsAt.timeIntervalSinceNow)
        guard remaining <= 0 else { return }

        switch phase {
        case .focusing: finishFocus()
        case .resting:
            phase = .finished
            self.endsAt = nil
            Haptics.tap(.medium)
        default: break
        }
    }

    private func finishFocus() {
        completedBlocks += 1
        reviewing = false
        Haptics.success()
        start(.resting)
    }
}
