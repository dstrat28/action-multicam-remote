import Foundation

@main
enum GoProCommandQueueRegression {
    static func main() {
        for command in [CameraCommand.startRecording, .capturePhoto, .toggleRecording] {
            var queue = GoProCommandQueue<String>()
            queue.deferUntilIdle(command)
            precondition(queue.takeDeferredCommand(isBusy: true) == nil)
            queue.prepare(for: .stopRecording)
            precondition(queue.takeDeferredCommand(isBusy: false) == nil)
        }

        var queue = GoProCommandQueue<String>()
        queue.append("active start", command: .startRecording)
        let activeWrite = queue.removeFirst()
        queue.append("query")
        queue.append("unsent start", command: .startRecording)
        queue.append("photo", command: .capturePhoto)
        queue.append("toggle", command: .toggleRecording)
        queue.append("mode", command: .setMode(.video))
        queue.prepare(for: .stopRecording)
        queue.append("stop", command: .stopRecording)
        precondition(activeWrite == "active start")
        precondition(queue.removeFirst() == "query")
        precondition(queue.removeFirst() == "mode")
        precondition(queue.removeFirst() == "stop")
        precondition(queue.isEmpty)

        // New capture intent after Stop remains eligible; it is not a blanket
        // block on future starts or on unrelated deferred settings/mode changes.
        queue.prepare(for: .startRecording)
        queue.deferUntilIdle(.startRecording)
        precondition(queue.takeDeferredCommand(isBusy: false) == .startRecording)
        precondition(queue.takeDeferredCommand(isBusy: false) == nil)
        queue.deferUntilIdle(.setMode(.video))
        queue.prepare(for: .stopRecording)
        precondition(queue.takeDeferredCommand(isBusy: false) == .setMode(.video))

        // Disconnect removes both kinds of work, so neither crosses sessions.
        queue.deferUntilIdle(.startRecording)
        queue.append("old start", command: .startRecording)
        precondition(queue.contains { $0 == "old start" })
        queue.removeAll()
        precondition(queue.isEmpty)
        precondition(queue.takeDeferredCommand(isBusy: false) == nil)
        let now = Date(timeIntervalSince1970: 100)
        var delayed = GoProCommandQueue<String>()
        delayed.prepare(for: .startRecording, at: now)
        delayed.deferUntilIdle(.startRecording)
        precondition(delayed.remainingStartLifetime(at: now.addingTimeInterval(9)) == 1)
        precondition(delayed.takeDeferredCommand(isBusy: false) == .startRecording)
        delayed.append("query")
        delayed.append("delayed start", command: .startRecording)
        precondition(delayed.removeFirstEntry().command == nil)
        precondition(delayed.hasPendingStart)
        precondition(!delayed.expireUnsentStart(at: now.addingTimeInterval(9.9)))
        precondition(delayed.expireUnsentStart(at: now.addingTimeInterval(10)))
        precondition(delayed.isEmpty)
        precondition(delayed.takeDeferredCommand(isBusy: false) == nil)

        delayed.prepare(for: .startRecording, at: now)
        delayed.deferUntilIdle(.startRecording)
        precondition(delayed.expireUnsentStart(at: now.addingTimeInterval(12)))
        precondition(delayed.takeDeferredCommand(isBusy: false) == nil)

        delayed.prepare(for: .startRecording, at: now)
        delayed.append("timely start", command: .startRecording)
        precondition(delayed.removeFirstEntry().command == .startRecording)
        precondition(!delayed.expireUnsentStart(at: now.addingTimeInterval(12)))

        delayed.prepare(for: .startRecording, at: now)
        delayed.append("old start", command: .startRecording)
        delayed.prepare(for: .startRecording, at: now.addingTimeInterval(9))
        delayed.append("new start", command: .startRecording)
        precondition(!delayed.expireUnsentStart(at: now.addingTimeInterval(12)))
        precondition(delayed.removeFirst() == "new start")
        precondition(delayed.isEmpty)

        delayed.prepare(for: .startRecording, at: now)
        delayed.append("unsent start", command: .startRecording)
        delayed.prepare(for: .stopRecording, at: now.addingTimeInterval(1))
        delayed.append("stop", command: .stopRecording)
        precondition(!delayed.expireUnsentStart(at: now.addingTimeInterval(20)))
        precondition(delayed.removeFirst() == "stop")

        delayed.prepare(for: .startRecording, at: now)
        delayed.append("clock change", command: .startRecording)
        precondition(delayed.expireUnsentStart(at: now.addingTimeInterval(-1)))

        for brand in [CameraBrand.gopro, .dji] {
            precondition(CameraRecordingStartPolicy.shouldDispatch(
                brand: brand, recordingState: .recording, hasPendingExplicitStart: true
            ))
            precondition(!CameraRecordingStartPolicy.shouldDispatch(
                brand: brand, recordingState: .recording, hasPendingExplicitStart: false
            ))
        }
        precondition(!CameraRecordingStartPolicy.shouldDispatch(
            brand: .insta360, recordingState: .recording, hasPendingExplicitStart: true
        ))
        precondition(CameraRecordingStartPolicy.shouldDispatch(
            brand: .insta360, recordingState: .unknown, hasPendingExplicitStart: true
        ))

        let cameraID = UUID()
        func result(_ command: CameraCommand) -> CameraCommandResult {
            .init(cameraID: cameraID, cameraName: "GoPro", command: command,
                  status: .queued, message: "Queued", timestamp: now)
        }
        let start = result(.startRecording)
        precondition(CameraRecordingStartPolicy.isLatestCaptureResult(start, among: [result(.addHighlight), start]))
        precondition(!CameraRecordingStartPolicy.isLatestCaptureResult(start, among: [result(.stopRecording), start]))
        precondition(!CameraRecordingStartPolicy.isLatestCaptureResult(start, among: [result(.startRecording), start]))
        print("GoPro command queue regression checks passed.")
    }
}
