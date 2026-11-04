import Foundation

@main
enum Insta360SDKSessionRegression {
    static func main() {
        let first = Insta360SDKSession(cameraID: UUID(), cameraName: "X5")
        let second = Insta360SDKSession(cameraID: UUID(), cameraName: "X6")
        var results: [CameraCommandResult] = []
        first.onCompletion = { results.append($0) }

        precondition(first.send(.startRecording, at: 0).status == .skipped)
        first.observe(state: .stopped, mode: .photo, at: 0, queryCommandID: nil)
        precondition(first.send(.startRecording, at: 0).status == .skipped)
        precondition(first.send(.setMode(.timelapse), at: 0).status == .skipped)
        precondition(first.send(.toggleRecording, at: 0).status == .skipped)
        precondition(first.send(.addHighlight, at: 0).status == .skipped)

        let mode = first.send(.setMode(.video), at: 1)
        precondition(mode.status == .queued)
        first.accepted(mode.id, error: nil, at: 1)
        precondition(results.isEmpty) // SDK acceptance does not confirm a mode change.
        first.observe(state: .stopped, mode: .video, at: 1, queryCommandID: nil)
        precondition(first.currentMode == .photo && results.isEmpty) // Pre-command reply ignored.
        first.observe(state: .stopped, mode: .video, at: 2, queryCommandID: mode.id)
        precondition(results.last?.id == mode.id && results.last?.status == .sent)

        let start = first.send(.startRecording, at: 3)
        precondition(start.status == .queued)
        precondition(first.send(.startRecording, at: 3).status == .skipped)
        first.observe(state: .recording, mode: .video, at: 3, queryCommandID: start.id)
        precondition(results.count == 1) // No confirmation until SDK accepts the command.
        first.accepted(start.id, error: nil, at: 3)
        first.observe(state: .recording, mode: .video, at: 2.5, queryCommandID: start.id)
        precondition(results.count == 1) // A reply observed before acceptance cannot confirm it.
        first.observe(state: .recording, mode: .video, at: 4, queryCommandID: start.id)
        precondition(results.last?.id == start.id && results.last?.status == .sent)
        precondition(second.recordingState == .unknown && second.pendingID == nil)
        precondition(first.send(.capturePhoto, at: 4).status == .skipped)
        precondition(first.send(.setMode(.photo), at: 4).status == .skipped)

        first.tick(at: 10)
        precondition(first.recordingState == .unknown && first.currentMode == nil)
        precondition(first.send(.startRecording, at: 10).status == .skipped)
        let stop = first.send(.stopRecording, at: 10)
        precondition(stop.status == .queued) // Explicit Stop remains safe with unknown status.
        first.accepted(stop.id, error: nil, at: 10)
        first.observe(state: .unknown, mode: .video, at: 11, queryCommandID: stop.id)
        precondition(first.pendingID == stop.id)
        first.observe(state: .stopped, mode: .video, at: 12, queryCommandID: stop.id)
        precondition(results.last?.id == stop.id && results.last?.status == .sent)

        let pendingStart = first.send(.startRecording, at: 13)
        let supersedingStop = first.send(.stopRecording, at: 14)
        precondition(results.last?.id == pendingStart.id && results.last?.status == .failed)
        precondition(supersedingStop.status == .queued)
        first.accepted(pendingStart.id, error: nil, at: 14)
        first.observe(state: .stopped, mode: .video, at: 14, queryCommandID: pendingStart.id)
        precondition(first.pendingID == supersedingStop.id)
        first.accepted(supersedingStop.id, error: nil, at: 14)
        first.observe(state: .stopped, mode: .video, at: 15, queryCommandID: supersedingStop.id)
        precondition(results.last?.id == supersedingStop.id && results.last?.status == .sent)

        let timeout = first.send(.startRecording, at: 16)
        first.accepted(timeout.id, error: nil, at: 16)
        first.tick(at: 41)
        precondition(results.last?.id == timeout.id && results.last?.status == .failed)
        let completedCount = results.count
        first.accepted(timeout.id, error: nil, at: 42)
        first.observe(state: .recording, mode: .video, at: 42, queryCommandID: timeout.id)
        precondition(first.recordingState == .unknown && results.count == completedCount)

        first.observe(state: .stopped, mode: .photo, at: 43, queryCommandID: nil)
        let photo = first.send(.capturePhoto, at: 43)
        first.accepted(photo.id, error: nil, at: 43)
        precondition(results.last?.status == .sent && first.recordingState == .stopped)
        let failedPhoto = first.send(.capturePhoto, at: 44)
        first.accepted(failedPhoto.id, error: NSError(domain: "Camera", code: 1), at: 44)
        precondition(results.last?.id == failedPhoto.id && results.last?.status == .failed)

        let disconnected = first.send(.stopRecording, at: 45)
        first.end()
        precondition(results.last?.id == disconnected.id && results.last?.status == .failed)
        first.accepted(disconnected.id, error: nil, at: 45)
        precondition(first.pendingID == nil && first.recordingState == .unknown)

        precondition(Insta360SDKSession.mode(photoSubMode: 0, videoSubMode: 100) == .photo)
        precondition(Insta360SDKSession.mode(photoSubMode: 100, videoSubMode: 0) == .video)
        precondition(Insta360SDKSession.mode(photoSubMode: 0, videoSubMode: 0) == nil)
        precondition(Insta360SDKSession.mode(photoSubMode: 100, videoSubMode: 100) == nil)
        precondition(Insta360SDKSession.mode(photoSubMode: nil, videoSubMode: 0) == nil)
        precondition(Insta360SDKSession.mode(photoSubMode: 0, videoSubMode: nil) == nil)
        precondition(Insta360SDKSession.mode(photoSubMode: 100, videoSubMode: 1) == nil)
        precondition(Insta360SDKSession.recordingState(rawValue: 0) == .stopped)
        precondition(Insta360SDKSession.recordingState(rawValue: 1) == .recording)
        precondition(Insta360SDKSession.recordingState(rawValue: 4) == .unknown)
        precondition(Insta360SDKSession.recordingState(rawValue: 999) == .unknown)
        precondition(CameraModel.insta360X5.supportsInsta360SDKPrototype)
        precondition(!CameraModel.insta360AcePro2.supportsInsta360SDKPrototype)
        precondition(!CameraModel.insta360Go3S.supportsInsta360SDKPrototype)

        let slowMode = Insta360SDKSession(cameraID: UUID(), cameraName: "X4")
        slowMode.observe(state: .stopped, mode: .video, at: 0, queryCommandID: nil)
        slowMode.tick(at: 6) // A delayed mode callback preserves the capture observation's age.
        precondition(slowMode.send(.startRecording, at: 6).status == .skipped)
        print("Insta360 SDK session regressions passed (synthetic; no camera validation).")
    }
}
