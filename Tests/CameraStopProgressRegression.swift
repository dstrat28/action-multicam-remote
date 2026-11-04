import Foundation

@main
enum CameraStopProgressRegression {
    static func main() {
        var x3 = DiscoveredCamera(id: UUID(), name: "X3 ABC123", brand: .insta360, model: .insta360X3,
            rssi: -40, capabilities: [.record, .mode, .status], connectionState: .connected,
            recordingState: .unknown, isPaired: true, isSelected: true, lastSeen: Date())
        precondition(!x3.isTargetForStopAll, "Unknown GPS Remote status cannot authorize a shutter toggle")
        x3.insta360UsesSDK = true
        precondition(x3.isTargetForStopAll, "Siri Stop must reach SDK cameras even after capture status expires")
        x3.connectionState = .disconnected
        precondition(!x3.isTargetForStopAll, "Do not newly reconnect an unknown-state camera to issue Stop")
        x3.connectionState = .connected
        for state in [CameraRecordingState.stopped, .ready, .unavailable] {
            x3.recordingState = state
            precondition(!x3.isTargetForStopAll)
        }
        for usesSDK in [false, true] {
            x3.insta360UsesSDK = usesSDK
            for state in [CameraRecordingState.recording, .starting] {
                x3.recordingState = state
                precondition(x3.isTargetForStopAll, "Preserve existing recording/starting Stop targets")
            }
        }

        let modeStarted = Date()
        var mode = CameraCommandResult(cameraID: x3.id, cameraName: x3.name, command: .setMode(.video),
            status: .queued, message: "Waiting for SDK", timestamp: modeStarted)
        precondition(CameraRecordingStartPolicy.sdkModePreparation(result: mode, currentMode: .photo,
            now: modeStarted.addingTimeInterval(1.6)) == .waiting)
        precondition(CameraRecordingStartPolicy.sdkModePreparation(result: mode, currentMode: nil,
            now: modeStarted.addingTimeInterval(24)) == .waiting)
        precondition(CameraRecordingStartPolicy.sdkModePreparation(result: mode, currentMode: .photo,
            now: modeStarted.addingTimeInterval(30)) == .failed)
        mode.status = .sent
        precondition(CameraRecordingStartPolicy.sdkModePreparation(result: mode, currentMode: .video,
            now: modeStarted.addingTimeInterval(8)) == .ready)
        mode.status = .failed
        precondition(CameraRecordingStartPolicy.sdkModePreparation(result: mode, currentMode: .video,
            now: modeStarted.addingTimeInterval(8)) == .failed)

        let front = UUID(), rear = UUID()
        func stop(_ cameraID: UUID, status: CameraCommandStatus = .sent) -> CameraCommandResult {
            CameraCommandResult(cameraID: cameraID, cameraName: "Test camera", command: .stopRecording,
                status: status, message: "Stop requested", timestamp: Date())
        }
        var progress = CameraStopProgress()
        precondition(progress.isEmpty)
        let first = stop(front)
        progress.begin(front, at: 0, timeout: 15)
        progress.attach(first)
        precondition(progress.contains(front), "A sent/acknowledged Stop is still awaiting state confirmation")
        for state in [CameraRecordingState.recording, .starting, .unknown] {
            precondition(!progress.observe(front, state: state, canClearActiveRecording: true))
            precondition(progress.contains(front))
        }
        precondition(!progress.observe(front, state: .stopped, canClearActiveRecording: false))
        let duplicate = stop(front, status: .skipped)
        progress.attach(duplicate)
        precondition(!progress.finish(front, matching: duplicate.id), "Rejected duplicate must not clear the active Stop")
        precondition(progress.observe(front, state: .stopped, canClearActiveRecording: true))
        precondition(progress.isEmpty)

        // Late failure from the old command cannot clear a new queued request,
        // either before or after its new transport result has been attached.
        progress.begin(front, at: 20, timeout: 15)
        precondition(!progress.finish(front, matching: first.id))
        let next = stop(front, status: .queued)
        progress.attach(next)
        precondition(!progress.finish(front, matching: first.id))
        precondition(progress.finish(front, matching: next.id), "Current failure ends only its own progress")
        progress.begin(front, at: 40, timeout: 15)
        let rejected = stop(front, status: .failed)
        progress.attach(rejected)
        precondition(progress.finish(front, matching: rejected.id), "Immediate rejection must not leave a spinner")

        progress.begin(front, at: 60, timeout: 15)
        progress.begin(rear, at: 60, timeout: 30)
        precondition(progress.observe(front, state: .ready, canClearActiveRecording: true))
        precondition(!progress.isEmpty && progress.contains(rear), "Group Stop waits for the remaining camera")
        progress.begin(rear, at: 70, timeout: 30)
        precondition(progress.expire(at: 89.9).isEmpty)
        precondition(progress.expire(at: 90) == [rear], "Repeated requests do not extend the confirmation deadline")
        precondition(progress.isEmpty, "Timeout clears progress without synthesizing a Stopped camera state")
        progress.begin(front, at: 100, timeout: 15)
        precondition(progress.finish(front), "Disconnect or a superseding capture clears progress")
        precondition(progress.expire(at: 120).isEmpty)
        print("Stop progress checks passed: confirmation, unknown state, rejected duplicates, late results, failures, independent cameras, deadlines, and cleanup.")
    }
}
