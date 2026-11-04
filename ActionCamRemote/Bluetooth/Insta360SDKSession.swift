import Foundation

/// Vendor-independent command safety and confirmation, exercised on the host.
final class Insta360SDKSession {
    private struct Pending {
        var result: CameraCommandResult
        var deadline: TimeInterval
        var acceptedAt: TimeInterval?
    }

    let cameraID: UUID
    let cameraName: String
    var onCompletion: ((CameraCommandResult) -> Void)?
    private(set) var recordingState: CameraRecordingState = .unknown
    private(set) var currentMode: CaptureMode?
    private(set) var statusAt: TimeInterval?
    private var pending: Pending?
    private(set) var observationToken = UUID()
    var pendingID: UUID? { pending?.result.id }
    var isBusy: Bool { pending != nil }

    init(cameraID: UUID, cameraName: String) {
        self.cameraID = cameraID
        self.cameraName = cameraName
    }

    // Only explicit, documented normal capture modes are exposed by this prototype.
    static func mode(photoSubMode: UInt32?, videoSubMode: UInt32?) -> CaptureMode? {
        // The inactive family is 100; normal Photo and Video are both 0.
        // Both fields must have been returned successfully to resolve the mode.
        if photoSubMode == 0, videoSubMode == 100 { return .photo }
        if photoSubMode == 100, videoSubMode == 0 { return .video }
        return nil
    }

    static func recordingState(rawValue: UInt) -> CameraRecordingState {
        switch rawValue {
        case 0: .stopped
        case 1, 2, 7, 9, 12, 13, 17, 18, 20, 21, 22: .recording
        default: .unknown
        }
    }

    func send(_ command: CameraCommand, at now: TimeInterval) -> CameraCommandResult {
        tick(at: now)
        if command == .stopRecording, let previous = pending?.result.command, previous != .stopRecording {
            finish(.failed, "\(previous.label) confirmation was superseded by explicit Stop; the command will not be repeated.")
        }
        let reason: String?
        if isBusy {
            reason = "Waiting for the previous SDK command to finish."
        } else {
            let fresh = statusAt.map { now - $0 <= 5 } == true
            switch command {
            case .startRecording:
                reason = fresh && recordingState == .stopped && currentMode == .video
                    ? nil : "SDK Start requires a fresh stopped status in normal Video mode."
            case .capturePhoto:
                reason = fresh && recordingState == .stopped && currentMode == .photo
                    ? nil : "SDK Photo requires a fresh stopped status in normal Photo mode."
            case .setMode(let mode):
                reason = fresh && recordingState == .stopped && (mode == .video || mode == .photo)
                    ? nil : "SDK mode changes require a fresh stopped status and normal Video or Photo mode."
            case .stopRecording:
                reason = nil // Explicit Stop is safe even when status is unknown.
            default:
                reason = "This command is not supported by the Insta360 SDK prototype."
            }
        }
        let result = CameraCommandResult(cameraID: cameraID, cameraName: cameraName, command: command,
            status: reason == nil ? .queued : .skipped,
            message: reason ?? "SDK command queued; waiting for camera confirmation.", timestamp: Date())
        if reason == nil {
            pending = Pending(result: result, deadline: now + 25)
            observationToken = UUID()
        }
        return result
    }

    func accepted(_ id: UUID, error: Error?, at now: TimeInterval) {
        guard pendingID == id else { return }
        tick(at: now)
        guard pendingID == id else { return }
        if let error {
            let isCapture: Bool
            switch pending?.result.command {
            case .startRecording, .stopRecording, .capturePhoto: isCapture = true
            default: isCapture = false
            }
            if isCapture {
                recordingState = .unknown
                currentMode = nil
                statusAt = nil
            }
            finish(.failed, isCapture
                ? "SDK capture outcome is unconfirmed: \(error.localizedDescription). Check the camera; no retry was sent."
                : "SDK command failed: \(error.localizedDescription)")
        } else if pending?.result.command == .capturePhoto {
            finish(.sent, "SDK photo request completed. Verify the photo on the camera.")
        } else {
            pending?.acceptedAt = now
            observationToken = UUID()
        }
    }

    @discardableResult
    func observe(state: CameraRecordingState, mode: CaptureMode?, at now: TimeInterval,
                 queryCommandID: UUID?, queryToken: UUID) -> Bool {
        guard queryToken == observationToken,
              queryCommandID == pendingID else { return false }
        recordingState = state
        currentMode = mode
        statusAt = now
        tick(at: now)
        guard let pending, let acceptedAt = pending.acceptedAt, now >= acceptedAt,
              pending.result.id == queryCommandID else { return true }
        let confirmed: Bool
        switch pending.result.command {
        case .startRecording: confirmed = state == .recording && mode == .video
        case .stopRecording: confirmed = state == .stopped
        case .setMode(let target): confirmed = mode == target && state == .stopped
        default: confirmed = false
        }
        if confirmed { finish(.sent, "SDK camera status confirmed \(pending.result.command.label).") }
        return true
    }

    func tick(at now: TimeInterval) {
        if let statusAt, now - statusAt > 5 {
            recordingState = .unknown
            currentMode = nil
            self.statusAt = nil
        }
        if let pending, now >= pending.deadline {
            finish(.failed, "SDK command confirmation timed out. Check the camera; the command was not repeated.")
        }
    }

    func end() {
        finish(.failed, "SDK disconnected before the command was confirmed. No command will be replayed.")
        recordingState = .unknown
        currentMode = nil
        statusAt = nil
        observationToken = UUID()
    }

    private func finish(_ status: CameraCommandStatus, _ message: String) {
        guard var result = pending?.result else { return }
        pending = nil
        observationToken = UUID()
        result.status = status
        result.message = message
        onCompletion?(result)
    }
}
