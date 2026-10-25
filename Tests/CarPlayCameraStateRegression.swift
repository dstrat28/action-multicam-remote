import Foundation

@main
enum CarPlayCameraStateRegression {
    static func main() {
        let empty = CarPlayCameraState(cameras: [])
        precondition(!empty.canStart && !empty.canStop && empty.cameras.isEmpty)
        precondition(empty.startDetail == "Pair cameras before your drive")

        var front = makeCamera(name: "Front")
        var rear = makeCamera(name: "Rear")
        rear.isSelected = false
        var unpaired = makeCamera(name: "Nearby camera")
        unpaired.isPaired = false
        let ready = CarPlayCameraState(cameras: [front, rear, unpaired])
        precondition(ready.cameras.map(\.id) == [front.id, rear.id], "Only paired cameras belong in CarPlay")
        precondition(ready.startCameraIDs == [front.id], "Start must honor selection")
        precondition(!ready.canStop)
        precondition(ready.cameras.allSatisfy(\.canToggleSelection))

        front.isSelected = false
        let deselected = CarPlayCameraState(cameras: [front, rear])
        precondition(!deselected.canStart && !deselected.canStop)
        precondition(deselected.startDetail == "Select connected cameras below")
        front.isSelected = true
        rear.isSelected = true
        precondition(CarPlayCameraState(cameras: [front, rear]).startCameraIDs == [front.id, rear.id])

        for mode in [CaptureMode.photo, .timelapse, .slowMotion] {
            rear.currentMode = mode
            let state = CarPlayCameraState(cameras: [front, rear])
            precondition(!state.canStart, "Start must never capture photos or silently change modes")
            precondition(state.startCameraIDs.isEmpty, "Do not partially start a selected group")
            precondition(!state.canStop)
        }
        rear.currentMode = nil
        precondition(!CarPlayCameraState(cameras: [rear]).canStart, "An unknown camera mode must not trigger a shutter toggle")
        rear.currentMode = .video
        for status in [CameraRecordingState.unknown, .unavailable] {
            rear.recordingState = status
            precondition(!CarPlayCameraState(cameras: [rear]).canStart, "Start requires confirmed stopped/ready status")
        }

        rear.recordingState = .recording
        let mixed = CarPlayCameraState(cameras: [front, rear])
        precondition(!mixed.canStart && mixed.stopCameraIDs == [rear.id])
        rear.isSelected = false
        precondition(CarPlayCameraState(cameras: [front, rear]).canStart)
        precondition(!CarPlayCameraState(cameras: [front, rear]).canStop, "Stop must not target deselected recordings")

        front.recordingState = .starting
        rear.isSelected = true
        let stopping = CarPlayCameraState(cameras: [front, rear])
        precondition(!stopping.canStart && stopping.stopCameraIDs == [front.id, rear.id], "Stop must cancel in-flight starts too")
        front.connectionState = .reconnecting
        let reconnecting = CarPlayCameraState(cameras: [front])
        precondition(!reconnecting.canStart && reconnecting.canStop, "Keep the existing queued Stop path available during reconnect")
        precondition(reconnecting.cameras[0].canToggleSelection, "An offline selected camera can still be deselected")
        front.isSelected = false
        precondition(!CarPlayCameraState(cameras: [front]).cameras[0].canToggleSelection)

        front = makeCamera(name: "Front")
        front.nickname = "Windshield"
        precondition(CarPlayCameraState(cameras: [front]).cameras[0].name == "Windshield")
        front.model = .goproHero8Black
        front.name = "HERO8 Black"
        front.isSelected = false
        let unsupported = CarPlayCameraState(cameras: [front])
        precondition(!unsupported.canStart && !unsupported.canStop)
        precondition(!unsupported.cameras[0].canToggleSelection)

        var insta360 = makeCamera(name: "Insta360 X5")
        insta360.brand = .insta360
        insta360.model = .insta360X5
        insta360.currentMode = nil
        insta360.recordingState = .unknown
        precondition(!CarPlayCameraState(cameras: [insta360]).canStart, "Unknown Insta360 mode/state cannot safely identify a recording start")
        insta360.recordingState = .recording
        precondition(CarPlayCameraState(cameras: [insta360]).canStop, "A confirmed recording can still be stopped")
        insta360.currentMode = .photo
        precondition(!CarPlayCameraState(cameras: [insta360]).canStop, "CarPlay must not operate a photo shutter")

        print("CarPlay camera selection and recording regression checks passed.")
    }

    private static func makeCamera(name: String) -> DiscoveredCamera {
        DiscoveredCamera(
            id: UUID(), name: name, brand: .gopro, model: .goproHero13Black,
            rssi: -50, capabilities: [.record, .status, .mode],
            connectionState: .connected, recordingState: .stopped, currentMode: .video,
            isPaired: true, isSelected: true, lastSeen: Date()
        )
    }
}
