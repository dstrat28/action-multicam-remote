import CoreBluetooth
import Foundation

final class DJIExperimentalBLEClient: NSObject, BLECameraDeviceClient {
    enum RSDKWriteDisposition {
        case sent
        case queued
        case skipped
    }

    private struct PendingRSDKWrite {
        var packet: Data
        var label: String
        var shouldLog: Bool
    }

    let cameraID: UUID
    let cameraName: String
    let cameraModel: CameraModel

    private weak var peripheral: CBPeripheral?
    private var writeCandidates: [DJIWritableCharacteristic] = []
    private var rSDKWriteCharacteristic: CBCharacteristic?
    private var rSDKNotifyCharacteristic: CBCharacteristic?
    private var rSDKReceiveBuffer = Data()
    private var rSDKSequenceNumber: UInt16 = UInt16.random(in: .min ... .max)
    private var hasSentRSDKConnectionRequest = false
    private var hasCompletedRSDKHandshake = false
    private var hasCompletedLegacyDumlHandshake = false
    private var hasReportedLegacyDumlReady = false
    private var hasReportedRSDKReady = false
    private var hasSentRSDKStatusSubscription = false
    private var rSDKHandshakePairingRetryCount = 0
    private var rSDKHandshakePairingRetryTimer: Timer?
    private var pendingRSDKWrites: [PendingRSDKWrite] = []
    private var silentRSDKStatusSubscriptionSequences: Set<UInt16> = []
    private var dumlRouting: DJIDUMLRouting
    private var sequenceNumber: UInt16 = UInt16.random(in: .min ... .max)
    private var pendingRecordActionsBySequence: [UInt16: RecordAction] = [:]
    private var pendingModeUpdatesBySequence: [UInt16: CaptureMode] = [:]
    private var pendingStatusProbeLabelsBySequence: [UInt16: String] = [:]
    private var pendingRSDKRecordActionsBySequence: [UInt16: RecordAction] = [:]
    private var pendingRSDKModeUpdatesBySequence: [UInt16: CaptureMode] = [:]
    private var hasSentInitialStatusProbe = false
    private var statusProbeTimer: Timer?
    private var lastCameraStateSummaryLabel: String?
    private var lastCameraStateSummaryLogDate = Date.distantPast
    private var lastRSDKStatusSummaryLabel: String?
    private var lastRSDKStatusSummaryLogDate = Date.distantPast
    private var lastRSDKBufferedFrameLogLabel: String?
#if DEBUG
    private var gpsWriteAttemptCount = 0
    private var gpsImmediateWriteCount = 0
    private var gpsQueuedWriteCount = 0
    private var gpsFlushedWriteCount = 0
    private var lastGPSDebugLogDate = Date.distantPast
    private var lastGPSNotReadyDebugLogDate = Date.distantPast
    private var lastGPSFlushDebugLogDate = Date.distantPast
    private var hasLoggedGPSFrame = false
    private let gpsDebugLogInterval: TimeInterval = 5
    private var lastRSDKStatusPayload: Data?
    private var lastDumlCameraStatePayload: Data?
#endif
    private let maxRSDKHandshakePairingRetries = 15
    private var lastVideoRecordTime: UInt32?
    private var lastAction6StatusDiagnosticLabel: String?
    private var lastUnhandledDumlPacketLabel: String?
    private var compactStoppedProtectionUntil = Date.distantPast
    private let onStatus: (UUID, CameraConnectionState, String?) -> Void
    private let onCameraStatus: (UUID, CameraStatusUpdate) -> Void
    private let onProtocolActivity: (UUID) -> Void
    private let onLog: (String) -> Void
    private let hasConfirmedAwakeNanoAdvertisement: Bool

    init(
        cameraID: UUID,
        cameraName: String,
        cameraModel: CameraModel,
        peripheral: CBPeripheral,
        onStatus: @escaping (UUID, CameraConnectionState, String?) -> Void,
        onCameraStatus: @escaping (UUID, CameraStatusUpdate) -> Void,
        onProtocolActivity: @escaping (UUID) -> Void,
        hasConfirmedAwakeNanoAdvertisement: Bool,
        onLog: @escaping (String) -> Void
    ) {
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.cameraModel = cameraModel
        self.peripheral = peripheral
        self.dumlRouting = Self.defaultDumlRouting(cameraModel: cameraModel, cameraName: cameraName)
        self.onStatus = onStatus
        self.onCameraStatus = onCameraStatus
        self.onProtocolActivity = onProtocolActivity
        self.hasConfirmedAwakeNanoAdvertisement = hasConfirmedAwakeNanoAdvertisement
        self.onLog = onLog
        super.init()
    }

    func didConnect() {
        peripheral?.delegate = self
        peripheral?.discoverServices(nil)
        if cameraBehavior.kind == .djiOsmoNano {
            onLog("\(cameraName): DJI Nano BLE connected; discovering legacy DUML characteristics.")
        } else {
            onLog("\(cameraName): DJI BLE connected; discovering R SDK characteristics.")
        }
        onStatus(cameraID, .connecting, "BLE link established; discovering DJI control characteristics.")
    }

    func didDisconnect(error: Error?) {
        writeCandidates.removeAll()
        rSDKWriteCharacteristic = nil
        rSDKNotifyCharacteristic = nil
        rSDKReceiveBuffer.removeAll(keepingCapacity: true)
        hasSentRSDKConnectionRequest = false
        hasCompletedRSDKHandshake = false
        hasCompletedLegacyDumlHandshake = false
        hasReportedLegacyDumlReady = false
        hasReportedRSDKReady = false
        hasSentRSDKStatusSubscription = false
        rSDKHandshakePairingRetryCount = 0
        rSDKHandshakePairingRetryTimer?.invalidate()
        rSDKHandshakePairingRetryTimer = nil
        pendingRSDKWrites.removeAll()
        silentRSDKStatusSubscriptionSequences.removeAll()
        pendingRecordActionsBySequence.removeAll()
        pendingModeUpdatesBySequence.removeAll()
        pendingStatusProbeLabelsBySequence.removeAll()
        pendingRSDKRecordActionsBySequence.removeAll()
        pendingRSDKModeUpdatesBySequence.removeAll()
        hasSentInitialStatusProbe = false
        statusProbeTimer?.invalidate()
        statusProbeTimer = nil
        lastVideoRecordTime = nil
        lastRSDKStatusSummaryLabel = nil
        lastRSDKStatusSummaryLogDate = .distantPast
        lastRSDKBufferedFrameLogLabel = nil
#if DEBUG
        gpsWriteAttemptCount = 0
        gpsImmediateWriteCount = 0
        gpsQueuedWriteCount = 0
        gpsFlushedWriteCount = 0
        lastGPSDebugLogDate = .distantPast
        lastGPSNotReadyDebugLogDate = .distantPast
        lastGPSFlushDebugLogDate = .distantPast
        hasLoggedGPSFrame = false
#endif
        lastAction6StatusDiagnosticLabel = nil
        compactStoppedProtectionUntil = .distantPast
    }

    func send(_ command: CameraCommand) -> CameraCommandResult {
        guard let peripheral else {
            return result(for: command, status: .failed, message: "DJI peripheral is unavailable.")
        }

        switch command {
        case .startRecording:
            if canUseRSDKControl {
                return sendRSDKRecordCommand(.start, to: peripheral, label: command)
            }
            guard cameraBehavior.usesLegacyDJIControl else {
                return rSDKNotReadyResult(for: command)
            }
            return sendRecordCommand(.start, to: peripheral, label: command)
        case .stopRecording:
            if canUseRSDKControl {
                return sendRSDKRecordCommand(.stop, to: peripheral, label: command)
            }
            guard cameraBehavior.usesLegacyDJIControl else {
                return rSDKNotReadyResult(for: command)
            }
            return sendRecordCommand(.stop, to: peripheral, label: command)
        case .toggleRecording:
            return result(for: command, status: .unsupported, message: "DJI toggle record is not safe without camera state confirmation.")
        case let .setMode(mode):
            guard mode == .video else {
                return result(for: command, status: .unsupported, message: "Only DJI Video mode is mapped.")
            }
            if canUseRSDKControl {
                return sendRSDKVideoModeCommand(to: peripheral, label: command)
            }
            guard cameraBehavior.usesLegacyDJIControl else {
                return rSDKNotReadyResult(for: command)
            }
            return sendVideoModeCommand(to: peripheral, label: command)
        case .keepAlive:
            if canUseRSDKControl {
                sendRSDKStatusSubscription(to: peripheral, shouldLog: true)
                sendRSDKVersionQuery(to: peripheral)
                return result(for: command, status: .sent, message: "Refreshed DJI R SDK status subscription.")
            } else if cameraBehavior.usesLegacyDJIControl {
                sendStatusProbe(to: peripheral, includeExtendedProbes: true, shouldLog: true)
                return result(for: command, status: .sent, message: "Sent DJI diagnostic status probe.")
            }
            return rSDKNotReadyResult(for: command)
        case .cycleMode, .applySetting:
            return result(
                for: command,
                status: .unsupported,
                message: "DJI settings control needs a proven BLE mapping."
            )
        }
    }

    @discardableResult
    func sendPhoneGPS(_ fix: DJIGPSFix) -> Bool {
        guard canUseRSDKControl,
              let peripheral,
              cameraBehavior.usesDJIRSDKControl else {
#if DEBUG
            logGPSNotReadyIfNeeded()
#endif
            return false
        }

        let payload = DJIGPSPayloadEncoder.payload(for: fix)
        let packet = DJIRSDKPacket.gpsData(
            sequenceNumber: nextRSDKSequence(),
            payload: payload
        )
        let disposition = writeRSDK(
            packet,
            to: peripheral,
            label: "phone GPS",
            shouldLog: false,
            coalescesPendingWrites: true
        )
#if DEBUG
        logGPSWrite(disposition, fix: fix, payload: payload, packet: packet)
#endif
        return disposition != .skipped
    }
}

extension DJIExperimentalBLEClient {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            onStatus(cameraID, .failed(error.localizedDescription), nil)
            return
        }

        let services = peripheral.services ?? []
        onLog("\(cameraName): discovered \(services.count) DJI candidate services.")
        services.forEach { service in
            onLog("\(cameraName): service \(service.uuid.uuidString)")
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
            let properties = characteristic.properties.debugLabels.joined(separator: ", ")
            onLog("\(cameraName): \(service.uuid.uuidString) / \(characteristic.uuid.uuidString) [\(properties)]")
            trackRSDKCharacteristic(characteristic, in: service, peripheral: peripheral)

            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }

            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                let candidate = DJIWritableCharacteristic(serviceUUID: service.uuid, characteristic: characteristic)
                if shouldTrackLegacyWriteCandidate(candidate), !writeCandidates.contains(candidate) {
                    writeCandidates.append(candidate)
                    writeCandidates.sort()
                    onLog("\(cameraName): DJI legacy write candidate \(candidate.debugLabel)")
                }
            }

            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        if cameraBehavior.kind == .djiOsmoNano, !writeTargets.isEmpty {
            onStatus(cameraID, .connecting, "DJI Nano control ready; waiting for camera status.")
            if hasConfirmedAwakeNanoAdvertisement {
                onLog("\(cameraName): awake Nano advertisement confirmed; requesting legacy camera status.")
                scheduleInitialStatusProbe(to: peripheral)
            }
        } else if rSDKWriteCharacteristic != nil {
            onStatus(cameraID, .connecting, "DJI R SDK characteristics ready; waiting for protocol handshake.")
        } else if cameraBehavior.usesDJIRSDKControl {
            onStatus(cameraID, .connecting, "Waiting for DJI R SDK control characteristics.")
        }

        bootstrapRSDKIfReady(to: peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            onLog("\(cameraName): DJI notification error: \(error.localizedDescription)")
            return
        }

        guard let value = characteristic.value else { return }
        if handleRSDKNotification(value, from: characteristic) {
            return
        }

        let dumlFrames = dumlFrames(in: value)
        if !dumlFrames.isEmpty {
            completeLegacyDumlHandshakeIfNeeded(to: peripheral)
        }
        for frame in dumlFrames {
            onProtocolActivity(cameraID)
            updateDumlRouting(from: frame)
            reportLegacyDumlReadyIfNeeded(from: frame)
            applyDumlRecordingHint(from: frame)
            logDumlAck(from: frame)
            logDumlStatusPush(from: frame)
            logUnhandledDumlPacket(from: frame)
        }

        if dumlFrames.isEmpty || dumlFrames.contains(where: shouldLogRawNotification) {
            onLog("\(cameraName): \(characteristic.uuid.uuidString) \(value.hexString)")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            onLog("\(cameraName): DJI write to \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == DJIRSDKBLEUUID.notifyCharacteristic else { return }

        if let error {
            let protocolName = cameraBehavior.kind == .djiOsmoNano ? "DJI Nano" : "DJI R SDK"
            onLog("\(cameraName): \(protocolName) notify enable failed: \(error.localizedDescription)")
            return
        }

        if characteristic.isNotifying {
            if cameraBehavior.kind == .djiOsmoNano {
                onLog("\(cameraName): DJI Nano notifications enabled on \(characteristic.debugLabel).")
            } else {
                onLog("\(cameraName): DJI R SDK notifications enabled on \(characteristic.debugLabel).")
                bootstrapRSDKIfReady(to: peripheral)
            }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushPendingRSDKWrites(to: peripheral)
    }
}

private extension DJIExperimentalBLEClient {
    enum RecordAction {
        case start
        case stop

        var isStarting: Bool { self == .start }
        var isStopping: Bool { self == .stop }
    }

    var canUseRSDKControl: Bool {
        hasCompletedRSDKHandshake && rSDKWriteCharacteristic != nil
    }

    func rSDKNotReadyResult(for command: CameraCommand) -> CameraCommandResult {
        result(
            for: command,
            status: .skipped,
            message: "DJI R SDK control is not ready. Wait for the camera to finish connecting."
        )
    }

#if DEBUG
    func logGPSNotReadyIfNeeded(now: Date = Date()) {
        guard now.timeIntervalSince(lastGPSNotReadyDebugLogDate) >= gpsDebugLogInterval else { return }
        lastGPSNotReadyDebugLogDate = now

        let supportedModel = cameraBehavior.usesDJIRSDKControl
        onLog(
            "\(cameraName): GPS debug: not sent; supportedModel=\(supportedModel), peripheral=\(peripheral != nil), handshake=\(hasCompletedRSDKHandshake), writeCharacteristic=\(rSDKWriteCharacteristic?.debugLabel ?? "none")"
        )
    }

    func logGPSWrite(
        _ disposition: RSDKWriteDisposition,
        fix: DJIGPSFix,
        payload: Data,
        packet: Data,
        now: Date = Date()
    ) {
        gpsWriteAttemptCount += 1

        let dispositionLabel: String
        switch disposition {
        case .sent:
            gpsImmediateWriteCount += 1
            dispositionLabel = "handed to CoreBluetooth"
        case .queued:
            gpsQueuedWriteCount += 1
            dispositionLabel = "queued for BLE buffer"
        case .skipped:
            dispositionLabel = "skipped"
        }

        if !hasLoggedGPSFrame {
            hasLoggedGPSFrame = true
            onLog(
                "\(cameraName): GPS debug frame: command=00/17, payload=\(payload.count)B, packet=\(packet.count)B, expectedSize=\(payload.count == 48 && packet.count == 66), bytes=\(packet.hexString)"
            )
        }

        guard now.timeIntervalSince(lastGPSDebugLogDate) >= gpsDebugLogInterval else { return }
        lastGPSDebugLogDate = now
        let fixAge = now.timeIntervalSince(fix.timestamp)
        onLog(
            String(
                format: "%@: GPS debug write #%d: %@; payload=%dB, packet=%dB, fixAge=%.2fs, lat=%.7f, lon=%.7f, hAcc=%.1fm, satellites=%u, immediate=%d, queued=%d, flushed=%d, pending=%d, characteristic=%@",
                cameraName,
                gpsWriteAttemptCount,
                dispositionLabel,
                payload.count,
                packet.count,
                fixAge,
                fix.latitude,
                fix.longitude,
                fix.horizontalAccuracyMeters,
                fix.satelliteCount,
                gpsImmediateWriteCount,
                gpsQueuedWriteCount,
                gpsFlushedWriteCount,
                pendingRSDKWrites.count,
                rSDKWriteCharacteristic?.debugLabel ?? "none"
            )
        )
    }
#endif

    func completeLegacyDumlHandshakeIfNeeded(to peripheral: CBPeripheral) {
        guard cameraBehavior.kind == .djiOsmoNano,
              !hasCompletedRSDKHandshake,
              !hasCompletedLegacyDumlHandshake,
              !writeTargets.isEmpty else {
            return
        }

        hasCompletedLegacyDumlHandshake = true
        onLog("\(cameraName): valid DJI DUML activity received; legacy Nano protocol is ready.")
        onStatus(cameraID, .connecting, "DJI Nano protocol detected; waiting for camera status.")
        scheduleInitialStatusProbe(to: peripheral)
        startStatusPolling(to: peripheral)
    }

    func reportLegacyDumlReadyIfNeeded(from value: Data) {
        guard cameraBehavior.kind == .djiOsmoNano,
              hasCompletedLegacyDumlHandshake,
              !hasCompletedRSDKHandshake,
              !hasReportedLegacyDumlReady,
              let packet = DJIDUMLIncomingPacket(data: value) else {
            return
        }

        let isCameraResponse = packet.isResponse && packet.senderType == dumlRouting.cameraAddress & 0x1F
        let isCameraStatePush = !packet.isResponse && packet.isCameraStatePush
        guard isCameraResponse || isCameraStatePush else { return }

        hasReportedLegacyDumlReady = true
        onLog("\(cameraName): DJI Nano returned camera status; legacy control is ready.")
        onStatus(cameraID, .connected, "DJI Nano protocol ready.")
    }

    func shouldTrackLegacyWriteCandidate(_ candidate: DJIWritableCharacteristic) -> Bool {
        cameraBehavior.usesLegacyDJIControl && !candidate.isRSDKControlTarget
    }

    func trackRSDKCharacteristic(
        _ characteristic: CBCharacteristic,
        in service: CBService,
        peripheral: CBPeripheral
    ) {
        guard service.uuid == DJIRSDKBLEUUID.service else { return }

        switch characteristic.uuid {
        case DJIRSDKBLEUUID.writeCharacteristic:
            rSDKWriteCharacteristic = characteristic
            onLog("\(cameraName): DJI R SDK write characteristic ready on \(characteristic.debugLabel).")
        case DJIRSDKBLEUUID.notifyCharacteristic:
            rSDKNotifyCharacteristic = characteristic
            onLog("\(cameraName): DJI R SDK notify characteristic ready on \(characteristic.debugLabel).")
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        default:
            break
        }
    }

    func bootstrapRSDKIfReady(to peripheral: CBPeripheral) {
        guard cameraBehavior.kind != .djiOsmoNano else { return }
        guard rSDKWriteCharacteristic != nil, let notify = rSDKNotifyCharacteristic else { return }
        guard notify.isNotifying else { return }
        guard !hasSentRSDKConnectionRequest else { return }

        hasSentRSDKConnectionRequest = true
        sendRSDKConnectionRequest(to: peripheral)
    }

    func sendRSDKConnectionRequest(to peripheral: CBPeripheral) {
        let seq = nextRSDKSequence()
        let packet = DJIRSDKPacket.connectionRequest(sequenceNumber: seq)
        writeRSDK(packet, to: peripheral, label: "protocol connect request")
    }

    func sendRSDKConnectionResponse(to peripheral: CBPeripheral, sequenceNumber: UInt16, cameraReserved: UInt8) {
        let packet = DJIRSDKPacket.connectionResponse(sequenceNumber: sequenceNumber, cameraReserved: cameraReserved)
        writeRSDK(packet, to: peripheral, label: "protocol connect response")
    }

    func sendRSDKStatusSubscription(to peripheral: CBPeripheral, shouldLog: Bool) {
        guard hasCompletedRSDKHandshake else { return }
        let seq = nextRSDKSequence()
        let packet = DJIRSDKPacket.statusSubscription(sequenceNumber: seq)
        if !shouldLog {
            silentRSDKStatusSubscriptionSequences.insert(seq)
        }
        writeRSDK(packet, to: peripheral, label: "status subscription", shouldLog: shouldLog)
        hasSentRSDKStatusSubscription = true
    }

    func sendRSDKVersionQuery(to peripheral: CBPeripheral) {
        guard hasCompletedRSDKHandshake else { return }
        let seq = nextRSDKSequence()
        let packet = DJIRSDKPacket.frame(
            sequenceNumber: seq,
            commandType: DJIRSDKCommandType.waitResult,
            commandSet: 0x00,
            commandID: 0x00,
            payload: Data()
        )
        writeRSDK(packet, to: peripheral, label: "version query")
    }

    func sendRSDKRecordCommand(
        _ action: RecordAction,
        to peripheral: CBPeripheral,
        label command: CameraCommand
    ) -> CameraCommandResult {
        if action.isStarting {
            protectAgainstStaleStoppedStatusAfterStart()
        }

        let seq = nextRSDKSequence()
        let packet = DJIRSDKPacket.recordControl(sequenceNumber: seq, isStarting: action.isStarting)
        pendingRSDKRecordActionsBySequence[seq] = action
        writeRSDK(packet, to: peripheral, label: "R SDK \(action.isStarting ? "start" : "stop") record")

        return result(
            for: command,
            status: .sent,
            message: "Sent DJI R SDK \(action.isStarting ? "start" : "stop") recording command."
        )
    }

    func sendRSDKVideoModeCommand(
        to peripheral: CBPeripheral,
        label command: CameraCommand
    ) -> CameraCommandResult {
        let seq = nextRSDKSequence()
        let packet = DJIRSDKPacket.modeSwitch(sequenceNumber: seq, mode: 0x01)
        pendingRSDKModeUpdatesBySequence[seq] = .video
        writeRSDK(packet, to: peripheral, label: "R SDK switch to video")

        return result(for: command, status: .sent, message: "Sent DJI R SDK Video mode command.")
    }

    @discardableResult
    func writeRSDK(
        _ packet: Data,
        to peripheral: CBPeripheral,
        label: String,
        shouldLog: Bool = true,
        coalescesPendingWrites: Bool = false
    ) -> RSDKWriteDisposition {
        guard let characteristic = rSDKWriteCharacteristic else {
            onLog("\(cameraName): DJI R SDK \(label) skipped; write characteristic is not ready.")
            return .skipped
        }

        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        if writeType == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
            if coalescesPendingWrites {
                pendingRSDKWrites.removeAll { $0.label == label }
            }
            pendingRSDKWrites.append(
                PendingRSDKWrite(packet: packet, label: label, shouldLog: shouldLog)
            )
            if shouldLog {
                onLog("\(cameraName): DJI \(label) queued until the BLE write buffer is ready.")
            }
            return .queued
        }

        peripheral.writeValue(packet, for: characteristic, type: writeType)
        if shouldLog {
            onLog("\(cameraName): DJI \(label) -> \(characteristic.debugLabel) (\(writeType.logLabel)) \(packet.hexString)")
        }
        return .sent
    }

    func flushPendingRSDKWrites(to peripheral: CBPeripheral) {
        guard let characteristic = rSDKWriteCharacteristic else {
            pendingRSDKWrites.removeAll()
            return
        }

        while peripheral.canSendWriteWithoutResponse, !pendingRSDKWrites.isEmpty {
            let write = pendingRSDKWrites.removeFirst()
            peripheral.writeValue(write.packet, for: characteristic, type: .withoutResponse)
#if DEBUG
            if write.label == "phone GPS" {
                gpsFlushedWriteCount += 1
                let now = Date()
                if now.timeIntervalSince(lastGPSFlushDebugLogDate) >= gpsDebugLogInterval {
                    lastGPSFlushDebugLogDate = now
                    onLog(
                        "\(cameraName): GPS debug: queued packet handed to CoreBluetooth; flushed=\(gpsFlushedWriteCount), pending=\(pendingRSDKWrites.count)"
                    )
                }
            }
#endif
            if write.shouldLog {
                onLog("\(cameraName): DJI \(write.label) -> \(characteristic.debugLabel) (withoutResponse) \(write.packet.hexString)")
            }
        }
    }

    func nextRSDKSequence() -> UInt16 {
        let sequence = rSDKSequenceNumber
        rSDKSequenceNumber &+= 1
        return sequence
    }

    func handleRSDKNotification(_ value: Data, from characteristic: CBCharacteristic) -> Bool {
        guard cameraBehavior.kind != .djiOsmoNano else { return false }
        let isRSDKCharacteristic = characteristic.service?.uuid == DJIRSDKBLEUUID.service
            && characteristic.uuid == DJIRSDKBLEUUID.notifyCharacteristic
        guard isRSDKCharacteristic else { return false }
        guard !rSDKReceiveBuffer.isEmpty || value.first == DJIRSDKPacket.startOfFrame else { return false }
        if rSDKReceiveBuffer.isEmpty,
           value.count >= DJIRSDKPacket.headerLength,
           !DJIRSDKPacket.hasValidHeader(in: value) {
            return false
        }

        rSDKReceiveBuffer.append(value)
        drainRSDKReceiveBuffer()
        return true
    }

    func drainRSDKReceiveBuffer() {
        while !rSDKReceiveBuffer.isEmpty {
            if rSDKReceiveBuffer.first != DJIRSDKPacket.startOfFrame {
                guard let startIndex = rSDKReceiveBuffer.firstIndex(of: DJIRSDKPacket.startOfFrame) else {
                    onLog("\(cameraName): discarded \(rSDKReceiveBuffer.count) non-R SDK notification bytes.")
                    rSDKReceiveBuffer.removeAll(keepingCapacity: true)
                    lastRSDKBufferedFrameLogLabel = nil
                    return
                }

                let droppedByteCount = rSDKReceiveBuffer.distance(from: rSDKReceiveBuffer.startIndex, to: startIndex)
                if droppedByteCount > 0 {
                    onLog("\(cameraName): discarded \(droppedByteCount) bytes before DJI R SDK frame.")
                    rSDKReceiveBuffer.removeSubrange(rSDKReceiveBuffer.startIndex ..< startIndex)
                    lastRSDKBufferedFrameLogLabel = nil
                }
            }

            guard rSDKReceiveBuffer.count >= 3 else { return }
            guard let declaredLength = DJIRSDKPacket.declaredLength(in: rSDKReceiveBuffer),
                  declaredLength >= DJIRSDKPacket.minimumFrameLength,
                  declaredLength <= DJIRSDKPacket.maximumFrameLength else {
                onLog("\(cameraName): DJI R SDK frame length was invalid; resyncing from \(rSDKReceiveBuffer.hexString).")
                rSDKReceiveBuffer.removeFirst()
                lastRSDKBufferedFrameLogLabel = nil
                continue
            }

            if rSDKReceiveBuffer.count >= DJIRSDKPacket.headerLength,
               !DJIRSDKPacket.hasValidHeader(in: rSDKReceiveBuffer) {
                onLog("\(cameraName): DJI R SDK frame header checksum was invalid; resyncing.")
                rSDKReceiveBuffer.removeFirst()
                lastRSDKBufferedFrameLogLabel = nil
                continue
            }

            guard rSDKReceiveBuffer.count >= declaredLength else {
                let logLabel = "\(rSDKReceiveBuffer.count)/\(declaredLength)"
                if logLabel != lastRSDKBufferedFrameLogLabel {
                    onLog("\(cameraName): buffering DJI R SDK frame \(logLabel) bytes.")
                    lastRSDKBufferedFrameLogLabel = logLabel
                }
                return
            }

            let frameData = Data(rSDKReceiveBuffer.prefix(declaredLength))
            rSDKReceiveBuffer.removeFirst(declaredLength)
            lastRSDKBufferedFrameLogLabel = nil

            guard let frame = DJIRSDKIncomingFrame(data: frameData) else {
                onLog("\(cameraName): invalid complete DJI R SDK frame \(frameData.hexString)")
                continue
            }

            handleRSDKFrame(frame)
        }
    }

    func dumlFrames(in value: Data) -> [Data] {
        var remaining = value
        var frames: [Data] = []

        while let startIndex = remaining.firstIndex(of: 0x55) {
            if startIndex != remaining.startIndex {
                remaining.removeSubrange(remaining.startIndex ..< startIndex)
            }

            guard remaining.count >= 3,
                  let versionAndLength = remaining.littleEndianUInt16(at: 1) else {
                break
            }

            let frameLength = Int(versionAndLength & 0x03FF)
            guard frameLength >= 13 else {
                remaining.removeFirst()
                continue
            }
            guard remaining.count >= frameLength else { break }

            let frame = Data(remaining.prefix(frameLength))
            if DJIDUMLIncomingPacket(data: frame) != nil {
                frames.append(frame)
            }
            remaining.removeFirst(frameLength)
        }

        return frames
    }

    func handleRSDKFrame(_ frame: DJIRSDKIncomingFrame) {
        onProtocolActivity(cameraID)

        switch (frame.cmdSet, frame.cmdID, frame.isResponse) {
        case (0x00, 0x19, true):
            let responseCode = frame.payload.byte(at: 4)
            if responseCode == 0x00 {
                onLog("\(cameraName): DJI R SDK connection request accepted; waiting for camera verification request.")
            } else {
                onLog("\(cameraName): DJI R SDK connection request returned \(responseCode.map { "0x\($0.hexByte)" } ?? "missing code").")
            }

        case (0x00, 0x19, false):
            guard let request = DJIRSDKConnectionRequest(payload: frame.payload) else {
                onLog(
                    "\(cameraName): DJI R SDK camera verification request was malformed (\(frame.payload.count) bytes): \(frame.payload.hexString)"
                )
                return
            }
            onLog("\(cameraName): DJI R SDK camera verification request \(request.debugLabel).")

            if request.verifyMode == 0x02, request.verifyData == 0 {
                if let peripheral {
                    sendRSDKConnectionResponse(
                        to: peripheral,
                        sequenceNumber: frame.sequenceNumber,
                        cameraReserved: request.cameraReserved
                    )
                    completeRSDKHandshake(to: peripheral, source: "camera verification")
                }
            } else if request.verifyMode == 0x02, request.verifyData == 1 {
                if let peripheral {
                    scheduleRSDKHandshakePairingRetry(to: peripheral)
                }
            } else {
                onLog(
                    "\(cameraName): DJI R SDK camera verification rejected: mode 0x\(request.verifyMode.hexByte), data 0x\(request.verifyData.hexWord)."
                )
            }

        case (0x1D, 0x02, false):
            applyRSDKStatusPush(frame.payload)

        case (0x1D, 0x06, false):
            if let details = DJIRSDKModeDetails(payload: frame.payload) {
                onLog("\(cameraName): DJI R SDK mode detail \(details.debugLabel).")
            }

        case (0x1D, 0x03, true):
            let resultCode = frame.payload.first
            let resultLabel = resultCode == 0x00 ? "success" : "error \(resultCode.map { "0x\($0.hexByte)" } ?? "missing code")"
            onLog("\(cameraName): DJI R SDK record ACK \(resultLabel).")
            if let action = pendingRSDKRecordActionsBySequence.removeValue(forKey: frame.sequenceNumber),
               resultCode == 0x00 {
                if action.isStarting {
                    protectAgainstStaleStoppedStatusAfterStart()
                    onCameraStatus(cameraID, CameraStatusUpdate(recordingState: .starting, shouldClearCurrentMode: true))
                } else {
                    onCameraStatus(cameraID, CameraStatusUpdate(recordingState: .stopped))
                }
            }

        case (0x1D, 0x04, true):
            let resultCode = frame.payload.first
            let resultLabel = resultCode == 0x00 ? "success" : "error \(resultCode.map { "0x\($0.hexByte)" } ?? "missing code")"
            onLog("\(cameraName): DJI R SDK mode ACK \(resultLabel).")
            if let mode = pendingRSDKModeUpdatesBySequence.removeValue(forKey: frame.sequenceNumber),
               resultCode == 0x00 {
                onCameraStatus(cameraID, CameraStatusUpdate(currentMode: mode))
            }

        case (0x1D, 0x05, true):
            let resultCode = frame.payload.first
            let wasSilentHeartbeat = silentRSDKStatusSubscriptionSequences.remove(frame.sequenceNumber) != nil
            if !wasSilentHeartbeat {
                let resultLabel = resultCode == 0x00 ? "success" : "error \(resultCode.map { "0x\($0.hexByte)" } ?? "missing code")"
                onLog("\(cameraName): DJI R SDK status subscription ACK \(resultLabel).")
            }

        default:
            let payloadLabel = frame.payload.isEmpty ? "empty payload" : "payload \(frame.payload.hexString)"
            onLog(
                "\(cameraName): DJI R SDK \(frame.isResponse ? "response" : "push") cmdset 0x\(frame.cmdSet.hexByte) cmd 0x\(frame.cmdID.hexByte), \(payloadLabel)."
            )
        }
    }

    func completeRSDKHandshake(to peripheral: CBPeripheral, source: String) {
        var completedNow = false
        if !hasCompletedRSDKHandshake {
            hasCompletedRSDKHandshake = true
            completedNow = true
            statusProbeTimer?.invalidate()
            statusProbeTimer = nil
            rSDKHandshakePairingRetryTimer?.invalidate()
            rSDKHandshakePairingRetryTimer = nil
            rSDKHandshakePairingRetryCount = 0
            onLog("\(cameraName): DJI R SDK protocol handshake complete via \(source).")
        }

        if !hasSentRSDKStatusSubscription {
            sendRSDKStatusSubscription(to: peripheral, shouldLog: true)
        }

        if completedNow {
            onStatus(cameraID, .connecting, "DJI R SDK handshake complete; waiting for camera status.")
        }
    }

    func scheduleRSDKHandshakePairingRetry(to peripheral: CBPeripheral) {
        guard rSDKHandshakePairingRetryCount < maxRSDKHandshakePairingRetries else {
            onLog("\(cameraName): DJI R SDK BLE pairing did not finish after \(maxRSDKHandshakePairingRetries) protocol retries.")
            onStatus(cameraID, .failed("DJI BLE pairing did not finish. Accept the system pairing prompt, then tap Pair again."), nil)
            return
        }

        rSDKHandshakePairingRetryCount += 1
        rSDKHandshakePairingRetryTimer?.invalidate()
        onLog(
            "\(cameraName): DJI R SDK BLE pairing is pending; retrying protocol handshake \(rSDKHandshakePairingRetryCount)/\(maxRSDKHandshakePairingRetries)."
        )
        onStatus(
            cameraID,
            .connecting,
            "DJI BLE pairing is pending; retrying protocol handshake \(rSDKHandshakePairingRetryCount)/\(maxRSDKHandshakePairingRetries)."
        )

        rSDKHandshakePairingRetryTimer = commonModeTimer(withTimeInterval: 2.0, repeats: false) { [weak self, weak peripheral] _ in
            guard let self,
                  let peripheral,
                  self.peripheral === peripheral,
                  !self.hasCompletedRSDKHandshake else {
                return
            }

            self.hasSentRSDKConnectionRequest = false
            self.bootstrapRSDKIfReady(to: peripheral)
        }
    }

    func applyRSDKStatusPush(_ payload: Data) {
#if DEBUG
        logRSDKStatusPayloadChange(payload)
#endif

        guard let status = DJIRSDKStatusPush(payload: payload) else {
            onLog("\(cameraName): DJI R SDK status push could not be parsed: \(payload.hexString)")
            return
        }

        if status.powerState != .sleeping, !hasReportedRSDKReady {
            hasReportedRSDKReady = true
            onStatus(cameraID, .connected, "DJI R SDK protocol ready.")
        }
        onCameraStatus(cameraID, status.cameraStatusUpdate)
        let now = Date()
        if status.debugLabel != lastRSDKStatusSummaryLabel
            || now.timeIntervalSince(lastRSDKStatusSummaryLogDate) >= 5 {
            onLog("\(cameraName): DJI R SDK status \(status.debugLabel).")
            lastRSDKStatusSummaryLabel = status.debugLabel
            lastRSDKStatusSummaryLogDate = now
        }
    }

#if DEBUG
    func logRSDKStatusPayloadChange(_ payload: Data) {
        defer { lastRSDKStatusPayload = payload }

        guard let previousPayload = lastRSDKStatusPayload else {
            onLog("\(cameraName): DJI R SDK status raw baseline (\(payload.count) bytes): \(payload.hexString)")
            return
        }

        guard previousPayload != payload else { return }

        let byteCount = max(previousPayload.count, payload.count)
        let changes = (0 ..< byteCount).compactMap { offset -> String? in
            let previousByte = previousPayload.byte(at: offset)
            let currentByte = payload.byte(at: offset)
            guard previousByte != currentByte else { return nil }

            let previousLabel = previousByte.map(\.hexByte) ?? "--"
            let currentLabel = currentByte.map(\.hexByte) ?? "--"
            return "\(offset):\(previousLabel)->\(currentLabel)"
        }

        onLog(
            "\(cameraName): DJI R SDK status raw changed [\(changes.joined(separator: ", "))] "
                + "(\(payload.count) bytes): \(payload.hexString)"
        )
    }
#endif

    var writeTargets: [DJIWritableCharacteristic] {
        let candidates = writeCandidates.filter { !$0.isRSDKControlTarget }
        let privateTargets = candidates.filter { !$0.isStandardBLETarget && !$0.isClearlyGenericBLETarget }
        let selectedTargets = privateTargets.isEmpty ? candidates : privateTargets

        return Array(selectedTargets.prefix(4))
    }

    func sendRecordCommand(
        _ action: RecordAction,
        to peripheral: CBPeripheral,
        label command: CameraCommand
    ) -> CameraCommandResult {
        guard cameraBehavior.usesLegacyDJIControl else {
            return rSDKNotReadyResult(for: command)
        }

        let targets = writeTargets
        guard !targets.isEmpty else {
            return result(
                for: command,
                status: .skipped,
                message: "DJI control characteristics are not ready yet. Reconnect the camera or keep the manage sheet open until discovery finishes."
            )
        }

        let burstCount = action.isStopping ? stopCommandBurstCount : 1
        var packetCount = 0
        if action.isStarting {
            protectAgainstStaleStoppedStatusAfterStart()
        }
        for burstIndex in 0 ..< burstCount {
            let packets = djiRecordPackets(for: action)
            packetCount += packets.count
            let burstLabel = burstCount > 1 ? " \(burstIndex + 1)/\(burstCount)" : ""
            for packet in packets {
                pendingRecordActionsBySequence[packet.sequenceNumber] = action
                for target in targets {
                    for writeType in target.commandWriteTypes {
                        peripheral.writeValue(packet.data, for: target.characteristic, type: writeType)
                        onLog("\(cameraName): DJI \(packet.label)\(burstLabel) -> \(target.debugLabel) (\(writeType.logLabel)) \(packet.data.hexString)")
                    }
                }
            }
        }

        return result(
            for: command,
            status: .sent,
            message: "Sent \(packetCount) experimental DJI \(action.isStarting ? "start" : "stop") record packets to \(targets.count) BLE targets."
        )
    }

    func djiRecordPackets(for action: RecordAction) -> [DJICommandPacket] {
        var packets = [
            DJICommandPacket(
                label: action.isStarting ? "special start video" : "special stop video",
                command: nextDumlPacket(
                    commandSet: 0x01,
                    commandID: action.isStarting ? 0x21 : 0x22,
                    payload: Data()
                )
            ),
            DJICommandPacket(
                label: "camera do record \(action.isStarting ? "on" : "off")",
                command: nextDumlPacket(
                    commandSet: 0x02,
                    commandID: 0x02,
                    payload: Data([action.isStarting ? 0x01 : 0x00])
                )
            )
        ]

        if action.isStopping {
            packets.append(
                DJICommandPacket(
                    label: "camera shutter \(action.isStarting ? "on" : "off")",
                    command: nextDumlPacket(
                        commandSet: 0x02,
                        commandID: 0x7C,
                        payload: Data([action.isStarting ? 0x01 : 0x00])
                    )
                )
            )
        }

        return packets
    }

    func sendVideoModeCommand(
        to peripheral: CBPeripheral,
        label command: CameraCommand
    ) -> CameraCommandResult {
        guard cameraBehavior.usesLegacyDJIControl else {
            return rSDKNotReadyResult(for: command)
        }

        let targets = writeTargets
        guard !targets.isEmpty else {
            return result(
                for: command,
                status: .skipped,
                message: "DJI control characteristics are not ready yet."
            )
        }

        let packets = djiVideoModePackets()
        for packet in packets {
            pendingModeUpdatesBySequence[packet.sequenceNumber] = .video
            for target in targets {
                for writeType in target.commandWriteTypes {
                    peripheral.writeValue(packet.data, for: target.characteristic, type: writeType)
                    onLog("\(cameraName): DJI \(packet.label) -> \(target.debugLabel) (\(writeType.logLabel)) \(packet.data.hexString)")
                }
            }
        }

        return result(for: command, status: .sent, message: "Sent \(packets.count) DJI Video mode command candidate\(packets.count == 1 ? "" : "s").")
    }

    func scheduleInitialStatusProbe(to peripheral: CBPeripheral) {
        guard !hasSentInitialStatusProbe else { return }
        hasSentInitialStatusProbe = true

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350)) { [weak self, weak peripheral] in
            guard let self, let peripheral, self.peripheral === peripheral else { return }
            self.sendStatusProbe(to: peripheral)
        }
    }

    func sendStatusProbe(to peripheral: CBPeripheral) {
        sendStatusProbe(to: peripheral, includeExtendedProbes: true, shouldLog: true)
    }

    func sendStatusProbe(
        to peripheral: CBPeripheral,
        includeExtendedProbes: Bool,
        shouldLog: Bool
    ) {
        let targets = writeTargets
        guard !targets.isEmpty else {
            onLog("\(cameraName): DJI status probe skipped; no write targets are ready.")
            return
        }

        let packets = djiStatusProbePackets(includeExtendedProbes: includeExtendedProbes)
        for packet in packets {
            if shouldLog {
                pendingStatusProbeLabelsBySequence[packet.sequenceNumber] = packet.label
            }
            for target in targets {
                for writeType in target.statusProbeWriteTypes {
                    peripheral.writeValue(packet.data, for: target.characteristic, type: writeType)
                    if shouldLog {
                        onLog("\(cameraName): DJI status probe \(packet.label) -> \(target.debugLabel) (\(writeType.logLabel)) \(packet.data.hexString)")
                    }
                }
            }
        }
    }

    func startStatusPolling(to peripheral: CBPeripheral) {
        statusProbeTimer?.invalidate()
        statusProbeTimer = commonModeTimer(withTimeInterval: 2.5, repeats: true) { [weak self, weak peripheral] timer in
            guard let self, let peripheral, self.peripheral === peripheral else {
                timer.invalidate()
                return
            }

            self.sendStatusProbe(to: peripheral, includeExtendedProbes: false, shouldLog: false)
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

    func djiStatusProbePackets(includeExtendedProbes: Bool) -> [DJICommandPacket] {
        var packets: [DJICommandPacket] = []
        for routing in statusProbeRoutings {
            packets.append(
                DJICommandPacket(
                    label: "system state get \(routing.debugLabel)",
                    command: nextDumlPacket(
                        routing: routing,
                        commandSet: 0x02,
                        commandID: 0x70,
                        payload: Data()
                    )
                )
            )

            packets.append(
                DJICommandPacket(
                    label: "camera work mode get \(routing.debugLabel)",
                    command: nextDumlPacket(
                        routing: routing,
                        commandSet: 0x02,
                        commandID: 0x11,
                        payload: Data()
                    )
                )
            )

            if includeExtendedProbes {
                packets.append(
                    DJICommandPacket(
                        label: "camera power info get \(routing.debugLabel)",
                        command: nextDumlPacket(
                            routing: routing,
                            commandSet: 0x02,
                            commandID: 0x76,
                            payload: Data()
                        )
                    )
                )
            }
        }

        return packets
    }

    var statusProbeRoutings: [DJIDUMLRouting] {
        [dumlRouting]
    }

    func djiVideoModePackets(routing: DJIDUMLRouting? = nil) -> [DJICommandPacket] {
        [
            DJICommandPacket(
                label: routing.map { "route \($0.debugLabel) camera work mode video" } ?? "camera work mode video",
                command: nextDumlPacket(
                    routing: routing,
                    commandSet: 0x02,
                    commandID: 0x10,
                    payload: Data([0x01])
                )
            )
        ]
    }

    var shouldUseNanoStopFallbacks: Bool {
        cameraBehavior.kind == .djiOsmoNano
    }

    var stopCommandBurstCount: Int {
        shouldUseNanoStopFallbacks ? 3 : 2
    }

    var cameraBehavior: CameraBehaviorProfile {
        CameraBehaviorProfile.resolve(brand: .dji, model: cameraModel, name: cameraName)
    }

    static func defaultDumlRouting(cameraModel: CameraModel, cameraName: String) -> DJIDUMLRouting {
        let profile = CameraBehaviorProfile.resolve(
            brand: .dji,
            model: cameraModel,
            name: cameraName
        )

        if profile.kind == .djiOsmoPocket3 {
            return DJIDUMLRouting(appAddress: 0x02, cameraAddress: 0x04)
        }

        return .default
    }

    func updateDumlRouting(from value: Data) {
        guard let packet = DJIDUMLIncomingPacket(data: value) else { return }

        if cameraBehavior.kind == .djiOsmoPocket3 {
            return
        }

        var learnedRouting = dumlRouting
        if packet.receiver != 0x01, packet.receiver != 0x05, packet.receiver != learnedRouting.appAddress {
            learnedRouting.appAddress = packet.receiver
        }

        if packet.isResponse, packet.senderType == 0x01, packet.sender != learnedRouting.cameraAddress {
            learnedRouting.cameraAddress = packet.sender
        }

        guard learnedRouting != dumlRouting else { return }

        dumlRouting = learnedRouting
        onLog("\(cameraName): learned DJI DUML route \(dumlRouting.debugLabel).")
    }

    func logDumlAck(from value: Data) {
        guard let packet = DJIDUMLIncomingPacket(data: value), packet.isResponse, let resultCode = packet.resultCode else {
            return
        }

        let resultLabel = resultCode == 0x00 ? "success" : "error 0x\(resultCode.hexByte)"
        let payloadLabel = packet.payload.isEmpty ? "empty payload" : "payload \(packet.payload.hexString)"
        onLog(
            "\(cameraName): DJI ACK cmdset 0x\(packet.commandSet.hexByte) cmd 0x\(packet.commandID.hexByte) \(resultLabel), \(payloadLabel)."
        )

        let statusPayload = packet.payloadWithoutResultCode
        let summary = resultCode == 0x00 ? applyStatusPayload(for: packet, statusPayload: statusPayload) : nil

        if let probeLabel = pendingStatusProbeLabelsBySequence.removeValue(forKey: packet.sequenceNumber) {
            logStatusProbeResult(
                label: probeLabel,
                packet: packet,
                resultLabel: resultLabel,
                statusPayload: statusPayload,
                summary: summary
            )
        }

        if let action = pendingRecordActionsBySequence.removeValue(forKey: packet.sequenceNumber),
           resultCode == 0x00 {
            if action.isStarting {
                protectAgainstStaleStoppedStatusAfterStart()
                onLog("\(cameraName): DJI start command accepted; waiting for recording status confirmation.")
                return
            }
            onCameraStatus(
                cameraID,
                CameraStatusUpdate(
                    recordingState: .stopped
                )
            )
        }

        if pendingModeUpdatesBySequence.removeValue(forKey: packet.sequenceNumber) != nil,
           resultCode == 0x00 {
            onLog("\(cameraName): DJI mode command accepted; waiting for camera state to confirm mode.")
        }
    }

    func logStatusProbeResult(
        label: String,
        packet: DJIDUMLIncomingPacket,
        resultLabel: String,
        statusPayload: Data,
        summary: String?
    ) {
        var message = "\(cameraName): DJI status probe \(label) returned \(resultLabel)"

        if statusPayload.isEmpty {
            message += ", empty status payload"
        } else {
            message += ", status payload \(statusPayload.hexString)"
        }

        if let summary {
            message += " (\(summary))"
        }

        onLog(message + ".")
    }

    func applyStatusPayload(for packet: DJIDUMLIncomingPacket, statusPayload: Data) -> String? {
        guard packet.commandSet == 0x01 || packet.commandSet == 0x02 else { return nil }

        switch packet.commandID {
        case 0x11:
            guard let mode = statusPayload.first else { return nil }
            if let captureMode = Self.captureMode(forDJIModeByte: mode) {
                onCameraStatus(cameraID, CameraStatusUpdate(currentMode: captureMode))
            }
            return "mode \(Self.cameraStateModeLabel(mode))"
        case 0x70:
            if let state = DJICameraStateSummary(payload: statusPayload) {
                if shouldApplyLegacyDumlRecordingStatus {
                    onCameraStatus(cameraID, cameraStatusUpdate(from: state))
                }
                return state.debugLabel
            }

            if let shortState = DJIAction6ShortState(payload: statusPayload),
               cameraBehavior.kind == .djiOsmoAction6,
               cameraBehavior.trustsDJICompactRecordingStatus {
                if shouldApplyLegacyDumlRecordingStatus {
                    onCameraStatus(
                        cameraID,
                        CameraStatusUpdate(
                            recordingState: shortState.recordingState,
                            canClearActiveRecording: true
                        )
                    )
                }
                return shortState.debugLabel
            }

            return statusPayload.isEmpty ? nil : "unparsed state bytes \(statusPayload.hexString)"
        case 0x76:
            return statusPayload.isEmpty ? nil : "power bytes \(statusPayload.hexString)"
        default:
            return nil
        }
    }

    func logDumlStatusPush(from value: Data) {
        guard let packet = DJIDUMLIncomingPacket(data: value),
              !packet.isResponse,
              packet.isCameraStatePush else {
            return
        }

#if DEBUG
        logDumlCameraStatePayloadChange(packet.payload)
#endif

        guard let state = DJICameraStateSummary(payload: packet.payload) else { return }

        let now = Date()
        if state.debugLabel != lastCameraStateSummaryLabel
            || now.timeIntervalSince(lastCameraStateSummaryLogDate) >= 5 {
            onLog("\(cameraName): DJI camera state push (\(state.debugLabel)).")
            lastCameraStateSummaryLabel = state.debugLabel
            lastCameraStateSummaryLogDate = now
        }

        let telemetry = cameraTelemetry(from: state)
        if shouldApplyLegacyDumlRecordingStatus {
            var update = cameraStatusUpdate(from: state)
            update.telemetry = telemetry
            onCameraStatus(cameraID, update)
        } else if let telemetry {
            // R SDK is authoritative for recording, but its documented status frame
            // does not include external power. Continue merging compact DUML telemetry.
            onCameraStatus(cameraID, CameraStatusUpdate(telemetry: telemetry))
        }
    }

#if DEBUG
    func logDumlCameraStatePayloadChange(_ payload: Data) {
        defer { lastDumlCameraStatePayload = payload }

        guard let previousPayload = lastDumlCameraStatePayload else {
            onLog("\(cameraName): DJI legacy camera-state raw baseline (\(payload.count) bytes): \(payload.hexString)")
            return
        }

        guard previousPayload != payload else { return }

        let byteCount = max(previousPayload.count, payload.count)
        let changes = (0 ..< byteCount).compactMap { offset -> String? in
            let previousByte = previousPayload.byte(at: offset)
            let currentByte = payload.byte(at: offset)
            guard previousByte != currentByte else { return nil }

            let previousLabel = previousByte.map(\.hexByte) ?? "--"
            let currentLabel = currentByte.map(\.hexByte) ?? "--"
            return "\(offset):\(previousLabel)->\(currentLabel)"
        }

        onLog(
            "\(cameraName): DJI legacy camera-state raw changed [\(changes.joined(separator: ", "))] "
                + "(\(payload.count) bytes): \(payload.hexString)"
        )
    }
#endif

    var shouldApplyLegacyDumlRecordingStatus: Bool {
        // Action cameras can emit legacy DUML state alongside the newer R SDK
        // stream. Once R SDK is ready, mixing both sources lets stale DUML
        // "stopped" packets overwrite a current R SDK "recording" state.
        !hasCompletedRSDKHandshake
    }

    func cameraTelemetry(from state: DJICameraStateSummary) -> CameraTelemetry? {
        var telemetry = state.telemetry ?? CameraTelemetry()

        switch cameraBehavior.kind {
        case .djiOsmoAction4, .djiOsmoAction5Pro, .djiOsmoAction6, .djiOsmo360:
            telemetry.isExternalPowerConnected = state.compactExternalPowerConnected
        case .djiOsmoNano:
            telemetry.isExternalPowerConnected = state.compactNanoExternalPowerConnected
        case .djiOsmoPocket3, .genericDJI, .goProOpen, .unknown:
            telemetry.isExternalPowerConnected = nil
        }

        return telemetry.isEmpty ? nil : telemetry
    }

    func cameraStatusUpdate(from state: DJICameraStateSummary) -> CameraStatusUpdate {
        let previousVideoRecordTime = lastVideoRecordTime
        let recordingTimerSignal = recordingTimerIsAdvancing(in: state)
        let recordingState: CameraRecordingState?

        switch state.format {
        case .full:
            if !cameraBehavior.trustsDJIFullRecordingStatus {
                recordingState = nil
            } else if recordingTimerSignal {
                recordingState = .recording
            } else {
                recordingState = state.recordingState
            }
        case .compact:
            // Action-family compact pushes can carry stale record-time and mode bytes.
            // Keep recording detection model-specific, and do not use compact mode as mode truth.
            if (cameraBehavior.trustsDJICompactRecordingStatus && state.isCompactRecordingSignal)
                || recordingTimerSignal {
                recordingState = .recording
            } else if shouldTrustCompactStoppedStatus && state.isCompactStoppedSignal {
                recordingState = .stopped
            } else {
                recordingState = nil
            }
        }

        logAction6StatusDecode(
            state,
            previousVideoRecordTime: previousVideoRecordTime,
            recordingTimerSignal: recordingTimerSignal,
            recordingState: recordingState
        )

        return CameraStatusUpdate(
            recordingState: recordingState,
            telemetry: state.telemetry,
            canClearActiveRecording: canClearActiveRecording(with: recordingState)
        )
    }

    func recordingTimerIsAdvancing(in state: DJICameraStateSummary) -> Bool {
        defer {
            lastVideoRecordTime = state.videoRecordTime
        }

        guard cameraBehavior.trustsDJIRecordingTimerStatus,
              state.videoRecordTime > 0,
              let lastVideoRecordTime else {
            return false
        }

        return state.videoRecordTime > lastVideoRecordTime
    }

    var shouldTrustCompactStoppedStatus: Bool {
        cameraBehavior.kind != .djiOsmoPocket3
    }

    func logAction6StatusDecode(
        _ state: DJICameraStateSummary,
        previousVideoRecordTime: UInt32?,
        recordingTimerSignal: Bool,
        recordingState: CameraRecordingState?
    ) {
        guard cameraBehavior.kind == .djiOsmoAction6 else { return }

        let previousTimerLabel = previousVideoRecordTime.map { "\($0)s" } ?? "none"
        let recordingLabel = recordingState?.rawValue ?? "nil"
        let diagnosticLabel = "decoded \(recordingLabel), timerAdvancing \(recordingTimerSignal ? "yes" : "no"), previousTimer \(previousTimerLabel), \(state.debugLabel)"
        guard diagnosticLabel != lastAction6StatusDiagnosticLabel else { return }

        lastAction6StatusDiagnosticLabel = diagnosticLabel
        onLog("\(cameraName): Action 6 status \(diagnosticLabel).")
    }

    func canClearActiveRecording(with recordingState: CameraRecordingState?) -> Bool {
        if recordingState == .recording {
            return true
        }

        if recordingState == .stopped {
            if Date() < compactStoppedProtectionUntil {
                return false
            }
            return cameraBehavior.trustsDJIStoppedStatusToClearActiveRecording
        }

        return false
    }

    func protectAgainstStaleStoppedStatusAfterStart() {
        compactStoppedProtectionUntil = Date().addingTimeInterval(staleStoppedProtectionIntervalAfterStart)
    }

    var staleStoppedProtectionIntervalAfterStart: TimeInterval {
        cameraBehavior.kind == .djiOsmoNano ? 15 : 4
    }

    func applyDumlRecordingHint(from value: Data) {
        guard let packet = DJIDUMLIncomingPacket(data: value),
              !packet.isResponse,
              let recordingState = packet.recordingStateHint else {
            return
        }

        guard shouldApplyLegacyDumlRecordingStatus else { return }

        if recordingState == .recording, !cameraBehavior.trustsDJIRecordingHints {
            onLog(
                "\(cameraName): ignored DJI recording hint cmdset 0x\(packet.commandSet.hexByte) cmd 0x\(packet.commandID.hexByte) for this camera profile."
            )
            return
        }

        onLog(
            "\(cameraName): DJI status hint cmdset 0x\(packet.commandSet.hexByte) cmd 0x\(packet.commandID.hexByte) -> \(recordingState.rawValue)."
        )
        onCameraStatus(
            cameraID,
            CameraStatusUpdate(
                recordingState: recordingState,
                canClearActiveRecording: canClearActiveRecording(with: recordingState),
                shouldClearCurrentMode: recordingState == .recording
            )
        )
    }

    func logUnhandledDumlPacket(from value: Data) {
        guard let packet = DJIDUMLIncomingPacket(data: value),
              !packet.isResponse,
              !packet.isCameraStatePush,
              packet.recordingStateHint == nil,
              packet.sender == dumlRouting.cameraAddress else {
            return
        }

        let payloadLabel = packet.payload.isEmpty ? "empty payload" : "payload \(packet.payload.hexString)"
        let label = "cmdset 0x\(packet.commandSet.hexByte) cmd 0x\(packet.commandID.hexByte), \(payloadLabel), flags 0x\(packet.flags.hexByte)"
        guard label != lastUnhandledDumlPacketLabel else { return }

        lastUnhandledDumlPacketLabel = label
        onLog("\(cameraName): DJI unhandled camera packet \(label).")
    }

    static func cameraStateModeLabel(_ value: UInt8) -> String {
        switch value {
        case 0x00:
            "takephoto (0x00)"
        case 0x01:
            "record/video (0x01)"
        case 0x02:
            "playback (0x02)"
        case 0x03:
            "transcode (0x03)"
        case 0x04:
            "tuning (0x04)"
        case 0x05:
            "savepower (0x05)"
        case 0x06:
            "download (0x06)"
        case 0x07:
            "new playback (0x07)"
        case 0x64:
            "other (0x64)"
        default:
            "unknown 0x\(value.hexByte)"
        }
    }

    static func captureMode(forDJIModeByte value: UInt8) -> CaptureMode? {
        switch value {
        case 0x00:
            .photo
        case 0x01:
            .video
        default:
            nil
        }
    }

    func shouldLogRawNotification(_ value: Data) -> Bool {
        guard let packet = DJIDUMLIncomingPacket(data: value) else { return true }
        if cameraBehavior.kind == .djiOsmoPocket3,
           !packet.isResponse,
           packet.isPocket3NoisyStatePacket {
            return false
        }
        return !packet.isHighFrequencyStatePush
    }

    func nextDumlPacket(
        routing: DJIDUMLRouting? = nil,
        commandSet: UInt8,
        commandID: UInt8,
        payload: Data,
        flags: UInt8 = 0x40
    ) -> DJISequencedCommand {
        let currentSequenceNumber = sequenceNumber
        defer { sequenceNumber &+= 1 }
        return DJISequencedCommand(
            sequenceNumber: currentSequenceNumber,
            data: DJIDUMLPacket.recordControl(
                sequenceNumber: currentSequenceNumber,
                routing: routing ?? dumlRouting,
                commandSet: commandSet,
                commandID: commandID,
                payload: payload,
                flags: flags
            )
        )
    }
}

private struct DJIDUMLRouting: Equatable {
    static let `default` = DJIDUMLRouting(appAddress: 0x02, cameraAddress: 0x01)

    var appAddress: UInt8
    var cameraAddress: UInt8

    var debugLabel: String {
        "app 0x\(appAddress.hexByte) -> camera 0x\(cameraAddress.hexByte)"
    }

}

private struct DJIDUMLIncomingPacket {
    var sender: UInt8
    var receiver: UInt8
    var sequenceNumber: UInt16
    var flags: UInt8
    var commandSet: UInt8
    var commandID: UInt8
    var payload: Data
    var resultCode: UInt8?

    var isResponse: Bool {
        flags & 0x80 == 0x80
    }

    var senderType: UInt8 {
        sender & 0x1F
    }

    var isHighFrequencyStatePush: Bool {
        !isResponse && isCameraStatePush
    }

    var isCameraStatePush: Bool {
        (commandSet == 0x02 && commandID == 0x80)
            || (commandSet == 0x0D && commandID == 0x02)
    }

    var isPocket3NoisyStatePacket: Bool {
        (commandSet == 0x04 && commandID == 0x05)
            || (commandSet == 0x04 && commandID == 0x27)
    }

    var payloadWithoutResultCode: Data {
        guard resultCode != nil, !payload.isEmpty else { return payload }
        return Data(payload.dropFirst())
    }

    init?(data: Data) {
        guard data.count >= 13, data[data.startIndex] == 0x55 else { return nil }

        let sender = data[data.index(data.startIndex, offsetBy: 4)]
        let receiver = data[data.index(data.startIndex, offsetBy: 5)]
        guard sender != 0, receiver != 0 else { return nil }

        self.sender = sender
        self.receiver = receiver
        self.sequenceNumber = UInt16(data[data.index(data.startIndex, offsetBy: 6)])
            | UInt16(data[data.index(data.startIndex, offsetBy: 7)]) << 8
        self.flags = data[data.index(data.startIndex, offsetBy: 8)]
        self.commandSet = data[data.index(data.startIndex, offsetBy: 9)]
        self.commandID = data[data.index(data.startIndex, offsetBy: 10)]

        let payloadStart = data.index(data.startIndex, offsetBy: 11)
        let payloadEnd = data.index(data.endIndex, offsetBy: -2)
        if payloadStart < payloadEnd {
            self.payload = Data(data[payloadStart ..< payloadEnd])
            self.resultCode = payload.first
        } else {
            self.payload = Data()
            self.resultCode = nil
        }
    }

    var recordingStateHint: CameraRecordingState? {
        if commandSet == 0x01, commandID == 0x21 {
            return .recording
        }

        if commandSet == 0x01, commandID == 0x22 {
            return .stopped
        }

        if commandSet == 0x02,
           commandID == 0x02 || commandID == 0x7C,
           let first = payload.first {
            if first == 0x00 {
                return .stopped
            }
            if first == 0x01 {
                return .recording
            }
        }

        return nil
    }
}

private struct DJICameraStateSummary {
    enum Format {
        case full
        case compact
    }

    var format: Format
    var flags: UInt32
    var mode: UInt8
    var sdCardTotalSize: UInt32
    var sdCardFreeSize: UInt32
    var remainedTime: UInt32
    var videoRecordTime: UInt32
    var cameraType: UInt8
    var version: UInt8
    var batteryPercent: UInt8?
    var compactStateByte: UInt8?

    init?(payload: Data) {
        if payload.count >= 37,
           let flags = payload.littleEndianUInt32(at: 0),
           let mode = payload.byte(at: 4),
           let sdCardTotalSize = payload.littleEndianUInt32(at: 5),
           let sdCardFreeSize = payload.littleEndianUInt32(at: 9),
           let remainedTime = payload.littleEndianUInt32(at: 17),
           let videoRecordTime = payload.littleEndianUInt16(at: 29),
           let cameraType = payload.byte(at: 33),
           let version = payload.byte(at: 36) {
            self.format = .full
            self.flags = flags
            self.mode = mode
            self.sdCardTotalSize = sdCardTotalSize
            self.sdCardFreeSize = sdCardFreeSize
            self.remainedTime = remainedTime
            self.videoRecordTime = UInt32(videoRecordTime)
            self.cameraType = cameraType
            self.version = version
            self.batteryPercent = nil
            self.compactStateByte = nil
            return
        }

        guard payload.count >= 34,
              let remainedTime = payload.littleEndianUInt32(at: 1),
              let flags = payload.littleEndianUInt16(at: 27),
              let videoRecordTime = payload.bigEndianUInt32(at: 29),
              let mode = payload.byte(at: 33) else {
            return nil
        }

        self.format = .compact
        self.flags = UInt32(flags)
        self.mode = mode
        self.sdCardTotalSize = 0
        self.sdCardFreeSize = 0
        self.remainedTime = remainedTime
        self.videoRecordTime = videoRecordTime
        self.cameraType = 0
        self.version = 0
        self.batteryPercent = payload.byte(at: 20)
        self.compactStateByte = payload.byte(at: 2)
    }

    var captureMode: CaptureMode? {
        DJIExperimentalBLEClient.captureMode(forDJIModeByte: mode)
    }

    var recordingState: CameraRecordingState? {
        guard mode == 0x01 else {
            return captureMode == nil ? nil : .stopped
        }
        switch format {
        case .full:
            return recordBits == 0 ? .stopped : .recording
        case .compact:
            return isCompactStoppedSignal ? .stopped : nil
        }
    }

    var canClearActiveRecording: Bool {
        true
    }

    var recordBits: UInt32 {
        (flags & 0x00C0) >> 6
    }

    var isCompactStoppedSignal: Bool {
        format == .compact && recordBits == 0 && videoRecordTime == 0
    }

    var isCompactRecordingSignal: Bool {
        format == .compact && mode == 0x01 && recordBits != 0
    }

    var compactExternalPowerConnected: Bool? {
        guard format == .compact else { return nil }
        return (flags & 0x0040) != 0
    }

    var compactNanoExternalPowerConnected: Bool? {
        guard format == .compact else { return nil }

        // Nano's camera and screen have separate batteries. The screen attachment
        // settles with both this flag and the trailing state value set. Once attached,
        // the screen battery is an external power source for the camera regardless of
        // whether the screen itself is connected to wall power.
        return (flags & 0x0040) != 0 && videoRecordTime == 1
    }

    var debugLabel: String {
        let sdCardBits = (flags & 0x3C00) >> 10
        switch format {
        case .full:
            return "mode \(DJIExperimentalBLEClient.cameraStateModeLabel(mode)), recordBits \(recordBits), sdBits \(sdCardBits), remainingTime \(remainedTime)s, videoRecordTime \(videoRecordTime)s, sdFree \(sdCardFreeSize)/\(sdCardTotalSize), cameraType 0x\(cameraType.hexByte), version \(version), flags 0x\(flags.hexWord)"
        case .compact:
            let batteryByte = batteryPercent.map(String.init) ?? "unknown"
            let stateByte = compactStateByte.map(\.hexByte) ?? "unknown"
            return "compact mode byte \(DJIExperimentalBLEClient.cameraStateModeLabel(mode)), recordBits \(recordBits), videoRecordTime \(videoRecordTime)s, remainingTime \(remainedTime)s, batteryByte \(batteryByte), stateByte2 0x\(stateByte), flags 0x\(flags.hexWord)"
        }
    }

    var telemetry: CameraTelemetry? {
        var telemetry = CameraTelemetry()

        if let batteryPercent, batteryPercent <= 100 {
            telemetry.batteryPercent = Int(batteryPercent)
        }

        if sdCardTotalSize > 0 {
            telemetry.storageTotalMB = sdCardTotalSize
        }

        if sdCardFreeSize > 0 {
            telemetry.storageFreeMB = sdCardFreeSize
        }

        telemetry.lastUpdated = Date()
        return telemetry.isEmpty ? nil : telemetry
    }
}

private struct DJIAction6ShortState {
    var statusByte: UInt8
    var payload: Data

    init?(payload: Data) {
        guard payload.count >= 5, let statusByte = payload.byte(at: 0) else { return nil }
        guard statusByte == 0x01 || statusByte == 0x81 else { return nil }

        self.statusByte = statusByte
        self.payload = payload
    }

    var recordingState: CameraRecordingState {
        (statusByte & 0x80) != 0 ? .recording : .stopped
    }

    var debugLabel: String {
        "Action 6 short state \(recordingState.rawValue), statusByte 0x\(statusByte.hexByte), payload \(payload.hexString)"
    }
}

private struct DJICommandPacket {
    var label: String
    var command: DJISequencedCommand

    var sequenceNumber: UInt16 {
        command.sequenceNumber
    }

    var data: Data {
        command.data
    }
}

private struct DJISequencedCommand {
    var sequenceNumber: UInt16
    var data: Data
}

private enum DJIRSDKBLEUUID {
    static let service = CBUUID(string: "FFF0")
    static let notifyCharacteristic = CBUUID(string: "FFF4")
    static let writeCharacteristic = CBUUID(string: "FFF5")
}

private enum DJIRSDKCommandType {
    static let noResponse: UInt8 = 0x00
    static let responseOrNot: UInt8 = 0x01
    static let waitResult: UInt8 = 0x02
    static let ackNoResponse: UInt8 = 0x20
}

private struct DJIRSDKIncomingFrame {
    var commandType: UInt8
    var sequenceNumber: UInt16
    var cmdSet: UInt8
    var cmdID: UInt8
    var payload: Data

    var isResponse: Bool {
        commandType & 0x20 == 0x20
    }

    init?(data: Data) {
        guard data.count >= DJIRSDKPacket.minimumFrameLength,
              data[data.startIndex] == DJIRSDKPacket.startOfFrame,
              let declaredLength = DJIRSDKPacket.declaredLength(in: data) else {
            return nil
        }

        guard declaredLength == data.count,
              let embeddedHeaderChecksum = data.littleEndianUInt16(at: 10),
              let embeddedPacketChecksum = data.littleEndianUInt32(at: data.count - 4) else {
            return nil
        }

        let headerChecksum = DJIRSDKChecksum.crc16(Data(data.prefix(10)))
        let packetChecksum = DJIRSDKChecksum.crc32(Data(data.prefix(data.count - 4)))
        guard headerChecksum == embeddedHeaderChecksum,
              packetChecksum == embeddedPacketChecksum else {
            return nil
        }

        self.commandType = data[data.index(data.startIndex, offsetBy: 3)]
        self.sequenceNumber = UInt16(data[data.index(data.startIndex, offsetBy: 8)])
            | UInt16(data[data.index(data.startIndex, offsetBy: 9)]) << 8
        self.cmdSet = data[data.index(data.startIndex, offsetBy: 12)]
        self.cmdID = data[data.index(data.startIndex, offsetBy: 13)]

        let payloadStart = data.index(data.startIndex, offsetBy: 14)
        let payloadEnd = data.index(data.endIndex, offsetBy: -4)
        self.payload = payloadStart < payloadEnd ? Data(data[payloadStart ..< payloadEnd]) : Data()
    }
}

private struct DJIRSDKConnectionRequest {
    var verifyMode: UInt8
    var verifyData: UInt16
    var cameraReserved: UInt8
    var payloadLength: Int
    var layoutLabel: String

    init?(payload: Data) {
        let candidates: [(label: String, verifyModeOffset: Int, verifyDataOffset: Int, cameraReservedOffset: Int)] = [
            ("standard", 26, 27, 29),
            ("compact", 25, 26, 28)
        ]
        let parsedCandidates = candidates.compactMap { candidate
            -> (label: String, verifyMode: UInt8, verifyData: UInt16, cameraReserved: UInt8)? in
            guard let verifyMode = payload.byte(at: candidate.verifyModeOffset),
                  let verifyData = payload.littleEndianUInt16(at: candidate.verifyDataOffset),
                  let cameraReserved = payload.byte(at: candidate.cameraReservedOffset) else {
                return nil
            }

            return (candidate.label, verifyMode, verifyData, cameraReserved)
        }

        guard let selected = parsedCandidates.first(where: { $0.verifyMode == 0x02 }) ?? parsedCandidates.first else {
            return nil
        }

        self.verifyMode = selected.verifyMode
        self.verifyData = selected.verifyData
        self.cameraReserved = selected.cameraReserved
        self.payloadLength = payload.count
        self.layoutLabel = selected.label
    }

    var debugLabel: String {
        "\(layoutLabel) payload \(payloadLength) bytes, mode 0x\(verifyMode.hexByte), data 0x\(verifyData.hexWord), reserved 0x\(cameraReserved.hexByte)"
    }
}

private struct DJIRSDKStatusPush {
    var cameraMode: UInt8
    var cameraStatus: UInt8
    var videoResolution: UInt8
    var frameRateIndex: UInt8
    var stabilizationMode: UInt8
    var recordTime: UInt16
    var photoRatio: UInt8
    var remainingPhotos: UInt32
    var remainingRecordTime: UInt32
    var powerMode: UInt8
    var batteryPercent: UInt8?

    init?(payload: Data) {
        guard payload.count >= 38,
              let cameraMode = payload.byte(at: 0),
              let cameraStatus = payload.byte(at: 1),
              let videoResolution = payload.byte(at: 2),
              let frameRateIndex = payload.byte(at: 3),
              let stabilizationMode = payload.byte(at: 4),
              let recordTime = payload.littleEndianUInt16(at: 5),
              let photoRatio = payload.byte(at: 8),
              let remainingPhotos = payload.littleEndianUInt32(at: 19),
              let remainingRecordTime = payload.littleEndianUInt32(at: 23),
              let powerMode = payload.byte(at: 28) else {
            return nil
        }

        self.cameraMode = cameraMode
        self.cameraStatus = cameraStatus
        self.videoResolution = videoResolution
        self.frameRateIndex = frameRateIndex
        self.stabilizationMode = stabilizationMode
        self.recordTime = recordTime
        self.photoRatio = photoRatio
        self.remainingPhotos = remainingPhotos
        self.remainingRecordTime = remainingRecordTime
        self.powerMode = powerMode
        self.batteryPercent = payload.byte(at: 37)
    }

    var cameraStatusUpdate: CameraStatusUpdate {
        CameraStatusUpdate(
            recordingState: recordingState,
            currentMode: captureMode,
            telemetry: telemetry,
            powerState: powerState,
            canClearActiveRecording: recordingState != .stopped || powerMode != 0x03
        )
    }

    var powerState: CameraPowerState? {
        switch powerMode {
        case 0x00:
            .awake
        case 0x03:
            .sleeping
        default:
            nil
        }
    }

    var recordingState: CameraRecordingState? {
        switch cameraStatus {
        case 0x03, 0x05:
            .recording
        case 0x00, 0x01, 0x02:
            .stopped
        default:
            nil
        }
    }

    var captureMode: CaptureMode? {
        switch cameraMode {
        case 0x01:
            .video
        case 0x05:
            .photo
        case 0x02, 0x0A:
            .timelapse
        default:
            nil
        }
    }

    var telemetry: CameraTelemetry? {
        var telemetry = CameraTelemetry()
        if let batteryPercent, batteryPercent <= 100 {
            telemetry.batteryPercent = Int(batteryPercent)
        }
        if remainingRecordTime > 0 {
            telemetry.remainingVideoSeconds = remainingRecordTime
        }
        if remainingPhotos > 0 {
            telemetry.remainingPhotos = remainingPhotos
        }
        telemetry.videoResolution = Self.videoResolutionLabel(videoResolution)
        telemetry.frameRate = Self.frameRateLabel(frameRateIndex)
        telemetry.hypersmooth = Self.stabilizationLabel(stabilizationMode)
        telemetry.lastUpdated = Date()
        return telemetry.isEmpty ? nil : telemetry
    }

    var debugLabel: String {
        let mode = captureMode?.rawValue ?? "mode 0x\(cameraMode.hexByte)"
        let state = recordingState?.rawValue ?? "status 0x\(cameraStatus.hexByte)"
        let battery = batteryPercent.map { "\($0)%" } ?? "unknown"
        return "\(mode), \(state), recordTime \(recordTime)s, remaining \(remainingRecordTime)s, battery \(battery)"
    }

    static func videoResolutionLabel(_ value: UInt8) -> String? {
        switch value {
        case 10:
            "1080p"
        case 16:
            "4K 16:9"
        case 45:
            "2.7K 16:9"
        case 66:
            "1080p 9:16"
        case 67:
            "2.7K 9:16"
        case 95:
            "2.7K 4:3"
        case 103:
            "4K 4:3"
        case 109:
            "4K 9:16"
        default:
            nil
        }
    }

    static func frameRateLabel(_ value: UInt8) -> String? {
        switch value {
        case 1:
            "24fps"
        case 2:
            "25fps"
        case 3:
            "30fps"
        case 4:
            "48fps"
        case 5:
            "50fps"
        case 6:
            "60fps"
        case 7:
            "120fps"
        case 8:
            "240fps"
        case 10:
            "100fps"
        case 19:
            "200fps"
        default:
            nil
        }
    }

    static func stabilizationLabel(_ value: UInt8) -> String? {
        switch value {
        case 0:
            "Off"
        case 1:
            "RS"
        case 2:
            "HS"
        case 3:
            "RS+"
        case 4:
            "HB"
        default:
            nil
        }
    }
}

private struct DJIRSDKModeDetails {
    var modeName: String?
    var modeParameters: String?

    init?(payload: Data) {
        guard payload.count >= 25 else { return nil }

        let nameLength = min(Int(payload.byte(at: 1) ?? 0), 20)
        if nameLength > 0, payload.count >= 2 + nameLength {
            let start = payload.index(payload.startIndex, offsetBy: 2)
            let end = payload.index(start, offsetBy: nameLength)
            modeName = String(data: Data(payload[start ..< end]), encoding: .ascii)
        }

        guard let paramMarker = payload.byte(at: 23), paramMarker == 0x02 else { return }
        let parameterLength = min(Int(payload.byte(at: 24) ?? 0), 20)
        if parameterLength > 0, payload.count >= 25 + parameterLength {
            let start = payload.index(payload.startIndex, offsetBy: 25)
            let end = payload.index(start, offsetBy: parameterLength)
            modeParameters = String(data: Data(payload[start ..< end]), encoding: .ascii)
        }
    }

    var debugLabel: String {
        [modeName, modeParameters]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " ")
    }
}

private enum DJIRSDKPacket {
    static let startOfFrame: UInt8 = 0xAA
    static let minimumFrameLength = 18
    static let maximumFrameLength = 0x03FF
    static let headerLength = 12

    static func declaredLength(in data: Data) -> Int? {
        guard data.count >= 3,
              data[data.startIndex] == startOfFrame,
              let versionAndLength = data.littleEndianUInt16(at: 1) else {
            return nil
        }

        return Int(versionAndLength & 0x03FF)
    }

    static func hasValidHeader(in data: Data) -> Bool {
        guard data.count >= headerLength,
              data[data.startIndex] == startOfFrame,
              let embeddedChecksum = data.littleEndianUInt16(at: 10) else {
            return false
        }

        return DJIRSDKChecksum.crc16(Data(data.prefix(10))) == embeddedChecksum
    }

    static func connectionRequest(sequenceNumber: UInt16) -> Data {
        var payload = Data()
        payload.appendLittleEndian(controllerDeviceID)
        payload.append(0x10)
        payload.append(contentsOf: controllerIdentifier)
        payload.appendLittleEndian(UInt32(0))
        payload.append(0x00)
        payload.append(0x00)
        payload.appendLittleEndian(UInt16(0))
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        return frame(
            sequenceNumber: sequenceNumber,
            commandType: DJIRSDKCommandType.waitResult,
            commandSet: 0x00,
            commandID: 0x19,
            payload: payload
        )
    }

    static func connectionResponse(sequenceNumber: UInt16, cameraReserved: UInt8) -> Data {
        var payload = Data()
        payload.appendLittleEndian(controllerDeviceID)
        payload.append(0x00)
        payload.append(contentsOf: [cameraReserved, 0x00, 0x00, 0x00])

        return frame(
            sequenceNumber: sequenceNumber,
            commandType: DJIRSDKCommandType.ackNoResponse,
            commandSet: 0x00,
            commandID: 0x19,
            payload: payload
        )
    }

    static func recordControl(sequenceNumber: UInt16, isStarting: Bool) -> Data {
        var payload = Data()
        payload.appendLittleEndian(UInt32(0x33FF0000))
        payload.append(isStarting ? 0x00 : 0x01)
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        return frame(
            sequenceNumber: sequenceNumber,
            commandType: DJIRSDKCommandType.responseOrNot,
            commandSet: 0x1D,
            commandID: 0x03,
            payload: payload
        )
    }

    static func modeSwitch(sequenceNumber: UInt16, mode: UInt8) -> Data {
        var payload = Data()
        payload.appendLittleEndian(UInt32(0xFF330000))
        payload.append(mode)
        payload.append(contentsOf: [0x01, 0x47, 0x39, 0x36])

        return frame(
            sequenceNumber: sequenceNumber,
            commandType: DJIRSDKCommandType.responseOrNot,
            commandSet: 0x1D,
            commandID: 0x04,
            payload: payload
        )
    }

    static func statusSubscription(sequenceNumber: UInt16) -> Data {
        var payload = Data()
        payload.append(0x03)
        payload.append(0x14)
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        return frame(
            sequenceNumber: sequenceNumber,
            commandType: DJIRSDKCommandType.noResponse,
            commandSet: 0x1D,
            commandID: 0x05,
            payload: payload
        )
    }

    static func gpsData(sequenceNumber: UInt16, fix: DJIGPSFix) -> Data {
        gpsData(
            sequenceNumber: sequenceNumber,
            payload: DJIGPSPayloadEncoder.payload(for: fix)
        )
    }

    static func gpsData(sequenceNumber: UInt16, payload: Data) -> Data {
        return frame(
            sequenceNumber: sequenceNumber,
            commandType: DJIRSDKCommandType.noResponse,
            commandSet: 0x00,
            commandID: 0x17,
            payload: payload
        )
    }

    static func frame(
        sequenceNumber: UInt16,
        commandType: UInt8,
        commandSet: UInt8,
        commandID: UInt8,
        payload: Data
    ) -> Data {
        let totalLength = UInt16(minimumFrameLength + payload.count)
        let versionAndLength = totalLength
        var bytes = Data()

        bytes.append(startOfFrame)
        bytes.appendLittleEndian(versionAndLength)
        bytes.append(commandType)
        bytes.append(0x00)
        bytes.append(contentsOf: [0x00, 0x00, 0x00])
        bytes.appendLittleEndian(sequenceNumber)
        bytes.appendLittleEndian(DJIRSDKChecksum.crc16(bytes))
        bytes.append(commandSet)
        bytes.append(commandID)
        bytes.append(payload)
        bytes.appendLittleEndian(DJIRSDKChecksum.crc32(bytes))
        return bytes
    }

    private static let controllerIdentifier: Data = {
        let storageKey = "djiRSDKControllerIdentifier.v1"
        if let saved = UserDefaults.standard.data(forKey: storageKey), saved.count == 16 {
            return saved
        }

        var bytes = Data()
        let uuid = UUID().uuid
        withUnsafeBytes(of: uuid) { rawBuffer in
            bytes.append(contentsOf: rawBuffer)
        }
        let identifier = Data(bytes.prefix(16))
        UserDefaults.standard.set(identifier, forKey: storageKey)
        return identifier
    }()

    private static let controllerDeviceID: UInt32 = 0x00000001
}

private enum DJIRSDKChecksum {
    static func crc16(_ data: Data) -> UInt16 {
        var checksum: UInt16 = 0x3AA3
        for byte in data {
            checksum ^= UInt16(byte)
            for _ in 0 ..< 8 {
                if checksum & 0x0001 == 0x0001 {
                    checksum = (checksum >> 1) ^ 0xA001
                } else {
                    checksum >>= 1
                }
            }
        }
        return checksum
    }

    static func crc32(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0x00003AA3
        for byte in data {
            checksum ^= UInt32(byte)
            for _ in 0 ..< 8 {
                if checksum & 0x00000001 == 0x00000001 {
                    checksum = (checksum >> 1) ^ 0xEDB88320
                } else {
                    checksum >>= 1
                }
            }
        }
        return checksum
    }
}

private struct DJIWritableCharacteristic: Comparable {
    var serviceUUID: CBUUID
    var characteristic: CBCharacteristic

    var debugLabel: String {
        "\(serviceUUID.uuidString) / \(characteristic.uuid.uuidString)"
    }

    var isStandardBLETarget: Bool {
        DJIStandardBLEUUIDs.contains(serviceUUID.uuidString.uppercased())
            || DJIStandardBLEUUIDs.contains(characteristic.uuid.uuidString.uppercased())
    }

    var isClearlyGenericBLETarget: Bool {
        DJIClearlyGenericBLEUUIDs.contains(serviceUUID.uuidString.uppercased())
            || DJIClearlyGenericBLEUUIDs.contains(characteristic.uuid.uuidString.uppercased())
    }

    var isRSDKControlTarget: Bool {
        serviceUUID == DJIRSDKBLEUUID.service
            && characteristic.uuid == DJIRSDKBLEUUID.writeCharacteristic
    }

    var commandWriteTypes: [CBCharacteristicWriteType] {
        let canWriteWithResponse = characteristic.properties.contains(.write)
        let canWriteWithoutResponse = characteristic.properties.contains(.writeWithoutResponse)

        if canWriteWithoutResponse {
            return [.withoutResponse]
        }

        return canWriteWithResponse ? [.withResponse] : []
    }

    var statusProbeWriteTypes: [CBCharacteristicWriteType] {
        if characteristic.properties.contains(.write) {
            return [.withResponse]
        }

        if characteristic.properties.contains(.writeWithoutResponse) {
            return [.withoutResponse]
        }

        return []
    }

    private var priority: Int {
        let service = serviceUUID.uuidString.uppercased()
        let characteristicID = characteristic.uuid.uuidString.uppercased()
        var score = 0

        if characteristic.properties.contains(.write) { score += 100 }
        if characteristic.properties.contains(.writeWithoutResponse) { score += 60 }
        if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) { score += 10 }
        if service.count > 8 { score += 8 }
        if characteristicID.count > 8 { score += 4 }
        if DJIStandardBLEUUIDs.contains(service) { score -= 80 }
        if DJIStandardBLEUUIDs.contains(characteristicID) { score -= 40 }

        return score
    }

    static func < (lhs: DJIWritableCharacteristic, rhs: DJIWritableCharacteristic) -> Bool {
        lhs.priority > rhs.priority
    }

    static func == (lhs: DJIWritableCharacteristic, rhs: DJIWritableCharacteristic) -> Bool {
        lhs.serviceUUID == rhs.serviceUUID && lhs.characteristic.uuid == rhs.characteristic.uuid
    }
}

private extension CBCharacteristicWriteType {
    var logLabel: String {
        switch self {
        case .withResponse:
            "withResponse"
        case .withoutResponse:
            "withoutResponse"
        @unknown default:
            "unknownWriteType"
        }
    }
}

private extension CBCharacteristic {
    var debugLabel: String {
        let serviceID = service?.uuid.uuidString ?? "unknown service"
        return "\(serviceID) / \(uuid.uuidString)"
    }
}

private extension Array where Element: Equatable {
    func uniqued() -> [Element] {
        reduce(into: []) { result, element in
            if !result.contains(element) {
                result.append(element)
            }
        }
    }
}

private let DJIStandardBLEUUIDs: Set<String> = [
    "1800", "1801", "180A", "180F", "1812",
    "2A00", "2A01", "2A04", "2A05", "2A19", "2A29", "2A4D", "2A4E", "2A4F"
]

private let DJIClearlyGenericBLEUUIDs: Set<String> = [
    "1800", "1801", "180A", "180F",
    "2A00", "2A01", "2A04", "2A05", "2A19", "2A29"
]

private enum DJIDUMLPacket {
    static func recordControl(
        sequenceNumber: UInt16,
        routing: DJIDUMLRouting,
        commandSet: UInt8,
        commandID: UInt8,
        payload: Data,
        flags: UInt8 = 0x40
    ) -> Data {
        let packetLength = UInt16(11 + payload.count + 2)
        let versionAndLength = packetLength | (1 << 10)
        var bytes = Data()

        bytes.append(0x55)
        bytes.append(UInt8(versionAndLength & 0xFF))
        bytes.append(UInt8((versionAndLength >> 8) & 0xFF))
        bytes.append(headerChecksum(for: bytes))
        bytes.append(routing.appAddress)
        bytes.append(routing.cameraAddress)
        bytes.append(UInt8(sequenceNumber & 0xFF))
        bytes.append(UInt8((sequenceNumber >> 8) & 0xFF))
        bytes.append(flags)
        bytes.append(commandSet)
        bytes.append(commandID)
        bytes.append(payload)

        let checksum = packetChecksum(for: bytes)
        bytes.append(UInt8(checksum & 0xFF))
        bytes.append(UInt8((checksum >> 8) & 0xFF))
        return bytes
    }

    private static func headerChecksum(for bytes: Data) -> UInt8 {
        bytes.reduce(UInt8(0x77)) { checksum, byte in
            crc8Maxim(checksum ^ byte)
        }
    }

    private static func packetChecksum(for bytes: Data) -> UInt16 {
        bytes.reduce(UInt16(0x3692)) { checksum, byte in
            crc16X25Step(checksum, byte: byte)
        }
    }

    private static func crc8Maxim(_ value: UInt8) -> UInt8 {
        var checksum = value
        for _ in 0 ..< 8 {
            if checksum & 0x01 == 0x01 {
                checksum = (checksum >> 1) ^ 0x8C
            } else {
                checksum >>= 1
            }
        }
        return checksum
    }

    private static func crc16X25Step(_ checksum: UInt16, byte: UInt8) -> UInt16 {
        var value = checksum ^ UInt16(byte)
        for _ in 0 ..< 8 {
            if value & 0x0001 == 0x0001 {
                value = (value >> 1) ^ 0x8408
            } else {
                value >>= 1
            }
        }
        return value
    }
}

private extension UInt8 {
    var hexByte: String {
        String(format: "%02X", self)
    }
}

private extension UInt16 {
    var hexWord: String {
        String(format: "%04X", self)
    }
}

private extension UInt32 {
    var hexWord: String {
        String(format: "%08X", self)
    }
}

private extension CBCharacteristicProperties {
    var debugLabels: [String] {
        var labels: [String] = []
        if contains(.broadcast) { labels.append("broadcast") }
        if contains(.read) { labels.append("read") }
        if contains(.writeWithoutResponse) { labels.append("writeWithoutResponse") }
        if contains(.write) { labels.append("write") }
        if contains(.notify) { labels.append("notify") }
        if contains(.indicate) { labels.append("indicate") }
        if contains(.authenticatedSignedWrites) { labels.append("signedWrites") }
        if contains(.extendedProperties) { labels.append("extended") }
        if contains(.notifyEncryptionRequired) { labels.append("notifyEncryption") }
        if contains(.indicateEncryptionRequired) { labels.append("indicateEncryption") }
        return labels.isEmpty ? ["unknown"] : labels
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[index(startIndex, offsetBy: offset)]
    }

    func littleEndianUInt16(at offset: Int) -> UInt16? {
        guard let b0 = byte(at: offset),
              let b1 = byte(at: offset + 1) else {
            return nil
        }

        return UInt16(b0) | UInt16(b1) << 8
    }

    func littleEndianUInt32(at offset: Int) -> UInt32? {
        guard let b0 = byte(at: offset),
              let b1 = byte(at: offset + 1),
              let b2 = byte(at: offset + 2),
              let b3 = byte(at: offset + 3) else {
            return nil
        }

        return UInt32(b0)
            | UInt32(b1) << 8
            | UInt32(b2) << 16
            | UInt32(b3) << 24
    }

    func bigEndianUInt32(at offset: Int) -> UInt32? {
        guard let b0 = byte(at: offset),
              let b1 = byte(at: offset + 1),
              let b2 = byte(at: offset + 2),
              let b3 = byte(at: offset + 3) else {
            return nil
        }

        return UInt32(b0) << 24
            | UInt32(b1) << 16
            | UInt32(b2) << 8
            | UInt32(b3)
    }
}
