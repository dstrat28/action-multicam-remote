import CoreBluetooth
import Foundation
import INSCameraServiceSDK
import UIKit

@main
@MainActor
enum CameraStoreRecordingWorkRegression {
    static func waitUntil(_ message: String, timeout: Duration = .seconds(4), _ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        precondition(predicate(), message)
    }

    static func main() async {
        // Demo initialization gives the real archives in-memory storage. Camera
        // control below uses the real store, scanner and SDK client with doubles.
        let store = CameraStore(demoMode: true)
        store.isDemoMode = false
        let camera = DiscoveredCamera(id: UUID(), name: "X5", brand: .insta360, model: .insta360X5,
            rssi: -50, capabilities: [.record, .mode, .status], connectionState: .discovered,
            recordingState: .unknown, isPaired: true, isSelected: true, lastSeen: Date())
        store.cameras = [camera]
        store.connect(camera)
        await waitUntil("SDK camera must connect") {
            store.cameras[0].connectionState == .connected && store.cameras[0].recordingState == .stopped
        }
        let commands = INSBluetoothManager.instances.last!.commands
        store.startScanning()
        let central = CBCentralManager.instances.last!
        store.startRecording(store.cameras[0])
        await waitUntil("Start must reach the SDK") { commands.starts == 1 }
        commands.status.state = .normalCapture
        await waitUntil("Recording must confirm") { store.cameras[0].recordingState == .recording }
        precondition(!store.isScanning && central.stopCount > 0)

        // Stop on the camera before the store's five-second Start guard ends.
        // An SDK status is published once, so it cannot wait for a later repeat.
        commands.status.state = .notCapture
        await waitUntil("A quick camera-side Stop must settle despite SDK deduplication") {
            store.cameras[0].recordingState == .stopped
        }
        precondition(store.isScanning)

        commands.status.state = .normalCapture
        await waitUntil("Camera-side Start must appear") { store.cameras[0].recordingState == .recording }
        store.stopRecording(store.cameras[0])
        commands.status.state = .notCapture
        await waitUntil("Explicit Stop must confirm") { store.cameras[0].recordingState == .stopped }
        commands.status.state = .normalCapture
        await waitUntil("A quick camera-side Start after Stop must appear") {
            store.cameras[0].recordingState == .recording
        }
        precondition(!store.isScanning)
        store.setPairingModeActive(true)
        precondition(store.isScanning)
        store.setPairingModeActive(false)
        precondition(!store.isScanning)
        let firstWindow = UUID()
        let secondWindow = UUID()
        commands.status.captureTime = 42
        store.setCameraDetailVisible(true, for: camera.id, source: firstWindow)
        store.setCameraDetailVisible(true, for: camera.id, source: secondWindow)
        await waitUntil("Visible details must publish elapsed time") {
            store.cameras[0].telemetry?.recordingElapsedSeconds == 42
        }
        store.setCameraDetailVisible(false, for: camera.id, source: firstWindow)
        precondition(store.cameras[0].telemetry?.recordingElapsedSeconds == 42,
            "Closing or backgrounding one window must preserve another visible window")
        store.setCameraDetailVisible(false, for: camera.id, source: secondWindow)
        await waitUntil("The last hidden detail must suppress elapsed time") {
            store.cameras[0].telemetry?.recordingElapsedSeconds == nil
        }
        let resultsBeforeRejectedStart = store.commandResults.count
        let dispatchedStarts = commands.starts
        store.startRecording(store.cameras[0])
        await waitUntil("The SDK must reject Start while already recording") {
            store.commandResults.count > resultsBeforeRejectedStart && store.commandResults.first?.status == .skipped
        }
        await waitUntil("A rejected command must restore unchanged SDK status") {
            store.cameras[0].recordingState == .recording
        }
        precondition(commands.starts == dispatchedStarts, "Rejected Start must not reach the camera")
        store.disconnect(store.cameras[0])
        await waitUntil("Disconnect must permit discovery again") { store.isScanning }
        await checkPreservedSDKModes(store)
        await checkInsta360DiscoveryRecovery(name: "X3 ABC123", model: .insta360X3, shortenedName: "X3")
        await checkInsta360DiscoveryRecovery(name: "GO 3S ABC123", model: .insta360Go3S, shortenedName: "GO 3")
        await checkNewerInsta360IdentitySurvivesWeakScan()
        await checkWatchCameraReconnect()
        await checkWatchReconnectWithSavedPeripherals()
        await checkWatchReconnectAfterDJISleep()
        await checkWatchRescanAfterConnectionFailure()
        await checkWatchRescanAfterSleepingGoPro()
        await checkWatchNanoReconnect()
        await checkDJIStopRecoveryAfterMissingAcknowledgement(savedReconnectTimesOut: false)
        await checkDJIStopRecoveryAfterMissingAcknowledgement(savedReconnectTimesOut: true)
        print("Store recording-work checks passed: SDK mode preservation, quick transitions, pairing, discovery, disconnect and Watch reconnect.")
    }

    private static func checkWatchCameraReconnect() async {
        let scanner = BLECameraScanner()
        let store = CameraStore(scanner: scanner, demoMode: true)
        store.isDemoMode = false
        let models: [CameraModel] = [.djiOsmoAction6, .djiOsmoAction5Pro, .goproHero13Black, .insta360X6, .insta360Go3S]
        let peripherals = models.map { _ in
            let peripheral = CBPeripheral()
            peripheral.state = .disconnected
            return peripheral
        }
        store.cameras = zip(models, peripherals).map { model, peripheral in
            DiscoveredCamera(id: peripheral.identifier, name: model.rawValue, brand: model.brand,
                model: model, rssi: -50, capabilities: [.record, .status], connectionState: .disconnected,
                recordingState: .unknown, isPaired: true, isSelected: false, lastSeen: .distantPast)
        }
        scanner.rememberKnownCameras(store.cameras)
        store.startScanning()
        let central = CBCentralManager.instances.last!
        let remoteManagersBeforeRefresh = CBPeripheralManager.instances.count

        store.requestWatchCameraReconnect()
        precondition(central.scannedServices == nil, "Watch refresh must preserve foreground discovery")

        UIApplication.shared.applicationState = .background
        defer { UIApplication.shared.applicationState = .active }
        store.requestWatchCameraReconnect()
        let scanServices = ["FFF0", "FEA6", "BE80"]
        precondition(Set(central.scannedServices ?? []) == Set(scanServices.map(CBUUID.init(string:))),
            "Background discovery must include the services for all saved camera brands")
        precondition(CBPeripheralManager.instances.count == remoteManagersBeforeRefresh + 1
            && CBPeripheralManager.instances.last?.services.map(\.uuid) == [CBUUID(string: "CE80")],
            "The saved GO 3S must use the GPS Remote peripheral service")
        let scanCount = central.scanCount
        store.requestWatchCameraReconnect()
        precondition(central.scanCount == scanCount && central.connectCount == 0,
            "Repeated refreshes must preserve the scan and wait for a fresh advertisement")

        // Background advertisements can omit the local name. For GoPro,
        // include the manufacturer bytes marking the camera as awake.
        for (peripheral, service) in zip(peripherals, ["FFF0", "FFF0", "FEA6", "BE80"]) {
            var advertisement: [String: Any] = [
                CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: service)],
                CBAdvertisementDataIsConnectable: true,
            ]
            if service == "FEA6" {
                advertisement[CBAdvertisementDataManufacturerDataKey] = Data([0x02, 0xF2, 0x00, 0x01])
            }
            scanner.centralManager(central, didDiscover: peripheral, advertisementData: advertisement, rssi: -65)
        }
        await waitUntil("Both DJI models and GoPro must attempt BLE reconnection, and X6 must reconnect through the SDK") {
            central.connectCount == 3
                && store.cameras.first(where: { $0.model == .insta360X6 })?.isConnected == true
        }
        precondition(store.commandResults.isEmpty, "Refreshing from the Watch must not issue a recording command")

        for camera in store.cameras {
            store.disconnect(camera)
        }
        await waitUntil("Manual Disconnect must settle before the next Watch refresh") {
            store.cameras.allSatisfy { $0.connectionState == .disconnected }
        }
        UIApplication.shared.applicationState = .active
        store.resumeCameraConnections()
        precondition(central.scannedServices == nil, "Foreground recovery must restore unfiltered discovery")
        UIApplication.shared.applicationState = .background
        store.requestWatchCameraReconnect()
        precondition(central.scannedServices == nil, "Watch refresh must respect manual Disconnect")
    }

    private static func checkWatchRescanAfterConnectionFailure() async {
        let scanner = BLECameraScanner()
        let store = CameraStore(scanner: scanner, demoMode: true)
        store.isDemoMode = false
        UIApplication.shared.applicationState = .background
        defer { UIApplication.shared.applicationState = .active }

        let peripheral = CBPeripheral()
        peripheral.state = .disconnected
        store.cameras = [
            DiscoveredCamera(id: peripheral.identifier, name: "Osmo Action 6", brand: .dji, model: .djiOsmoAction6,
                rssi: -55, capabilities: [.record, .status], connectionState: .disconnected, recordingState: .unknown,
                isPaired: true, isSelected: false, lastSeen: .distantPast)
        ]
        scanner.rememberKnownCameras(store.cameras)
        store.requestWatchCameraReconnect()
        let central = CBCentralManager.instances.last!
        let scanCount = central.scanCount
        let stopCount = central.stopCount
        scanner.centralManager(central, didDiscover: peripheral, advertisementData: [
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "FFF0")],
            CBAdvertisementDataIsConnectable: true,
        ], rssi: -65)
        await waitUntil("The first background discovery must attempt to connect") { central.connectCount == 1 }
        scanner.centralManager(central, didFailToConnect: peripheral, error: nil)
        await waitUntil("The failed passive connection must release its client") { peripheral.delegate == nil }

        let failedAt = Date()
        store.requestWatchCameraReconnect(now: failedAt.addingTimeInterval(4))
        precondition(central.scanCount == scanCount && central.stopCount == stopCount,
            "Reopening during the connection cooldown must not consume another background discovery")
        let reopenedAt = failedAt.addingTimeInterval(13)
        store.requestWatchCameraReconnect(now: reopenedAt)
        precondition(central.scanCount == scanCount + 1 && central.stopCount == stopCount + 1,
            "Reopening after cooldown must restart discovery even with the same Bluetooth service")
        store.requestWatchCameraReconnect(now: reopenedAt.addingTimeInterval(0.1))
        precondition(central.scanCount == scanCount + 1 && central.connectCount == 2,
            "Reopening after cooldown can retry the remembered link; a duplicate refresh must not retry it")
    }

    private static func checkWatchReconnectWithSavedPeripherals() async {
        let scanner = BLECameraScanner()
        let store = CameraStore(scanner: scanner, demoMode: true)
        store.isDemoMode = false
        let models: [CameraModel] = [.djiOsmoAction6, .djiOsmoAction5Pro, .djiOsmoNano, .goproHero13Black]
        let peripherals = models.map { _ in
            let peripheral = CBPeripheral()
            peripheral.state = .disconnected
            return peripheral
        }
        store.cameras = zip(models, peripherals).map { model, peripheral in
            DiscoveredCamera(id: peripheral.identifier, name: model.rawValue, brand: model.brand,
                model: model, rssi: -50, capabilities: [.record, .status], connectionState: .disconnected,
                recordingState: .unknown, isPaired: true, isSelected: false, lastSeen: .distantPast)
        }

        store.startScanning()
        let central = CBCentralManager.instances.last!
        central.rememberedPeripherals = peripherals
        store.requestWatchCameraReconnect()
        precondition(central.connectCount == 0, "Foreground reconnect still requires discovery")

        UIApplication.shared.applicationState = .background
        defer { UIApplication.shared.applicationState = .active }
        central.state = .unknown
        store.requestWatchCameraReconnect(scanRetry: true)
        central.state = .poweredOn
        scanner.centralManagerDidUpdateState(central)
        await waitUntil("Bluetooth must start the requested scan") { store.bluetoothStateLabel == "Powered On" }
        precondition(central.connectCount == 0, "Starting Bluetooth for a scan retry must not start a direct probe")

        central.state = .unknown
        store.requestWatchCameraReconnect()
        precondition(central.connectCount == 0, "The Watch can request reconnect before Bluetooth is ready")

        central.state = .poweredOn
        scanner.centralManagerDidUpdateState(central)
        await waitUntil("Watch reconnect must try the saved R SDK links without advertisements") {
            central.connectCount == 2
        }
        precondition(Set(central.connectionRequests) == Set(peripherals.prefix(2).map(\.identifier)),
            "GoPro and Nano must still wait for an advertisement")
        store.requestWatchCameraReconnect()
        precondition(central.connectCount == 2, "A repeated refresh must keep the pending probes")
        precondition(store.cameras.allSatisfy { $0.connectionState == .disconnected },
            "A BLE connection attempt must stay invisible until the camera protocol confirms readiness")
        precondition(store.commandResults.isEmpty, "Refreshing from the Watch must not issue a recording command")
    }

    private static func checkWatchReconnectAfterDJISleep() async {
        let scanner = BLECameraScanner()
        let store = CameraStore(scanner: scanner, demoMode: true)
        store.isDemoMode = false
        let peripheral = CBPeripheral()
        peripheral.state = .disconnected
        store.cameras = [
            DiscoveredCamera(id: peripheral.identifier, name: "Osmo Action 6", brand: .dji, model: .djiOsmoAction6,
                rssi: -55, capabilities: [.record, .status], connectionState: .disconnected, recordingState: .unknown,
                isPaired: true, isSelected: false, lastSeen: .distantPast)
        ]
        scanner.rememberKnownCameras(store.cameras)
        store.startScanning()
        let central = CBCentralManager.instances.last!
        central.rememberedPeripherals = [peripheral]
        UIApplication.shared.applicationState = .background
        defer { UIApplication.shared.applicationState = .active }

        let notify = CBCharacteristic(uuid: DJIRSDKBLEUUID.notifyCharacteristic, properties: [.notify])
        peripheral.services = [CBService(uuid: DJIRSDKBLEUUID.service, characteristics: [notify])]
        func connectAndGetClient() -> DJIExperimentalBLEClient {
            peripheral.state = .connected
            scanner.centralManager(central, didConnect: peripheral)
            return peripheral.delegate as! DJIExperimentalBLEClient
        }
        func status(_ powerMode: UInt8, checksum: [UInt8], on client: DJIExperimentalBLEClient) {
            // A synthetic R SDK status push with a fixed header and known CRCs.
            let header = Data([0xAA, 0x38, 0, 0, 0, 0, 0, 0, 1, 0, 0xC8, 0xDF, 0x1D, 0x02])
            var payload = Data(repeating: 0, count: 38)
            payload[28] = powerMode
            notify.value = header + payload + Data(checksum)
            client.peripheral(peripheral, didUpdateValueFor: notify, error: nil)
        }

        store.requestWatchCameraReconnect()
        precondition(central.connectCount == 1)
        let firstClient = peripheral.delegate as! DJIExperimentalBLEClient
        peripheral.state = .connecting

        // Foreground resume clears the retry cooldown while the Watch probe is pending.
        UIApplication.shared.applicationState = .active
        store.resumeCameraConnections()
        scanner.centralManager(central, didDiscover: peripheral, advertisementData: [
            CBAdvertisementDataServiceUUIDsKey: [DJIRSDKBLEUUID.service],
            CBAdvertisementDataIsConnectable: true,
        ], rssi: -55)
        await waitUntil("The late advertisement must reach the store") { store.cameras[0].lastConnectableSeen != nil }
        precondition(central.connectCount == 1 && peripheral.delegate === firstClient,
            "Discovery must keep the original Watch probe after the cooldown is cleared")
        store.resumeCameraConnections()
        precondition(central.connectCount == 1 && peripheral.delegate === firstClient,
            "Remembered-camera reconnect must also keep the original Watch probe")
        UIApplication.shared.applicationState = .background

        _ = connectAndGetClient()
        store.cameras[0].lastSeen = .distantPast
        status(255, checksum: [0xD0, 0xF1, 0x4B, 0x2D], on: firstClient)
        await waitUntil("The original probe must receive the unknown power status") {
            store.cameras[0].lastSeen > .distantPast
        }
        precondition(store.readyConnectedCameras.isEmpty, "Unknown power is not evidence that the camera is awake")
        status(0, checksum: [0xC4, 0x26, 0x0C, 0xCC], on: firstClient)
        await waitUntil("The first Watch connection must report the awake camera") { store.cameras[0].isConnected }
        status(3, checksum: [0xC7, 0x9D, 0x3B, 0x27], on: firstClient)
        await waitUntil("The sleeping camera must disconnect") {
            store.cameras[0].connectionState == .disconnected && central.disconnectCount == 1
        }
        peripheral.state = .disconnected
        scanner.centralManager(central, didDisconnectPeripheral: peripheral, error: nil)
        await waitUntil("The transport disconnect must reach the store") {
            store.eventLog.contains { $0.hasSuffix("BLE disconnected.") }
        }

        let sleptAt = Date()
        store.requestWatchCameraReconnect(now: sleptAt.addingTimeInterval(4))
        precondition(central.connectCount == 1, "A Watch reopen must respect the sleep cooldown")
        store.requestWatchCameraReconnect(now: sleptAt.addingTimeInterval(13), scanRetry: true)
        precondition(central.connectCount == 1, "An automatic scan retry must not probe a sleeping camera")
        store.requestWatchCameraReconnect(now: sleptAt.addingTimeInterval(14))
        precondition(central.connectCount == 2,
            "A later Watch open must try the saved device after sleep without needing an advertisement")
        store.requestWatchCameraReconnect(now: sleptAt.addingTimeInterval(15))
        precondition(central.connectCount == 2, "Duplicate refresh must not start another probe")

        let retryClient = connectAndGetClient()
        status(0, checksum: [0xC4, 0x26, 0x0C, 0xCC], on: retryClient)
        await waitUntil("The second Watch connection must wait for awake status") { store.cameras[0].isConnected }
        precondition(store.commandResults.isEmpty, "The reconnect must issue no recording command")
    }

    private static func checkWatchRescanAfterSleepingGoPro() async {
        let scanner = BLECameraScanner()
        let store = CameraStore(scanner: scanner, demoMode: true)
        store.isDemoMode = false
        let peripheral = CBPeripheral()
        peripheral.state = .disconnected
        store.cameras = [
            DiscoveredCamera(id: peripheral.identifier, name: "GoPro HERO13 Black", brand: .gopro,
                model: .goproHero13Black, rssi: -55, capabilities: [.record, .status],
                connectionState: .disconnected, recordingState: .unknown, isPaired: true,
                isSelected: false, lastSeen: .distantPast)
        ]
        scanner.rememberKnownCameras(store.cameras)
        UIApplication.shared.applicationState = .background
        defer { UIApplication.shared.applicationState = .active }
        let openedAt = Date()
        store.requestWatchCameraReconnect(now: openedAt)
        let central = CBCentralManager.instances.last!
        let firstScanCount = central.scanCount

        func discover(awake: Bool) {
            scanner.centralManager(central, didDiscover: peripheral, advertisementData: [
                CBAdvertisementDataServiceUUIDsKey: [GoProBLEUUID.serviceControlAndQuery],
                CBAdvertisementDataIsConnectable: true,
                CBAdvertisementDataManufacturerDataKey: Data([0x02, 0xF2, 0, awake ? 1 : 0]),
            ], rssi: -55)
        }
        discover(awake: false)
        await waitUntil("The first scan reports the GoPro is asleep") { store.cameras[0].advertisementAwake == false }
        precondition(central.connectCount == 0, "A Watch refresh must never wake a sleeping GoPro")

        store.requestWatchCameraReconnect(now: openedAt.addingTimeInterval(4), scanRetry: true)
        precondition(central.scanCount == firstScanCount + 1 && central.connectCount == 0)
        discover(awake: true)
        await waitUntil("The new scan must connect when the GoPro advertises awake") { central.connectCount == 1 }
        store.requestWatchCameraReconnect(now: openedAt.addingTimeInterval(8), scanRetry: true)
        precondition(central.scanCount == firstScanCount + 1 && central.connectCount == 1,
            "A scan retry must leave an in-progress GoPro connection alone")
    }

    private static func checkDJIStopRecoveryAfterMissingAcknowledgement(savedReconnectTimesOut: Bool) async {
        let scanner = BLECameraScanner()
        let store = CameraStore(scanner: scanner, demoMode: true)
        store.isDemoMode = false
        let peripheral = CBPeripheral()
        peripheral.state = .disconnected
        let camera = DiscoveredCamera(id: peripheral.identifier, name: "Osmo Action 4", brand: .dji,
            model: .djiOsmoAction4, rssi: -50, capabilities: [.record, .status], connectionState: .disconnected,
            recordingState: .unknown, isPaired: true, isSelected: false, lastSeen: .distantPast)
        store.cameras = [camera]
        scanner.rememberKnownCameras(store.cameras)
        store.startScanning()
        let central = CBCentralManager.instances.last!
        central.rememberedPeripherals = [peripheral]
        UIApplication.shared.applicationState = .background
        defer { UIApplication.shared.applicationState = .active }

        let notify = CBCharacteristic(uuid: DJIRSDKBLEUUID.notifyCharacteristic, properties: [.notify])
        let writer = CBCharacteristic(uuid: DJIRSDKBLEUUID.writeCharacteristic, properties: [.writeWithoutResponse])
        let service = CBService(uuid: DJIRSDKBLEUUID.service, characteristics: [notify, writer])
        peripheral.services = [service]

        // Synthetic R SDK frames with valid checksums.
        let verification = "aa 33 00 02 00 00 00 00 01 00 98 2f 00 19 00 00 ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 02 00 00 00 00 00 00 f9 f6 0e 5b"
        func openLink() -> DJIExperimentalBLEClient {
            peripheral.state = .connected
            scanner.centralManager(central, didConnect: peripheral)
            let client = peripheral.delegate as! DJIExperimentalBLEClient
            client.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)
            notify.value = Data(verification.split(separator: " ").map { UInt8($0, radix: 16)! })
            client.peripheral(peripheral, didUpdateValueFor: notify, error: nil)
            return client
        }
        func status(recording: Bool, power: UInt8, checksum: [UInt8], on client: DJIExperimentalBLEClient) {
            var payload = Data(repeating: 0, count: 38)
            payload[0] = 1
            payload[1] = recording ? 3 : 1
            payload[28] = power
            notify.value = Data([0xAA, 0x38, 0, 0, 0, 0, 0, 0, 1, 0, 0xC8, 0xDF, 0x1D, 0x02])
                + payload + Data(checksum)
            client.peripheral(peripheral, didUpdateValueFor: notify, error: nil)
        }
        func advertise() {
            for _ in 0..<12 {
                scanner.centralManager(central, didDiscover: peripheral, advertisementData: [
                    CBAdvertisementDataServiceUUIDsKey: [DJIRSDKBLEUUID.service],
                    CBAdvertisementDataIsConnectable: true,
                ], rssi: -50)
            }
        }
        func recordActions() -> [UInt8] {
            peripheral.writes.compactMap { entry in
                let frame = entry.data
                guard frame.count >= 19, frame[12] == 0x1D, frame[13] == 0x03 else { return nil }
                return frame[18]
            }
        }

        store.requestWatchCameraReconnect()
        precondition(central.connectCount == 1)
        let firstClient = openLink()
        status(recording: true, power: 0, checksum: [0x46, 0xE4, 0xE5, 0x1B], on: firstClient)
        await waitUntil("The Action 4 must be connected and recording") {
            store.cameras[0].isConnected && store.cameras[0].recordingState == .recording
        }
        store.stopRecording(store.cameras[0])
        precondition(recordActions() == [1], "The original Stop must be sent once")
        await waitUntil("An unacknowledged Stop should close the stalled BLE link") {
            central.disconnectCount == 1 && store.cameras[0].connectionState == .reconnecting
        }
        peripheral.state = .disconnecting
        advertise()
        await waitUntil("Advertisements must be processed during link teardown") {
            store.cameras[0].lastConnectableSeen != nil
        }
        precondition(central.connectCount == 1 && peripheral.delegate === firstClient,
            "Discovery must not replace the client before Bluetooth reports the disconnect")

        // The next connection must also work when the phone sees no fresh advertisement.
        store.cameras[0].lastConnectableSeen = nil
        peripheral.state = .disconnected
        scanner.centralManager(central, didDisconnectPeripheral: peripheral, error: nil)
        await waitUntil("The queued Stop must reconnect through the saved R SDK peripheral") {
            central.connectCount == 2 && store.cameras[0].connectionState == .connecting
        }
        precondition(recordActions() == [1], "A BLE connection attempt must not send Stop")
        let retryClient = openLink()
        status(recording: true, power: 255, checksum: [0x52, 0x33, 0xA2, 0xFA], on: retryClient)
        await waitUntil("The reconnect must process the unknown power status") {
            store.cameras[0].recordingState == .recording
        }
        precondition(!store.cameras[0].isConnected && recordActions() == [1])
        let readyClient: DJIExperimentalBLEClient
        if savedReconnectTimesOut {
            await waitUntil("A stalled recovery must close its BLE link", timeout: .seconds(40)) {
                central.disconnectCount == 2
            }
            peripheral.state = .disconnecting
            advertise()
            await waitUntil("Advertisements must be processed during recovery teardown") {
                store.cameras[0].lastConnectableSeen != nil
            }
            precondition(central.connectCount == 2 && peripheral.delegate === retryClient,
                "The recovery timeout must wait for Bluetooth to finish disconnecting")

            store.cameras[0].lastConnectableSeen = nil
            peripheral.state = .disconnected
            scanner.centralManager(central, didDisconnectPeripheral: peripheral, error: nil)
            await waitUntil("The spent saved-camera attempt must leave Stop unconfirmed") {
                store.isCameraStopUnconfirmed(store.cameras[0])
            }
            precondition(central.connectCount == 2 && recordActions() == [1],
                "A failed saved-camera attempt must wait for discovery")

            advertise()
            await waitUntil("Normal discovery can still recover the outstanding Stop") { central.connectCount == 3 }
            readyClient = openLink()
        } else {
            readyClient = retryClient
        }
        status(recording: true, power: 0, checksum: [0x46, 0xE4, 0xE5, 0x1B], on: readyClient)
        await waitUntil("The awake control session must send the queued Stop once") { recordActions() == [1, 1] }
        status(recording: false, power: 0, checksum: [0x39, 0xCC, 0x74, 0xC1], on: readyClient)
        await waitUntil("Camera status must confirm Stop") { store.cameras[0].recordingState == .stopped }
        precondition(central.connectCount == (savedReconnectTimesOut ? 3 : 2) && recordActions() == [1, 1])
    }

    private static func checkWatchNanoReconnect() async {
        let scanner = BLECameraScanner()
        let store = CameraStore(scanner: scanner, demoMode: true)
        store.isDemoMode = false
        UIApplication.shared.applicationState = .background
        defer { UIApplication.shared.applicationState = .active }

        func savedCamera(_ model: CameraModel, id: UUID = UUID()) -> DiscoveredCamera {
            DiscoveredCamera(id: id, name: model.rawValue, brand: model.brand, model: model,
                rssi: -55, capabilities: [.record, .status], connectionState: .disconnected,
                recordingState: .unknown, isPaired: true, isSelected: false, lastSeen: .distantPast)
        }

        var recordingNano = savedCamera(.djiOsmoNano)
        recordingNano.connectionState = .connected
        recordingNano.recordingState = .recording
        store.cameras = [recordingNano, savedCamera(.goproHero13Black)]
        store.startScanning()
        store.requestWatchCameraReconnect()
        let central = CBCentralManager.instances.last!
        precondition(Set(central.scannedServices?.map(\.uuidString) ?? []) == ["FEA6", "FFF0"],
            "The Watch scan must retain the connected Nano’s sleep advertisements during GoPro reconnect")

        let awakeNano = CBPeripheral()
        let sleepingNano = CBPeripheral()
        let disconnectedNano = CBPeripheral()
        for peripheral in [awakeNano, sleepingNano, disconnectedNano] {
            peripheral.state = .disconnected
            store.cameras.append(savedCamera(.djiOsmoNano, id: peripheral.identifier))
        }
        scanner.rememberKnownCameras(store.cameras)
        func discover(_ peripheral: CBPeripheral, awake: Bool) {
            scanner.centralManager(central, didDiscover: peripheral, advertisementData: [
                CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "FFF0")],
                CBAdvertisementDataIsConnectable: true,
                CBAdvertisementDataManufacturerDataKey: Data([0xAA, 0x08, 0x19, 0, 0xFA, 0, 0, 0, 0, 0, 0, awake ? 0x02 : 0x03]),
            ], rssi: -65)
        }
        discover(awakeNano, awake: true)
        discover(sleepingNano, awake: true)
        discover(disconnectedNano, awake: true)
        await waitUntil("All three awake advertisements must reach the store before cancellation") {
            store.cameras.filter { $0.advertisementAwake == true }.count == 3
        }
        precondition(central.connectCount == 0, "Nano must still wait for the awake settle time")
        discover(sleepingNano, awake: false)
        store.disconnect(savedCamera(.djiOsmoNano, id: disconnectedNano.identifier))

        await waitUntil("One awake advertisement must be enough to attempt a background Nano link") {
            central.connectCount == 1
        }
        precondition(sleepingNano.delegate == nil && disconnectedNano.delegate == nil)
        precondition(!store.readyConnectedCameras.contains { $0.id == awakeNano.identifier },
            "The passive link must wait for the Nano protocol to confirm readiness")

        awakeNano.state = .connected
        scanner.centralManager(central, didConnect: awakeNano)
        let client = awakeNano.delegate as! DJIExperimentalBLEClient
        let notify = CBCharacteristic(uuid: CBUUID(string: "FFF4"), properties: [.notify])
        let writer = CBCharacteristic(uuid: CBUUID(string: "FFF5"), properties: [.writeWithoutResponse])
        let service = CBService(uuid: CBUUID(string: "FFF0"), characteristics: [notify, writer])
        client.peripheral(awakeNano, didDiscoverCharacteristicsFor: service, error: nil)
        var payload = Data(repeating: 0, count: 60)
        payload[0] = 0x40
        payload[4] = 1
        payload[57] = 1
        notify.value = DJINanoProtocol.frame(sequenceNumber: 100, source: 1, destination: 2,
            flags: 0, commandSet: 2, commandID: 0x80, payload: payload)
        client.peripheral(awakeNano, didUpdateValueFor: notify, error: nil)
        await waitUntil("One advertisement plus real Nano protocol status must expose a ready camera") {
            store.readyConnectedCameras.contains { $0.id == awakeNano.identifier }
        }
        precondition(store.cameras.first(where: { $0.id == recordingNano.id })?.recordingState == .recording)
        precondition(store.commandResults.isEmpty, "A Watch reconnect must issue no recording command")
    }

    private static func checkInsta360DiscoveryRecovery(name: String, model: CameraModel, shortenedName: String) async {
        let scanner = BLECameraScanner()
        let store = CameraStore(scanner: scanner, demoMode: true)
        store.cameras = []
        let central = CBCentralManager.instances.last!
        let peripheral = CBPeripheral()
        peripheral.name = "amba_boss"
        func discover(_ name: String, connectable: Bool = true, rssi: NSNumber = -50) {
            scanner.centralManager(central, didDiscover: peripheral, advertisementData: [
                CBAdvertisementDataLocalNameKey: name,
                CBAdvertisementDataServiceUUIDsKey: [Insta360BLEUUID.directControl],
                CBAdvertisementDataIsConnectable: NSNumber(value: connectable)
            ], rssi: rssi)
        }

        discover("amba_boss")
        await waitUntil("A generic first sighting has no supported model") {
            store.cameras.count == 1 && !store.cameras[0].isSupportedByApp
        }
        discover(name, connectable: false)
        await waitUntil("Model identification alone cannot make a nonconnectable advertisement available") {
            store.cameras[0].model == model && store.cameras[0].connectionState == .disconnected
        }
        discover("amba_boss")
        await waitUntil("The camera becomes available on a subsequent connectable advertisement") {
            store.cameras[0].connectionState == .discovered
        }
        precondition(store.cameras.count == 1 && store.cameras[0].name == name)
        precondition(store.cameras[0].model == model && store.cameras[0].insta360UsesSDK == model.supportsInsta360SDK)
        precondition(store.cameras[0].recordingState == .unknown && !store.cameras[0].isPaired)

        peripheral.name = shortenedName
        discover("amba_boss", connectable: false, rssi: -65)
        await waitUntil("A nonconnectable scan must update the recovered row") {
            store.cameras[0].connectionState == .disconnected && store.cameras[0].rssi == -65
        }
        precondition(store.cameras[0].name == name && store.cameras[0].model == model,
            "A shortened peripheral name must preserve the model and identifier before pairing")
    }

    private static func checkNewerInsta360IdentitySurvivesWeakScan() async {
        let scanner = BLECameraScanner()
        let store = CameraStore(scanner: scanner, demoMode: true)
        let central = CBCentralManager.instances.last!
        let peripheral = CBPeripheral()
        store.cameras = [
            DiscoveredCamera(id: peripheral.identifier, name: "GO 3 ABC123", brand: .insta360, model: .insta360Go3,
                rssi: -50, capabilities: [.record], connectionState: .disconnected, recordingState: .unknown,
                isPaired: true, isSelected: false, lastSeen: Date())
        ]
        scanner.rememberKnownCameras(store.cameras)

        func discover(_ localName: String?, peripheralName: String?, rssi: NSNumber) {
            peripheral.name = peripheralName
            var advertisement: [String: Any] = [
                CBAdvertisementDataServiceUUIDsKey: [Insta360BLEUUID.directControl],
                CBAdvertisementDataIsConnectable: false,
            ]
            advertisement[CBAdvertisementDataLocalNameKey] = localName
            scanner.centralManager(central, didDiscover: peripheral, advertisementData: advertisement, rssi: rssi)
        }

        let fullName = "GO 3S ABC123"
        discover(fullName, peripheralName: "amba_boss", rssi: -65)
        await waitUntil("A full name must update the paired camera") {
            store.cameras[0].name == fullName && store.cameras[0].model == .insta360Go3S
        }

        discover("amba_boss", peripheralName: "GO 3S", rssi: -80)
        await waitUntil("The model-only scan must refresh signal strength") { store.cameras[0].rssi == -80 }
        precondition(store.cameras[0].name == fullName && store.cameras[0].model == .insta360Go3S,
            "A model-only scan must preserve the most recent full identity")

        discover(nil, peripheralName: nil, rssi: -95)
        await waitUntil("The nameless scan must refresh signal strength") { store.cameras[0].rssi == -95 }
        precondition(store.cameras[0].name == fullName && store.cameras[0].model == .insta360Go3S,
            "A nameless scan must preserve the most recent full identity")
    }

    private static func checkPreservedSDKModes(_ store: CameraStore) async {
        store.connect(store.cameras[0])
        let commands = INSBluetoothManager.instances.last!.commands
        // A nonzero value proves we preserve a camera-selected submode. It is
        // deliberately not labeled FreeFrame without a verified vendor mapping.
        commands.options.videoSubMode = 7
        await waitUntil("The camera-selected video family must be ready") {
            store.cameras[0].currentMode == .cameraVideo && store.cameras[0].recordingState == .stopped
        }
        precondition(store.cameras[0].insta360UsesSDK == true)
        precondition(commands.starts == 0 && commands.modeChanges == 0 && commands.options.videoSubMode == 7,
            "Connecting the X5 must not capture or change the camera-selected mode")
        precondition(store.cameras[0].canStartRecording && store.canStartMulticamRecording)
        precondition(CarPlayCameraState(cameras: store.cameras).canStart)

        for surface in ["camera", "multicam", "Siri", "Watch", "CarPlay"] {
            let before = commands.starts
            switch surface {
            case "camera": store.startRecording(store.cameras[0])
            case "multicam": store.startMulticamRecording()
            case "Siri": precondition(store.startAllRecording())
            case "Watch": precondition(store.startWatchRecording())
            default: precondition(store.startCarPlayRecording())
            }
            await waitUntil("\(surface) Start must reach the selected video submode") { commands.starts == before + 1 }
            precondition(commands.modeChanges == 0 && commands.options.videoSubMode == 7,
                "\(surface) Start must not select normal Video")
            commands.status.state = .fpv
            await waitUntil("\(surface) recording must confirm in the selected submode") {
                store.cameras[0].recordingState == .recording && store.cameras[0].currentMode == .cameraVideo
            }
            store.stopRecording(store.cameras[0])
            commands.status.state = .notCapture
            await waitUntil("\(surface) Stop must preserve the selected submode") {
                store.cameras[0].recordingState == .stopped && store.cameras[0].currentMode == .cameraVideo
            }
            precondition(commands.modeChanges == 0 && commands.options.videoSubMode == 7)
        }

        // Photo-priority and unknown mode reads must block video Start without
        // overwriting the camera's selection. Include the reported X3 zero pair.
        for submodes: (UInt32, UInt32) in [(0, 0), (100, 100), (0, 100), (1, 0), (0, 7), (100, 16), (100, 99)] {
            commands.options.photoSubMode = submodes.0
            commands.options.videoSubMode = submodes.1
            await waitUntil("The camera must report the new non-video/unknown mode") {
                store.cameras[0].currentMode == (submodes.0 == 0 ? .photo : nil)
            }
            let starts = commands.starts
            precondition(!store.startAllRecording() && !store.startWatchRecording() && !store.startCarPlayRecording())
            precondition(commands.starts == starts && commands.modeChanges == 0)
        }

        // If the zero pair accompanies camera-side video capture, keep Stop
        // available instead of showing a disabled Photo capture.
        commands.options.photoSubMode = 0
        commands.options.videoSubMode = 0
        commands.status.state = .normalCapture
        await waitUntil("Camera-side video capture must remain visible with conflicting mode readback") {
            store.cameras[0].recordingState == .recording
        }
        precondition(store.cameras[0].currentMode == nil)
        precondition(store.cameras[0].primaryRecordCommand == .stopRecording)
        precondition(store.cameras[0].primaryRecordTitle == "Stop")
        precondition(store.canStopMulticamRecording && CarPlayCameraState(cameras: store.cameras).canStop)
        let stops = commands.stops
        store.stopRecording(store.cameras[0])
        precondition(commands.stops == stops + 1)
        commands.status.state = .notCapture
        await waitUntil("Stop must confirm and restore Photo-first stopped readback") {
            store.cameras[0].recordingState == .stopped && store.cameras[0].currentMode == .photo
        }

        commands.options.photoSubMode = 100
        commands.options.videoSubMode = 7
        await waitUntil("Camera Video must return after a successful read") { store.cameras[0].currentMode == .cameraVideo }
        store.switchMode(.video, for: store.cameras[0])
        await waitUntil("Explicit Video selection must still set and confirm normal Video") {
            commands.modeChanges == 1 && store.cameras[0].currentMode == .video
        }
        precondition(commands.options.videoSubMode == 0)
        store.switchMode(.photo, for: store.cameras[0])
        await waitUntil("Explicit Photo selection must still work") {
            commands.modeChanges == 2 && store.cameras[0].currentMode == .photo
        }
        store.disconnect(store.cameras[0])

        // A pending Start must also preserve the mode discovered on reconnect.
        await waitUntil("Disconnect must finish before requesting a reconnect Start") {
            store.cameras[0].connectionState == .disconnected
        }
        store.startRecording(store.cameras[0])
        let reconnected = INSBluetoothManager.instances.last!.commands
        reconnected.options.videoSubMode = 7
        await waitUntil("Queued Start must use the camera-selected mode after reconnect") { reconnected.starts == 1 }
        precondition(reconnected.modeChanges == 0 && reconnected.options.videoSubMode == 7)
        reconnected.status.state = .fpv
        await waitUntil("Reconnected recording must confirm") { store.cameras[0].recordingState == .recording }
        store.disconnect(store.cameras[0])
    }
}
