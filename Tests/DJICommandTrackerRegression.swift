import Foundation

@main
enum DJICommandTrackerRegression {
    static func main() {
        func result(_ command: CameraCommand) -> CameraCommandResult {
            CameraCommandResult(cameraID: UUID(), cameraName: "DJI test", command: command,
                status: .sent, message: "Queued", timestamp: Date())
        }
        var tracker = DJICommandTracker()
        let start = result(.startRecording)
        tracker.register(sequence: 100, commandID: 3, result: start, at: 0)
        precondition(tracker.acknowledge(sequence: 100, commandID: 3, returnCode: 0, at: 1) == nil)
        precondition(tracker.canSend(sequence: 100, at: 4.9))
        precondition(!tracker.canSend(sequence: 100, at: 5))
        precondition(tracker.expire(at: 5).first?.result.id == start.id)
        precondition(!tracker.canSend(sequence: 100, at: 6), "An expired queued Start must never flush later")

        tracker.register(sequence: 101, commandID: 3, result: start, at: 10)
        tracker.didSend(sequence: 101, at: 14)
        precondition(tracker.acknowledge(sequence: 101, commandID: 4, returnCode: 0, at: 14.1) == nil)
        precondition(tracker.acknowledge(sequence: 102, commandID: 3, returnCode: 0, at: 14.1) == nil)
        precondition(tracker.expire(at: 16.9).isEmpty, "ACK deadline begins at delivery")
        let accepted = tracker.acknowledge(sequence: 101, commandID: 3, returnCode: 0, at: 16.9)
        precondition(accepted?.id == start.id && accepted?.status == .sent)
        precondition(tracker.acknowledge(sequence: 101, commandID: 3, returnCode: 0, at: 17) == nil)

        tracker.register(sequence: 103, commandID: 3, result: start, at: 20)
        tracker.didSend(sequence: 103, at: 20)
        precondition(tracker.acknowledge(sequence: 103, commandID: 3, returnCode: 0, at: 23) == nil)
        precondition(tracker.expire(at: 23).count == 1)
        tracker.register(sequence: 104, commandID: 4, result: result(.setMode(.video)), at: 30)
        tracker.didSend(sequence: 104, at: 30)
        precondition(tracker.acknowledge(sequence: 104, commandID: 4, returnCode: 2, at: 31)?.status == .failed)

        tracker.register(sequence: 105, commandID: 3, result: start, at: 40)
        tracker.register(sequence: 106, commandID: 3, result: result(.stopRecording), at: 40)
        precondition(tracker.cancelUnsentStarts().map(\.sequence) == [105])
        precondition(!tracker.canSend(sequence: 105, at: 41) && tracker.canSend(sequence: 106, at: 41))
        tracker.didSend(sequence: 106, at: 41)
        precondition(tracker.cancelUnsentStarts().isEmpty)
        precondition(tracker.removeAll().count == 1 && tracker.isEmpty)
        precondition(tracker.acknowledge(sequence: 106, commandID: 3, returnCode: 0, at: 42) == nil)
        tracker.register(sequence: 200, commandID: 3, result: start, at: 50)
        tracker.didSend(sequence: 200, at: 50)
        tracker.register(sequence: 201, commandID: 3, result: result(.stopRecording), at: 50.1)
        tracker.didSend(sequence: 201, at: 50.1)
        precondition(tracker.acknowledge(sequence: 201, commandID: 3, returnCode: 0, at: 50.2) != nil)
        precondition(tracker.isLatestCapture(sequence: 201))
        precondition(tracker.acknowledge(sequence: 200, commandID: 3, returnCode: 0, at: 50.3) != nil)
        precondition(!tracker.isLatestCapture(sequence: 200),
                     "A late Start acknowledgement must not restore Starting after a newer Stop")
        _ = tracker.removeAll()
        precondition(!tracker.isLatestCapture(sequence: 201))
        checkStopFailureRecovery()
        print("DJI command lifecycle checks passed: deadlines, response correlation, Stop recovery, supersession, and disconnect cleanup.")
    }

    private static func checkStopFailureRecovery() {
        let id = UUID()
        func result(_ command: CameraCommand, status: CameraCommandStatus = .sent) -> CameraCommandResult {
            CameraCommandResult(cameraID: id, cameraName: "DJI test", command: command,
                status: status, message: "Requested", timestamp: Date())
        }
        func action(_ failure: CameraCommandResult, brand: CameraBrand = .dji,
                    results: [CameraCommandResult]? = nil, pendingStart: Bool = false,
                    disconnected: Bool = false) -> CameraCommandFailureAction {
            CameraCommandFailurePolicy.action(for: failure, brand: brand, among: results ?? [failure],
                hasPendingExplicitStart: pendingStart, userDisconnected: disconnected)
        }

        for wasSent in [false, true] {
            var tracker = DJICommandTracker()
            let stop = result(.stopRecording)
            tracker.register(sequence: 1, commandID: 3, result: stop, at: 0)
            if wasSent { tracker.didSend(sequence: 1, at: 0) }
            let expired = tracker.expire(at: wasSent ? 3 : 5)
            precondition(expired.count == 1)
            let failure = tracker.completed(expired[0], status: .failed, message: "Timed out")
            precondition(failure.id == stop.id && failure.command == .stopRecording)
            precondition(action(failure) == .reconnectToStop,
                "Queued and delivered Stop timeouts must preserve Stop for reconnect")
            precondition(!tracker.canSend(sequence: 1, at: 10), "Transport must not replay the expired write")
        }

        var tracker = DJICommandTracker()
        tracker.register(sequence: 2, commandID: 3, result: result(.stopRecording), at: 0)
        tracker.didSend(sequence: 2, at: 0)
        let rejected = tracker.acknowledge(sequence: 2, commandID: 3, returnCode: 1, at: 1)!
        precondition(action(rejected) == .reconnectToStop)
        tracker.register(sequence: 3, commandID: 3, result: result(.stopRecording), at: 0)
        let abandoned = tracker.removeAll()[0]
        precondition(action(tracker.completed(abandoned, status: .failed, message: "Disconnected")) == .reconnectToStop)

        let failure = result(.stopRecording, status: .failed)
        for newerCommand in [CameraCommand.startRecording, .capturePhoto, .toggleRecording, .stopRecording] {
            precondition(action(failure, results: [result(newerCommand), failure]) == .ignore,
                "A late Stop failure cannot replace a newer capture intent")
        }
        precondition(action(failure, pendingStart: true) == .ignore,
            "An explicit Start preparing Video mode supersedes Stop before its result exists")
        precondition(action(failure, disconnected: true) == .ignore,
            "A disconnect callback must not undo the user's Disconnect request")
        var otherCamera = result(.startRecording)
        otherCamera.cameraID = UUID()
        precondition(action(failure, results: [otherCamera, failure]) == .reconnectToStop)
        precondition(action(failure, results: []) == .ignore)

        for brand in [CameraBrand.gopro, .insta360, .unknown] {
            precondition(action(failure, brand: brand) == .report, "Only DJI explicit Stop is eligible for recovery")
        }
        for command in [CameraCommand.startRecording, .capturePhoto, .toggleRecording, .setMode(.video)] {
            precondition(action(result(command, status: .failed)) != .reconnectToStop,
                "Uncertain Start/photo/toggle/mode commands must never replay")
        }
        for status in [CameraCommandStatus.sent, .queued, .skipped, .unsupported] {
            precondition(action(result(.stopRecording, status: status)) != .reconnectToStop,
                "Accepted or cancelled Stop results must not start recovery")
        }
    }
}
