import ActivityKit
import Foundation

/// Mirrors the queue's current job onto the Lock Screen and Dynamic Island.
///
/// Every update carries a stale date. If the app gets suspended anyway, iOS
/// dims the activity instead of leaving a percentage that will never move
/// looking authoritative.
@MainActor
final class RecapLiveActivity {
    private var activity: Activity<CatchMeUpActivityAttributes>?

    func start(for recording: Recording, phase: ProcessingQueue.Phase) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // A leftover activity here belongs to a job that was parked, not one
        // that succeeded — ending it with "your recap is ready" would be a lie.
        await discard()

        let attributes = CatchMeUpActivityAttributes(
            recordingID: recording.id.uuidString,
            title: recording.displayTitle,
            mode: recording.mode.rawValue
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: content(phase: phase, eta: nil),
                pushType: nil
            )
        } catch {
            // Live Activities can be disabled by the user or unavailable on a
            // simulator. Processing should continue normally in either case.
        }
    }

    func update(phase: ProcessingQueue.Phase, eta: Double?) async {
        guard let activity else { return }
        await activity.update(content(phase: phase, eta: eta))
    }

    func paused() async {
        guard let activity else { return }
        await activity.update(content(phase: .paused, eta: nil))
    }

    func finish(success: Bool) async {
        guard let activity else { return }
        let state = CatchMeUpActivityAttributes.ContentState(
            stage: success ? "Your recap is ready" : "Needs your attention",
            progress: 1,
            symbol: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            isComplete: true,
            etaText: nil
        )
        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(Date().addingTimeInterval(success ? 60 : 300))
        )
        self.activity = nil
    }

    /// Clears an activity without claiming an outcome for it.
    private func discard() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }

    private func content(
        phase: ProcessingQueue.Phase, eta: Double?
    ) -> ActivityContent<CatchMeUpActivityAttributes.ContentState> {
        let progress: Double
        switch phase {
        case .transcribing(let p): progress = p
        case .writing(let p): progress = p
        case .done: progress = 1
        default: progress = 0
        }

        let state = CatchMeUpActivityAttributes.ContentState(
            stage: phase.label,
            progress: min(max(progress, 0), 1),
            symbol: phase.symbol,
            isComplete: phase.isFinished,
            etaText: eta.map { etaText($0) + " left" },
            isPaused: phase == .paused
        )

        // Whatever we last said is only trustworthy for as long as we expected
        // the step to take, plus a margin.
        let stale = eta.map { Date().addingTimeInterval(max(30, $0 * 1.5)) }
            ?? Date().addingTimeInterval(120)
        return ActivityContent(state: state, staleDate: phase == .paused ? Date() : stale)
    }
}
