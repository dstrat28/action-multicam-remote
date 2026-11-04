#if INSTA360_SDK && !targetEnvironment(simulator)
import CoreBluetooth
import Foundation
import INSCameraServiceSDK

private enum Insta360SDKRuntime {
    static var users = 0
    static func acquire() {
        // The sample initializes the camera manager before Bluetooth use. Its
        // header directs setup through the explicit USB manager, not shared().
        if users == 0 { INSCameraManager.usb().setup() }
        users += 1
    }
    static func release() {
        guard users > 0 else { return }
        users -= 1
        if users == 0 { INSCameraManager.usb().shutdown() }
    }
}

private final class Insta360SDKConnectionDelegate: NSObject, INSBluetoothManagerDelegate {
    let onDisconnect: (INSBluetoothDevice, Error?) -> Void
    init(onDisconnect: @escaping (INSBluetoothDevice, Error?) -> Void) { self.onDisconnect = onDisconnect }
    func device(_ device: INSBluetoothDevice, didDisconnectWithError error: Error?) { onDisconnect(device, error) }
}

/// Each camera owns a vendor Bluetooth manager, device, and command interface.
/// Capture and status commands always use the per-device command interface.
final class Insta360SDKClient: NSObject, BLECameraDeviceClient {
    let cameraID: UUID
    let cameraName: String
    private let cameraModel: CameraModel
    var managesOwnConnection: Bool { true }
    private var manager: INSBluetoothManager?
    private var connectionDelegate: Insta360SDKConnectionDelegate?
    private var holdsRuntime = false
    private var device: INSBluetoothDevice?
    private var commands: INSCameraBasicCommands?
    private var connectTask: Any?
    private var stateObservation: NSKeyValueObservation?
    private var timer: Timer?
    private var generation = UUID()
    private var beganAt: TimeInterval = 0
    private var nextStatusAt: TimeInterval = 0
    private var nextTelemetryAt: TimeInterval = 0
    private var queryBeganAt: TimeInterval?
    private var ready = false
    private var telemetry = CameraTelemetry()
    private var telemetryAt: TimeInterval?
    private var lastStatusAt: TimeInterval?
    private var nextModeErrorLogAt: TimeInterval = 0
    private let session: Insta360SDKSession
    private let onStatus: (UUID, CameraConnectionState, String?) -> Void
    private let onCameraStatus: (UUID, CameraStatusUpdate) -> Void
    private let onLog: (String) -> Void

    init(cameraID: UUID, cameraName: String, cameraModel: CameraModel,
         onStatus: @escaping (UUID, CameraConnectionState, String?) -> Void,
         onCameraStatus: @escaping (UUID, CameraStatusUpdate) -> Void,
         onLog: @escaping (String) -> Void,
         onCommandCompleted: @escaping (CameraCommandResult) -> Void) {
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.cameraModel = cameraModel
        self.onStatus = onStatus
        self.onCameraStatus = onCameraStatus
        self.onLog = onLog
        session = Insta360SDKSession(cameraID: cameraID, cameraName: cameraName)
        super.init()
        session.onCompletion = onCommandCompleted
    }

    deinit { disconnectManagedConnection() }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func didConnect() {
        disconnectManagedConnection()
        Insta360SDKRuntime.acquire()
        holdsRuntime = true
        beganAt = now
        let manager = INSBluetoothManager()
        self.manager = manager
        let token = generation
        let delegate = Insta360SDKConnectionDelegate { [weak self] device, error in
            DispatchQueue.main.async {
                guard let self, self.generation == token,
                      UUID(uuidString: device.identifierUUIDStringSafe) == self.cameraID else { return }
                self.fail(error?.localizedDescription ?? "Camera disconnected from SDK Bluetooth.")
            }
        }
        connectionDelegate = delegate
        manager.delegate = delegate
        stateObservation = manager.observe(\.state, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.pump()
            }
        }
        // Tick command deadlines and poll per-device capture status. The
        // vendor's sendHeartbeats API is documented for socket connections;
        // its Bluetooth sample polls capture status instead. Common modes
        // keep our polling active while menus and scrolling track touches.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.pump() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        log("Opening per-camera SDK Bluetooth session.")
        pump()
    }

    func didDisconnect(error: Error?) { disconnectManagedConnection() }

    func disconnectManagedConnection() {
        generation = UUID()
        timer?.invalidate()
        timer = nil
        stateObservation = nil
        let oldManager = manager
        manager = nil
        oldManager?.delegate = nil
        connectionDelegate = nil
        if let connectTask { oldManager?.cancelConnect(connectTask) }
        if let device { oldManager?.disconnectDevice(device) }
        oldManager?.stopScan()
        connectTask = nil
        device = nil
        commands = nil
        queryBeganAt = nil
        nextStatusAt = 0
        nextTelemetryAt = 0
        ready = false
        telemetry = CameraTelemetry()
        telemetryAt = nil
        lastStatusAt = nil
        nextModeErrorLogAt = 0
        session.end()
        if holdsRuntime {
            holdsRuntime = false
            Insta360SDKRuntime.release()
        }
    }

    func send(_ command: CameraCommand) -> CameraCommandResult {
        guard ready, let commands else {
            return result(for: command, status: .skipped, message: "SDK Bluetooth is not ready.")
        }
        let result = session.send(command, at: now)
        guard result.status == .queued else { return result }
        let token = generation
        let completion: (Error?) -> Void = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.session.accepted(result.id, error: error, at: self.now)
                self.log("\(command.label): \(error?.localizedDescription ?? "SDK accepted; awaiting status").")
                self.nextStatusAt = 0
            }
        }
        switch command {
        case .startRecording:
            commands.startCapture(with: nil, completion: completion)
        case .stopRecording:
            commands.stopCapture(with: nil) { error, _ in completion(error) }
        case .capturePhoto:
            commands.takePicture(with: nil) { error, _ in completion(error) }
        case .setMode(let mode):
            let options = INSCameraOptions()
            let type = NSNumber(value: (mode == .video
                ? INSCameraOptionsType.videoSubMode : .photoSubMode).rawValue)
            if mode == .video { options.videoSubMode = 0 } else { options.photoSubMode = 0 }
            commands.setOptions(options, forTypes: [type]) { error, _ in completion(error) }
        default:
            break // Rejected by session.send before any SDK call.
        }
        return result
    }

    private func pump() {
        guard let manager else { return }
        session.tick(at: now)
        if manager.state == .bluetoothDisable || manager.state == .bluetoothUnauthorized {
            fail("Bluetooth is disabled or unavailable to the SDK.")
            return
        }
        if commands == nil {
            guard now - beganAt < 30 else { fail("SDK Bluetooth connection timed out."); return }
            if manager.state == .ready, connectTask == nil {
                let token = generation
                connectTask = manager.connect(with: cameraID) { [weak self] error, device in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { return }
                        guard let device, error == nil,
                              UUID(uuidString: device.identifierUUIDStringSafe) == self.cameraID,
                              let commands = self.manager?.getCommandBy(device) as? INSCameraBasicCommands else {
                            self.fail(error?.localizedDescription ?? "SDK did not return this camera's command interface.")
                            return
                        }
                        self.device = device
                        self.commands = commands
                        self.connectTask = nil
                        self.pump()
                    }
                }
            }
            return
        }
        guard now - (lastStatusAt ?? beganAt) < 30 else {
            fail("SDK has not returned a capture status for 30 seconds.")
            return
        }
        publish()
        if let queryBeganAt {
            if now - queryBeganAt >= 30 { fail("SDK status request timed out; closing the session.") }
            return
        }
        if now >= nextTelemetryAt, ready, !session.isBusy {
            readTelemetry()
        } else if now >= nextStatusAt {
            readStatus()
        }
    }

    private func readStatus() {
        guard let commands else { return }
        queryBeganAt = now
        let token = generation
        let commandID = session.pendingID
        let observationToken = session.observationToken
        commands.getCurrentCaptureStatus { [weak self] error, status in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                guard error == nil, let status else {
                    self.queryBeganAt = nil
                    self.nextStatusAt = self.now + 1
                    self.log("SDK capture status failed: \(error?.localizedDescription ?? "missing status").")
                    return
                }
                let observedAt = self.now
                let recordingState = Insta360SDKSession.recordingState(rawValue: status.state.rawValue)
                let elapsed = UInt32(clamping: status.captureTime)
                let photoType = NSNumber(value: INSCameraOptionsType.photoSubMode.rawValue)
                let videoType = NSNumber(value: INSCameraOptionsType.videoSubMode.rawValue)
                self.commands?.getOptionsWithTypes([photoType, videoType]) { [weak self] error, options, successTypes in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { return }
                        self.queryBeganAt = nil
                        self.nextStatusAt = self.now + 1
                        // The SDK contract says nil error means all requested
                        // options succeeded; successTypes itself is nullable.
                        let successful = error == nil ? [photoType, videoType] : (successTypes ?? [])
                        let captureMode = Insta360SDKSession.mode(
                            photoSubMode: successful.contains(photoType) ? options?.photoSubMode : nil,
                            videoSubMode: successful.contains(videoType) ? options?.videoSubMode : nil)
                        if captureMode == nil, self.now >= self.nextModeErrorLogAt {
                            self.log("SDK normal capture mode is unknown: \(error?.localizedDescription ?? "unsupported or incomplete mode response").")
                            self.nextModeErrorLogAt = self.now + 30
                        }
                        self.session.tick(at: self.now)
                        let accepted = self.session.observe(state: recordingState,
                            mode: captureMode, at: observedAt, queryCommandID: commandID, queryToken: observationToken)
                        // A slow mode response must not make an old stopped
                        // observation fresh enough to authorize a new Start.
                        self.session.tick(at: self.now)
                        guard accepted else { self.publish(); return }
                        self.lastStatusAt = observedAt
                        self.telemetry.recordingElapsedSeconds = elapsed
                        if !self.ready {
                            self.ready = true
                            self.log("SDK Bluetooth ready; capture status received.")
                            self.onStatus(self.cameraID, .connected, "Insta360 SDK Bluetooth ready (experimental).")
                        }
                        self.publish()
                    }
                }
            }
        }
    }

    private func readTelemetry() {
        guard let commands else { return }
        queryBeganAt = now
        nextTelemetryAt = now + 30
        let token = generation
        let battery = NSNumber(value: INSCameraOptionsType.batteryStatus.rawValue)
        let storage = NSNumber(value: INSCameraOptionsType.storageState.rawValue)
        let storageList = NSNumber(value: INSCameraOptionsType.storageStateList.rawValue)
        let types = cameraModel == .insta360X6 ? [battery, storage, storageList] : [battery, storage]
        commands.getOptionsWithTypes(types) { [weak self] error, options, successTypes in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.queryBeganAt = nil
                let successful = error == nil ? types : (successTypes ?? [])
                guard let options else {
                    self.log("SDK telemetry failed: \(error?.localizedDescription ?? "missing options").")
                    return
                }
                // Partial responses refresh only explicitly successful fields.
                self.telemetry.batteryPercent = nil
                self.telemetry.isExternalPowerConnected = nil
                self.telemetry.storageState = nil
                self.telemetry.storageFreeMB = nil
                self.telemetry.storageTotalMB = nil
                if successful.contains(battery), let value = options.batteryStatus,
                   value.batteryScale > 0, (0...value.batteryScale).contains(value.batteryLevel) {
                    self.telemetry.batteryPercent = Int((Double(value.batteryLevel) / Double(value.batteryScale) * 100).rounded())
                    self.telemetry.isExternalPowerConnected = value.powerType == .adapter
                }
                if self.cameraModel == .insta360X6 {
                    // The vendor documents separate X6 internal/SD responses.
                    // Do not sum them or claim either is the selected recording volume.
                    var descriptions: [String] = []
                    if successful.contains(storage), let value = options.cameraStorageStatus {
                        descriptions.append(self.storageDescription(value, name: "Internal"))
                    }
                    if successful.contains(storageList),
                       let values = options.storageStateList as? [INSCameraStorageStatus],
                       let value = values.first(where: { $0.cardLocation == .SD }) {
                        descriptions.append(self.storageDescription(value, name: "SD card"))
                    }
                    self.telemetry.storageState = descriptions.isEmpty ? nil : descriptions.joined(separator: " · ")
                } else if successful.contains(storage), let value = options.storageStatus {
                    self.telemetry.storageState = value.cardState == .normal ? "Ready" : "Storage unavailable"
                    if value.cardState == .normal, value.freeSpace >= 0, value.totalSpace > 0,
                       value.freeSpace <= value.totalSpace {
                        self.telemetry.storageFreeMB = UInt32(clamping: value.freeSpace / 1_048_576)
                        self.telemetry.storageTotalMB = UInt32(clamping: value.totalSpace / 1_048_576)
                    }
                }
                self.telemetryAt = self.now
                self.publish()
            }
        }
    }

    private func storageDescription(_ value: INSCameraStorageStatus, name: String) -> String {
        if value.cardState == .normal, value.freeSpace >= 0, value.totalSpace > 0, value.freeSpace <= value.totalSpace {
            let free = ByteCountFormatter.string(fromByteCount: value.freeSpace, countStyle: .file)
            return "\(name): \(free) free"
        }
        return "\(name): storage unavailable"
    }

    private func publish() {
        var value = telemetry
        if telemetryAt.map({ now - $0 > 75 }) != false {
            value = CameraTelemetry(recordingElapsedSeconds: telemetry.recordingElapsedSeconds)
        }
        if session.statusAt == nil { value.recordingElapsedSeconds = nil }
        value.lastUpdated = Date()
        onCameraStatus(cameraID, CameraStatusUpdate(recordingState: session.recordingState,
            currentMode: session.currentMode, telemetry: value, replacesTelemetry: true))
    }

    private func fail(_ message: String) {
        log(message)
        disconnectManagedConnection()
        onCameraStatus(cameraID, CameraStatusUpdate(recordingState: .unknown,
            telemetry: CameraTelemetry(), replacesTelemetry: true))
        onStatus(cameraID, .failed(message), message)
    }

    private func log(_ message: String) { onLog("\(cameraName): Insta360 SDK: \(message)") }
}
#endif
