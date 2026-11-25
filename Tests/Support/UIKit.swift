import Foundation

// Host-only surface used by CameraStore.
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
    public enum State { case active, inactive, background }
    public static let shared = UIApplication()
    public var applicationState: State = .active
    public func beginBackgroundTask(withName name: String) -> UIBackgroundTaskIdentifier { .invalid }
    public func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {}
}
