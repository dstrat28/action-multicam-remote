import Foundation
import WatchConnectivity

struct WatchCamera: Identifiable, Equatable {
    let id: String
    let name: String
    let model: String
    let isRecording: Bool
}

@MainActor
final class WatchSessionModel: NSObject, ObservableObject {
    private enum Key {
        static let command = "command"
        static let cameras = "cameras"
        static let id = "id"
        static let name = "name"
        static let model = "model"
        static let isRecording = "isRecording"
        static let recording = "recording"
    }

    @Published private(set) var cameras: [WatchCamera] = []
    @Published private(set) var isRecording = false
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var statusMessage: String?

    override init() {
        super.init()

        guard WCSession.isSupported() else {
            statusMessage = "Watch connection unavailable"
            return
        }

        let session = WCSession.default
        session.delegate = self
        session.activate()
        apply(session.receivedApplicationContext)
    }

    func record() {
        send(command: "record")
    }

    func stop() {
        send(command: "stop")
    }

    private func send(command: String) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else {
            statusMessage = "Open Multicam on iPhone"
            return
        }

        statusMessage = nil
        WCSession.default.sendMessage(
            [Key.command: command],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    if reply["accepted"] as? Bool != true {
                        self?.statusMessage = "Command not accepted"
                    }
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.statusMessage = "iPhone unavailable"
                }
            }
        )
    }

    private func apply(_ context: [String: Any]) {
        guard !context.isEmpty else { return }

        let cameraDictionaries = context[Key.cameras] as? [[String: Any]] ?? []
        cameras = cameraDictionaries.compactMap { dictionary in
            guard let id = dictionary[Key.id] as? String,
                  let name = dictionary[Key.name] as? String,
                  let model = dictionary[Key.model] as? String else {
                return nil
            }

            return WatchCamera(
                id: id,
                name: name,
                model: model,
                isRecording: dictionary[Key.isRecording] as? Bool ?? false
            )
        }
        isRecording = context[Key.recording] as? Bool
            ?? cameras.contains(where: \.isRecording)
    }
}

extension WatchSessionModel: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.isPhoneReachable = activationState == .activated && session.isReachable
            if let error {
                self?.statusMessage = error.localizedDescription
            }
            self?.apply(session.receivedApplicationContext)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.isPhoneReachable = session.isReachable
            if session.isReachable {
                self?.statusMessage = nil
            }
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.apply(applicationContext)
        }
    }
}
