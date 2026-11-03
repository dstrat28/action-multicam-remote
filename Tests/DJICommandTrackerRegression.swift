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
        print("DJI command lifecycle checks passed: delivery deadlines, sequence/type matching, rejection, Stop priority, and disconnect cleanup.")
    }
}
