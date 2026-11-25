import Foundation

// Host-only boundary double; production snapshot encoding and Watch decoding run unchanged.
public enum WCSessionActivationState { case notActivated, activated }
public protocol WCSessionDelegate: AnyObject {}
public final class WCSessionUserInfoTransfer {
    public let userInfo: [String: Any]
    init(userInfo: [String: Any]) { self.userInfo = userInfo }
}
public final class WCSession {
    public static let `default` = WCSession()
    public static var supported = false
    public static func isSupported() -> Bool { supported }
    public weak var delegate: WCSessionDelegate?
    public var activationState = WCSessionActivationState.notActivated
    public var isReachable = false
    public var receivedApplicationContext: [String: Any] = [:]
    public private(set) var sentMessages: [[String: Any]] = []
    public private(set) var userInfoTransfers: [WCSessionUserInfoTransfer] = []
    public func activate() {}
    public func updateApplicationContext(_ context: [String: Any]) throws {}
    public func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?,
                            errorHandler: ((Error) -> Void)?) { sentMessages.append(message) }
    @discardableResult public func transferUserInfo(_ info: [String: Any]) -> WCSessionUserInfoTransfer {
        let transfer = WCSessionUserInfoTransfer(userInfo: info)
        userInfoTransfers.append(transfer)
        return transfer
    }
}
