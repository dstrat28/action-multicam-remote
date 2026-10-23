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
        print("GoPro command queue regression checks passed.")
    }
}
