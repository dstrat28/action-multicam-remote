import CoreBluetooth
import CoreLocation
import Foundation

enum Insta360RemoteEvent {
    case bluetoothStateChanged(CBManagerState)
    case cameraSessionActive(UUID)
    case cameraConnected(UUID)
    case cameraDisconnected(UUID)
    case cameraStatus(UUID, CameraStatusUpdate)
    case commandCompleted(CameraCommandResult)
    case log(String)
}

final class Insta360RemoteService: NSObject {
    private struct WakeRequest {
        var cameraID: UUID
        var cameraName: String
        var beaconUUID: UUID
    }

    private static let serviceUUID = CBUUID(string: "CE80")
    private static let writeCharacteristicUUID = CBUUID(string: "CE81")
    private static let notifyCharacteristicUUID = CBUUID(string: "CE82")
    private static let infoCharacteristicUUID = CBUUID(string: "CE83")
    // The X3/RS reference remote exposes this companion GATT service as well
    // as CE80. Add it only for X3 requests; other models keep their profile.
    // Values are little-endian, matching pchwalek/insta360_ble_esp32.
    private static let companionServiceUUID = CBUUID(string: "0000D0FF-3C17-D293-8E48-14FE2E4DA212")
    private static let companionReadValues: [CBUUID: Data] = [
        CBUUID(string: "FFD2"): Data(),
        CBUUID(string: "FFD3"): Data([0x01, 0x90, 0x1E, 0x30]),
        CBUUID(string: "FFD4"): Data([0x01, 0x20, 0x00, 0x18]),
        CBUUID(string: "FFD5"): Data(),
        CBUUID(string: "FFF1"): Data(),
        CBUUID(string: "FFE0"): Data()
    ]
    private static let companionWriteUUIDs: Set<CBUUID> = ["FFD1", "FFD8", "FFF2"].reduce(into: []) {
        $0.insert(CBUUID(string: $1))
    }
    private static let restoreIdentifier = "com.ds.ActionCamRemote.insta360-gps-remote"

    private lazy var peripheralManager = CBPeripheralManager(
        delegate: self,
        queue: nil,
        options: [CBPeripheralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
    )
    private var writeCharacteristic: CBMutableCharacteristic?
    private var notifyCharacteristic: CBMutableCharacteristic?
    private var infoCharacteristic: CBMutableCharacteristic?
    private var requestedCameraIDs: [UUID] = []
    private var cameraNamesByID: [UUID: String] = [:]
    private var centralByCameraID: [UUID: CBCentral] = [:]
    private var cameraIDByCentralID: [UUID: UUID] = [:]
    private var assignmentMatchByCentralID: [UUID: Insta360RemoteAssignmentMatch] = [:]
    private var cameraIdentifierByCentralID: [UUID: Data] = [:]
    private var restoredCentralsByID: [UUID: CBCentral] = [:]
    private var subscribedCentralIDs: Set<UUID> = []
    private var lastActivityByCentralID: [UUID: Date] = [:]
    private var lastLoggedWriteByCentralID: [UUID: [Data: Date]] = [:]
    private var reportedActiveCameraIDs: Set<UUID> = []
    private var recordingStatusByCameraID: [UUID: Insta360RemoteRecordingStatus] = [:]
    private var sessionIDByCameraID: [UUID: UUID] = [:]
    private var buttonSequenceByCameraID: [UUID: Insta360RemoteButtonSequence] = [:]
    private var pendingCommands = Insta360RemoteCommandQueue()
    private var statusTimer: Timer?
    private var wakeTimer: Timer?
    private var pendingWake: WakeRequest?
    private var activeWake: WakeRequest?
    private var isServicePublished = false
    private var isCompanionServicePublished = false
    private var publishingServices: [CBUUID: CBMutableService] = [:]
    private var needsServiceRepublish = false
    private var shouldReplaceRestoredWakeAdvertisement = false

    var onEvent: ((Insta360RemoteEvent) -> Void)?

    override init() {
        super.init()
    }

    deinit {
        statusTimer?.invalidate()
        wakeTimer?.invalidate()
    }

    var bluetoothState: CBManagerState {
        peripheralManager.state
    }

    func requestConnection(cameraID: UUID, cameraName: String) {
        cameraNamesByID[cameraID] = cameraName
        if !requestedCameraIDs.contains(cameraID) {
            requestedCameraIDs.append(cameraID)
        }
        reconcileRestoredSubscriptions()
        if let central = centralByCameraID[cameraID],
           subscribedCentralIDs.contains(central.identifier) {
            if sessionIDByCameraID[cameraID] == nil {
                beginCommandSession(for: cameraID)
            }
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
        clearCommandSession(for: cameraID)
        if pendingWake?.cameraID == cameraID || activeWake?.cameraID == cameraID {
            cancelWakeAndResumeRemoteAdvertising()
        }
        onEvent?(.cameraDisconnected(cameraID))

        // CBPeripheralManager cannot explicitly cancel a central's connection. Keep the
        // assignment so a user-initiated reconnect can immediately reuse a camera that
        // is still subscribed, and clear it when didUnsubscribeFrom arrives.
        if requestedCameraIDs.isEmpty {
            peripheralManager.stopAdvertising()
        }
    }

    @discardableResult
    func wake(cameraID: UUID, cameraName: String) -> Bool {
        guard let beaconUUID = Insta360RemoteProtocol.wakeBeaconUUID(from: cameraName) else {
            onEvent?(.log(
                "\(cameraName): cannot build an Insta360 wake advertisement without a six-character camera identifier."
            ))
            return false
        }

        cameraNamesByID[cameraID] = cameraName
        if !requestedCameraIDs.contains(cameraID) {
            requestedCameraIDs.append(cameraID)
        }
        pendingWake = WakeRequest(cameraID: cameraID, cameraName: cameraName, beaconUUID: beaconUUID)
        publishAndAdvertiseIfPossible()
        beginPendingWakeIfPossible()
        return true
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
            assignmentMatchByCentralID.removeValue(forKey: central.identifier)
            cameraIdentifierByCentralID.removeValue(forKey: central.identifier)
            lastActivityByCentralID.removeValue(forKey: central.identifier)
            lastLoggedWriteByCentralID.removeValue(forKey: central.identifier)
            reportedActiveCameraIDs.remove(cameraID)
            clearCommandSession(for: cameraID)
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
        expireRecordingTimers()
        guard let central = centralByCameraID[cameraID],
              requestedCameraIDs.contains(cameraID),
              sessionIDByCameraID[cameraID] != nil,
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
            message = "Sent the Insta360 shutter toggle. Valid camera timer packets indicate recording; silence leaves status unknown."
        case .cycleMode:
            packet = Insta360RemoteProtocol.cycleModeCommand
            message = "Sent the Insta360 remote mode-cycle command."
        case .setMode, .loadGoProPreset:
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

        // Keep the latest intent even when no packet is needed for it.
        for pending in pendingCommands.remove(for: cameraID) {
            completeQueuedCommand(pending, status: .skipped, message: "A newer Insta360 command replaced the queued command.")
        }
        if let reason = recordingStatusByCameraID[cameraID]?.rejectionReason(for: command) {
            return result(cameraID: cameraID, cameraName: cameraName, command: command, status: .skipped, message: reason)
        }

        onEvent?(.log("\(cameraName): requesting \(command.label) on subscribed CE82."))
        let result = enqueueOrSend(
            packet,
            command: command,
            cameraID: cameraID,
            cameraName: cameraName,
            message: message
        )

        if command == .cycleMode {
            onEvent?(.cameraStatus(cameraID, CameraStatusUpdate(currentMode: nil)))
        }

        return result
    }
}

extension Insta360RemoteService: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        onEvent?(.bluetoothStateChanged(peripheral.state))

        switch peripheral.state {
        case .poweredOn:
            if needsServiceRepublish {
                peripheral.removeAllServices()
                isServicePublished = false
                writeCharacteristic = nil
                notifyCharacteristic = nil
                infoCharacteristic = nil
                isCompanionServicePublished = false
                publishingServices.removeAll()
                needsServiceRepublish = false
            }
            if shouldReplaceRestoredWakeAdvertisement {
                peripheral.stopAdvertising()
                shouldReplaceRestoredWakeAdvertisement = false
                onEvent?(.log(
                    "Discarded an interrupted Insta360 wake advertisement; resuming the connectable GPS Remote service."
                ))
            }
            publishAndAdvertiseIfPossible()
            beginPendingWakeIfPossible()
        case .unknown:
            // State restoration is delivered before the first stable manager state.
            // Preserve restored services and subscribers through this transition.
            break
        case .poweredOff:
            if !publishingServices.isEmpty {
                // An interrupted add may never complete. Bluetooth is already
                // disconnected, so rebuild this partial database on power-on.
                needsServiceRepublish = true
                publishingServices.removeAll()
            }
            clearActiveSessions(clearPublishedService: false)
        case .resetting, .unsupported, .unauthorized:
            clearActiveSessions(clearPublishedService: true)
        @unknown default:
            clearActiveSessions(clearPublishedService: true)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let restoredServices = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        guard let service = restoredServices.first(where: { $0.uuid == Self.serviceUUID }) else {
            onEvent?(.log("Insta360 state restoration contained no CE80 GPS Remote service; it will be republished."))
            return
        }

        let characteristics = service.characteristics?.compactMap { $0 as? CBMutableCharacteristic } ?? []
        writeCharacteristic = characteristics.first(where: { $0.uuid == Self.writeCharacteristicUUID })
        notifyCharacteristic = characteristics.first(where: { $0.uuid == Self.notifyCharacteristicUUID })
        infoCharacteristic = characteristics.first(where: { $0.uuid == Self.infoCharacteristicUUID })
        guard writeCharacteristic != nil,
              let notifyCharacteristic,
              notifyCharacteristic.properties == [.notify],
              infoCharacteristic != nil else {
            isServicePublished = false
            needsServiceRepublish = true
            onEvent?(.log("Insta360 restored an outdated CE80 service; CE81, CE82, and CE83 will be republished."))
            return
        }
        isServicePublished = true
        needsServiceRepublish = false
        isCompanionServicePublished = restoredServices.contains { service in
            guard service.uuid == Self.companionServiceUUID else { return false }
            let characteristics = service.characteristics ?? []
            return Self.companionReadValues.keys.allSatisfy { uuid in
                characteristics.contains { $0.uuid == uuid && $0.properties.contains(.read) }
            } && Self.companionWriteUUIDs.allSatisfy { uuid in
                characteristics.contains { $0.uuid == uuid && $0.properties.contains(.write) }
            }
        }

        let restoredCentrals = notifyCharacteristic.subscribedCentrals ?? []
        let restoredAdvertisement = dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] as? [String: Any]
        let restoredAdvertising = restoredAdvertisement != nil
        shouldReplaceRestoredWakeAdvertisement = restoredAdvertisement?[CBAdvertisementDataManufacturerDataKey] != nil
        onEvent?(.log(
            "Restored Insta360 CE80 service with \(restoredCentrals.count) CE82 subscriber(s)"
                + (restoredAdvertising ? " and active advertisement data." : ".")
        ))

        let now = Date()
        for central in restoredCentrals {
            restoredCentralsByID[central.identifier] = central
            subscribedCentralIDs.insert(central.identifier)
            lastActivityByCentralID[central.identifier] = now
            onEvent?(.log("Restored Insta360 peer \(peerLabel(central.identifier)) CE82 subscription."))
        }
        reconcileRestoredSubscriptions()
        if !restoredCentrals.isEmpty {
            startStatusTimerIfNeeded()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard service.uuid == Self.serviceUUID || service.uuid == Self.companionServiceUUID else { return }
        guard let pendingService = publishingServices[service.uuid], pendingService === service else { return }
        publishingServices.removeValue(forKey: service.uuid)
        if let error {
            onEvent?(.log("Insta360 remote service \(service.uuid.uuidString) could not be published: \(error.localizedDescription)"))
            return
        }
        if service.uuid == Self.serviceUUID { isServicePublished = true }
        if service.uuid == Self.companionServiceUUID { isCompanionServicePublished = true }
        onEvent?(.log("Insta360 GPS Remote service \(service.uuid.uuidString) published."))
        if pendingWake != nil {
            beginPendingWakeIfPossible()
        } else {
            startAdvertising()
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let wake = activeWake {
            if let error {
                onEvent?(.log(
                    "\(wake.cameraName): experimental Insta360 wake advertising failed: \(error.localizedDescription)"
                ))
                cancelWakeAndResumeRemoteAdvertising()
            } else {
                onEvent?(.log(
                    "\(wake.cameraName): broadcasting the experimental targeted Insta360 wake advertisement."
                ))
            }
            return
        }

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
        subscribedCentralIDs.insert(central.identifier)
        lastActivityByCentralID[central.identifier] = Date()
        guard let cameraID = assignCameraIfNeeded(central, interaction: "CE82 notification subscription") else { return }
        beginCommandSession(for: cameraID)
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
        restoredCentralsByID.removeValue(forKey: central.identifier)
        subscribedCentralIDs.remove(central.identifier)
        lastActivityByCentralID.removeValue(forKey: central.identifier)
        lastLoggedWriteByCentralID.removeValue(forKey: central.identifier)
        cameraIdentifierByCentralID.removeValue(forKey: central.identifier)
        guard let cameraID = cameraIDByCentralID.removeValue(forKey: central.identifier) else {
            onEvent?(.log("Insta360 peer \(peer) was not assigned when it unsubscribed."))
            return
        }
        assignmentMatchByCentralID.removeValue(forKey: central.identifier)

        reportedActiveCameraIDs.remove(cameraID)
        centralByCameraID.removeValue(forKey: cameraID)
        clearCommandSession(for: cameraID)
        onEvent?(.cameraDisconnected(cameraID))
        startAdvertising()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let peer = peerLabel(request.central.identifier)
        let value: Data?
        if request.characteristic.uuid == Self.infoCharacteristicUUID {
            value = Data([0x01, 0x02])
        } else if isCompanionServicePublished,
                  request.characteristic.service?.uuid == Self.companionServiceUUID {
            value = Self.companionReadValues[request.characteristic.uuid]
        } else {
            value = nil
        }
        guard let value else {
            onEvent?(.log(
                "Insta360 peer \(peer) requested unsupported read \(request.characteristic.uuid.uuidString)."
            ))
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        onEvent?(.log("Insta360 peer \(peer) read \(request.characteristic.uuid.uuidString) at offset \(request.offset)."))
        guard request.offset >= 0, request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        if request.characteristic.uuid == Self.infoCharacteristicUUID,
           let cameraID = assignCameraIfNeeded(request.central, interaction: "CE83 read") {
            noteSessionActivity(for: request.central, cameraID: cameraID)
        }
        request.value = Data(value.dropFirst(request.offset))
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let firstRequest = requests.first else { return }
        // CoreBluetooth delivers an ATT write transaction as a batch. Validate
        // the entire transaction before changing any camera/session state, then
        // acknowledge it exactly once using the first request. The camera's
        // CE81 frames require the ATT acknowledgement, not a CE82 auth reply.
        for request in requests {
            let isCommandWrite = request.characteristic.uuid == Self.writeCharacteristicUUID
            let isCompanionWrite = isCompanionServicePublished
                && request.characteristic.service?.uuid == Self.companionServiceUUID
                && Self.companionWriteUUIDs.contains(request.characteristic.uuid)
            guard isCommandWrite || isCompanionWrite, request.value != nil else {
                onEvent?(.log("Insta360 rejected write batch (\(requests.count) requests): unsupported or empty \(request.characteristic.uuid.uuidString)."))
                peripheral.respond(to: firstRequest, withResult: .requestNotSupported)
                return
            }
            guard request.offset == 0 else {
                onEvent?(.log("Insta360 rejected write batch (\(requests.count) requests): invalid offset \(request.offset)."))
                peripheral.respond(to: firstRequest, withResult: .invalidOffset)
                return
            }
        }
        if requests.count > 1 {
            onEvent?(.log("Insta360 accepted ATT write batch with \(requests.count) requests."))
        }
        for request in requests {
            let peer = peerLabel(request.central.identifier)
            let data = request.value!
            guard request.characteristic.uuid == Self.writeCharacteristicUUID else {
                // Match the reference's passive companion write endpoints. No
                // capture commands or firmware update behavior is implemented.
                onEvent?(.log("Insta360 peer \(peer) wrote companion \(request.characteristic.uuid.uuidString) (\(data.count) bytes)."))
                continue
            }

            let now = Date()
            if shouldLogWrite(data, from: request.central, now: now) {
                onEvent?(.log(
                    "Insta360 peer \(peer) wrote CE81 (\(data.count) bytes): \(hexString(data))"
                ))
            }
            let cameraID: UUID?
            if let identifier = Insta360RemoteProtocol.cameraIdentifier(from: data) {
                cameraID = assignCamera(
                    request.central,
                    usingCameraIdentifier: identifier,
                    interaction: "CE81 camera identifier"
                )
            } else {
                cameraID = assignCameraIfNeeded(request.central, interaction: "CE81 write")
            }
            if let cameraID {
                noteSessionActivity(for: request.central, cameraID: cameraID, now: now)
                handleStatusPacket(data, from: cameraID)
            }
        }
        peripheral.respond(to: firstRequest, withResult: .success)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flushPendingUpdates()
    }
}

private extension Insta360RemoteService {
    func reconcileRestoredSubscriptions() {
        let unassignedCentrals = restoredCentralsByID.values.filter {
            cameraIDByCentralID[$0.identifier] == nil
        }
        guard !unassignedCentrals.isEmpty, !requestedCameraIDs.isEmpty else { return }

        let assignments = Insta360RemoteAssignmentStrategy.assignments(
            peerIdentifiers: unassignedCentrals.map(\.identifier),
            requestedCameraIDs: requestedCameraIDs,
            assignedCameraIDs: Set(centralByCameraID.keys)
        )
        for central in unassignedCentrals {
            guard let assignment = assignments[central.identifier] else { continue }
            attach(
                central,
                assignment: assignment,
                interaction: "CoreBluetooth state restoration"
            )
            reportedActiveCameraIDs.remove(assignment.cameraID)
            onEvent?(.cameraConnected(assignment.cameraID))
        }
    }

    func assignCameraIfNeeded(_ central: CBCentral, interaction: String) -> UUID? {
        if let existing = cameraIDByCentralID[central.identifier] {
            return existing
        }

        if let identifier = cameraIdentifierByCentralID[central.identifier] {
            return assignCamera(
                central,
                usingCameraIdentifier: identifier,
                interaction: interaction
            )
        }

        if requestedCameraIDs.contains(central.identifier) {
            if let assignedCentral = centralByCameraID[central.identifier],
               assignedCentral.identifier != central.identifier {
                let existingMatch = assignmentMatchByCentralID[assignedCentral.identifier]
                    ?? .requestOrderFallback
                guard Insta360RemoteAssignmentMatch.exactPeerIdentifier.authorityRank
                    > existingMatch.authorityRank else {
                    return nil
                }
                displace(
                    assignedCentral,
                    from: central.identifier,
                    replacementIsSubscribed: subscribedCentralIDs.contains(central.identifier),
                    reason: "an exact peer identifier became available"
                )
            }
            let assignment = Insta360RemoteAssignment(
                cameraID: central.identifier,
                match: .exactPeerIdentifier
            )
            attach(central, assignment: assignment, interaction: interaction)
            return assignment.cameraID
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

        attach(central, assignment: assignment, interaction: interaction)
        return assignment.cameraID
    }

    func assignCamera(
        _ central: CBCentral,
        usingCameraIdentifier identifier: Data,
        interaction: String
    ) -> UUID? {
        cameraIdentifierByCentralID[central.identifier] = identifier
        let identifierLabel = String(data: identifier, encoding: .ascii) ?? hexString(identifier)
        guard let cameraID = Insta360RemoteAssignmentStrategy.cameraID(
            matching: identifier,
            cameraNamesByID: cameraNamesByID,
            requestedCameraIDs: requestedCameraIDs
        ) else {
            let peer = peerLabel(central.identifier)
            onEvent?(.log(
                "Insta360 peer \(peer) identified itself as \(identifierLabel), which is not a requested camera."
            ))
            if let existingMatch = assignmentMatchByCentralID[central.identifier],
               existingMatch.authorityRank < Insta360RemoteAssignmentMatch.cameraSerialIdentifier.authorityRank,
               let fallbackCameraID = cameraIDByCentralID[central.identifier] {
                unassign(
                    central,
                    from: fallbackCameraID,
                    notifyDisconnected: true,
                    reason: "camera identifier \(identifierLabel) did not match the \(existingMatch.rawValue) assignment"
                )
            }
            return nil
        }

        let previousCameraID = cameraIDByCentralID[central.identifier]
        let previousMatch = assignmentMatchByCentralID[central.identifier]
        if previousCameraID == cameraID {
            if previousMatch != .cameraSerialIdentifier {
                assignmentMatchByCentralID[central.identifier] = .cameraSerialIdentifier
                let name = cameraNamesByID[cameraID] ?? "Insta360 camera"
                onEvent?(.log(
                    "\(name): confirmed peer \(peerLabel(central.identifier)) using camera identifier \(identifierLabel)."
                ))
            }
            reportConnectedIfSubscribed(cameraID, central: central)
            return cameraID
        }

        if let previousCameraID {
            unassign(
                central,
                from: previousCameraID,
                notifyDisconnected: true,
                reason: "camera identifier \(identifierLabel) superseded \(previousMatch?.rawValue ?? "an earlier assignment")"
            )
        }

        if let assignedCentral = centralByCameraID[cameraID],
           assignedCentral.identifier != central.identifier {
            displace(
                assignedCentral,
                from: cameraID,
                replacementIsSubscribed: subscribedCentralIDs.contains(central.identifier),
                reason: "camera identifier \(identifierLabel) identified peer \(peerLabel(central.identifier))"
            )
        }

        attach(
            central,
            assignment: Insta360RemoteAssignment(
                cameraID: cameraID,
                match: .cameraSerialIdentifier
            ),
            interaction: interaction
        )
        reportConnectedIfSubscribed(cameraID, central: central)
        return cameraID
    }

    func attach(
        _ central: CBCentral,
        assignment: Insta360RemoteAssignment,
        interaction: String
    ) {
        let cameraID = assignment.cameraID
        let peer = peerLabel(central.identifier)
        centralByCameraID[cameraID] = central
        cameraIDByCentralID[central.identifier] = cameraID
        assignmentMatchByCentralID[central.identifier] = assignment.match
        beginCommandSession(for: cameraID)
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
    }

    func displace(
        _ central: CBCentral,
        from cameraID: UUID,
        replacementIsSubscribed: Bool,
        reason: String
    ) {
        unassign(
            central,
            from: cameraID,
            notifyDisconnected: !replacementIsSubscribed,
            reason: reason
        )
    }

    func unassign(
        _ central: CBCentral,
        from cameraID: UUID,
        notifyDisconnected: Bool,
        reason: String
    ) {
        guard cameraIDByCentralID[central.identifier] == cameraID else { return }
        cameraIDByCentralID.removeValue(forKey: central.identifier)
        assignmentMatchByCentralID.removeValue(forKey: central.identifier)
        if centralByCameraID[cameraID]?.identifier == central.identifier {
            centralByCameraID.removeValue(forKey: cameraID)
        }
        reportedActiveCameraIDs.remove(cameraID)
        clearCommandSession(for: cameraID)
        let name = cameraNamesByID[cameraID] ?? "Insta360 camera"
        onEvent?(.log(
            "\(name): released peer \(peerLabel(central.identifier)) because \(reason)."
        ))
        if notifyDisconnected {
            onEvent?(.cameraDisconnected(cameraID))
        }
    }

    func reportConnectedIfSubscribed(_ cameraID: UUID, central: CBCentral) {
        guard subscribedCentralIDs.contains(central.identifier) else { return }
        reportedActiveCameraIDs.remove(cameraID)
        onEvent?(.cameraConnected(cameraID))
    }

    func clearActiveSessions(clearPublishedService: Bool) {
        let connectedCameraIDs = Array(centralByCameraID.keys)
        wakeTimer?.invalidate()
        wakeTimer = nil
        pendingWake = nil
        activeWake = nil
        shouldReplaceRestoredWakeAdvertisement = false
        centralByCameraID.removeAll()
        cameraIDByCentralID.removeAll()
        assignmentMatchByCentralID.removeAll()
        cameraIdentifierByCentralID.removeAll()
        restoredCentralsByID.removeAll()
        subscribedCentralIDs.removeAll()
        lastActivityByCentralID.removeAll()
        lastLoggedWriteByCentralID.removeAll()
        reportedActiveCameraIDs.removeAll()
        recordingStatusByCameraID.removeAll()
        sessionIDByCameraID.removeAll()
        buttonSequenceByCameraID.removeAll()
        for command in pendingCommands.removeAll() {
            completeQueuedCommand(command, status: .skipped, message: "The Insta360 connection ended; the queued command was discarded.")
        }
        connectedCameraIDs.forEach { onEvent?(.cameraDisconnected($0)) }

        guard clearPublishedService else { return }
        isServicePublished = false
        writeCharacteristic = nil
        notifyCharacteristic = nil
        infoCharacteristic = nil
        isCompanionServicePublished = false
        publishingServices.removeAll()
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

    var needsX3CompanionService: Bool {
        requestedCameraIDs.contains {
            Insta360CameraNameClassifier.model(for: cameraNamesByID[$0] ?? "") == .insta360X3
        }
    }

    var servicesReady: Bool {
        isServicePublished && (!needsX3CompanionService || isCompanionServicePublished)
    }

    func publishAndAdvertiseIfPossible() {
        guard peripheralManager.state == .poweredOn, !requestedCameraIDs.isEmpty else { return }

        if servicesReady {
            if pendingWake != nil {
                beginPendingWakeIfPossible()
            } else {
                startAdvertising()
            }
            return
        }

        // A pending add is not a published service. Do not advertise a partial
        // database, or republish CE80 when an X3 joins another remote session.
        peripheralManager.stopAdvertising()
        if !isServicePublished, publishingServices[Self.serviceUUID] == nil {
            publishCommandService()
        }
        if needsX3CompanionService, !isCompanionServicePublished,
           publishingServices[Self.companionServiceUUID] == nil {
            let companion = CBMutableService(type: Self.companionServiceUUID, primary: true)
            companion.characteristics = ["FFD1", "FFD2", "FFD3", "FFD4", "FFD5", "FFD8", "FFF1", "FFF2", "FFE0"].map { name in
                let uuid = CBUUID(string: name)
                let isWrite = Self.companionWriteUUIDs.contains(uuid)
                return CBMutableCharacteristic(type: uuid, properties: isWrite ? [.write] : [.read],
                    value: nil, permissions: isWrite ? [.writeable] : [.readable])
            }
            publishingServices[Self.companionServiceUUID] = companion
            peripheralManager.add(companion)
        }
    }

    func publishCommandService() {
        let write = CBMutableCharacteristic(
            type: Self.writeCharacteristicUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let notify = CBMutableCharacteristic(
            type: Self.notifyCharacteristicUUID,
            properties: [.notify],
            value: nil,
            permissions: []
        )
        let info = CBMutableCharacteristic(
            type: Self.infoCharacteristicUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [write, notify, info]
        writeCharacteristic = write
        notifyCharacteristic = notify
        infoCharacteristic = info
        publishingServices[Self.serviceUUID] = service
        peripheralManager.add(service)
    }

    func startAdvertising() {
        guard peripheralManager.state == .poweredOn,
              servicesReady,
              pendingWake == nil,
              activeWake == nil,
              !requestedCameraIDs.isEmpty else {
            return
        }

        guard !peripheralManager.isAdvertising else { return }
        peripheralManager.startAdvertising([
            CBAdvertisementDataLocalNameKey: Insta360RemoteProtocol.remoteName,
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]
        ])
    }

    func beginPendingWakeIfPossible() {
        guard peripheralManager.state == .poweredOn,
              servicesReady,
              activeWake == nil,
              let wake = pendingWake else {
            return
        }

        let region = CLBeaconRegion(
            uuid: wake.beaconUUID,
            major: 0,
            minor: 0,
            identifier: "com.ds.ActionCamRemote.insta360-wake"
        )
        let advertisement = region.peripheralData(
            withMeasuredPower: NSNumber(value: Insta360RemoteProtocol.wakeMeasuredPower)
        ) as NSDictionary as! [String: Any]

        pendingWake = nil
        activeWake = wake
        wakeTimer?.invalidate()
        peripheralManager.stopAdvertising()
        peripheralManager.startAdvertising(advertisement)
        wakeTimer = Timer.scheduledTimer(
            withTimeInterval: Insta360RemoteProtocol.wakeAdvertisementDuration,
            repeats: false
        ) { [weak self] _ in
            self?.finishWakeAdvertising(for: wake.cameraID)
        }
    }

    func finishWakeAdvertising(for cameraID: UUID) {
        guard activeWake?.cameraID == cameraID else { return }
        let name = activeWake?.cameraName ?? "Insta360 camera"
        wakeTimer?.invalidate()
        wakeTimer = nil
        activeWake = nil
        peripheralManager.stopAdvertising()
        onEvent?(.log(
            "\(name): targeted wake advertisement finished; resuming the connectable GPS Remote service."
        ))
        startAdvertising()
    }

    func cancelWakeAndResumeRemoteAdvertising() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        pendingWake = nil
        let wasAdvertisingWake = activeWake != nil
        activeWake = nil
        if wasAdvertisingWake {
            peripheralManager.stopAdvertising()
        }
        startAdvertising()
    }

    func beginCommandSession(for cameraID: UUID) {
        clearCommandSession(for: cameraID)
        sessionIDByCameraID[cameraID] = UUID()
        buttonSequenceByCameraID[cameraID] = Insta360RemoteButtonSequence()
        recordingStatusByCameraID[cameraID] = Insta360RemoteRecordingStatus()
    }

    func clearCommandSession(for cameraID: UUID) {
        sessionIDByCameraID.removeValue(forKey: cameraID)
        buttonSequenceByCameraID.removeValue(forKey: cameraID)
        recordingStatusByCameraID.removeValue(forKey: cameraID)
        for command in pendingCommands.remove(for: cameraID) {
            completeQueuedCommand(command, status: .skipped, message: "The Insta360 connection changed; the queued command was discarded.")
        }
    }

    func enqueueOrSend(
        _ data: Data,
        command: CameraCommand,
        cameraID: UUID,
        cameraName: String,
        message: String
    ) -> CameraCommandResult {
        var commandResult = result(
            cameraID: cameraID,
            cameraName: cameraName,
            command: command,
            status: .failed,
            message: "The Insta360 remote notification characteristic is not ready."
        )
        guard let notifyCharacteristic,
              let central = centralByCameraID[cameraID],
              let sessionID = sessionIDByCameraID[cameraID],
              subscribedCentralIDs.contains(central.identifier) else {
            return commandResult
        }

        if transmitButton(data, to: cameraID, characteristic: notifyCharacteristic, central: central) {
            noteCommandSent(command, to: cameraID)
            commandResult.status = .sent
            commandResult.message = message
            return commandResult
        }

        commandResult.status = .queued
        commandResult.message = "Insta360 command queued briefly while Bluetooth is busy."
        pendingCommands.enqueue(Insta360RemotePendingCommand(
            data: data,
            result: commandResult,
            peerID: central.identifier,
            sessionID: sessionID,
            recordingRevision: recordingStatusByCameraID[cameraID]?.revision ?? 0,
            enqueuedAt: Date()
        ))
        startStatusTimerIfNeeded()
        return commandResult
    }

    func flushPendingUpdates(now: Date = Date()) {
        expireRecordingTimers(now: now)
        while let update = pendingCommands.first {
            let cameraID = update.result.cameraID
            let central = centralByCameraID[cameraID]
            if let reason = queuedCommandRejectionReason(update, now: now) {
                pendingCommands.removeFirst()
                completeQueuedCommand(update, status: .skipped, message: reason)
                continue
            }
            guard let notifyCharacteristic, let central else {
                pendingCommands.removeFirst()
                completeQueuedCommand(update, status: .failed, message: "The Insta360 command channel is no longer available.")
                continue
            }
            guard transmitButton(update.data, to: cameraID, characteristic: notifyCharacteristic, central: central) else {
                return
            }
            pendingCommands.removeFirst()
            noteCommandSent(update.result.command, to: cameraID)
            completeQueuedCommand(update, status: .sent, message: "Sent the queued Insta360 remote command.")
        }
    }

    func transmitButton(_ template: Data, to cameraID: UUID, characteristic: CBMutableCharacteristic, central: CBCentral) -> Bool {
        var sequence = buttonSequenceByCameraID[cameraID] ?? Insta360RemoteButtonSequence()
        let packet = sequence.packet(template)
        guard peripheralManager.updateValue(packet, for: characteristic, onSubscribedCentrals: [central]) else { return false }
        onEvent?(.log("Insta360 button sent to \(peerLabel(central.identifier)), sequence \(sequence.value): \(hexString(packet))"))
        sequence.didSend()
        buttonSequenceByCameraID[cameraID] = sequence
        return true
    }

    func queuedCommandRejectionReason(_ command: Insta360RemotePendingCommand, now: Date) -> String? {
        let cameraID = command.result.cameraID
        let central = centralByCameraID[cameraID]
        let isSubscribed = central.map { subscribedCentralIDs.contains($0.identifier) } ?? false
        return command.discardReason(
            now: now,
            peerID: isSubscribed ? central?.identifier : nil,
            sessionID: requestedCameraIDs.contains(cameraID) ? sessionIDByCameraID[cameraID] : nil,
            recordingRevision: recordingStatusByCameraID[cameraID]?.revision
        ) ?? recordingStatusByCameraID[cameraID]?.rejectionReason(for: command.result.command)
    }

    func discardInvalidPendingCommands(now: Date) {
        let discarded = pendingCommands.discardInvalid {
            queuedCommandRejectionReason($0, now: now)
        }
        for (command, reason) in discarded {
            completeQueuedCommand(command, status: .skipped, message: reason)
        }
    }

    func noteCommandSent(_ command: CameraCommand, to cameraID: UUID) {
        switch command {
        case .startRecording, .stopRecording, .capturePhoto, .toggleRecording:
            var status = recordingStatusByCameraID[cameraID] ?? Insta360RemoteRecordingStatus()
            status.shutterSent(at: Date())
            recordingStatusByCameraID[cameraID] = status
        case .addHighlight, .setMode, .loadGoProPreset, .cycleMode, .applySetting, .keepAlive:
            break
        }
    }

    func completeQueuedCommand(_ command: Insta360RemotePendingCommand, status: CameraCommandStatus, message: String) {
        var result = command.result
        result.status = status
        result.message = message
        result.timestamp = Date()
        onEvent?(.commandCompleted(result))
        onEvent?(.log("\(result.cameraName): \(message)"))
    }

    func handleStatusPacket(_ data: Data, from cameraID: UUID) {
        guard requestedCameraIDs.contains(cameraID),
              let timer = Insta360RemoteProtocol.recordingTimeLabel(from: data) else { return }

        var status = recordingStatusByCameraID[cameraID] ?? Insta360RemoteRecordingStatus()
        let changed = status.observeTimer(at: Date())
        recordingStatusByCameraID[cameraID] = status
        guard !status.awaitingStopFeedback else { return }
        onEvent?(.cameraStatus(cameraID, CameraStatusUpdate(recordingState: .recording)))
        if changed {
            let name = cameraNamesByID[cameraID] ?? "Insta360 camera"
            onEvent?(.log("\(name): recording timer started at \(timer)."))
        }
    }

    func startStatusTimerIfNeeded() {
        guard statusTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            let now = Date()
            self?.expireRecordingTimers(now: now)
            // Expire unsent toggles even if CoreBluetooth stays busy. Retry
            // transmission only after peripheralManagerIsReady is delivered.
            self?.discardInvalidPendingCommands(now: now)
        }
        statusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func expireRecordingTimers(now: Date = Date()) {
        for cameraID in Array(recordingStatusByCameraID.keys) {
            guard var status = recordingStatusByCameraID[cameraID], status.expire(at: now) else { continue }
            recordingStatusByCameraID[cameraID] = status
            onEvent?(.cameraStatus(cameraID, CameraStatusUpdate(recordingState: .unknown)))
            let name = cameraNamesByID[cameraID] ?? "Insta360 camera"
            onEvent?(.log("\(name): recording feedback expired; recording status is unknown."))
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
