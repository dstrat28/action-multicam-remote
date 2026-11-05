#if os(watchOS) || DEBUG
import Combine
import Foundation
import WatchConnectivity

struct WatchCamera: Identifiable, Equatable {
    let id: String
    let name: String
    let model: String
    let isRecording: Bool
    let modeName: String?
    let modeDetails: [String]
    let batteryPercent: Int?
    let batteryBars: Int?
    let isExternalPowerConnected: Bool?
    let storageFreeMB: Int?
    let storageTotalMB: Int?
    let sdCardCapacityMB: Int?
    let storageState: String?
    let storageVolumes: [CameraStorageVolume]?
    let remainingVideoSeconds: Int?
    let remainingPhotos: Int?

    init?(snapshot: [String: Any]) {
        guard let id = snapshot["id"] as? String,
              let name = snapshot["name"] as? String,
              let model = snapshot["model"] as? String else { return nil }
        self.id = id
        self.name = name
        self.model = model
        isRecording = snapshot["isRecording"] as? Bool ?? false
        modeName = snapshot["modeName"] as? String
        modeDetails = snapshot["modeDetails"] as? [String] ?? []
        batteryPercent = snapshot["batteryPercent"] as? Int
        batteryBars = snapshot["batteryBars"] as? Int
        isExternalPowerConnected = snapshot["isExternalPowerConnected"] as? Bool
        storageFreeMB = snapshot["storageFreeMB"] as? Int
        storageTotalMB = snapshot["storageTotalMB"] as? Int
        sdCardCapacityMB = snapshot["sdCardCapacityMB"] as? Int
        storageState = snapshot["storageState"] as? String
        storageVolumes = (snapshot["storageVolumes"] as? Data).flatMap {
            try? JSONDecoder().decode([CameraStorageVolume].self, from: $0)
        }
        remainingVideoSeconds = snapshot["remainingVideoSeconds"] as? Int
        remainingPhotos = snapshot["remainingPhotos"] as? Int
    }

    var storageVolumeForRing: CameraStorageVolume? {
        guard let storageVolumes else { return nil }
        if let sd = storageVolumes.first(where: { $0.location == .sdCard }), sd.state != .notInserted {
            return sd
        }
        return storageVolumes.first(where: { $0.location == .internalStorage })
    }

    var storageRingTitle: String {
        switch storageVolumeForRing?.location {
        case .sdCard: "SD Card"
        case .internalStorage: "Internal"
        case nil: "Storage"
        }
    }

    var storageProgress: Double? {
        let free: Double
        let total: Double
        if storageVolumes != nil {
            // Prefer SD for this display; it does not assert the recording target.
            guard let volume = storageVolumeForRing,
                  volume.state == .available,
                  let freeMB = volume.freeMB, let totalMB = volume.totalMB,
                  freeMB != .max, totalMB != .max, totalMB > 0, freeMB <= totalMB else { return nil }
            free = Double(freeMB)
            total = Double(totalMB)
        } else {
            guard let freeMB = storageFreeMB,
                  let totalMB = storageTotalMB ?? sdCardCapacityMB,
                  freeMB >= 0, totalMB > 0, freeMB <= totalMB,
                  let totalValue = UInt32(exactly: totalMB), totalValue != .max else { return nil }
            free = Double(freeMB)
            total = Double(totalMB)
        }
        return 1 - free / total
    }
}

@MainActor
final class WatchSessionModel: NSObject, ObservableObject {
    private enum Key {
        static let command = "command"
        static let commandID = "commandID"
        static let commandAccepted = "commandAccepted"
        static let cameras = "cameras"
        static let recording = "recording"
        static let highlightAvailable = "highlightAvailable"
        static let stateVersion = "stateVersion"
    }

    @Published private(set) var cameras: [WatchCamera] = []
    @Published private(set) var isRecording = false
    @Published private(set) var hasReceivedState = false
    @Published private(set) var isCommandPending = false
    @Published private(set) var pendingCommand: String?
    @Published private(set) var canAddHighlight = false
    @Published private(set) var statusMessage: String?
    private var expectedRecordingState: Bool?
    private var latestStateVersion: TimeInterval = 0
    private var pendingCommandID: String?
    private var commandTimeoutTask: Task<Void, Never>?

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
        send(command: "record", expectedRecordingState: true)
    }

    func stop() {
        send(command: "stop", expectedRecordingState: false)
    }

    func highlight() {
        send(command: "highlight", expectedRecordingState: nil)
    }

    private func send(command: String, expectedRecordingState: Bool?) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            statusMessage = "Connecting…"
            session.activate()
            return
        }

        self.expectedRecordingState = expectedRecordingState
        let commandID = UUID().uuidString
        pendingCommandID = commandID
        isCommandPending = true
        pendingCommand = command
        statusMessage = "Sending…"
        let message: [String: Any] = [
            Key.command: command,
            Key.commandID: commandID,
        ]
        scheduleCommandTimeout(for: commandID)

        guard session.isReachable else {
            session.transferUserInfo(message)
            return
        }

        session.sendMessage(
            message,
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    guard let self else { return }
                    self.apply(reply)
                    if reply["accepted"] as? Bool != true {
                        self.finishPendingCommand(message: "Try again")
                    } else if expectedRecordingState == nil,
                              self.pendingCommandID == commandID {
                        self.finishPendingCommand(message: nil)
                    }
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    guard self?.pendingCommandID == commandID else { return }
                    self?.finishPendingCommand(message: "Try again")
                }
            }
        )
    }

    private func scheduleCommandTimeout(for commandID: String) {
        commandTimeoutTask?.cancel()
        commandTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, self?.pendingCommandID == commandID else { return }
            self?.finishPendingCommand(message: "Check iPhone")
        }
    }

    private func finishPendingCommand(message: String?) {
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        pendingCommandID = nil
        expectedRecordingState = nil
        isCommandPending = false
        pendingCommand = nil
        statusMessage = message
    }

    private func requestLatestState() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }

        session.sendMessage(
            [Key.command: "refresh"],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.apply(reply)
                }
            },
            errorHandler: nil
        )
    }

    private func apply(_ context: [String: Any]) {
        guard !context.isEmpty else { return }

        if let stateVersion = context[Key.stateVersion] as? TimeInterval {
            guard stateVersion >= latestStateVersion else { return }
            latestStateVersion = stateVersion
        }

        hasReceivedState = true
        let cameraDictionaries = context[Key.cameras] as? [[String: Any]] ?? []
        cameras = cameraDictionaries.compactMap(WatchCamera.init(snapshot:))
        isRecording = context[Key.recording] as? Bool
            ?? cameras.contains(where: \.isRecording)
        canAddHighlight = context[Key.highlightAvailable] as? Bool ?? false

        if let pendingCommandID,
           context[Key.commandID] as? String == pendingCommandID {
            if context[Key.commandAccepted] as? Bool == false {
                finishPendingCommand(message: "Try again")
                return
            }

            if context[Key.commandAccepted] as? Bool == true,
               expectedRecordingState == nil {
                finishPendingCommand(message: nil)
                return
            }
        }

        if let expectedRecordingState, isRecording == expectedRecordingState {
            finishPendingCommand(message: nil)
        } else if !isCommandPending {
            statusMessage = nil
        }
    }
}

extension WatchSessionModel: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            if error != nil {
                self?.statusMessage = "Open iPhone app"
            }
            self?.apply(session.receivedApplicationContext)
            self?.requestLatestState()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            if session.isReachable {
                self?.requestLatestState()
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

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.apply(message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        guard error != nil else { return }

        Task { @MainActor [weak self] in
            self?.finishPendingCommand(message: "Try again")
        }
    }
}
#endif
