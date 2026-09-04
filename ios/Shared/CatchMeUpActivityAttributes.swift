import ActivityKit
import Foundation

struct CatchMeUpActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var stage: String
        var progress: Double
        var symbol: String
        var isComplete: Bool
        /// "about 2 min left", already phrased for display. Nil when we don't
        /// know — an empty slot reads better than a fabricated number.
        var etaText: String?
        /// Waiting on background time. Drawn differently so a stalled
        /// percentage doesn't masquerade as live progress.
        var isPaused: Bool = false
        /// Optional so an activity created by an older app still decodes.
        var isIndeterminate: Bool? = nil
    }

    var recordingID: String
    var title: String
    var mode: String
}
