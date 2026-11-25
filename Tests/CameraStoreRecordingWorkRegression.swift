import CoreBluetooth
import Foundation
import INSCameraServiceSDK
import UIKit

@main
@MainActor
enum CameraStoreRecordingWorkRegression {
    static func waitUntil(_ message: String, _ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
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
        await checkWatchAction6Reconnect()
        print("Store recording-work checks passed: SDK mode preservation, quick transitions, pairing, discovery, disconnect and Watch reconnect.")
    }

    private static func checkWatchAction6Reconnect() async {
        let scanner = BLECameraScanner()
        let store = CameraStore(scanner: scanner, demoMode: true)
        store.isDemoMode = false
        let peripheral = CBPeripheral()
        peripheral.state = .disconnected
        let camera = DiscoveredCamera(id: peripheral.identifier, name: "Osmo Action 6", brand: .dji,
            model: .djiOsmoAction6, rssi: -50, capabilities: [.record, .status], connectionState: .disconnected,
            recordingState: .unknown, isPaired: true, isSelected: false, lastSeen: .distantPast)
        store.cameras = [camera]
        scanner.rememberKnownCameras(store.cameras)
        store.startScanning()
        let central = CBCentralManager.instances.last!

        store.requestWatchCameraReconnect()
        precondition(central.scannedServices == nil, "Watch refresh must preserve foreground discovery")

        UIApplication.shared.applicationState = .background
        defer { UIApplication.shared.applicationState = .active }
        store.requestWatchCameraReconnect()
        precondition(central.scannedServices == [CBUUID(string: "FFF0")], "Background discovery must filter for the Action 6 service")
        let scanCount = central.scanCount
        store.requestWatchCameraReconnect()
        precondition(central.scanCount == scanCount && central.connectCount == 0,
            "Repeated refreshes must preserve the scan and wait for a fresh advertisement")

        // A background advertisement may omit the local name. The known camera
        // identifier and a connectable advertisement are sufficient to retry it.
        scanner.centralManager(central, didDiscover: peripheral, advertisementData: [
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "FFF0")],
            CBAdvertisementDataIsConnectable: NSNumber(value: true),
        ], rssi: -65)
        await waitUntil("The saved Action 6 must reconnect after a fresh connectable advertisement") {
            central.connectCount == 1
        }
        precondition(store.commandResults.isEmpty, "Refreshing from the Watch must not issue a recording command")

        store.disconnect(camera)
        await waitUntil("Manual Disconnect must settle before the next Watch refresh") {
            store.cameras[0].connectionState == .disconnected
        }
        UIApplication.shared.applicationState = .active
        store.resumeCameraConnections()
        precondition(central.scannedServices == nil, "Foreground recovery must restore unfiltered discovery")
        UIApplication.shared.applicationState = .background
        store.requestWatchCameraReconnect()
        precondition(central.scannedServices == nil, "Watch refresh must respect manual Disconnect")
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
