import CoreBluetooth
import Foundation
import INSCameraServiceSDK

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
        let camera = DiscoveredCamera(id: UUID(), name: "X3", brand: .insta360, model: .insta360X3,
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
        print("Store recording-work checks passed: quick SDK transitions, pairing, discovery and disconnect.")
    }
}
