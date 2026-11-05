import Foundation

// Host-only boundary double; production snapshot encoding and Watch decoding run unchanged.
public enum WCSessionActivationState { case notActivated, activated }
public protocol WCSessionDelegate: AnyObject {}
public final class WCSessionUserInfoTransfer {}
public final class WCSession {
    public static let `default` = WCSession()
    public static func isSupported() -> Bool { false }
    public weak var delegate: WCSessionDelegate?
    public var activationState = WCSessionActivationState.notActivated
    public var isReachable = false
    public var receivedApplicationContext: [String: Any] = [:]
    public func activate() {}
    public func updateApplicationContext(_ context: [String: Any]) throws {}
    public func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?,
                            errorHandler: ((Error) -> Void)?) {}
    @discardableResult public func transferUserInfo(_ info: [String: Any]) -> WCSessionUserInfoTransfer {
        WCSessionUserInfoTransfer()
    }
}
