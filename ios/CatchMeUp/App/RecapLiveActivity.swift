import ActivityKit
import Foundation

@MainActor
final class RecapLiveActivity {
    private var activity: Activity<CatchMeUpActivityAttributes>?

    func start(for recording: Recording) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = CatchMeUpActivityAttributes(
            recordingID: recording.id.uuidString,
            title: recording.displayTitle,
            mode: recording.mode.rawValue
        )
        let state = CatchMeUpActivityAttributes.ContentState(
            stage: "Transcribing on device",
            progress: 0,
            symbol: "waveform",
            isComplete: false
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            // Live Activities can be disabled by the user or unavailable on a
            // simulator. Processing should continue normally in either case.
        }
    }

    func transcription(progress: Double) async {
        await update(stage: "Transcribing on device", progress: progress, symbol: "waveform")
    }

    func writing() async {
        await update(stage: "Writing your notes", progress: 1, symbol: "sparkles")
    }

    func finish(success: Bool) async {
        guard let activity else { return }
        let state = CatchMeUpActivityAttributes.ContentState(
            stage: success ? "Your recap is ready" : "Needs your attention",
            progress: 1,
            symbol: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            isComplete: true
        )
        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(Date().addingTimeInterval(success ? 60 : 300))
        )
        self.activity = nil
    }

    private func update(stage: String, progress: Double, symbol: String) async {
        guard let activity else { return }
        let state = CatchMeUpActivityAttributes.ContentState(
            stage: stage,
            progress: min(max(progress, 0), 1),
            symbol: symbol,
            isComplete: false
        )
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }
}
