import CoreBluetooth
import Foundation

enum GoProBLEUUID {
    static let serviceControlAndQuery = CBUUID(string: "FEA6")
    static let serviceCameraManagement = CBUUID(string: "b5f90090-aa8d-11e3-9046-0002a5d5c51b")

    static let command = CBUUID(string: "b5f90072-aa8d-11e3-9046-0002a5d5c51b")
    static let commandResponse = CBUUID(string: "b5f90073-aa8d-11e3-9046-0002a5d5c51b")
    static let settings = CBUUID(string: "b5f90074-aa8d-11e3-9046-0002a5d5c51b")
    static let settingsResponse = CBUUID(string: "b5f90075-aa8d-11e3-9046-0002a5d5c51b")
    static let query = CBUUID(string: "b5f90076-aa8d-11e3-9046-0002a5d5c51b")
    static let queryResponse = CBUUID(string: "b5f90077-aa8d-11e3-9046-0002a5d5c51b")
    static let cameraManagement = CBUUID(string: "b5f90091-aa8d-11e3-9046-0002a5d5c51b")
    static let cameraManagementResponse = CBUUID(string: "b5f90092-aa8d-11e3-9046-0002a5d5c51b")
}

final class GoProBLEClient: NSObject, BLECameraDeviceClient {
    private struct PendingWrite {
        var data: Data
        var characteristic: CBCharacteristic
        var logMessage: String?
    }

    let cameraID: UUID
    let cameraName: String

    private weak var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var commandResponseCharacteristic: CBCharacteristic?
    private var settingsCharacteristic: CBCharacteristic?
    private var queryCharacteristic: CBCharacteristic?
    private var queryResponseCharacteristic: CBCharacteristic?
    private var cameraManagementCharacteristic: CBCharacteristic?
    private var cameraManagementResponseCharacteristic: CBCharacteristic?
    private var commandResponseReassembler = GoProPacketReassembler()
    private var queryResponseReassembler = GoProPacketReassembler()
    private var cameraManagementResponseReassembler = GoProPacketReassembler()
    private var keepAliveTimer: Timer?
    private var statusPollTimer: Timer?
    private var statusRefreshTimer: Timer?
    private var settingRefreshTimer: Timer?
    private var pendingWrites: [PendingWrite] = []
    private var activeWrite: PendingWrite?
    private var pendingShutterTargetState: CameraRecordingState?
    private var deferredCommandWhileBusy: CameraCommand?
    private var isCameraBusy = false
    private var hasReceivedBusyStatus = false
    private var hasReceivedEncodingStatus = false
    private var isRegisteredForStatusUpdates = false
    private var isRegisteredForSettingUpdates = false
    private var isProtocolReady = false
    private var reportedCaptureMode: CaptureMode?
    private var requestedCaptureMode: CaptureMode?
    private var hasRequestedHardwareInfo = false
    private var hasSentPairingComplete = false
    private var hasSentThirdPartyClientInfo = false
    private var hasClaimedExternalControl = false
#if DEBUG
    private var lastPowerStatusDebugLabel: String?
    private var lastPowerStatusDebugLogDate = Date.distantPast
#endif
    private let onStatus: (UUID, CameraConnectionState, String?) -> Void
    private let onCameraStatus: (UUID, CameraStatusUpdate) -> Void
    private let onLog: (String) -> Void

    init(
        cameraID: UUID,
        cameraName: String,
        peripheral: CBPeripheral,
        onStatus: @escaping (UUID, CameraConnectionState, String?) -> Void,
        onCameraStatus: @escaping (UUID, CameraStatusUpdate) -> Void,
        onLog: @escaping (String) -> Void
    ) {
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.peripheral = peripheral
        self.onStatus = onStatus
        self.onCameraStatus = onCameraStatus
        self.onLog = onLog
        super.init()
    }

    func didConnect() {
        peripheral?.delegate = self
        peripheral?.discoverServices([
            GoProBLEUUID.serviceControlAndQuery,
            GoProBLEUUID.serviceCameraManagement
        ])
    }

    func didDisconnect(error: Error?) {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        statusPollTimer?.invalidate()
        statusPollTimer = nil
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = nil
        settingRefreshTimer?.invalidate()
        settingRefreshTimer = nil
        pendingWrites.removeAll()
        activeWrite = nil
        pendingShutterTargetState = nil
        deferredCommandWhileBusy = nil
        isCameraBusy = false
        hasReceivedBusyStatus = false
        hasReceivedEncodingStatus = false
        commandCharacteristic = nil
        commandResponseCharacteristic = nil
        settingsCharacteristic = nil
        queryCharacteristic = nil
        queryResponseCharacteristic = nil
        cameraManagementCharacteristic = nil
        cameraManagementResponseCharacteristic = nil
        commandResponseReassembler.reset()
        queryResponseReassembler.reset()
        cameraManagementResponseReassembler.reset()
        isRegisteredForStatusUpdates = false
        isRegisteredForSettingUpdates = false
        isProtocolReady = false
        reportedCaptureMode = nil
        requestedCaptureMode = nil
        hasRequestedHardwareInfo = false
        hasSentPairingComplete = false
        hasSentThirdPartyClientInfo = false
        hasClaimedExternalControl = false
    }

    func send(_ command: CameraCommand) -> CameraCommandResult {
        guard peripheral != nil else {
            return result(for: command, status: .failed, message: "GoPro peripheral is unavailable.")
        }

        if isCameraBusy, shouldDeferWhileBusy(command) {
            deferredCommandWhileBusy = command
            requestStatusValues(shouldLog: false)
            return result(
                for: command,
                status: .queued,
                message: "Waiting for the GoPro to finish its current operation."
            )
        }

        switch command {
        case .startRecording:
            let result = writeCommand(.setShutter(on: true), label: command)
            if result.status == .sent {
                pendingShutterTargetState = .recording
                scheduleStatusRefresh()
            }
            return result
        case .capturePhoto:
            let result = writeCommand(.setShutter(on: true), label: command)
            if result.status == .sent {
                pendingShutterTargetState = .recording
                scheduleStatusRefresh()
            }
            return result
        case .stopRecording:
            let result = writeCommand(.setShutter(on: false), label: command)
            if result.status == .sent {
                pendingShutterTargetState = .stopped
                scheduleStatusRefresh()
            }
            return result
        case .toggleRecording:
            let result = writeCommand(.pressShutterButton, label: command)
            scheduleStatusRefresh()
            return result
        case let .setMode(mode):
            guard let presetGroupID = mode.goProPresetGroupID else {
                return result(for: command, status: .unsupported, message: "This mode is not available on GoPro cameras.")
            }
            let result = writeCommand(.loadPresetGroup(presetGroupID), label: command)
            if result.status == .sent || result.status == .queued {
                requestedCaptureMode = mode
            }
            scheduleStatusRefresh()
            scheduleSettingRefresh()
            return result
        case .cycleMode:
            let result = writeCommand(.pressModeButton, label: command)
            scheduleStatusRefresh()
            return result
        case let .applySetting(setting):
            guard let settingsCharacteristic else {
                return result(for: command, status: .skipped, message: "Settings characteristic is not ready yet.")
            }
            let payload = GoProPacket.commandPayload(id: setting.id, parameters: [setting.value])
            enqueueWrite(
                GoProPacket.packetize(payload),
                to: settingsCharacteristic,
                logMessage: "\(cameraName): GoPro set \(setting.label) -> settings \(payload.hexString)"
            )
            return result(for: command, status: .sent, message: "Queued GoPro setting \(setting.id).")
        case .keepAlive:
            return writeSettingCommand(.keepAlive, label: command)
        }
    }

    private func shouldDeferWhileBusy(_ command: CameraCommand) -> Bool {
        switch command {
        case .startRecording, .capturePhoto, .setMode, .cycleMode, .applySetting:
            true
        case .stopRecording, .toggleRecording, .keepAlive:
            false
        }
    }
}

extension GoProBLEClient {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            onStatus(cameraID, .failed(error.localizedDescription), nil)
            return
        }

        peripheral.services?.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            onStatus(cameraID, .failed(error.localizedDescription), nil)
            return
        }

        service.characteristics?.forEach { characteristic in
            switch characteristic.uuid {
            case GoProBLEUUID.command:
                commandCharacteristic = characteristic
            case GoProBLEUUID.commandResponse:
                commandResponseCharacteristic = characteristic
            case GoProBLEUUID.settings:
                settingsCharacteristic = characteristic
            case GoProBLEUUID.query:
                queryCharacteristic = characteristic
            case GoProBLEUUID.queryResponse:
                queryResponseCharacteristic = characteristic
            case GoProBLEUUID.cameraManagement:
                cameraManagementCharacteristic = characteristic
            case GoProBLEUUID.cameraManagementResponse:
                cameraManagementResponseCharacteristic = characteristic
            default:
                break
            }

            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        if commandCharacteristic != nil, queryCharacteristic != nil {
            onStatus(cameraID, .connecting, "Open GoPro characteristics ready; waiting for camera status.")
        }

        configureReadyNotificationsIfPossible()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            onLog("\(cameraName): notify for \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
            return
        }

        guard characteristic.isNotifying else { return }

        switch characteristic.uuid {
        case GoProBLEUUID.commandResponse:
            requestHardwareInfo()
            sendThirdPartyClientInfoIfPossible()
            claimExternalControlIfPossible(reason: "connection")
        case GoProBLEUUID.queryResponse:
            registerForStatusUpdates()
            registerForSettingUpdates()
            requestStatusValues()
            requestSettingValues()
        case GoProBLEUUID.cameraManagementResponse:
            sendPairingCompleteIfPossible()
        default:
            break
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            onLog("\(cameraName): write to \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
        }
        activeWrite = nil
        writeNextIfPossible()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            onLog("\(cameraName): notification error: \(error.localizedDescription)")
            return
        }

        guard let value = characteristic.value else { return }
        if characteristic.uuid == GoProBLEUUID.commandResponse {
            commandResponseReassembler.append(value).forEach(handleCommandResponse)
        } else if characteristic.uuid == GoProBLEUUID.queryResponse {
            queryResponseReassembler.append(value).forEach(handleQueryResponse)
        } else if characteristic.uuid == GoProBLEUUID.cameraManagementResponse {
            cameraManagementResponseReassembler.append(value).forEach(handleCameraManagementResponse)
        }
        onLog("\(cameraName): \(characteristic.uuid.uuidString) \(value.hexString)")
    }
}

private extension GoProBLEClient {
    enum GoProCommand {
        case setShutter(on: Bool)
        case getHardwareInfo
        case keepAlive
        case setThirdPartyClientInfo
        case pressShutterButton
        case pressModeButton
        case loadPresetGroup(UInt16)

        var payload: Data {
            switch self {
            case let .setShutter(on):
                GoProPacket.commandPayload(id: 0x01, parameters: [on ? 0x01 : 0x00])
            case .getHardwareInfo:
                GoProPacket.commandPayload(id: 0x3C, parameters: [])
            case .keepAlive:
                GoProPacket.commandPayload(id: 0x5B, parameters: [0x42])
            case .setThirdPartyClientInfo:
                GoProPacket.commandPayload(id: 0x50, parameters: [])
            case .pressShutterButton:
                GoProPacket.commandPayload(id: 0x1B, parameterData: [Data([0x00, 0x00])])
            case .pressModeButton:
                GoProPacket.commandPayload(id: 0x1B, parameterData: [Data([0x01, 0x00])])
            case let .loadPresetGroup(presetGroupID):
                GoProPacket.commandPayload(
                    id: 0x3E,
                    parameterData: [GoProPacket.uint16(presetGroupID)]
                )
            }
        }
    }

    enum GoProQuery {
        static let getSettingValues: UInt8 = 0x12
        static let getStatusValues: UInt8 = 0x13
        static let registerSettingUpdates: UInt8 = 0x52
        static let registerStatusUpdates: UInt8 = 0x53
        static let settingUpdateNotification: UInt8 = 0x92
        static let statusUpdateNotification: UInt8 = 0x93

        static let batteryBarsStatusID: UInt8 = 0x02
        static let busyStatusID: UInt8 = 0x08
        static let encodingStatusID: UInt8 = 0x0A
        static let remainingVideoTimeStatusID: UInt8 = 0x23
        static let remainingPhotosStatusID: UInt8 = 0x22
        static let sdCardRemainingStatusID: UInt8 = 0x36
        static let batteryPercentStatusID: UInt8 = 0x46
        static let usbConnectedStatusID: UInt8 = 0x73
        static let flatModeStatusID: UInt8 = 0x59
        static let presetGroupStatusID: UInt8 = 0x60
        static let sdCardCapacityStatusID: UInt8 = 0x75

        static let videoResolutionSettingID: UInt8 = 0x02
        static let frameRateSettingID: UInt8 = 0x03
        static let videoTimelapseRateSettingID: UInt8 = 0x05
        static let videoAspectRatioSettingID: UInt8 = 0x6C
        static let videoLensSettingID: UInt8 = 0x79
        static let photoLensSettingID: UInt8 = 0x7A
        static let timelapseLensSettingID: UInt8 = 0x7B
        static let hypersmoothSettingID: UInt8 = 0x87
        static let multiShotAspectRatioSettingID: UInt8 = 0xC0
        static let framingSettingID: UInt8 = 0xC1
        static let videoFramingSettingID: UInt8 = 0xE8
        static let multiShotFramingSettingID: UInt8 = 0xE9
        static let modernFrameRateSettingID: UInt8 = 0xEA

        static let statusIDs: [UInt8] = [
            batteryBarsStatusID,
            busyStatusID,
            encodingStatusID,
            remainingPhotosStatusID,
            remainingVideoTimeStatusID,
            sdCardRemainingStatusID,
            batteryPercentStatusID,
            usbConnectedStatusID,
            flatModeStatusID,
            presetGroupStatusID,
            sdCardCapacityStatusID
        ]

        static let settingIDs: [UInt8] = [
            videoResolutionSettingID,
            frameRateSettingID,
            videoTimelapseRateSettingID,
            videoAspectRatioSettingID,
            videoLensSettingID,
            photoLensSettingID,
            timelapseLensSettingID,
            hypersmoothSettingID,
            multiShotAspectRatioSettingID,
            framingSettingID,
            videoFramingSettingID,
            multiShotFramingSettingID,
            modernFrameRateSettingID
        ]
    }

    func configureReadyNotificationsIfPossible() {
        if commandResponseCharacteristic?.isNotifying == true {
            requestHardwareInfo()
            sendThirdPartyClientInfoIfPossible()
            claimExternalControlIfPossible(reason: "connection")
        }

        if queryResponseCharacteristic?.isNotifying == true {
            registerForStatusUpdates()
            registerForSettingUpdates()
            requestStatusValues()
            requestSettingValues()
        }

        if cameraManagementResponseCharacteristic?.isNotifying == true {
            sendPairingCompleteIfPossible()
        }
    }

    func writeCommand(
        _ goProCommand: GoProCommand,
        label command: CameraCommand
    ) -> CameraCommandResult {
        guard let commandCharacteristic else {
            return result(for: command, status: .skipped, message: "GoPro command characteristic is not ready yet.")
        }

        claimExternalControlIfPossible(reason: command.label)
        enqueueWrite(
            GoProPacket.packetize(goProCommand.payload),
            to: commandCharacteristic,
            logMessage: "\(cameraName): GoPro \(command.label) -> command \(goProCommand.payload.hexString)"
        )

        return result(for: command, status: .sent, message: "Queued \(command.label) over Open GoPro BLE.")
    }

    func requestHardwareInfo() {
        guard let commandCharacteristic else { return }
        guard !hasRequestedHardwareInfo else { return }

        let payload = GoProCommand.getHardwareInfo.payload
        enqueueWrite(
            GoProPacket.packetize(payload),
            to: commandCharacteristic,
            logMessage: "\(cameraName): GoPro request hardware info \(payload.hexString)"
        )
        hasRequestedHardwareInfo = true
    }

    func sendThirdPartyClientInfoIfPossible() {
        guard let commandCharacteristic, !hasSentThirdPartyClientInfo else { return }

        let payload = GoProCommand.setThirdPartyClientInfo.payload
        enqueueWrite(
            GoProPacket.packetize(payload),
            to: commandCharacteristic,
            logMessage: "\(cameraName): GoPro identify third-party client \(payload.hexString)"
        )
        hasSentThirdPartyClientInfo = true
    }

    func claimExternalControlIfPossible(reason: String) {
        guard let commandCharacteristic, !hasClaimedExternalControl else { return }

        let payload = GoProPacket.protobufPayload(
            featureID: 0xF1,
            actionID: 0x69,
            message: Data([0x08, 0x02])
        )
        enqueueWrite(
            GoProPacket.packetize(payload),
            to: commandCharacteristic,
            logMessage: "\(cameraName): GoPro claim external control (\(reason)) \(payload.hexString)"
        )
        hasClaimedExternalControl = true
    }

    func sendPairingCompleteIfPossible() {
        guard let cameraManagementCharacteristic, !hasSentPairingComplete else { return }

        let phoneName = Data("Action Remote".utf8)
        var message = Data([0x08, 0x00, 0x12, UInt8(phoneName.count)])
        message.append(phoneName)
        let payload = GoProPacket.protobufPayload(featureID: 0x03, actionID: 0x01, message: message)
        enqueueWrite(
            GoProPacket.packetize(payload),
            to: cameraManagementCharacteristic,
            logMessage: "\(cameraName): GoPro pairing complete \(payload.hexString)"
        )
        hasSentPairingComplete = true
    }

    func enqueueWrite(
        _ data: Data,
        to characteristic: CBCharacteristic,
        logMessage: String?,
        coalesce: Bool = false
    ) {
        if coalesce {
            let isAlreadyQueued = activeWrite.map {
                $0.characteristic.uuid == characteristic.uuid && $0.data == data
            } == true || pendingWrites.contains {
                $0.characteristic.uuid == characteristic.uuid && $0.data == data
            }
            guard !isAlreadyQueued else { return }
        }

        pendingWrites.append(
            PendingWrite(data: data, characteristic: characteristic, logMessage: logMessage)
        )
        writeNextIfPossible()
    }

    func writeNextIfPossible() {
        guard activeWrite == nil,
              let peripheral,
              peripheral.state == .connected,
              !pendingWrites.isEmpty else {
            return
        }

        let write = pendingWrites.removeFirst()
        activeWrite = write
        peripheral.writeValue(write.data, for: write.characteristic, type: .withResponse)
        if let logMessage = write.logMessage {
            onLog(logMessage)
        }
    }

    func writeSettingCommand(
        _ goProCommand: GoProCommand,
        label command: CameraCommand
    ) -> CameraCommandResult {
        guard let settingsCharacteristic else {
            return result(for: command, status: .skipped, message: "GoPro settings characteristic is not ready yet.")
        }

        enqueueWrite(
            GoProPacket.packetize(goProCommand.payload),
            to: settingsCharacteristic,
            logMessage: command == .keepAlive
                ? nil
                : "\(cameraName): GoPro \(command.label) -> settings \(goProCommand.payload.hexString)",
            coalesce: command == .keepAlive
        )

        return result(for: command, status: .sent, message: "Queued \(command.label) over Open GoPro BLE.")
    }

    func startKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = commonModeTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            _ = self.send(.keepAlive)
        }
    }

    func registerForStatusUpdates() {
        guard let queryCharacteristic else { return }
        guard !isRegisteredForStatusUpdates else { return }
        let payload = GoProPacket.queryPayload(
            id: GoProQuery.registerStatusUpdates,
            elements: GoProQuery.statusIDs
        )
        enqueueWrite(
            GoProPacket.packetize(payload),
            to: queryCharacteristic,
            logMessage: "\(cameraName): GoPro register status updates \(payload.hexString)"
        )
        isRegisteredForStatusUpdates = true
    }

    func registerForSettingUpdates() {
        guard let queryCharacteristic else { return }
        guard !isRegisteredForSettingUpdates else { return }
        let payload = GoProPacket.queryPayload(
            id: GoProQuery.registerSettingUpdates,
            elements: GoProQuery.settingIDs
        )
        enqueueWrite(
            GoProPacket.packetize(payload),
            to: queryCharacteristic,
            logMessage: "\(cameraName): GoPro register setting updates \(payload.hexString)"
        )
        isRegisteredForSettingUpdates = true
    }

    func requestStatusValues(shouldLog: Bool = true) {
        guard let queryCharacteristic else { return }
        let payload = GoProPacket.queryPayload(
            id: GoProQuery.getStatusValues,
            elements: GoProQuery.statusIDs
        )
        enqueueWrite(
            GoProPacket.packetize(payload),
            to: queryCharacteristic,
            logMessage: shouldLog ? "\(cameraName): GoPro request status values \(payload.hexString)" : nil,
            coalesce: true
        )
    }

    func requestSettingValues(shouldLog: Bool = true) {
        guard let queryCharacteristic else { return }
        let payload = GoProPacket.queryPayload(
            id: GoProQuery.getSettingValues,
            elements: GoProQuery.settingIDs
        )
        enqueueWrite(
            GoProPacket.packetize(payload),
            to: queryCharacteristic,
            logMessage: shouldLog ? "\(cameraName): GoPro request setting values \(payload.hexString)" : nil,
            coalesce: true
        )
    }

    func scheduleStatusRefresh() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = commonModeTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            self?.requestStatusValues()
        }
    }

    func scheduleSettingRefresh() {
        settingRefreshTimer?.invalidate()
        settingRefreshTimer = commonModeTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            self?.requestSettingValues()
        }
    }

    func startStatusPolling() {
        guard statusPollTimer == nil else { return }
        statusPollTimer = commonModeTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.requestStatusValues(shouldLog: false)
        }
    }

    func commonModeTimer(
        withTimeInterval interval: TimeInterval,
        repeats: Bool,
        block: @escaping (Timer) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    func handleCommandResponse(_ payload: Data) {
        logCommandResponsePayload(payload)

        guard payload.count >= 2 else { return }
        let commandID = payload[payload.startIndex]
        let status = payload[payload.index(after: payload.startIndex)]

        if commandID == 0x01, let target = pendingShutterTargetState {
            pendingShutterTargetState = nil
            if status == 0x00 {
                scheduleStatusRefresh()
            } else {
                let recoveredState: CameraRecordingState = target == .recording ? .stopped : .recording
                onCameraStatus(cameraID, CameraStatusUpdate(recordingState: recoveredState))
                onLog("\(cameraName): GoPro rejected shutter command; restored \(recoveredState.rawValue) state.")
            }
        }

        if commandID == GoProHardwareInfo.commandID,
           status == 0x00,
           let hardwareInfo = GoProHardwareInfo(commandResponse: payload) {
            let model = payload.goProModel
            let serialSuffix = hardwareInfo.serialNumber.suffix(4)
            let modelLabel = model?.rawValue ?? hardwareInfo.modelName
            onLog("\(cameraName): GoPro hardware reports \(modelLabel), serial ending \(serialSuffix).")
            onCameraStatus(
                cameraID,
                CameraStatusUpdate(
                    model: model,
                    hardwareIdentifier: hardwareInfo.hardwareIdentifier
                )
            )
            return
        }

        guard let model = payload.goProModel else { return }
        onLog("\(cameraName): GoPro hardware reports \(model.rawValue).")
        onCameraStatus(cameraID, CameraStatusUpdate(model: model))
    }

    func handleCameraManagementResponse(_ payload: Data) {
        guard payload.count >= 3 else {
            onLog("\(cameraName): GoPro camera-management response \(payload.hexString)")
            return
        }

        let status = payload.last ?? 0xFF
        let statusLabel = status == 0x00 ? "success" : "status 0x\(status.hexByte)"
        onLog("\(cameraName): GoPro camera-management response \(statusLabel), payload \(payload.hexString)")
    }

    func logCommandResponsePayload(_ payload: Data) {
        guard let commandID = payload.first else { return }
        let statusIndex = payload.index(after: payload.startIndex)
        let status = statusIndex < payload.endIndex ? payload[statusIndex] : nil
        let statusLabel = status.map { $0 == 0 ? "success" : "status 0x\($0.hexByte)" } ?? "no status"
        onLog(
            "\(cameraName): GoPro command response 0x\(commandID.hexByte) \(statusLabel), payload \(payload.hexString)"
        )
    }

    func handleQueryResponse(_ payload: Data) {
        guard payload.count >= 2, let responseID = payload.first else { return }
        guard responseID == GoProQuery.getStatusValues
            || responseID == GoProQuery.registerStatusUpdates
            || responseID == GoProQuery.statusUpdateNotification
            || responseID == GoProQuery.getSettingValues
            || responseID == GoProQuery.registerSettingUpdates
            || responseID == GoProQuery.settingUpdateNotification else {
            return
        }

        let statusIndex = payload.index(after: payload.startIndex)
        let status = payload[statusIndex]
        guard status == 0x00 else {
            onLog("\(cameraName): GoPro query 0x\(responseID.hexByte) failed with status 0x\(status.hexByte).")
            if responseID == GoProQuery.registerStatusUpdates {
                isRegisteredForStatusUpdates = false
            } else if responseID == GoProQuery.registerSettingUpdates {
                isRegisteredForSettingUpdates = false
            }
            return
        }

        var update = CameraStatusUpdate()
        let valuesStart = payload.index(after: statusIndex)
        let valuesPayload = payload[valuesStart ..< payload.endIndex]

        if responseID == GoProQuery.getStatusValues
            || responseID == GoProQuery.registerStatusUpdates
            || responseID == GoProQuery.statusUpdateNotification {
            let parsedValues = GoProPacket.parseTLVValues(in: valuesPayload)
#if DEBUG
            logPowerStatusDebugValues(parsedValues, rawPayload: Data(valuesPayload))
#endif
            let values = parsedValues
                .filter { Set(GoProQuery.statusIDs).contains($0.key) }

            if let busy = values[GoProQuery.busyStatusID]?.first {
                isCameraBusy = busy != 0
                hasReceivedBusyStatus = true
            }

            if let encoding = values[GoProQuery.encodingStatusID]?.first {
                update.recordingState = encoding == 0 ? .stopped : .recording
                pendingShutterTargetState = nil
                hasReceivedEncodingStatus = true
            }

            markProtocolReadyIfNeeded()

            if let flatMode = values[GoProQuery.flatModeStatusID],
               let mode = CaptureMode(goProFlatModeData: flatMode) {
                update.currentMode = mode
            } else if let presetGroup = values[GoProQuery.presetGroupStatusID],
               let mode = CaptureMode(goProPresetGroupData: presetGroup) {
                update.currentMode = mode
            }

            if let currentMode = update.currentMode {
                let didChangeMode = reportedCaptureMode != currentMode
                reportedCaptureMode = currentMode
                if requestedCaptureMode == currentMode {
                    requestedCaptureMode = nil
                }
                if didChangeMode {
                    requestSettingValues(shouldLog: false)
                }
            }

            let telemetry = goProTelemetry(fromStatusValues: values)
            if !telemetry.isEmpty {
                update.telemetry = telemetry
            }
        }

        if responseID == GoProQuery.getSettingValues
            || responseID == GoProQuery.registerSettingUpdates
            || responseID == GoProQuery.settingUpdateNotification {
            let values = GoProPacket.parseTLVValues(in: valuesPayload)
                .filter { Set(GoProQuery.settingIDs).contains($0.key) }
            let telemetry = goProTelemetry(
                fromSettingValues: values,
                mode: requestedCaptureMode ?? reportedCaptureMode
            )
            if !values.isEmpty {
                update.telemetry = telemetry
                update.replacesCaptureSettings = responseID == GoProQuery.getSettingValues
                    || responseID == GoProQuery.registerSettingUpdates
            }
        }

        if update.recordingState != nil || update.currentMode != nil || update.telemetry != nil {
            onCameraStatus(cameraID, update)
        } else if responseID == GoProQuery.getStatusValues
            || responseID == GoProQuery.registerStatusUpdates
            || responseID == GoProQuery.statusUpdateNotification {
            onCameraStatus(cameraID, CameraStatusUpdate())
        }

        executeDeferredCommandIfReady()
    }

#if DEBUG
    func logPowerStatusDebugValues(_ values: [UInt8: Data], rawPayload: Data) {
        let valueLabel: (UInt8) -> String = { id in
            values[id]?.hexString ?? "missing"
        }
        let label = "USB 0x73=\(valueLabel(GoProQuery.usbConnectedStatusID)), "
            + "battery 0x46=\(valueLabel(GoProQuery.batteryPercentStatusID)), "
            + "bars 0x02=\(valueLabel(GoProQuery.batteryBarsStatusID))"
        let now = Date()

        guard label != lastPowerStatusDebugLabel
            || now.timeIntervalSince(lastPowerStatusDebugLogDate) >= 5 else {
            return
        }

        onLog("\(cameraName): GoPro power status \(label), raw TLV \(rawPayload.hexString).")
        lastPowerStatusDebugLabel = label
        lastPowerStatusDebugLogDate = now
    }
#endif

    func markProtocolReadyIfNeeded() {
        guard !isProtocolReady, hasReceivedBusyStatus, hasReceivedEncodingStatus else { return }
        isProtocolReady = true
        onStatus(cameraID, .connected, "Open GoPro protocol ready.")
        startKeepAlive()
        startStatusPolling()
    }

    func executeDeferredCommandIfReady() {
        guard !isCameraBusy, let command = deferredCommandWhileBusy else { return }
        deferredCommandWhileBusy = nil
        let commandResult = send(command)
        onLog("\(cameraName): deferred GoPro \(command.label.lowercased()) \(commandResult.status.rawValue.lowercased()).")
    }

    func goProTelemetry(fromStatusValues values: [UInt8: Data]) -> CameraTelemetry {
        var telemetry = CameraTelemetry()

        if let batteryPercent = values[GoProQuery.batteryPercentStatusID]?.boundedInt(max: 100) {
            telemetry.batteryPercent = batteryPercent
        }

        let batteryBars = values[GoProQuery.batteryBarsStatusID]?.boundedInt(max: 4)
        if let batteryBars {
            telemetry.batteryBars = batteryBars
        }

        let usbConnected = values[GoProQuery.usbConnectedStatusID]?.first
        if let batteryBars {
            // GoPro reports the otherwise undocumented fourth battery-bars value while
            // externally powered. Status 115 describes a USB data connection and stays
            // false when the camera is connected to a wall charger or power bank.
            telemetry.isExternalPowerConnected = batteryBars == 4 || (usbConnected ?? 0) != 0
        } else if let usbConnected, usbConnected != 0 {
            // A positive USB connection is still valid on hosts that establish USB data.
            // Ignore a lone false value so it cannot clear a charging state reported by
            // the battery-bars notification.
            telemetry.isExternalPowerConnected = true
        }

        if let remainingVideoSeconds = values[GoProQuery.remainingVideoTimeStatusID]?.unsignedInteger,
           remainingVideoSeconds > 0 {
            telemetry.remainingVideoSeconds = remainingVideoSeconds
        }

        if let remainingPhotos = values[GoProQuery.remainingPhotosStatusID]?.unsignedInteger {
            telemetry.remainingPhotos = remainingPhotos
        }

        if let remaining = values[GoProQuery.sdCardRemainingStatusID]?.storageMegabytes {
            telemetry.storageFreeMB = remaining
        }

        if let capacity = values[GoProQuery.sdCardCapacityStatusID]?.storageMegabytes, capacity > 0 {
            telemetry.storageTotalMB = capacity
        }

        telemetry.lastUpdated = Date()
        return telemetry
    }

    func goProTelemetry(
        fromSettingValues values: [UInt8: Data],
        mode: CaptureMode?
    ) -> CameraTelemetry {
        var telemetry = CameraTelemetry()

        switch mode {
        case .photo:
            if let value = values[GoProQuery.multiShotAspectRatioSettingID]?.first {
                telemetry.photoAspectRatio = GoProSettingLabels.aspectRatio(value)
            }
            if let value = values[GoProQuery.multiShotFramingSettingID]?.first {
                telemetry.framing = GoProSettingLabels.videoFraming(value)
            } else if let value = values[GoProQuery.framingSettingID]?.first {
                telemetry.framing = GoProSettingLabels.videoFraming(value)
            }
            if let value = values[GoProQuery.photoLensSettingID]?.first {
                telemetry.lens = GoProSettingLabels.lens(value)
            }
        case .timelapse, .hyperlapse:
            if let value = values[GoProQuery.videoResolutionSettingID]?.first {
                telemetry.videoResolution = GoProSettingLabels.videoResolution(value)
            }
            if let value = values[GoProQuery.multiShotAspectRatioSettingID]?.first {
                telemetry.framing = GoProSettingLabels.aspectRatio(value)
            } else if let value = values[GoProQuery.videoAspectRatioSettingID]?.first {
                telemetry.framing = GoProSettingLabels.aspectRatio(value)
            }
            if let value = values[GoProQuery.multiShotFramingSettingID]?.first {
                telemetry.framing = GoProSettingLabels.videoFraming(value)
            }
            if let value = values[GoProQuery.timelapseLensSettingID]?.first {
                telemetry.lens = GoProSettingLabels.lens(value)
            }
            if let value = values[GoProQuery.videoTimelapseRateSettingID]?.first {
                telemetry.timelapseIntervalTenths = GoProSettingLabels.timelapseIntervalTenths(value)
            }
        default:
            if let value = values[GoProQuery.videoResolutionSettingID]?.first {
                telemetry.videoResolution = GoProSettingLabels.videoResolution(value)
            }
            if let value = values[GoProQuery.frameRateSettingID]?.first {
                telemetry.frameRate = GoProSettingLabels.frameRate(value)
            }
            if let value = values[GoProQuery.modernFrameRateSettingID]?.first {
                telemetry.frameRate = GoProSettingLabels.modernFrameRate(value)
            }
            if let value = values[GoProQuery.videoAspectRatioSettingID]?.first {
                telemetry.framing = GoProSettingLabels.aspectRatio(value)
            }
            if let value = values[GoProQuery.videoFramingSettingID]?.first {
                telemetry.framing = GoProSettingLabels.videoFraming(value)
            }
            if let value = values[GoProQuery.videoLensSettingID]?.first {
                telemetry.lens = GoProSettingLabels.lens(value)
            }
            if let value = values[GoProQuery.hypersmoothSettingID]?.first {
                telemetry.hypersmooth = GoProSettingLabels.hypersmooth(value)
            }
        }

        let now = Date()
        telemetry.captureSettingsUpdatedAt = now
        telemetry.lastUpdated = now
        return telemetry
    }
}

enum GoProPacket {
    static func commandPayload(id: UInt8, parameters: [UInt8]) -> Data {
        commandPayload(id: id, parameterData: parameters.map { Data([$0]) })
    }

    static func commandPayload(id: UInt8, parameterData: [Data]) -> Data {
        var bytes: [UInt8] = [id]
        parameterData.forEach { value in
            bytes.append(UInt8(value.count))
            bytes.append(contentsOf: value)
        }
        return Data(bytes)
    }

    static func queryPayload(id: UInt8, elements: [UInt8]) -> Data {
        Data([id, UInt8(elements.count)] + elements)
    }

    static func protobufPayload(featureID: UInt8, actionID: UInt8, message: Data = Data()) -> Data {
        Data([featureID, actionID]) + message
    }

    static func uint16(_ value: UInt16) -> Data {
        Data([
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    static func packetize(_ payload: Data) -> Data {
        var bytes: [UInt8] = []
        let length = payload.count

        if length <= 0x1FFF {
            bytes.append(0x20 | UInt8((length >> 8) & 0x1F))
            bytes.append(UInt8(length & 0xFF))
            bytes.append(contentsOf: payload)
            return Data(bytes)
        }

        bytes.append(0x1F)
        bytes.append(contentsOf: payload.prefix(0x1FFF))
        return Data(bytes)
    }

    static func depacketize(_ packet: Data) -> Data? {
        guard let first = packet.first else { return nil }

        if (first & 0x80) == 0x80 {
            return nil
        }

        if (first & 0xE0) == 0x20 {
            guard packet.count >= 2 else { return nil }
            let lengthHigh = Int(first & 0x1F) << 8
            let lengthLow = Int(packet[packet.index(after: packet.startIndex)])
            let length = lengthHigh | lengthLow
            guard packet.count >= length + 2 else { return nil }
            let payloadStart = packet.index(packet.startIndex, offsetBy: 2)
            let payloadEnd = packet.index(payloadStart, offsetBy: length)
            return Data(packet[payloadStart ..< payloadEnd])
        }

        if first <= 0x1F {
            let length = Int(first)
            guard packet.count >= length + 1 else { return Data(packet) }
            let payloadStart = packet.index(after: packet.startIndex)
            let payloadEnd = packet.index(payloadStart, offsetBy: length)
            return Data(packet[payloadStart ..< payloadEnd])
        }

        return Data(packet)
    }

    static func parseTLVValues(in payload: Data.SubSequence) -> [UInt8: Data] {
        var values: [UInt8: Data] = [:]
        var offset = payload.startIndex

        while offset < payload.endIndex {
            let id = payload[offset]
            offset = payload.index(after: offset)
            guard offset < payload.endIndex else { break }
            let length = Int(payload[offset])
            offset = payload.index(after: offset)
            guard let valueEnd = payload.index(offset, offsetBy: length, limitedBy: payload.endIndex) else { break }
            values[id] = Data(payload[offset ..< valueEnd])
            offset = valueEnd
        }

        return values
    }
}

private struct GoProPacketReassembler {
    private var pendingMessage = Data()
    private var expectedLength: Int?
    private var expectedContinuationCounter: UInt8 = 0

    mutating func append(_ packet: Data) -> [Data] {
        guard let first = packet.first else { return [] }

        if (first & 0x80) == 0x80 {
            return appendContinuationPacket(packet, header: first)
        }

        return appendStartPacket(packet, header: first)
    }

    mutating func reset() {
        pendingMessage.removeAll()
        expectedLength = nil
        expectedContinuationCounter = 0
    }

    private mutating func appendStartPacket(_ packet: Data, header: UInt8) -> [Data] {
        let parsed = GoProPacketHeader(startPacket: packet, header: header)
        guard let parsed else {
            reset()
            return []
        }

        expectedLength = parsed.messageLength
        expectedContinuationCounter = 0
        pendingMessage = Data(packet.dropFirst(parsed.headerLength))

        return completeMessagesIfReady()
    }

    private mutating func appendContinuationPacket(_ packet: Data, header: UInt8) -> [Data] {
        guard expectedLength != nil else { return [] }

        let counter = header & 0x0F
        if counter != expectedContinuationCounter {
            reset()
            return []
        }

        expectedContinuationCounter = (expectedContinuationCounter + 1) & 0x0F
        pendingMessage.append(contentsOf: packet.dropFirst())
        return completeMessagesIfReady()
    }

    private mutating func completeMessagesIfReady() -> [Data] {
        guard let expectedLength else { return [] }
        guard pendingMessage.count >= expectedLength else { return [] }

        let message = Data(pendingMessage.prefix(expectedLength))
        reset()
        return [message]
    }
}

private struct GoProPacketHeader {
    var messageLength: Int
    var headerLength: Int

    init?(startPacket: Data, header: UInt8) {
        switch header & 0x60 {
        case 0x00:
            self.messageLength = Int(header & 0x1F)
            self.headerLength = 1
        case 0x20:
            guard startPacket.count >= 2 else { return nil }
            let lowByte = startPacket[startPacket.index(after: startPacket.startIndex)]
            self.messageLength = (Int(header & 0x1F) << 8) | Int(lowByte)
            self.headerLength = 2
        case 0x40:
            guard startPacket.count >= 3 else { return nil }
            let highByte = startPacket[startPacket.index(after: startPacket.startIndex)]
            let lowByte = startPacket[startPacket.index(startPacket.startIndex, offsetBy: 2)]
            self.messageLength = (Int(highByte) << 8) | Int(lowByte)
            self.headerLength = 3
        default:
            return nil
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var unsignedInteger: UInt32? {
        if count == 1, let first {
            return UInt32(first)
        }

        if count == 2 {
            let bytes = Array(self)
            return UInt32(bytes[0]) << 8 | UInt32(bytes[1])
        }

        if count >= 4 {
            let bytes = Array(prefix(4))
            return UInt32(bytes[0]) << 24
                | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3])
        }

        return nil
    }

    func boundedInt(max: UInt32) -> Int? {
        guard let unsignedInteger, unsignedInteger <= max else { return nil }
        return Int(unsignedInteger)
    }

    var storageMegabytes: UInt32? {
        let value: UInt64
        if count >= 8 {
            value = prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        } else if let unsignedInteger {
            value = UInt64(unsignedInteger)
        } else {
            return nil
        }

        // Recent GoPro storage statuses are reported in KiB.
        if value >= 1024 {
            return UInt32(Swift.min(value / 1024, UInt64(UInt32.max)))
        }

        return UInt32(value)
    }

    var goProModel: CameraModel? {
        let normalizedText = printableASCIIText.lowercased().filter { $0.isLetter || $0.isNumber }
        for signature in goProModelNameSignatures {
            if normalizedText.contains(signature.normalizedName) {
                return signature.model
            }
        }
        return nil
    }

    var goProModelNameSignatures: [(normalizedName: String, model: CameraModel)] {
        [
            ("h2503", .goproLitHero),
            ("lithero", .goproLitHero),
            ("h2402", .goproMax2),
            ("max2", .goproMax2),
            ("h2401", .goproHero13Black),
            ("hero13", .goproHero13Black),
            ("13black", .goproHero13Black),
            ("h2301", .goproHero12Black),
            ("hero12", .goproHero12Black),
            ("12black", .goproHero12Black),
            ("h2203", .goproHero11BlackMini),
            ("hero11blackmini", .goproHero11BlackMini),
            ("11blackmini", .goproHero11BlackMini),
            ("h2201", .goproHero11Black),
            ("hero11", .goproHero11Black),
            ("11black", .goproHero11Black),
            ("h2101", .goproHero10Black),
            ("hero10", .goproHero10Black),
            ("10black", .goproHero10Black),
            ("hd901", .goproHero9Black),
            ("hero9", .goproHero9Black),
            ("9black", .goproHero9Black),
            ("hero8", .goproHero8Black),
            ("8black", .goproHero8Black),
            ("gopromax", .goproMax),
            ("max", .goproMax)
        ]
    }

    var printableASCIIText: String {
        String(
            bytes: map { byte in
                (0x20 ... 0x7E).contains(byte) ? byte : 0x20
            },
            encoding: .ascii
        ) ?? ""
    }

    var uint32Candidates: Set<UInt32> {
        var values: Set<UInt32> = []
        if count == 1, let first {
            values.insert(UInt32(first))
        }
        if count == 2 {
            let bytes = Array(self)
            values.insert(UInt32(bytes[0]) << 8 | UInt32(bytes[1]))
            values.insert(UInt32(bytes[1]) << 8 | UInt32(bytes[0]))
        }
        if count >= 4 {
            let bytes = Array(prefix(4))
            values.insert(
                UInt32(bytes[0]) << 24
                    | UInt32(bytes[1]) << 16
                    | UInt32(bytes[2]) << 8
                    | UInt32(bytes[3])
            )
            values.insert(
                UInt32(bytes[3]) << 24
                    | UInt32(bytes[2]) << 16
                    | UInt32(bytes[1]) << 8
                    | UInt32(bytes[0])
            )
        }
        return values
    }
}

private enum GoProSettingLabels {
    static func timelapseIntervalTenths(_ value: UInt8) -> UInt16? {
        switch value {
        case 0: 5
        case 1: 10
        case 2: 20
        case 3: 50
        case 4: 100
        case 5: 300
        case 6: 600
        case 7: 1_200
        case 8: 3_000
        case 9: 18_000
        case 10: 36_000
        case 11: 30
        default: nil
        }
    }

    static func videoResolution(_ value: UInt8) -> String {
        switch value {
        case 1:
            "4K"
        case 4:
            "2.7K"
        case 6:
            "2.7K 4:3"
        case 7:
            "1440"
        case 9:
            "1080"
        case 12:
            "720"
        case 18:
            "4K 4:3"
        case 21:
            "5.6K"
        case 24:
            "5K"
        case 25:
            "5K 4:3"
        case 26:
            "5.3K 8:7"
        case 27:
            "5.3K 4:3"
        case 28:
            "4K 8:7"
        case 31:
            "8K"
        case 35:
            "5.3K 21:9"
        case 36:
            "4K 21:9"
        case 37:
            "4K 1:1"
        case 38:
            "900"
        case 39:
            "4K SPH"
        case 100:
            "5.3K"
        case 107:
            "5.3K 8:7"
        case 108:
            "4K 8:7"
        case 109:
            "4K 9:16"
        case 110:
            "1080 9:16"
        case 111:
            "2.7K 4:3"
        case 112:
            "4K 4:3"
        case 113:
            "5.3K 4:3"
        default:
            "Res \(Int(value))"
        }
    }

    static func frameRate(_ value: UInt8) -> String {
        switch value {
        case 0:
            "240fps"
        case 1:
            "120fps"
        case 2:
            "100fps"
        case 3:
            "90fps"
        case 5:
            "60fps"
        case 6:
            "50fps"
        case 8:
            "30fps"
        case 9:
            "25fps"
        case 10:
            "24fps"
        case 13:
            "200fps"
        case 15:
            "400fps"
        case 16:
            "360fps"
        case 17:
            "300fps"
        default:
            "FPS \(Int(value))"
        }
    }

    static func modernFrameRate(_ value: UInt8) -> String {
        switch value {
        case 1:
            "24fps"
        case 2:
            "25fps"
        case 3:
            "30fps"
        case 4:
            "50fps"
        case 5:
            "60fps"
        case 6:
            "100fps"
        case 7:
            "120fps"
        case 8:
            "200fps"
        case 9:
            "240fps"
        default:
            frameRate(value)
        }
    }

    static func aspectRatio(_ value: UInt8) -> String {
        switch value {
        case 0:
            "4:3"
        case 1:
            "16:9"
        case 3:
            "8:7"
        case 4:
            "9:16"
        case 5:
            "21:9"
        case 6:
            "1:1"
        default:
            "Aspect \(Int(value))"
        }
    }

    static func videoFraming(_ value: UInt8) -> String {
        switch value {
        case 0:
            "4:3"
        case 1:
            "16:9"
        case 3:
            "8:7"
        case 4:
            "9:16"
        case 5:
            "21:9"
        case 6:
            "1:1"
        default:
            "Frame \(Int(value))"
        }
    }

    static func lens(_ value: UInt8) -> String {
        switch value {
        case 0:
            "Wide"
        case 2:
            "Narrow"
        case 3:
            "SuperView"
        case 4:
            "Linear"
        case 7:
            "Max SuperView"
        case 8:
            "Linear+HL"
        case 9:
            "HyperView"
        case 10:
            "Linear+Lock"
        case 11:
            "Max HyperView"
        case 12:
            "Ultra SuperView"
        case 13:
            "Ultra Wide"
        case 14:
            "Ultra Linear"
        case 104:
            "Ultra HyperView"
        default:
            "Lens \(Int(value))"
        }
    }

    static func hypersmooth(_ value: UInt8) -> String {
        switch value {
        case 0:
            "Off"
        case 1:
            "Low"
        case 2:
            "High"
        case 3:
            "Boost"
        case 4:
            "AutoBoost"
        case 100:
            "Standard"
        default:
            "\(Int(value))"
        }
    }
}

private extension UInt8 {
    var hexByte: String {
        String(format: "%02X", self)
    }
}

private extension CaptureMode {
    var goProPresetGroupID: UInt16? {
        switch self {
        case .video:
            1000
        case .photo:
            1001
        case .timelapse:
            1002
        case .slowMotion, .hyperlapse, .superNight, .selfie, .boostVideo, .vortex,
             .panoramicSuperNight, .singleLensSuperNight:
            nil
        }
    }

    init?(goProPresetGroupData data: Data) {
        let candidates = data.uint32Candidates
        if candidates.contains(1000) {
            self = .video
        } else if candidates.contains(1001) {
            self = .photo
        } else if candidates.contains(1002) {
            self = .timelapse
        } else {
            return nil
        }
    }

    init?(goProFlatModeData data: Data) {
        let candidates = data.uint32Candidates
        if !candidates.isDisjoint(with: [12, 15, 22, 27, 29, 30, 31, 32]) {
            self = .video
        } else if !candidates.isDisjoint(with: [13, 20, 21, 24, 26]) {
            self = .timelapse
        } else if !candidates.isDisjoint(with: [16, 17, 18, 19, 25]) {
            self = .photo
        } else {
            return nil
        }
    }
}
