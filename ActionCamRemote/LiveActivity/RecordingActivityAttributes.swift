import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var recordingCameraCount: Int
        var connectedCameraCount: Int
        var isStopping: Bool
        var canAddHighlight: Bool

        init(
            recordingCameraCount: Int,
            connectedCameraCount: Int,
            isStopping: Bool,
            canAddHighlight: Bool
        ) {
            self.recordingCameraCount = recordingCameraCount
            self.connectedCameraCount = connectedCameraCount
            self.isStopping = isStopping
            self.canAddHighlight = canAddHighlight
        }

        private enum CodingKeys: String, CodingKey {
            case recordingCameraCount
            case connectedCameraCount
            case isStopping
            case canAddHighlight
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            recordingCameraCount = try container.decode(Int.self, forKey: .recordingCameraCount)
            connectedCameraCount = try container.decode(Int.self, forKey: .connectedCameraCount)
            isStopping = try container.decode(Bool.self, forKey: .isStopping)
            canAddHighlight = try container.decodeIfPresent(Bool.self, forKey: .canAddHighlight) ?? false
        }
    }

    var startedAt: Date
}
