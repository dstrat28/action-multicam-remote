import CoreBluetooth
import Foundation

enum Insta360RemoteEvent {
    case bluetoothStateChanged(CBManagerState)
    case cameraConnected(UUID)
    case cameraDisconnected(UUID)
    case cameraStatus(UUID, CameraStatusUpdate)
    case log(String)
}

final class Insta360RemoteService: NSObject {
    private struct PendingUpdate {
        var data: Data
        var cameraID: UUID
    }

    private static let serviceUUID = CBUUID(string: "CE80")
    private static let writeCharacteristicUUID = CBUUID(string: "CE81")
    private static let notifyCharacteristicUUID = CBUUID(string: "CE82")

    private lazy var peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    private var writeCharacteristic: CBMutableCharacteristic?
    private var notifyCharacteristic: CBMutableCharacteristic?
    private var requestedCameraIDs: [UUID] = []
    private var cameraNamesByID: [UUID: String] = [:]
    private var centralByCameraID: [UUID: CBCentral] = [:]
    private var cameraIDByCentralID: [UUID: UUID] = [:]
    private var subscribedCentralIDs: Set<UUID> = []
    private var lastRecordingTimerByCameraID: [UUID: Date] = [:]
    private var pendingUpdates: [PendingUpdate] = []
    private var statusTimer: Timer?
    private var isServicePublished = false

    var onEvent: ((Insta360RemoteEvent) -> Void)?

    override init() {
        super.init()
        _ = peripheralManager
    }

    deinit {
        statusTimer?.invalidate()
    }

    var bluetoothState: CBManagerState {
        peripheralManager.state
    }

    func requestConnection(cameraID: UUID, cameraName: String) {
        cameraNamesByID[cameraID] = cameraName
        if let central = centralByCameraID[cameraID],
           subscribedCentralIDs.contains(central.identifier) {
            onEvent?(.cameraConnected(cameraID))
            return
        }
        if !requestedCameraIDs.contains(cameraID) {
            requestedCameraIDs.append(cameraID)
        }
        publishAndAdvertiseIfPossible()
        onEvent?(.log("\(cameraName): waiting for the camera to connect to the Insta360 GPS Remote service."))
    }

    func release(cameraID: UUID) {
        requestedCameraIDs.removeAll { $0 == cameraID }
        lastRecordingTimerByCameraID.removeValue(forKey: cameraID)
        pendingUpdates.removeAll { $0.cameraID == cameraID }
        onEvent?(.cameraDisconnected(cameraID))

        // CBPeripheralManager cannot explicitly cancel a central's connection. Keep the
        // assignment so a user-initiated reconnect can immediately reuse a camera that
        // is still subscribed, and clear it when didUnsubscribeFrom arrives.
        if requestedCameraIDs.isEmpty {
            peripheralManager.stopAdvertising()
        }
    }

    func resetIncompleteSession(cameraID: UUID) {
        guard let central = centralByCameraID[cameraID],
              !subscribedCentralIDs.contains(central.identifier) else {
            return
        }

        centralByCameraID.removeValue(forKey: cameraID)
        cameraIDByCentralID.removeValue(forKey: central.identifier)
        pendingUpdates.removeAll { $0.cameraID == cameraID }
        let name = cameraNamesByID[cameraID] ?? "Insta360 camera"
        onEvent?(.log("\(name): incomplete GPS Remote session reset while continuing to advertise."))
        startAdvertising()
    }

    func send(_ command: CameraCommand, to cameraID: UUID, cameraName: String) -> CameraCommandResult {
        guard let central = centralByCameraID[cameraID],
              subscribedCentralIDs.contains(central.identifier) else {
            return result(
                cameraID: cameraID,
                cameraName: cameraName,
                command: command,
                status: .skipped,
                message: "The camera has not subscribed to Insta360 GPS Remote commands yet. Open its Bluetooth Remote menu and reconnect."
            )
        }

        let packet: Data
        let message: String
        switch command {
        case .startRecording, .capturePhoto, .stopRecording, .toggleRecording:
            packet = Insta360RemoteProtocol.shutterCommand
            message = "Sent the Insta360 remote shutter command. Camera timer packets confirm recording state."
        case .cycleMode:
            packet = Insta360RemoteProtocol.cycleModeCommand
            message = "Sent the Insta360 remote mode-cycle command."
        case .setMode:
            return result(
                cameraID: cameraID,
                cameraName: cameraName,
                command: command,
                status: .unsupported,
                message: "Insta360 GPS Remote can only cycle modes; it cannot select a specific capture mode safely."
            )
        case .addHighlight:
            return result(
                cameraID: cameraID,
                cameraName: cameraName,
                command: command,
                status: .unsupported,
                message: "The Insta360 GPS Remote protocol does not expose highlight markers."
            )
        case .applySetting:
            return result(
                cameraID: cameraID,
                cameraName: cameraName,
                command: command,
                status: .unsupported,
                message: "Camera settings are not exposed by the Insta360 GPS Remote protocol."
            )
        case .keepAlive:
            return result(
                cameraID: cameraID,
                cameraName: cameraName,
                command: command,
                status: .sent,
                message: "The subscribed GPS Remote connection does not require an app heartbeat."
            )
        }

        let packetHex = packet.map { String(format: "%02X", $0) }.joined(separator: " ")
        onEvent?(.log("\(cameraName): sending \(command.label) on subscribed CE82: \(packetHex)"))
        let status = enqueueOrSend(packet, to: cameraID)
        if status == .failed {
            return result(
                cameraID: cameraID,
                cameraName: cameraName,
                command: command,
                status: .failed,
                message: "The Insta360 remote notification characteristic is not ready."
            )
        }

        if command == .cycleMode {
            onEvent?(.cameraStatus(cameraID, CameraStatusUpdate(currentMode: nil)))
        }

        return result(
            cameraID: cameraID,
            cameraName: cameraName,
            command: command,
            status: status,
            message: message
        )
    }
}

extension Insta360RemoteService: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        onEvent?(.bluetoothStateChanged(peripheral.state))

        guard peripheral.state == .poweredOn else {
            isServicePublished = false
            writeCharacteristic = nil
            notifyCharacteristic = nil
            let connectedCameraIDs = Array(centralByCameraID.keys)
            centralByCameraID.removeAll()
            cameraIDByCentralID.removeAll()
            subscribedCentralIDs.removeAll()
            connectedCameraIDs.forEach { onEvent?(.cameraDisconnected($0)) }
            return
        }

        publishAndAdvertiseIfPossible()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard service.uuid == Self.serviceUUID else { return }
        if let error {
            isServicePublished = false
            onEvent?(.log("Insta360 remote service could not be published: \(error.localizedDescription)"))
            return
        }
        onEvent?(.log("Insta360 GPS Remote service published."))
        startAdvertising()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            onEvent?(.log("Insta360 GPS Remote advertising failed: \(error.localizedDescription)"))
        } else {
            onEvent?(.log("Insta360 GPS Remote is advertising for a camera connection."))
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == Self.notifyCharacteristicUUID else { return }
        guard let cameraID = assignCameraIfNeeded(central, interaction: "CE82 notification subscription") else { return }
        subscribedCentralIDs.insert(central.identifier)
        let name = cameraNamesByID[cameraID] ?? "Insta360 camera"
        onEvent?(.log("\(name): subscribed to Insta360 GPS Remote notifications."))
        onEvent?(.cameraConnected(cameraID))
        startStatusTimerIfNeeded()
        startAdvertising()
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == Self.notifyCharacteristicUUID,
              let cameraID = cameraIDByCentralID.removeValue(forKey: central.identifier) else {
            return
        }

        subscribedCentralIDs.remove(central.identifier)
        centralByCameraID.removeValue(forKey: cameraID)
        lastRecordingTimerByCameraID.removeValue(forKey: cameraID)
        pendingUpdates.removeAll { $0.cameraID == cameraID }
        onEvent?(.cameraDisconnected(cameraID))
        startAdvertising()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Self.notifyCharacteristicUUID else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        _ = assignCameraIfNeeded(request.central, interaction: "CE82 read")
        request.value = Data([0x00])
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == Self.writeCharacteristicUUID,
                  let data = request.value else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
                continue
            }

            if let cameraID = assignCameraIfNeeded(request.central, interaction: "CE81 write") {
                handleStatusPacket(data, from: cameraID)
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flushPendingUpdates()
    }
}

private extension Insta360RemoteService {
    func assignCameraIfNeeded(_ central: CBCentral, interaction: String) -> UUID? {
        if let existing = cameraIDByCentralID[central.identifier] {
            return existing
        }

        guard let cameraID = requestedCameraIDs.first(where: { centralByCameraID[$0] == nil }) else {
            onEvent?(.log("An unassigned Insta360 camera initiated a \(interaction)."))
            return nil
        }

        centralByCameraID[cameraID] = central
        cameraIDByCentralID[central.identifier] = cameraID
        let name = cameraNamesByID[cameraID] ?? "Insta360 camera"
        onEvent?(.log("\(name): GPS Remote session confirmed by \(interaction)."))
        startStatusTimerIfNeeded()
        startAdvertising()
        return cameraID
    }

    func publishAndAdvertiseIfPossible() {
        guard peripheralManager.state == .poweredOn, !requestedCameraIDs.isEmpty else { return }

        if isServicePublished {
            startAdvertising()
            return
        }

        let write = CBMutableCharacteristic(
            type: Self.writeCharacteristicUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let notify = CBMutableCharacteristic(
            type: Self.notifyCharacteristicUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [write, notify]
        writeCharacteristic = write
        notifyCharacteristic = notify
        isServicePublished = true
        peripheralManager.add(service)
    }

    func startAdvertising() {
        guard peripheralManager.state == .poweredOn,
              isServicePublished,
              !requestedCameraIDs.isEmpty else {
            return
        }

        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
        }
        peripheralManager.startAdvertising([
            CBAdvertisementDataLocalNameKey: Insta360RemoteProtocol.remoteName,
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]
        ])
    }

    func enqueueOrSend(_ data: Data, to cameraID: UUID) -> CameraCommandStatus {
        guard let notifyCharacteristic,
              let central = centralByCameraID[cameraID],
              subscribedCentralIDs.contains(central.identifier) else {
            return .failed
        }

        if peripheralManager.updateValue(data, for: notifyCharacteristic, onSubscribedCentrals: [central]) {
            return .sent
        }

        pendingUpdates.append(PendingUpdate(data: data, cameraID: cameraID))
        return .queued
    }

    func flushPendingUpdates() {
        while let update = pendingUpdates.first,
              let notifyCharacteristic,
              let central = centralByCameraID[update.cameraID],
              subscribedCentralIDs.contains(central.identifier) {
            guard peripheralManager.updateValue(
                update.data,
                for: notifyCharacteristic,
                onSubscribedCentrals: [central]
            ) else {
                return
            }
            pendingUpdates.removeFirst()
        }
    }

    func handleStatusPacket(_ data: Data, from cameraID: UUID) {
        guard Insta360RemoteProtocol.isRecordingTimerPacket(data) else { return }

        let wasRecording = lastRecordingTimerByCameraID[cameraID] != nil
        lastRecordingTimerByCameraID[cameraID] = Date()
        if !wasRecording {
            onEvent?(.cameraStatus(cameraID, CameraStatusUpdate(recordingState: .recording)))
            let name = cameraNamesByID[cameraID] ?? "Insta360 camera"
            if let timer = Insta360RemoteProtocol.recordingTimeLabel(from: data) {
                onEvent?(.log("\(name): recording timer started at \(timer)."))
            }
        }
    }

    func startStatusTimerIfNeeded() {
        guard statusTimer == nil else { return }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.expireRecordingTimers()
        }
    }

    func expireRecordingTimers(now: Date = Date()) {
        let expiredCameraIDs = lastRecordingTimerByCameraID.compactMap { cameraID, lastTimer in
            now.timeIntervalSince(lastTimer) > Insta360RemoteProtocol.recordingStatusTimeout
                ? cameraID
                : nil
        }
        for cameraID in expiredCameraIDs {
            lastRecordingTimerByCameraID.removeValue(forKey: cameraID)
            onEvent?(.cameraStatus(cameraID, CameraStatusUpdate(recordingState: .stopped)))
        }
    }

    func result(
        cameraID: UUID,
        cameraName: String,
        command: CameraCommand,
        status: CameraCommandStatus,
        message: String
    ) -> CameraCommandResult {
        CameraCommandResult(
            cameraID: cameraID,
            cameraName: cameraName,
            command: command,
            status: status,
            message: message,
            timestamp: Date()
        )
    }
}
