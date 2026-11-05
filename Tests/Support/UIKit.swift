import Foundation

// Host-only surface used by CameraStore diagnostics; never in an app target.
public final class UIDevice {
    public static let current = UIDevice()
    public let model = "Host fixture"
    public let systemName = "Test"
    public let systemVersion = "1"
}
public struct UIBackgroundTaskIdentifier: Equatable {
    public static let invalid = Self()
}
public final class UIApplication {
    public static let shared = UIApplication()
    public func beginBackgroundTask(withName name: String) -> UIBackgroundTaskIdentifier { .invalid }
    public func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {}
}
