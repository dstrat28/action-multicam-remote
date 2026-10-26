import CarPlay
import Observation

// The real controller observes this store using the same Observation mechanism
// as the app. Camera command delivery is covered by the protocol/device checks.
@MainActor
@Observable
final class CameraStore {
    var cameras: [DiscoveredCamera] = []

    func startCarPlayRecording() -> Bool { false }
    func stopCarPlayRecording() -> Bool { false }

    func toggleSelection(for camera: DiscoveredCamera) {
        guard let index = cameras.firstIndex(where: { $0.id == camera.id }) else { return }
        cameras[index].isSelected.toggle()
    }
}

@main
@MainActor
enum CarPlayCameraControllerRegression {
    static func main() async throws {
        let store = CameraStore()
        store.cameras = [DiscoveredCamera(
            id: UUID(), name: "Front", brand: .gopro, model: .goproHero13Black,
            rssi: -50, capabilities: [.record, .status, .mode],
            connectionState: .connected, recordingState: .stopped, currentMode: .video,
            telemetry: CameraTelemetry(batteryPercent: 83),
            isPaired: true, isSelected: true, lastSeen: Date()
        )]
        let interface = CPInterfaceController()
        let controller = CarPlayCameraController(store: store, interfaceController: interface)
        controller.connect()
        let template = interface.rootTemplate!
        precondition(template.sections[0].items[0].detailText == "Connected · 83%")

        store.cameras[0].connectionState = .disconnected
        try await waitUntil { template.sections[0].items[0].detailText == "Not Connected" }
        store.cameras[0].connectionState = .connected
        try await waitUntil { template.sections[0].items[0].detailText == "Connected · 83%" }

        let countBeforeBattery = template.updateCount
        store.cameras[0].telemetry?.batteryPercent = 82
        try await Task.sleep(for: .milliseconds(50))
        precondition(template.updateCount == countBeforeBattery,
                     "Battery must not cause an immediate redraw")

        store.cameras[0].recordingState = .starting
        try await waitUntil { template.trailingNavigationBarButtons[0].title == "Starting..." }
        precondition(!template.trailingNavigationBarButtons[0].isEnabled)
        store.cameras[0].recordingState = .recording
        try await waitUntil { template.trailingNavigationBarButtons[0].title == "Stop" }
        precondition(template.trailingNavigationBarButtons[0].isEnabled)

        controller.pause()
        let countBeforePause = template.updateCount
        store.cameras[0].connectionState = .disconnected
        try await Task.sleep(for: .milliseconds(50))
        precondition(template.updateCount == countBeforePause,
                     "Paused scenes must stop observing")

        controller.activate()
        precondition(template.sections[0].items[0].detailText == "Not Connected")
        store.cameras[0].connectionState = .connected
        try await waitUntil { template.sections[0].items[0].detailText == "Recording · 82%" }

        store.cameras[0].telemetry?.batteryPercent = 81
        let countBeforeTick = template.updateCount
        try await Task.sleep(for: .milliseconds(50))
        precondition(template.updateCount == countBeforeTick)
        try await waitUntil(timeout: .seconds(12)) {
            template.sections[0].items[0].detailText == "Recording · 81%"
        }

        controller.disconnect()
        let countBeforeDisconnect = template.updateCount
        store.cameras[0].connectionState = .disconnected
        try await Task.sleep(for: .milliseconds(50))
        precondition(template.updateCount == countBeforeDisconnect,
                     "Disconnected CarPlay scenes must stop observing")

        print("CarPlay controller regression checks passed: immediate connection/recording updates, periodic battery refresh, pause/resume, and disconnect.")
    }

    private static func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(predicate(), "Expected UI update before deadline")
    }
}
