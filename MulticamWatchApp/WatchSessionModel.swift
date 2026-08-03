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
    let remainingVideoSeconds: Int?
    let remainingPhotos: Int?
}

@MainActor
final class WatchSessionModel: NSObject, ObservableObject {
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
                isRecording: dictionary[Key.isRecording] as? Bool ?? false,
                modeName: dictionary[Key.modeName] as? String,
                modeDetails: dictionary[Key.modeDetails] as? [String] ?? [],
                batteryPercent: dictionary[Key.batteryPercent] as? Int,
                batteryBars: dictionary[Key.batteryBars] as? Int,
                isExternalPowerConnected: dictionary[Key.isExternalPowerConnected] as? Bool,
                storageFreeMB: dictionary[Key.storageFreeMB] as? Int,
                storageTotalMB: dictionary[Key.storageTotalMB] as? Int,
                sdCardCapacityMB: dictionary[Key.sdCardCapacityMB] as? Int,
                storageState: dictionary[Key.storageState] as? String,
                remainingVideoSeconds: dictionary[Key.remainingVideoSeconds] as? Int,
                remainingPhotos: dictionary[Key.remainingPhotos] as? Int
            )
        }
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
