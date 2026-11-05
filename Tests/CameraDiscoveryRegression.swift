import CoreBluetooth
import Foundation

private final class ManagedClient: NSObject, BLECameraDeviceClient {
    let cameraID = UUID()
    let cameraName = "SDK camera"
    var managesOwnConnection: Bool { true }
    var disconnects = 0
    func didConnect() {}
    func didDisconnect(error: Error?) { disconnects += 1 }
    func disconnectManagedConnection() { disconnects += 1 }
    func send(_ command: CameraCommand) -> CameraCommandResult { result(for: command, status: .sent, message: "") }
}

@main
enum CameraDiscoveryRegression {
    static func main() {
        var first = DiscoveredCamera(id: UUID(), name: "Front", brand: .gopro, model: .goproHero13Black,
            rssi: -50, capabilities: [.record], connectionState: .connected, recordingState: .recording,
            isPaired: true, isSelected: true, lastSeen: Date())
        var second = DiscoveredCamera(id: UUID(), name: "Rear", brand: .gopro, model: .goproHero13Black,
            rssi: -50, capabilities: [.record], connectionState: .connected, recordingState: .recording,
            isPaired: true, isSelected: true, lastSeen: Date())
        func paused(pairing: Bool = false, pending: Bool = false) -> Bool {
            CameraDiscoveryPolicy.shouldPause(cameras: [first, second],
                pairingRequested: pairing, hasPendingCommands: pending)
        }
        precondition(paused())
        precondition(!paused(pairing: true) && !paused(pending: true))
        second.connectionState = .disconnected
        precondition(!paused(), "A dropped camera must permit discovery while another records")
        second.connectionState = .reconnecting
        precondition(!paused())
        second.connectionState = .connected
        second.recordingState = .starting
        precondition(!paused())
        second.recordingState = .stopped
        precondition(paused())
        second.model = .djiOsmoNano
        second.brand = .dji
        precondition(!paused(), "Nano sleep advertisements must remain available")
        second.model = .goproHero13Black
        first.recordingState = .stopped
        precondition(!paused())
        precondition(!CameraDiscoveryPolicy.shouldPause(cameras: [], pairingRequested: false, hasPendingCommands: false))

        let scanner = BLECameraScanner()
        scanner.setDiscoveryPaused(true)
        precondition(CBCentralManager.instances.isEmpty, "Pausing unused discovery must not initialize Bluetooth")
        scanner.start()
        precondition(scanner.isScanningRequested && CBCentralManager.instances.isEmpty)
        scanner.setDiscoveryPaused(false)
        let central = CBCentralManager.instances.last!
        precondition(central.scanCount == 1)
        let client = ManagedClient()
        scanner.connectManaged(client: client)
        scanner.setDiscoveryPaused(true)
        precondition(central.stopCount == 1 && client.disconnects == 0 && central.disconnectCount == 0)
        scanner.centralManagerDidUpdateState(central)
        precondition(central.scanCount == 1, "Bluetooth state callbacks cannot restart paused discovery")
        var discoveries = 0
        scanner.onEvent = { if case .discovered = $0 { discoveries += 1 } }
        let peripheral = CBPeripheral()
        let advertisement: [String: Any] = [CBAdvertisementDataLocalNameKey: "GoPro HERO13 Black"]
        scanner.centralManager(central, didDiscover: peripheral, advertisementData: advertisement, rssi: -50)
        precondition(discoveries == 0, "Queued advertisements must be ignored during the pause")
        scanner.setDiscoveryPaused(false)
        precondition(central.scanCount == 2)
        scanner.centralManager(central, didDiscover: peripheral, advertisementData: advertisement, rssi: -50)
        precondition(discoveries == 1)
        scanner.setDiscoveryPaused(true)
        scanner.stop()
        scanner.setDiscoveryPaused(false)
        precondition(!scanner.isScanningRequested && central.scanCount == 2,
            "An explicit Stop Scan during the pause must survive resumption")
        precondition(client.disconnects == 0)
        print("Discovery checks passed: recording, reconnect, pairing, Nano sleep, scan intent and managed connections.")
    }
}
