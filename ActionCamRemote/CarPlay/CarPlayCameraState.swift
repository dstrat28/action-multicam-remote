import Foundation

/// A value snapshot keeps CarPlay presentation and command eligibility in agreement.
struct CarPlayCameraState: Equatable {
    enum RecordingAction {
        case start
        case stop
    }

    struct Camera: Equatable {
        let id: UUID
        let name: String
        let detail: String
        let isSelected: Bool
        let canToggleSelection: Bool
    }

    let cameras: [Camera]
    let startCameraIDs: [UUID]
    let stopCameraIDs: [UUID]
    let startDetail: String
    let isStarting: Bool

    var canStart: Bool { !startCameraIDs.isEmpty }
    var canStop: Bool { !stopCameraIDs.isEmpty }

    // Never offer Record while selected recordings are active or starting.
    var recordingAction: RecordingAction { canStop ? .stop : .start }
    var canPerformRecordingAction: Bool { !isStarting && (canStart || canStop) }
    var recordingActionTitle: String { isStarting ? "Starting..." : (canStop ? "Stop" : "Record") }
    var recordingActionDetail: String { isStarting ? "Starting selected cameras" : (canStop ? stopDetail : startDetail) }

    var stopDetail: String {
        stopCameraIDs.isEmpty
            ? "No selected cameras are recording"
            : "Stop \(stopCameraIDs.count) selected camera\(stopCameraIDs.count == 1 ? "" : "s")"
    }

    init(cameras: [DiscoveredCamera]) {
        self.init(cameras: cameras, includesPowerDetails: true)
    }

    /// Discrete UI changes update immediately. Power readings and list reordering
    /// from signal updates must not turn telemetry packets into frequent redraws.
    static func eventSnapshot(cameras: [DiscoveredCamera]) -> Self {
        Self(
            cameras: cameras.sorted { $0.id.uuidString < $1.id.uuidString },
            includesPowerDetails: false
        )
    }

    private init(cameras: [DiscoveredCamera], includesPowerDetails: Bool) {
        let paired = cameras.filter(\.isPaired)
        self.cameras = paired.map { camera in
            Camera(
                id: camera.id,
                name: camera.displayName,
                detail: Self.detail(for: camera, includesPowerDetails: includesPowerDetails),
                isSelected: camera.isSelected,
                canToggleSelection: camera.canSelectForBatch || camera.isSelected
            )
        }

        let selected = paired.filter(\.isSelected)
        isStarting = selected.contains { $0.canSelectForBatch && $0.recordingState == .starting }
        // Never call the phone's photo-aware group shutter from CarPlay. Requiring
        // confirmed Video mode also protects cameras whose remote uses a toggle.
        let ready = selected.filter {
            $0.canSelectForBatch
                && $0.currentMode == .video
                && ($0.recordingState == .ready || $0.recordingState == .stopped)
        }
        startCameraIDs = !selected.isEmpty && ready.count == selected.count
            ? selected.map(\.id) : []
        stopCameraIDs = selected.filter {
            $0.supportsBatchRecord
                && !$0.isInPhotoMode
                && ($0.recordingState == .recording || $0.recordingState == .starting)
        }.map(\.id)

        if paired.isEmpty {
            startDetail = "Pair cameras before your drive"
        } else if selected.isEmpty {
            startDetail = "No cameras selected"
        } else if selected.contains(where: { !$0.canSelectForBatch }) {
            startDetail = "Waiting for selected cameras to connect"
        } else if selected.contains(where: { $0.recordingState == .starting }) {
            startDetail = "Starting selected cameras"
        } else if selected.contains(where: { $0.recordingState == .recording }) {
            startDetail = "Stop selected recordings before starting"
        } else if selected.contains(where: { $0.currentMode != .video }) {
            startDetail = "Set cameras to Video before your drive"
        } else if ready.count != selected.count {
            startDetail = "Waiting for camera recording status"
        } else {
            startDetail = "Record on \(selected.count) selected camera\(selected.count == 1 ? "" : "s")"
        }
    }

    private static func detail(for camera: DiscoveredCamera, includesPowerDetails: Bool) -> String {
        guard camera.isSupportedByApp else { return "Unsupported" }
        switch camera.connectionState {
        case .connected:
            var details = [camera.recordingState == .recording ? "Recording" : "Connected"]
            if includesPowerDetails, let telemetry = camera.telemetry {
                if let percent = telemetry.batteryPercent, (0...100).contains(percent) {
                    details.append("\(percent)%")
                } else if let bars = telemetry.batteryBars, (0...4).contains(bars) {
                    details.append("Battery \(bars)/4")
                }
                if telemetry.isExternalPowerConnected == true {
                    details.append("External Power")
                }
            }
            return details.joined(separator: " · ")
        case .connecting, .reconnecting:
            return "Connecting"
        case .discovered, .disconnected, .failed:
            return "Not Connected"
        case .unsupported:
            return "Unsupported"
        }
    }
}
