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
    private struct TelemetryRequest {
        let id = UUID()
        let beganAt: TimeInterval
        var expired = false
    }
    private var telemetryRequest: TelemetryRequest?
    private var ready = false
    private var telemetry = CameraTelemetry()
    private var telemetryAt: TimeInterval?
    private var lastStatusAt: TimeInterval?
    private var recordingElapsedVisible = false
    private var lastPublishedStatus: CameraStatusUpdate?
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
        session.onCompletion = { [weak self] result in
            // Commands can change the store's progress without changing the
            // camera. Its next status must be allowed to restore that state.
            self?.lastPublishedStatus = nil
            onCommandCompleted(result)
        }
    }

    deinit { disconnectManagedConnection() }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func setRecordingElapsedVisible(_ visible: Bool) {
        guard recordingElapsedVisible != visible else { return }
        recordingElapsedVisible = visible
        if ready { publish() }
    }

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
        telemetryRequest = nil
        nextStatusAt = 0
        nextTelemetryAt = 0
        ready = false
        telemetry = CameraTelemetry()
        telemetryAt = nil
        lastStatusAt = nil
        lastPublishedStatus = nil
        nextModeErrorLogAt = 0
        session.end()
        if holdsRuntime {
            holdsRuntime = false
            Insta360SDKRuntime.release()
        }
    }

    func send(_ command: CameraCommand) -> CameraCommandResult {
        // Even a rejected command can change the store's progress state.
        lastPublishedStatus = nil
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
        if let request = telemetryRequest, !request.expired, now - request.beganAt >= 5 {
            // Keep one outstanding vendor request until it returns. Expiry
            // discards its result without queuing more optional work behind it.
            telemetryRequest?.expired = true
            log("SDK battery/storage request expired; capture polling continues.")
        }
        if let queryBeganAt {
            if now - queryBeganAt >= 30 { fail("SDK status request timed out; closing the session.") }
            return
        }
        if now >= nextStatusAt {
            readStatus()
        } else if telemetryRequest == nil, now >= nextTelemetryAt, ready, !session.isBusy {
            readTelemetry()
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
                // Capture status remains the health signal while recording.
                // Mode must be read again for transitions and pending commands.
                if recordingState == .recording, self.session.recordingState == .recording,
                   !self.session.isBusy, let mode = self.session.currentMode {
                    self.finishStatus(recordingState, mode: mode, elapsed: elapsed,
                        observedAt: observedAt, commandID: commandID, observationToken: observationToken)
                    return
                }
                let photoType = NSNumber(value: INSCameraOptionsType.photoSubMode.rawValue)
                let videoType = NSNumber(value: INSCameraOptionsType.videoSubMode.rawValue)
                self.commands?.getOptionsWithTypes([photoType, videoType]) { [weak self] error, options, successTypes in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { return }
                        // The SDK contract says nil error means all requested
                        // options succeeded; successTypes itself is nullable.
                        let successful = error == nil ? [photoType, videoType] : (successTypes ?? [])
                        let photoSubMode = successful.contains(photoType) ? options?.photoSubMode : nil
                        let videoSubMode = successful.contains(videoType) ? options?.videoSubMode : nil
                        let captureMode = Insta360SDKSession.mode(
                            photoSubMode: photoSubMode, videoSubMode: videoSubMode)
                        if captureMode == nil, self.now >= self.nextModeErrorLogAt {
                            let values = "photoSubMode=\(photoSubMode.map { String($0) } ?? "unavailable"), videoSubMode=\(videoSubMode.map { String($0) } ?? "unavailable")"
                            self.log("SDK capture mode is unknown (\(values)): \(error?.localizedDescription ?? "unsupported or incomplete mode response").")
                            self.nextModeErrorLogAt = self.now + 30
                        }
                        self.finishStatus(recordingState, mode: captureMode, elapsed: elapsed,
                            observedAt: observedAt, commandID: commandID, observationToken: observationToken)
                    }
                }
            }
        }
    }

    private func finishStatus(
        _ state: CameraRecordingState, mode: CaptureMode?, elapsed: UInt32,
        observedAt: TimeInterval, commandID: UUID?, observationToken: UUID
    ) {
        queryBeganAt = nil
        nextStatusAt = now + 1
        session.tick(at: now)
        let accepted = session.observe(state: state, mode: mode, at: observedAt,
            queryCommandID: commandID, queryToken: observationToken)
        // A slow mode response cannot refresh an old stopped observation.
        session.tick(at: now)
        guard accepted else { publish(); return }
        lastStatusAt = observedAt
        telemetry.recordingElapsedSeconds = elapsed
        if !ready {
            ready = true
            log("SDK Bluetooth ready; capture status received.")
            onStatus(cameraID, .connected, "Insta360 SDK Bluetooth ready (experimental).")
        }
        publish()
    }

    private func readTelemetry() {
        guard let commands else { return }
        let request = TelemetryRequest(beganAt: now)
        telemetryRequest = request
        nextTelemetryAt = now + 30
        let token = generation
        let battery = NSNumber(value: INSCameraOptionsType.batteryStatus.rawValue)
        let storage = NSNumber(value: INSCameraOptionsType.storageState.rawValue)
        let storageList = NSNumber(value: INSCameraOptionsType.storageStateList.rawValue)
        let types = cameraModel == .insta360X6 ? [battery, storage, storageList] : [battery, storage]
        commands.getOptionsWithTypes(types) { [weak self] error, options, successTypes in
            DispatchQueue.main.async {
                guard let self, self.generation == token,
                      let pending = self.telemetryRequest, pending.id == request.id else { return }
                self.telemetryRequest = nil
                guard !pending.expired, self.now - pending.beganAt < 5 else { return }
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
                self.telemetry.storageVolumes = []
                if successful.contains(battery), let value = options.batteryStatus,
                   value.batteryScale > 0, (0...value.batteryScale).contains(value.batteryLevel) {
                    self.telemetry.batteryPercent = Int((Double(value.batteryLevel) / Double(value.batteryScale) * 100).rounded())
                    self.telemetry.isExternalPowerConnected = value.powerType == .adapter
                }
                if self.cameraModel == .insta360X6 {
                    // Preserve each reported volume; neither is asserted as primary.
                    if successful.contains(storage), let value = options.cameraStorageStatus {
                        self.telemetry.storageVolumes?.append(self.storageVolume(value, location: .internalStorage))
                    }
                    if successful.contains(storageList),
                       let values = options.storageStateList as? [INSCameraStorageStatus] {
                        let sd = values.filter { $0.cardLocation == .SD }
                        if sd.count == 1 {
                            self.telemetry.storageVolumes?.append(self.storageVolume(sd[0], location: .sdCard))
                        }
                    }
                } else if successful.contains(storage), let value = options.storageStatus {
                    let volume = self.storageVolume(value, location: .sdCard)
                    self.telemetry.storageVolumes = [volume]
                    self.telemetry.storageState = value.cardState == .normal ? "Ready" : "Storage unavailable"
                    self.telemetry.storageFreeMB = volume.freeMB
                    self.telemetry.storageTotalMB = volume.totalMB
                }
                self.telemetryAt = self.now
                self.publish()
            }
        }
    }

    private func storageVolume(_ value: INSCameraStorageStatus, location: CameraStorageVolume.Location) -> CameraStorageVolume {
        if value.cardState == .noCard {
            return .init(location: location, state: location == .sdCard ? .notInserted : .unavailable)
        }
        let readable = value.cardState == .normal || (value.cardState == .noSpace && value.freeSpace == 0)
        if readable, value.freeSpace >= 0, value.totalSpace > 0, value.freeSpace <= value.totalSpace,
           let free = UInt32(exactly: value.freeSpace / 1_048_576),
           let total = UInt32(exactly: value.totalSpace / 1_048_576), total > 0,
           free != .max, total != .max {
            return .init(location: location, freeMB: free, totalMB: total)
        }
        return .init(location: location, state: .unavailable)
    }

    private func publish() {
        var value = telemetry
        if telemetryAt.map({ now - $0 > 75 }) != false {
            value = CameraTelemetry(recordingElapsedSeconds: telemetry.recordingElapsedSeconds)
        }
        if session.statusAt == nil || !recordingElapsedVisible { value.recordingElapsedSeconds = nil }
        // Keep freshness internal; a new display timestamp is not a change.
        value.lastUpdated = nil
        var update = CameraStatusUpdate(recordingState: session.recordingState,
            currentMode: session.currentMode, telemetry: value, replacesTelemetry: true)
        guard update != lastPublishedStatus else { return }
        lastPublishedStatus = update
        update.telemetry?.lastUpdated = Date()
        onCameraStatus(cameraID, update)
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
