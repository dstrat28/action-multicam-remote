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
        static let modeName = "modeName"
        static let modeDetails = "modeDetails"
        static let batteryPercent = "batteryPercent"
        static let batteryBars = "batteryBars"
        static let isExternalPowerConnected = "isExternalPowerConnected"
        static let storageFreeMB = "storageFreeMB"
        static let storageTotalMB = "storageTotalMB"
        static let sdCardCapacityMB = "sdCardCapacityMB"
        static let storageState = "storageState"
        static let remainingVideoSeconds = "remainingVideoSeconds"
        static let remainingPhotos = "remainingPhotos"
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
                var snapshot = [
                    Key.id: camera.id.uuidString,
                    Key.name: camera.displayName,
                    Key.model: camera.model.rawValue,
                    Key.isRecording: camera.recordingState == .recording,
                ] as [String: Any]

                if let modeName = camera.currentMode?.displayName(for: camera.model)
                    ?? camera.telemetry?.modeName {
                    snapshot[Key.modeName] = modeName
                }
                snapshot[Key.modeDetails] = captureSettingsSummary(for: camera)

                if let telemetry = camera.telemetry {
                    if let batteryPercent = telemetry.batteryPercent {
                        snapshot[Key.batteryPercent] = batteryPercent
                    }
                    if let batteryBars = telemetry.batteryBars {
                        snapshot[Key.batteryBars] = batteryBars
                    }
                    if let isExternalPowerConnected = telemetry.isExternalPowerConnected {
                        snapshot[Key.isExternalPowerConnected] = isExternalPowerConnected
                    }
                    if let storageFreeMB = telemetry.storageFreeMB {
                        snapshot[Key.storageFreeMB] = Int(storageFreeMB)
                    }
                    if let storageTotalMB = telemetry.storageTotalMB {
                        snapshot[Key.storageTotalMB] = Int(storageTotalMB)
                    }
                    if let sdCardCapacityMB = telemetry.sdCardCapacityMB {
                        snapshot[Key.sdCardCapacityMB] = Int(sdCardCapacityMB)
                    }
                    if let storageState = telemetry.storageState {
                        snapshot[Key.storageState] = storageState
                    }
                    if let remainingVideoSeconds = telemetry.remainingVideoSeconds {
                        snapshot[Key.remainingVideoSeconds] = Int(remainingVideoSeconds)
                    }
                    if let remainingPhotos = telemetry.remainingPhotos {
                        snapshot[Key.remainingPhotos] = Int(remainingPhotos)
                    }
                }

                return snapshot
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

    private func captureSettingsSummary(for camera: DiscoveredCamera) -> [String] {
        guard let telemetry = camera.telemetry else { return [] }

        let settings: [String?]
        switch camera.currentMode {
        case .photo:
            settings = [
                telemetry.videoResolution,
                telemetry.photoAspectRatio,
                telemetry.photoBurstCount.flatMap { $0 > 1 ? "\($0) photos" : nil },
                telemetry.photoCountdownMilliseconds.flatMap {
                    $0 > 0 ? Self.milliseconds($0) + " timer" : nil
                },
            ]
        case .slowMotion:
            settings = [
                telemetry.videoResolution,
                telemetry.frameRate,
                Self.slowMotionRate(from: telemetry.modeParameters),
            ]
        case .timelapse:
            settings = [
                telemetry.videoResolution,
                telemetry.timelapseIntervalTenths.map {
                    "Every \(Self.timelapseInterval(tenths: $0, isHyperlapse: false))"
                },
                telemetry.timelapseDurationSeconds.flatMap {
                    $0 > 0 ? "\(Self.duration(seconds: UInt32($0))) duration" : nil
                },
            ]
        case .hyperlapse:
            settings = [
                telemetry.videoResolution,
                telemetry.timelapseIntervalTenths.map {
                    "\(Self.timelapseInterval(tenths: $0, isHyperlapse: true)) rate"
                },
                telemetry.timelapseDurationSeconds.flatMap {
                    $0 > 0 ? "\(Self.duration(seconds: UInt32($0))) duration" : nil
                },
            ]
        case .video, .superNight,
             .selfie, .boostVideo, .vortex, .panoramicSuperNight, .singleLensSuperNight,
             nil:
            settings = [
                telemetry.videoResolution,
                telemetry.frameRate,
                telemetry.lens ?? telemetry.framing,
            ]
        }

        var seen = Set<String>()
        return settings
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(3)
            .map { $0 }
    }

    private static func slowMotionRate(from modeParameters: String?) -> String? {
        guard let token = modeParameters?
            .split(whereSeparator: \.isWhitespace)
            .last(where: { part in
                let uppercased = part.uppercased()
                return uppercased.hasSuffix("X")
                    && uppercased.dropLast().allSatisfy(\.isNumber)
            }) else {
            return nil
        }
        return "\(token.dropLast())×"
    }

    private static func duration(seconds: UInt32) -> String {
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0, minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(max(1, minutes))m"
    }

    private static func milliseconds(_ value: UInt32) -> String {
        let seconds = Double(value) / 1_000
        return seconds.rounded() == seconds
            ? "\(Int(seconds))s"
            : String(format: "%.1fs", seconds)
    }

    private static func timelapseInterval(tenths: UInt16, isHyperlapse: Bool) -> String {
        if isHyperlapse {
            return tenths == 0 ? "Auto" : "\(tenths)×"
        }

        let seconds = Double(tenths) / 10
        if seconds >= 60, seconds.rounded() == seconds {
            return duration(seconds: UInt32(seconds))
        }
        return seconds.rounded() == seconds
            ? "\(Int(seconds))s"
            : String(format: "%.1fs", seconds)
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
