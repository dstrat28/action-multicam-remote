import CoreBluetooth
import Foundation

final class DJIExperimentalBLEClient: NSObject, BLECameraDeviceClient {
    let cameraID: UUID
    let cameraName: String
    let cameraModel: CameraModel

    private weak var peripheral: CBPeripheral?
    private var writeCandidates: [DJIWritableCharacteristic] = []
    private var dumlRouting: DJIDUMLRouting
    private var sequenceNumber: UInt16 = UInt16.random(in: .min ... .max)
    private var pendingRecordActionsBySequence: [UInt16: RecordAction] = [:]
    private var pendingModeUpdatesBySequence: [UInt16: CaptureMode] = [:]
    private var pendingStatusProbeLabelsBySequence: [UInt16: String] = [:]
    private var hasSentInitialStatusProbe = false
    private var statusProbeTimer: Timer?
    private var lastCameraStateSummaryLabel: String?
    private var lastCameraStateSummaryLogDate = Date.distantPast
    private var lastVideoRecordTime: UInt32?
    private var lastAction6StatusDiagnosticLabel: String?
    private var compactStoppedProtectionUntil = Date.distantPast
    private let onStatus: (UUID, CameraConnectionState, String?) -> Void
    private let onCameraStatus: (UUID, CameraStatusUpdate) -> Void
    private let onLog: (String) -> Void

    init(
        cameraID: UUID,
        cameraName: String,
        cameraModel: CameraModel,
        peripheral: CBPeripheral,
        onStatus: @escaping (UUID, CameraConnectionState, String?) -> Void,
        onCameraStatus: @escaping (UUID, CameraStatusUpdate) -> Void,
        onLog: @escaping (String) -> Void
    ) {
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.cameraModel = cameraModel
        self.peripheral = peripheral
        self.dumlRouting = Self.defaultDumlRouting(cameraModel: cameraModel, cameraName: cameraName)
        self.onStatus = onStatus
        self.onCameraStatus = onCameraStatus
        self.onLog = onLog
        super.init()
    }

    func didConnect() {
        peripheral?.delegate = self
        peripheral?.discoverServices(nil)
        onLog("\(cameraName): DJI DUML route \(dumlRouting.debugLabel).")
        onStatus(cameraID, .connecting, "BLE link established; discovering DJI control characteristics.")
    }

    func didDisconnect(error: Error?) {
        writeCandidates.removeAll()
        pendingRecordActionsBySequence.removeAll()
        pendingModeUpdatesBySequence.removeAll()
        pendingStatusProbeLabelsBySequence.removeAll()
        hasSentInitialStatusProbe = false
        statusProbeTimer?.invalidate()
        statusProbeTimer = nil
        lastVideoRecordTime = nil
        lastAction6StatusDiagnosticLabel = nil
        compactStoppedProtectionUntil = .distantPast
    }

    func send(_ command: CameraCommand) -> CameraCommandResult {
        guard let peripheral else {
            return result(for: command, status: .failed, message: "DJI peripheral is unavailable.")
        }

        switch command {
        case .startRecording:
            return sendRecordCommand(.start, to: peripheral, label: command)
        case .stopRecording:
            return sendRecordCommand(.stop, to: peripheral, label: command)
        case .toggleRecording:
            return result(for: command, status: .unsupported, message: "DJI toggle record is not safe without camera state confirmation.")
        case let .setMode(mode):
            guard mode == .video else {
                return result(for: command, status: .unsupported, message: "Only DJI Video mode is mapped.")
            }
            return sendVideoModeCommand(to: peripheral, label: command)
        case .keepAlive:
            sendStatusProbe(to: peripheral, includeExtendedProbes: true, shouldLog: true)
            return result(for: command, status: .sent, message: "Sent DJI diagnostic status probe.")
        case .cycleMode, .applySetting:
            return result(
                for: command,
                status: .unsupported,
                message: "DJI settings control needs a proven BLE mapping."
            )
        }
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

            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }

            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                let candidate = DJIWritableCharacteristic(serviceUUID: service.uuid, characteristic: characteristic)
                if !writeCandidates.contains(candidate) {
                    writeCandidates.append(candidate)
                }
                writeCandidates.sort()
                onLog("\(cameraName): DJI write candidate \(candidate.debugLabel)")
            }

            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }

            if shouldDiscoverDescriptors(for: characteristic, in: service) {
                peripheral.discoverDescriptors(for: characteristic)
            }
        }

        if !writeCandidates.isEmpty {
            if shouldUsePocket3RecordFallbacks {
                onLog("\(cameraName): Pocket 3 write candidates: \(writeTargetSummary).")
                onLog("\(cameraName): Pocket 3 selected write targets: \(selectedWriteTargetSummary).")
            }
            onStatus(cameraID, .connected, "DJI record characteristics ready: \(writeTargets.count)")
            scheduleInitialStatusProbe(to: peripheral)
            startStatusPolling(to: peripheral)
        }
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
        updateDumlRouting(from: value)
        applyDumlRecordingHint(from: value)
        logDumlAck(from: value)
        logDumlStatusPush(from: value)
        if shouldLogRawNotification(value) {
            onLog("\(cameraName): \(characteristic.uuid.uuidString) \(value.hexString)")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let characteristicLabel = characteristic.debugLabel

        if let error {
            onLog("\(cameraName): descriptor discovery for \(characteristicLabel) failed: \(error.localizedDescription)")
            return
        }

        let descriptors = characteristic.descriptors ?? []
        if descriptors.isEmpty {
            onLog("\(cameraName): descriptors for \(characteristicLabel): none.")
            return
        }

        let descriptorIDs = descriptors.map { $0.uuid.uuidString }.joined(separator: ", ")
        onLog("\(cameraName): descriptors for \(characteristicLabel): \(descriptorIDs).")
        descriptors.forEach { peripheral.readValue(for: $0) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor descriptor: CBDescriptor,
        error: Error?
    ) {
        let characteristicLabel = descriptor.characteristic?.debugLabel ?? "unknown characteristic"

        if let error {
            onLog("\(cameraName): descriptor \(characteristicLabel) / \(descriptor.uuid.uuidString) read failed: \(error.localizedDescription)")
            return
        }

        onLog(
            "\(cameraName): descriptor \(characteristicLabel) / \(descriptor.uuid.uuidString) = \(descriptorValueLabel(descriptor.value))."
        )
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
}

private extension DJIExperimentalBLEClient {
    enum RecordAction {
        case start
        case stop

        var isStarting: Bool { self == .start }
        var isStopping: Bool { self == .stop }
    }

    var writeTargets: [DJIWritableCharacteristic] {
        if shouldUsePocket3RecordFallbacks {
            let pocketTargets = writeCandidates.filter(\.isPocket3CommandTarget)
            if !pocketTargets.isEmpty {
                return Array(pocketTargets.prefix(4))
            }
        }

        let privateTargets = writeCandidates.filter { !$0.isStandardBLETarget }
        if shouldUseExpandedActionWriteTargets {
            let safeTargets = writeCandidates.filter { !$0.isClearlyGenericBLETarget }
            let candidates = (privateTargets + safeTargets.filter { !privateTargets.contains($0) })
            return Array(candidates.prefix(8))
        }

        let candidates = privateTargets.isEmpty ? writeCandidates : privateTargets
        return Array(candidates.prefix(4))
    }

    func sendRecordCommand(
        _ action: RecordAction,
        to peripheral: CBPeripheral,
        label command: CameraCommand
    ) -> CameraCommandResult {
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
                    for writeType in target.writeTypes(expanded: shouldUseExpandedActionWriteTargets) {
                        peripheral.writeValue(packet.data, for: target.characteristic, type: writeType)
                        onLog("\(cameraName): DJI \(packet.label)\(burstLabel) -> \(target.debugLabel) (\(writeType.logLabel)) \(packet.data.hexString)")
                    }
                }
            }
        }

        return result(
            for: command,
            status: .sent,
            message: "Sent \(packetCount) experimental DJI \(action.isStarting ? "start" : "stop") record packets to \(targets.count) BLE targets.\(pocket3CommandDiagnosticSuffix())"
        )
    }

    func djiRecordPackets(for action: RecordAction) -> [DJICommandPacket] {
        if shouldUsePocket3RecordFallbacks {
            return djiPocket3RecordPackets(for: action)
        }

        if shouldSendDirectCameraRecordOnly {
            var packets = action.isStarting ? djiVideoModePackets() : []
            packets.append(
                DJICommandPacket(
                    label: "camera do record \(action.isStarting ? "on" : "off")",
                    command: nextDumlPacket(
                        commandSet: 0x02,
                        commandID: 0x02,
                        payload: Data([action.isStarting ? 0x01 : 0x00])
                    )
                )
            )

            packets.append(
                DJICommandPacket(
                    label: action.isStarting ? "special start video" : "special stop video",
                    command: nextDumlPacket(
                        commandSet: 0x01,
                        commandID: action.isStarting ? 0x21 : 0x22,
                        payload: Data()
                    )
                )
            )

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

            return packets
        }

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

        if shouldSendShutterControlPacket || (action.isStopping && shouldUseNanoStopFallbacks) {
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

    func djiPocket3RecordPackets(for action: RecordAction) -> [DJICommandPacket] {
        var packets: [DJICommandPacket] = []
        let payload = Data([action.isStarting ? 0x01 : 0x00])

        for routing in recordCommandRoutings {
            packets.append(
                DJICommandPacket(
                    label: "pocket route \(routing.debugLabel) camera control \(action.isStarting ? "start" : "stop")",
                    command: nextDumlPacket(
                        routing: routing,
                        commandSet: 0x02,
                        commandID: 0x01,
                        payload: payload
                    )
                )
            )

            packets.append(
                DJICommandPacket(
                    label: "pocket route \(routing.debugLabel) camera do record \(action.isStarting ? "on" : "off")",
                    command: nextDumlPacket(
                        routing: routing,
                        commandSet: 0x02,
                        commandID: 0x02,
                        payload: payload
                    )
                )
            )

            packets.append(
                DJICommandPacket(
                    label: "pocket route \(routing.debugLabel) \(action.isStarting ? "special start video" : "special stop video")",
                    command: nextDumlPacket(
                        routing: routing,
                        commandSet: 0x01,
                        commandID: action.isStarting ? 0x21 : 0x22,
                        payload: Data()
                    )
                )
            )

            packets.append(
                DJICommandPacket(
                    label: "pocket route \(routing.debugLabel) camera shutter \(action.isStarting ? "on" : "off")",
                    command: nextDumlPacket(
                        routing: routing,
                        commandSet: 0x02,
                        commandID: 0x7C,
                        payload: payload
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
                for writeType in target.writeTypes(expanded: shouldUseExpandedActionWriteTargets) {
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
        statusProbeTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self, weak peripheral] timer in
            guard let self, let peripheral, self.peripheral === peripheral else {
                timer.invalidate()
                return
            }

            self.sendStatusProbe(to: peripheral, includeExtendedProbes: false, shouldLog: false)
        }
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
        guard shouldUseExpandedActionWriteTargets else { return [dumlRouting] }

        return [
            dumlRouting,
            .default,
            DJIDUMLRouting(appAddress: 0x25, cameraAddress: 0x01)
        ].uniqued()
    }

    func djiVideoModePackets(routing: DJIDUMLRouting? = nil) -> [DJICommandPacket] {
        var packets = [
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

        if shouldUseActionVideoModeFallbacks {
            packets.append(contentsOf: [
                DJICommandPacket(
                    label: "camera work mode video alt",
                    command: nextDumlPacket(
                        routing: routing,
                        commandSet: 0x02,
                        commandID: 0x10,
                        payload: Data([0x00])
                    )
                ),
                DJICommandPacket(
                    label: "camera set mode video",
                    command: nextDumlPacket(
                        routing: routing,
                        commandSet: 0x02,
                        commandID: 0x1C,
                        payload: Data([0x00])
                    )
                ),
                DJICommandPacket(
                    label: "camera set mode record",
                    command: nextDumlPacket(
                        routing: routing,
                        commandSet: 0x02,
                        commandID: 0x1C,
                        payload: Data([0x01])
                    )
                )
            ])
        }

        return packets
    }

    var shouldSendDirectCameraRecordOnly: Bool {
        cameraBehavior.kind == .djiOsmoAction6
    }

    var shouldSendShutterControlPacket: Bool {
        cameraBehavior.kind == .djiOsmoAction6
            || cameraBehavior.kind == .djiOsmoPocket3
    }

    var shouldUseNanoStopFallbacks: Bool {
        cameraBehavior.kind == .djiOsmoNano
    }

    var shouldUsePocket3RecordFallbacks: Bool {
        // Pocket 3 is recognized at the app layer but intentionally unsupported:
        // local testing found status traffic, not a working BLE-only record path.
        false
    }

    var stopCommandBurstCount: Int {
        shouldUseNanoStopFallbacks ? 3 : 2
    }

    var shouldUseExpandedActionWriteTargets: Bool {
        cameraModel == .djiOsmoAction6
            || normalizedCameraName.contains("action")
            || normalizedCameraName.contains("oa6")
            || normalizedCameraName.contains("osmoaction")
    }

    var shouldUseActionVideoModeFallbacks: Bool {
        cameraBehavior.kind == .djiOsmoAction6
    }

    var normalizedCameraName: String {
        cameraName.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    var recordCommandRoutings: [DJIDUMLRouting] {
        guard shouldUsePocket3RecordFallbacks else { return [dumlRouting] }
        return [
            dumlRouting,
            .default,
            DJIDUMLRouting(appAddress: 0x02, cameraAddress: 0x05)
        ].uniqued()
    }

    var writeTargetSummary: String {
        guard !writeCandidates.isEmpty else { return "none" }
        return writeCandidates
            .map(\.diagnosticLabel)
            .joined(separator: ", ")
    }

    var selectedWriteTargetSummary: String {
        let targets = writeTargets
        guard !targets.isEmpty else { return "none" }
        return targets
            .map(\.diagnosticLabel)
            .joined(separator: ", ")
    }

    var cameraBehavior: CameraBehaviorProfile {
        CameraBehaviorProfile.resolve(brand: .dji, model: cameraModel, name: cameraName)
    }

    func pocket3CommandDiagnosticSuffix() -> String {
        guard shouldUsePocket3RecordFallbacks else { return "" }
        return " Pocket 3 selected targets: \(selectedWriteTargetSummary). All write candidates: \(writeTargetSummary)."
    }

    func shouldDiscoverDescriptors(for characteristic: CBCharacteristic, in service: CBService) -> Bool {
        guard shouldUsePocket3RecordFallbacks else { return false }

        let serviceID = service.uuid.uuidString.uppercased()
        let characteristicID = characteristic.uuid.uuidString.uppercased()

        return serviceID == "FFF0"
            || serviceID == "1812"
            || characteristicID == "2A4B"
            || characteristicID == "2A4D"
            || characteristicID == "2A4E"
            || characteristicID == "2A4F"
    }

    func descriptorValueLabel(_ value: Any?) -> String {
        switch value {
        case let data as Data:
            data.isEmpty ? "empty data" : data.hexString
        case let string as String:
            "\"\(string)\""
        case let number as NSNumber:
            number.stringValue
        case let uuid as CBUUID:
            uuid.uuidString
        case .none:
            "nil"
        case let value?:
            String(describing: value)
        }
    }

    static func defaultDumlRouting(cameraModel: CameraModel, cameraName: String) -> DJIDUMLRouting {
        let profile = CameraBehaviorProfile.resolve(
            brand: .dji,
            model: cameraModel,
            name: cameraName
        )

        if profile.kind == .djiOsmoAction6 {
            return DJIDUMLRouting(appAddress: 0x25, cameraAddress: 0x01)
        }

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
                onCameraStatus(cameraID, cameraStatusUpdate(from: state))
                return state.debugLabel
            }

            if let shortState = DJIAction6ShortState(payload: statusPayload),
               cameraBehavior.kind == .djiOsmoAction6 {
                onCameraStatus(
                    cameraID,
                    CameraStatusUpdate(
                        recordingState: shortState.recordingState,
                        canClearActiveRecording: true
                    )
                )
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
              packet.isCameraStatePush,
              let state = DJICameraStateSummary(payload: packet.payload) else {
            return
        }

        let now = Date()
        if state.debugLabel != lastCameraStateSummaryLabel
            || now.timeIntervalSince(lastCameraStateSummaryLogDate) >= 5 {
            onLog("\(cameraName): DJI camera state push (\(state.debugLabel)).")
            lastCameraStateSummaryLabel = state.debugLabel
            lastCameraStateSummaryLogDate = now
        }

        onCameraStatus(cameraID, cameraStatusUpdate(from: state))
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

    var debugLabel: String {
        let sdCardBits = (flags & 0x3C00) >> 10
        switch format {
        case .full:
            return "mode \(DJIExperimentalBLEClient.cameraStateModeLabel(mode)), recordBits \(recordBits), sdBits \(sdCardBits), remainingTime \(remainedTime)s, videoRecordTime \(videoRecordTime)s, sdFree \(sdCardFreeSize)/\(sdCardTotalSize), cameraType 0x\(cameraType.hexByte), version \(version), flags 0x\(flags.hexWord)"
        case .compact:
            let battery = batteryPercent.map(String.init) ?? "unknown"
            return "compact mode byte \(DJIExperimentalBLEClient.cameraStateModeLabel(mode)), recordBits \(recordBits), videoRecordTime \(videoRecordTime)s, remainingTime \(remainedTime)s, battery \(battery), flags 0x\(flags.hexWord)"
        }
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

private struct DJIWritableCharacteristic: Comparable {
    var serviceUUID: CBUUID
    var characteristic: CBCharacteristic

    var debugLabel: String {
        "\(serviceUUID.uuidString) / \(characteristic.uuid.uuidString)"
    }

    var diagnosticLabel: String {
        let writeTypeLabel = writeTypes(expanded: true)
            .map(\.logLabel)
            .joined(separator: "/")
        let propertyLabel = characteristic.properties.debugLabels.joined(separator: "/")
        return "\(debugLabel) [\(propertyLabel); \(writeTypeLabel.isEmpty ? "no write type" : writeTypeLabel)]"
    }

    var isStandardBLETarget: Bool {
        DJIStandardBLEUUIDs.contains(serviceUUID.uuidString.uppercased())
            || DJIStandardBLEUUIDs.contains(characteristic.uuid.uuidString.uppercased())
    }

    var isClearlyGenericBLETarget: Bool {
        DJIClearlyGenericBLEUUIDs.contains(serviceUUID.uuidString.uppercased())
            || DJIClearlyGenericBLEUUIDs.contains(characteristic.uuid.uuidString.uppercased())
    }

    var isPocket3CommandTarget: Bool {
        serviceUUID.uuidString.uppercased() == "FFF0"
    }

    func writeTypes(expanded: Bool) -> [CBCharacteristicWriteType] {
        let canWriteWithResponse = characteristic.properties.contains(.write)
        let canWriteWithoutResponse = characteristic.properties.contains(.writeWithoutResponse)

        if expanded, canWriteWithResponse, canWriteWithoutResponse {
            return [.withResponse, .withoutResponse]
        }

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
