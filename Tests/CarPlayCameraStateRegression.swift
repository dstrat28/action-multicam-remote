import Foundation

@main
enum CarPlayCameraStateRegression {
    static func main() {
        let empty = CarPlayCameraState(cameras: [])
        precondition(!empty.canStart && !empty.canStop && empty.cameras.isEmpty)
        precondition(empty.recordingAction == .start && !empty.canPerformRecordingAction)
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
        precondition(ready.recordingAction == .start && ready.canPerformRecordingAction)
        precondition(ready.recordingActionTitle == "Record")
        precondition(ready.cameras.allSatisfy(\.canToggleSelection))
        precondition(ready.cameras.allSatisfy { $0.detail == "Connected" },
                     "The checkmark alone represents selection; status must match the phone")

        var statusCamera = makeCamera(name: "Status")
        for isSelected in [true, false] {
            statusCamera.isSelected = isSelected
            for connectionState in [CameraConnectionState.discovered, .disconnected, .failed("Unavailable")] {
                statusCamera.connectionState = connectionState
                statusCamera.recordingState = .recording
                precondition(CarPlayCameraState(cameras: [statusCamera]).cameras[0].detail == "Not Connected",
                             "Offline status must not include selection or a stale recording status")
            }
            for connectionState in [CameraConnectionState.connecting, .reconnecting] {
                statusCamera.connectionState = connectionState
                precondition(CarPlayCameraState(cameras: [statusCamera]).cameras[0].detail == "Connecting")
            }
            statusCamera.connectionState = .connected
            precondition(CarPlayCameraState(cameras: [statusCamera]).cameras[0].detail == "Recording")
            for recordingState in [CameraRecordingState.ready, .stopped, .starting, .unknown, .unavailable] {
                statusCamera.recordingState = recordingState
                precondition(CarPlayCameraState(cameras: [statusCamera]).cameras[0].detail == "Connected")
            }
        }

        var batteryCamera = makeCamera(name: "Battery")
        batteryCamera.telemetry = CameraTelemetry(batteryPercent: 83, batteryBars: 3)
        precondition(CarPlayCameraState(cameras: [batteryCamera]).cameras[0].detail == "Connected · 83%")
        batteryCamera.recordingState = .recording
        batteryCamera.telemetry?.isExternalPowerConnected = true
        precondition(CarPlayCameraState(cameras: [batteryCamera]).cameras[0].detail == "Recording · 83% · External Power")
        batteryCamera.telemetry?.batteryPercent = nil
        precondition(CarPlayCameraState(cameras: [batteryCamera]).cameras[0].detail == "Recording · Battery 3/4 · External Power")
        batteryCamera.connectionState = .disconnected
        precondition(CarPlayCameraState(cameras: [batteryCamera]).cameras[0].detail == "Not Connected",
                     "Disconnected cameras must not show cached battery readings")
        batteryCamera.connectionState = .connected
        batteryCamera.telemetry = CameraTelemetry(batteryPercent: -1, batteryBars: 5)
        precondition(CarPlayCameraState(cameras: [batteryCamera]).cameras[0].detail == "Recording",
                     "Invalid or unavailable battery readings must not invent a battery level")

        var eventCamera = makeCamera(name: "Events")
        eventCamera.telemetry = CameraTelemetry(batteryPercent: 83)
        let connectedEvents = CarPlayCameraState.eventSnapshot(cameras: [eventCamera, rear])
        let displayedBattery = CarPlayCameraState(cameras: [eventCamera, rear])
        eventCamera.telemetry = CameraTelemetry(
            batteryPercent: 82, isExternalPowerConnected: true, recordingElapsedSeconds: 10
        )
        eventCamera.rssi = -80
        precondition(CarPlayCameraState.eventSnapshot(cameras: [rear, eventCamera]) == connectedEvents,
                     "Power, elapsed time, RSSI, and list ordering must not trigger event redraws")
        precondition(CarPlayCameraState(cameras: [eventCamera, rear]) != displayedBattery,
                     "The periodic refresh must still pick up new power readings")
        for connectionState in [CameraConnectionState.connecting, .reconnecting, .disconnected, .failed("Lost connection")] {
            eventCamera.connectionState = connectionState
            precondition(CarPlayCameraState.eventSnapshot(cameras: [eventCamera, rear]) != connectedEvents,
                         "Connection changes must update immediately without a timer tick")
        }
        eventCamera.connectionState = .connected
        precondition(CarPlayCameraState.eventSnapshot(cameras: [eventCamera, rear]) == connectedEvents)
        eventCamera.recordingState = .starting
        precondition(CarPlayCameraState.eventSnapshot(cameras: [eventCamera, rear]) != connectedEvents,
                     "Starting must disable the control immediately, including starts from iPhone")
        eventCamera.recordingState = .stopped
        eventCamera.isSelected = false
        precondition(CarPlayCameraState.eventSnapshot(cameras: [eventCamera, rear]) != connectedEvents,
                     "Selection changes must stay in sync with iPhone immediately")
        eventCamera.isSelected = true
        eventCamera.currentMode = .photo
        precondition(CarPlayCameraState.eventSnapshot(cameras: [eventCamera, rear]) != connectedEvents,
                     "Recording readiness must update when the camera reports its mode")
        precondition(CarPlayCameraState.eventSnapshot(cameras: [rear]) != connectedEvents,
                     "Removing a paired camera must update the list immediately")

        front.isSelected = false
        let deselected = CarPlayCameraState(cameras: [front, rear])
        precondition(!deselected.canStart && !deselected.canStop)
        precondition(!deselected.canPerformRecordingAction)
        precondition(deselected.startDetail == "No cameras selected")
        front.isSelected = true
        rear.isSelected = true
        precondition(CarPlayCameraState(cameras: [front, rear]).startCameraIDs == [front.id, rear.id])

        for mode in [CaptureMode.photo, .timelapse, .slowMotion] {
            rear.currentMode = mode
            let state = CarPlayCameraState(cameras: [front, rear])
            precondition(!state.canStart, "Start must never capture photos or silently change modes")
            precondition(state.startCameraIDs.isEmpty, "Do not partially start a selected group")
            precondition(!state.canStop)
            precondition(!state.canPerformRecordingAction)
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
        precondition(mixed.recordingAction == .stop && mixed.canPerformRecordingAction,
                     "A mixed idle/recording selection must offer Stop, never Start")
        precondition(mixed.recordingActionTitle == "Stop")
        precondition(mixed.recordingActionDetail == "Stop 1 selected camera")
        rear.isSelected = false
        precondition(CarPlayCameraState(cameras: [front, rear]).canStart)
        precondition(CarPlayCameraState(cameras: [front, rear]).recordingAction == .start,
                     "The single button must follow the current selection")
        precondition(!CarPlayCameraState(cameras: [front, rear]).canStop, "Stop must not target deselected recordings")

        front.recordingState = .starting
        rear.isSelected = true
        let stopping = CarPlayCameraState(cameras: [front, rear])
        precondition(!stopping.canStart && stopping.stopCameraIDs == [front.id, rear.id], "Stop must cancel in-flight starts too")
        precondition(stopping.recordingAction == .stop && !stopping.canPerformRecordingAction)
        precondition(stopping.isStarting && stopping.recordingActionTitle == "Starting...",
                     "A mixed recording/starting group must wait for starts to settle, like iOS")
        front.connectionState = .reconnecting
        let reconnecting = CarPlayCameraState(cameras: [front])
        precondition(!reconnecting.canStart && reconnecting.canStop, "Keep the existing queued Stop path available during reconnect")
        precondition(reconnecting.recordingAction == .stop)
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

        front = makeCamera(name: "Front")
        front.recordingState = .starting
        let starting = CarPlayCameraState(cameras: [front])
        precondition(starting.recordingAction == .stop && !starting.canPerformRecordingAction,
                     "Disable the button while a selected camera is starting, like iOS")
        precondition(starting.isStarting && starting.recordingActionTitle == "Starting...")
        front.isSelected = false
        precondition(!CarPlayCameraState(cameras: [front]).isStarting,
                     "A deselected camera must not leave the recording button busy")
        front.isSelected = true
        front.recordingState = .recording
        let recording = CarPlayCameraState(cameras: [front])
        precondition(!recording.isStarting && recording.recordingActionTitle == "Stop" && recording.canPerformRecordingAction)
        front.recordingState = .stopped
        let stopped = CarPlayCameraState(cameras: [front])
        precondition(stopped.recordingAction == .start && stopped.canPerformRecordingAction,
                     "Stop must return to Start after recording finishes")

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
