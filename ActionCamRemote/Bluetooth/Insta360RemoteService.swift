import CoreBluetooth
import Foundation

enum Insta360RemoteEvent {
    case bluetoothStateChanged(CBManagerState)
    case cameraSessionActive(UUID)
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
    private var lastActivityByCentralID: [UUID: Date] = [:]
    private var lastLoggedWriteByCentralID: [UUID: [Data: Date]] = [:]
    private var reportedActiveCameraIDs: Set<UUID> = []
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
        if !requestedCameraIDs.contains(cameraID) {
            requestedCameraIDs.append(cameraID)
        }
        if let central = centralByCameraID[cameraID],
           subscribedCentralIDs.contains(central.identifier) {
            onEvent?(.cameraConnected(cameraID))
            return
        }
        if let central = centralByCameraID[cameraID],
           Insta360RemoteSessionPolicy.timeoutDisposition(
               hasAssignedCentral: true,
               isSubscribed: false,
               lastActivity: lastActivityByCentralID[central.identifier],
               now: Date()
           ) == .activeAwaitingCommands {
            reportActiveSessionIfNeeded(cameraID)
            publishAndAdvertiseIfPossible()
            return
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

    func reconcileKnownSessions() {
        for (cameraID, central) in centralByCameraID {
            if subscribedCentralIDs.contains(central.identifier) {
                onEvent?(.cameraConnected(cameraID))
            } else if Insta360RemoteSessionPolicy.timeoutDisposition(
                hasAssignedCentral: true,
                isSubscribed: false,
                lastActivity: lastActivityByCentralID[central.identifier],
                now: Date()
            ) == .activeAwaitingCommands {
                onEvent?(.cameraSessionActive(cameraID))
            }
        }
    }

    func resolveConnectionTimeout(
        cameraID: UUID,
        now: Date = Date()
    ) -> Insta360RemoteSessionTimeoutDisposition {
        let central = centralByCameraID[cameraID]
        let disposition = Insta360RemoteSessionPolicy.timeoutDisposition(
            hasAssignedCentral: central != nil,
            isSubscribed: central.map { subscribedCentralIDs.contains($0.identifier) } ?? false,
            lastActivity: central.flatMap { lastActivityByCentralID[$0.identifier] },
            now: now
        )

        switch disposition {
        case .commandReady:
            onEvent?(.cameraConnected(cameraID))
        case .activeAwaitingCommands:
            reportActiveSessionIfNeeded(cameraID)
            let name = cameraNamesByID[cameraID] ?? "Insta360 camera"
            onEvent?(.log(
                "\(name): GPS Remote session is still active; preserving it while waiting for the CE82 command subscription."
            ))
        case .reset:
            guard let central else { break }
            centralByCameraID.removeValue(forKey: cameraID)
            cameraIDByCentralID.removeValue(forKey: central.identifier)
            lastActivityByCentralID.removeValue(forKey: central.identifier)
            lastLoggedWriteByCentralID.removeValue(forKey: central.identifier)
            reportedActiveCameraIDs.remove(cameraID)
            pendingUpdates.removeAll { $0.cameraID == cameraID }
            let name = cameraNamesByID[cameraID] ?? "Insta360 camera"
            onEvent?(.log(
                "\(name): inactive GPS Remote session for peer \(peerLabel(central.identifier)) reset while continuing to advertise."
            ))
        case .waitingForCamera:
            break
        }

        startAdvertising()
        return disposition
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
            lastActivityByCentralID.removeAll()
            lastLoggedWriteByCentralID.removeAll()
            reportedActiveCameraIDs.removeAll()
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
        onEvent?(.log(
            "Insta360 peer \(peerLabel(central.identifier)) subscribed to CE82 notifications "
                + "(maximum update \(central.maximumUpdateValueLength) bytes)."
        ))
        guard let cameraID = assignCameraIfNeeded(central, interaction: "CE82 notification subscription") else { return }
        subscribedCentralIDs.insert(central.identifier)
        lastActivityByCentralID[central.identifier] = Date()
        reportedActiveCameraIDs.remove(cameraID)
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
        guard characteristic.uuid == Self.notifyCharacteristicUUID else {
            return
        }
        let peer = peerLabel(central.identifier)
        onEvent?(.log("Insta360 peer \(peer) unsubscribed from CE82 notifications."))
        guard let cameraID = cameraIDByCentralID.removeValue(forKey: central.identifier) else {
            onEvent?(.log("Insta360 peer \(peer) was not assigned when it unsubscribed."))
            return
        }

        subscribedCentralIDs.remove(central.identifier)
        lastActivityByCentralID.removeValue(forKey: central.identifier)
        lastLoggedWriteByCentralID.removeValue(forKey: central.identifier)
        reportedActiveCameraIDs.remove(cameraID)
        centralByCameraID.removeValue(forKey: cameraID)
        lastRecordingTimerByCameraID.removeValue(forKey: cameraID)
        pendingUpdates.removeAll { $0.cameraID == cameraID }
        onEvent?(.cameraDisconnected(cameraID))
        startAdvertising()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let peer = peerLabel(request.central.identifier)
        guard request.characteristic.uuid == Self.notifyCharacteristicUUID else {
            onEvent?(.log(
                "Insta360 peer \(peer) requested unsupported read \(request.characteristic.uuid.uuidString)."
            ))
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        onEvent?(.log("Insta360 peer \(peer) read CE82 at offset \(request.offset)."))
        if let cameraID = assignCameraIfNeeded(request.central, interaction: "CE82 read") {
            noteSessionActivity(for: request.central, cameraID: cameraID)
        }
        request.value = Data([0x00])
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let peer = peerLabel(request.central.identifier)
            guard request.characteristic.uuid == Self.writeCharacteristicUUID,
                  let data = request.value else {
                onEvent?(.log(
                    "Insta360 peer \(peer) sent an unsupported or empty write to "
                        + "\(request.characteristic.uuid.uuidString)."
                ))
                peripheral.respond(to: request, withResult: .requestNotSupported)
                continue
            }

            let now = Date()
            if shouldLogWrite(data, from: request.central, now: now) {
                onEvent?(.log(
                    "Insta360 peer \(peer) wrote CE81 (\(data.count) bytes): \(hexString(data))"
                ))
            }
            if let cameraID = assignCameraIfNeeded(request.central, interaction: "CE81 write") {
                noteSessionActivity(for: request.central, cameraID: cameraID, now: now)
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

        let peer = peerLabel(central.identifier)
        guard let assignment = Insta360RemoteAssignmentStrategy.assignment(
            peerIdentifier: central.identifier,
            requestedCameraIDs: requestedCameraIDs,
            assignedCameraIDs: Set(centralByCameraID.keys)
        ) else {
            onEvent?(.log("Unassigned Insta360 peer \(peer) initiated a \(interaction)."))
            return nil
        }

        let cameraID = assignment.cameraID
        centralByCameraID[cameraID] = central
        cameraIDByCentralID[central.identifier] = cameraID
        let name = cameraNamesByID[cameraID] ?? "Insta360 camera"
        onEvent?(.log(
            "\(name): assigned Insta360 peer \(peer) by \(assignment.match.rawValue) during \(interaction)."
        ))
        if assignment.match == .requestOrderFallback {
            onEvent?(.log(
                "\(name): scanned camera identifier did not match peer \(peer); verify camera identity when testing multiple Insta360 cameras."
            ))
        }
        startStatusTimerIfNeeded()
        startAdvertising()
        return cameraID
    }

    func noteSessionActivity(for central: CBCentral, cameraID: UUID, now: Date = Date()) {
        lastActivityByCentralID[central.identifier] = now
        guard !subscribedCentralIDs.contains(central.identifier) else { return }
        reportActiveSessionIfNeeded(cameraID)
    }

    func reportActiveSessionIfNeeded(_ cameraID: UUID) {
        guard reportedActiveCameraIDs.insert(cameraID).inserted else { return }
        let name = cameraNamesByID[cameraID] ?? "Insta360 camera"
        onEvent?(.log("\(name): camera link is active; waiting for the CE82 command subscription."))
        onEvent?(.cameraSessionActive(cameraID))
    }

    func shouldLogWrite(_ data: Data, from central: CBCentral, now: Date) -> Bool {
        var loggedWrites = lastLoggedWriteByCentralID[central.identifier] ?? [:]
        let shouldLog = Insta360RemoteSessionPolicy.shouldLogPacket(
            lastLoggedAt: loggedWrites[data],
            now: now
        )
        guard shouldLog else { return false }

        loggedWrites[data] = now
        if loggedWrites.count > 32,
           let oldest = loggedWrites.min(by: { $0.value < $1.value })?.key {
            loggedWrites.removeValue(forKey: oldest)
        }
        lastLoggedWriteByCentralID[central.identifier] = loggedWrites
        return true
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

        guard !peripheralManager.isAdvertising else { return }
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

    func peerLabel(_ identifier: UUID) -> String {
        String(identifier.uuidString.prefix(8))
    }

    func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
