import CoreBluetooth
import Foundation

@main
enum Insta360RemoteServiceRegression {
    private static let companionUUID = CBUUID(string: "0000D0FF-3C17-D293-8E48-14FE2E4DA212")

    static func main() {
        let remote = Insta360RemoteService()
        let cameraID = UUID()
        var active: [UUID] = []
        var connected: [UUID] = []
        var statuses: [CameraStatusUpdate] = []
        remote.onEvent = { event in
            switch event {
            case .cameraSessionActive(let id): active.append(id)
            case .cameraConnected(let id): connected.append(id)
            case .cameraStatus(_, let status): statuses.append(status)
            default: break
            }
        }
        remote.requestConnection(cameraID: cameraID, cameraName: "X3 ABC123")
        let manager = CBPeripheralManager.instances.last!
        precondition(manager.services.count == 2 && manager.advertisements.isEmpty)
        let commandService = manager.services.first { $0.uuid == CBUUID(string: "CE80") }!
        let companion = manager.services.first { $0.uuid == companionUUID }!
        precondition(companion.characteristics?.count == 9)
        let write = commandService.characteristics!.first { $0.uuid == CBUUID(string: "CE81") }!
        let notify = commandService.characteristics!.first { $0.uuid == CBUUID(string: "CE82") }!
        precondition(notify.properties == [.notify], "CoreBluetooth owns the CCCD; no indication or encryption requirement")
        remote.peripheralManager(manager, didAdd: commandService, error: nil)
        precondition(manager.advertisements.isEmpty, "Wait for the complete X3 GATT profile")
        remote.requestConnection(cameraID: cameraID, cameraName: "X3 ABC123")
        precondition(manager.services.count == 2, "Repeated Pair must not duplicate pending services")
        remote.peripheralManager(manager, didAdd: companion, error: nil)
        precondition(manager.isAdvertising)
        precondition((manager.advertisements.last?[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) == [CBUUID(string: "CE80")])

        let central = CBCentral()
        let serial = Data([0xFE, 0xEF, 0xFE, 0x07, 0, 6] + Array("ABC123".utf8))
        let timer = Data([0xFC, 0xEF, 0, 0, 0, 0]) + Data("00:00:01".utf8) + Data(repeating: 0, count: 6)
        func request(_ characteristic: CBCharacteristic, _ value: Data?, offset: Int = 0) -> CBATTRequest {
            CBATTRequest(central: central, characteristic: characteristic, offset: offset, value: value)
        }
        let first = request(write, serial)
        let invalid = request(notify, timer)
        remote.peripheralManager(manager, didReceiveWrite: [first, invalid])
        precondition(manager.responses.count == 1 && manager.responses.last!.request === first)
        precondition(manager.responses.last!.result == .requestNotSupported && active.isEmpty && statuses.isEmpty,
                     "A rejected mixed batch must not assign a camera or apply an earlier status")
        let badOffset = request(write, timer, offset: 1)
        remote.peripheralManager(manager, didReceiveWrite: [first, badOffset])
        precondition(manager.responses.count == 2 && manager.responses.last!.result == .invalidOffset && active.isEmpty)
        remote.peripheralManager(manager, didReceiveWrite: [first, request(write, nil)])
        precondition(manager.responses.count == 3 && active.isEmpty)
        remote.peripheralManager(manager, didReceiveWrite: [])
        precondition(manager.responses.count == 3)

        let status = request(write, timer)
        remote.peripheralManager(manager, didReceiveWrite: [first, status])
        precondition(manager.responses.count == 4 && manager.responses.last!.request === first && manager.responses.last!.result == .success)
        precondition(active == [cameraID] && connected.isEmpty)
        precondition(statuses.last?.recordingState == .recording, "Valid writes in a successful batch are all applied")
        precondition(manager.updates.isEmpty, "No speculative CE82 handshake response")
        precondition(remote.send(.toggleRecording, to: cameraID, cameraName: "X3 ABC123").status == .skipped,
                     "CE81 activity alone cannot enable controls")

        let info = commandService.characteristics!.first { $0.uuid == CBUUID(string: "CE83") }!
        let infoRead = request(info, nil)
        remote.peripheralManager(manager, didReceiveRead: infoRead)
        precondition(infoRead.value == Data([1, 2]))
        let ffd3 = companion.characteristics!.first { $0.uuid == CBUUID(string: "FFD3") }!
        let read = request(ffd3, nil, offset: 1)
        remote.peripheralManager(manager, didReceiveRead: read)
        precondition(read.value == Data([0x90, 0x1E, 0x30]))
        remote.peripheralManager(manager, didReceiveRead: request(ffd3, nil, offset: 5))
        precondition(manager.responses.last!.result == .invalidOffset)
        let companionWrite = companion.characteristics!.first { $0.uuid == CBUUID(string: "FFD1") }!
        let before = manager.responses.count
        remote.peripheralManager(manager, didReceiveWrite: [request(write, serial), request(companionWrite, Data([0]))])
        precondition(manager.responses.count == before + 1 && manager.responses.last!.result == .success)

        remote.peripheralManager(manager, central: central, didSubscribeTo: notify)
        precondition(connected == [cameraID])
        manager.acceptsUpdates = false
        precondition(remote.send(.toggleRecording, to: cameraID, cameraName: "X3 ABC123").status == .queued)
        manager.acceptsUpdates = true
        remote.peripheralManagerIsReady(toUpdateSubscribers: manager)
        precondition(manager.updates.count == 1 && manager.updates[0].centrals?.first === central)
        precondition(manager.updates[0].data == Insta360RemoteProtocol.shutterCommand)

        // Other models retain CE80 only. Adding X3 must preserve that CE80 and
        // any existing subscribers rather than replacing their service.
        let other = Insta360RemoteService()
        other.requestConnection(cameraID: UUID(), cameraName: "Ace Pro 2 DEF456")
        let otherManager = CBPeripheralManager.instances.last!
        precondition(otherManager.services.count == 1)
        let existing = otherManager.services[0]
        other.peripheralManager(otherManager, didAdd: existing, error: nil)
        precondition(otherManager.isAdvertising)
        other.requestConnection(cameraID: UUID(), cameraName: "X3 ABC123")
        precondition(otherManager.services.count == 2 && otherManager.services[0] === existing && !otherManager.isAdvertising)

        // Upgrade a restored CE80 database without tearing down CE80. A fully
        // restored profile must not add duplicate services on the next request.
        let restored = Insta360RemoteService()
        _ = restored.bluetoothState
        let restoredManager = CBPeripheralManager.instances.last!
        restored.peripheralManager(restoredManager, willRestoreState: [CBPeripheralManagerRestoredStateServicesKey: [existing]])
        restored.requestConnection(cameraID: UUID(), cameraName: "X3 ABC123")
        precondition(restoredManager.services.count == 1 && restoredManager.services[0].uuid == companionUUID)
        let complete = Insta360RemoteService()
        _ = complete.bluetoothState
        let completeManager = CBPeripheralManager.instances.last!
        complete.peripheralManager(completeManager, willRestoreState: [CBPeripheralManagerRestoredStateServicesKey: [commandService, companion]])
        complete.requestConnection(cameraID: UUID(), cameraName: "X3 ABC123")
        precondition(completeManager.services.isEmpty && completeManager.isAdvertising)

        let retry = Insta360RemoteService()
        retry.requestConnection(cameraID: cameraID, cameraName: "X3 ABC123")
        let retryManager = CBPeripheralManager.instances.last!
        let failedService = retryManager.services[0]
        retry.peripheralManager(retryManager, didAdd: failedService, error: NSError(domain: "Test", code: 1))
        retry.peripheralManager(retryManager, didAdd: retryManager.services[1], error: nil)
        precondition(!retryManager.isAdvertising)
        retry.requestConnection(cameraID: cameraID, cameraName: "X3 ABC123")
        precondition(retryManager.services.count == 3 && retryManager.services.last?.uuid == failedService.uuid)
        retry.peripheralManager(retryManager, didAdd: retryManager.services.last!, error: nil)
        precondition(retryManager.isAdvertising)

        let interrupted = Insta360RemoteService()
        interrupted.requestConnection(cameraID: cameraID, cameraName: "X3 ABC123")
        let interruptedManager = CBPeripheralManager.instances.last!
        let obsoleteServices = interruptedManager.services
        interruptedManager.state = .poweredOff
        interrupted.peripheralManagerDidUpdateState(interruptedManager)
        interruptedManager.state = .poweredOn
        interrupted.peripheralManagerDidUpdateState(interruptedManager)
        precondition(interruptedManager.services.count == 2 && !interruptedManager.isAdvertising)
        for service in obsoleteServices { interrupted.peripheralManager(interruptedManager, didAdd: service, error: nil) }
        precondition(!interruptedManager.isAdvertising, "Late publication callbacks must not revive an obsolete database")
        for service in interruptedManager.services { interrupted.peripheralManager(interruptedManager, didAdd: service, error: nil) }
        precondition(interruptedManager.isAdvertising)
        print("Insta360 remote service regressions passed: atomic ATT batches, X3 companion profile/publication, reads, CE82 readiness and unicast backpressure (CoreBluetooth double).")
    }
}
