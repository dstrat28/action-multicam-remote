import Foundation
import WatchConnectivity

@MainActor
final class WatchConnectivityController: NSObject {
    private enum Command: String {
        case record
        case stop
        case highlight
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
        static let highlightAvailable = "highlightAvailable"
        static let stateVersion = "stateVersion"
    }

    private let store: CameraStore
    private var refreshTask: Task<Void, Never>?
    private var lastPublishedSnapshot: NSDictionary?
    private var lastGeneratedState: NSDictionary?
    private var stateVersion = Date().timeIntervalSinceReferenceDate
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
            return store.startWatchRecording()
        case .stop:
            return store.stopWatchRecording()
        case .highlight:
            guard store.canAddHighlight else { return false }
            store.addHighlight()
            return true
        case .refresh:
            return true
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
            Key.highlightAvailable: store.canAddHighlight,
        ]
        if let lastCommandID, let lastCommandAccepted {
            snapshot[Key.commandID] = lastCommandID
            snapshot[Key.commandAccepted] = lastCommandAccepted
        }

        let comparableState = snapshot as NSDictionary
        if !(lastGeneratedState?.isEqual(comparableState) ?? false) {
            let now = Date().timeIntervalSinceReferenceDate
            stateVersion = max(now, stateVersion.nextUp)
            lastGeneratedState = comparableState
        }
        snapshot[Key.stateVersion] = stateVersion
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
            let session = WCSession.default
            try session.updateApplicationContext(snapshot)
            lastPublishedSnapshot = comparableSnapshot

            // Application context is the durable latest-state fallback, but its
            // delivery can be deferred. Push the same versioned snapshot directly
            // whenever the Watch app is reachable so its visible UI updates now.
            if session.isReachable {
                session.sendMessage(snapshot, replyHandler: nil, errorHandler: nil)
            }
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
