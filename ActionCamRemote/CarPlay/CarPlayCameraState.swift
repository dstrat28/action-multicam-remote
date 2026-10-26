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

    var canStart: Bool { !startCameraIDs.isEmpty }
    var canStop: Bool { !stopCameraIDs.isEmpty }

    // A mixed selection must offer Stop until all selected recordings are idle.
    var recordingAction: RecordingAction { canStop ? .stop : .start }
    var canPerformRecordingAction: Bool { canStart || canStop }
    var recordingActionTitle: String { canStop ? "Stop Recording" : "Start Recording" }
    var recordingActionDetail: String { canStop ? stopDetail : startDetail }
    var recordingActionImageName: String { canStop ? "stop.circle" : "record.circle" }

    var stopDetail: String {
        stopCameraIDs.isEmpty
            ? "No selected cameras are recording"
            : "Stop \(stopCameraIDs.count) selected camera\(stopCameraIDs.count == 1 ? "" : "s")"
    }

    init(cameras: [DiscoveredCamera]) {
        let paired = cameras.filter(\.isPaired)
        self.cameras = paired.map { camera in
            Camera(
                id: camera.id,
                name: camera.displayName,
                detail: Self.detail(for: camera),
                isSelected: camera.isSelected,
                canToggleSelection: camera.canSelectForBatch || camera.isSelected
            )
        }

        let selected = paired.filter(\.isSelected)
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
            startDetail = "Select connected cameras below"
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

    private static func detail(for camera: DiscoveredCamera) -> String {
        let selection = camera.isSelected ? "Selected" : "Not selected"
        let status: String
        if !camera.isConnected {
            status = camera.displayConnectionLabel
        } else if camera.isInPhotoMode {
            status = "Photo mode"
        } else {
            switch camera.recordingState {
            case .recording: status = "Recording"
            case .starting: status = "Starting"
            case .unknown, .unavailable: status = "Recording status unknown"
            case .ready, .stopped:
                status = camera.currentMode == .video ? "Ready" : "Video mode required"
            }
        }
        return "\(selection) · \(status)"
    }
}
