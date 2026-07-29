import Foundation
import WatchConnectivity

@MainActor
final class WatchConnectivityController: NSObject {
    private enum Command: String {
        case record
        case stop
        case refresh
    }

    private enum Key {
        static let command = "command"
        static let commandID = "commandID"
        static let commandAccepted = "commandAccepted"
        static let cameras = "cameras"
        static let id = "id"
        static let name = "name"
        static let model = "model"
        static let isRecording = "isRecording"
        static let recording = "recording"
    }

    private let store: CameraStore
    private var refreshTask: Task<Void, Never>?
    private var lastPublishedSnapshot: NSDictionary?
    private var lastCommandID: String?
    private var lastCommandAccepted: Bool?

    init(store: CameraStore) {
        self.store = store
        super.init()

        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.publishSnapshotIfNeeded()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    private func handle(_ command: Command) -> Bool {
        switch command {
        case .record:
            store.startWatchRecording()
        case .stop:
            store.stopWatchRecording()
        case .refresh:
            true
        }
    }

    private func makeSnapshot() -> [String: Any] {
        let cameras = store.readyConnectedCameras
            .filter(\.supportsBatchRecord)
            .map { camera in
                [
                    Key.id: camera.id.uuidString,
                    Key.name: camera.displayName,
                    Key.model: camera.model.rawValue,
                    Key.isRecording: camera.recordingState == .recording,
                ] as [String: Any]
            }
        let isRecording = store.cameras.contains {
            $0.supportsBatchRecord
                && $0.recordingState == .recording
        }
        var snapshot: [String: Any] = [
            Key.cameras: cameras,
            Key.recording: isRecording,
        ]
        if let lastCommandID, let lastCommandAccepted {
            snapshot[Key.commandID] = lastCommandID
            snapshot[Key.commandAccepted] = lastCommandAccepted
        }
        return snapshot
    }

    private func publishSnapshotIfNeeded(force: Bool = false) {
        guard WCSession.isSupported() else { return }

        let snapshot = makeSnapshot()
        let comparableSnapshot = snapshot as NSDictionary

        guard force || !(lastPublishedSnapshot?.isEqual(comparableSnapshot) ?? false) else {
            return
        }

        do {
            try WCSession.default.updateApplicationContext(snapshot)
            lastPublishedSnapshot = comparableSnapshot
        } catch {
            // A future refresh retries once the session becomes active.
        }
    }
}

extension WatchConnectivityController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.publishSnapshotIfNeeded(force: true)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let rawCommand = message[Key.command] as? String,
                  let command = Command(rawValue: rawCommand) else {
                replyHandler(["accepted": false])
                return
            }

            let accepted = self?.handle(command) ?? false
            if command != .refresh {
                self?.lastCommandID = message[Key.commandID] as? String
                self?.lastCommandAccepted = accepted
            }
            self?.publishSnapshotIfNeeded(force: true)
            var reply = self?.makeSnapshot() ?? [:]
            reply["accepted"] = accepted
            replyHandler(reply)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            guard let rawCommand = userInfo[Key.command] as? String,
                  let command = Command(rawValue: rawCommand),
                  command != .refresh else {
                return
            }

            let accepted = self?.handle(command) ?? false
            self?.lastCommandID = userInfo[Key.commandID] as? String
            self?.lastCommandAccepted = accepted
            self?.publishSnapshotIfNeeded(force: true)
        }
    }
}
