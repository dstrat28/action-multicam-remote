import Foundation

// Isolate host fixtures from the user's saved cameras and ActivityKit.
final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor
final class RecordingLiveActivityController {
    func reconcile(cameras: [DiscoveredCamera]) {}
    func markStopping(cameras: [DiscoveredCamera]) {}
}

extension Notification.Name {
    static let stopRecordingFromLiveActivity = Self("test.stop")
    static let addHighlightFromLiveActivity = Self("test.highlight")
}
