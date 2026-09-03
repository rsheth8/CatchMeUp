import ActivityKit
import Foundation

struct CatchMeUpActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var stage: String
        var progress: Double
        var symbol: String
        var isComplete: Bool
    }

    var recordingID: String
    var title: String
    var mode: String
}
