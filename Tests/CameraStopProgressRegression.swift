import Foundation

@main
enum CameraStopProgressRegression {
    static func main() async {
        var x3 = DiscoveredCamera(id: UUID(), name: "X3 ABC123", brand: .insta360, model: .insta360X3,
            rssi: -40, capabilities: [.record, .mode, .status], connectionState: .connected,
            recordingState: .unknown, isPaired: true, isSelected: true, lastSeen: Date())
        precondition(!x3.isTargetForStopAll, "Unknown GPS Remote status cannot authorize a shutter toggle")
        x3.insta360UsesSDK = true
        precondition(x3.isTargetForStopAll, "Siri Stop must reach SDK cameras even after capture status expires")
        var pendingReplay: Set<UUID> = [x3.id]
        precondition(!CameraStopReplayPolicy.consumeIfReady(camera: x3, detail: nil, pending: &pendingReplay))
        precondition(CameraStopReplayPolicy.consumeIfReady(camera: x3, detail: "Insta360 SDK Bluetooth ready", pending: &pendingReplay))
        precondition(!CameraStopReplayPolicy.consumeIfReady(camera: x3, detail: "Insta360 SDK Bluetooth ready", pending: &pendingReplay))
        x3.insta360UsesSDK = false
        pendingReplay.insert(x3.id)
        precondition(!CameraStopReplayPolicy.consumeIfReady(camera: x3, detail: "Insta360 GPS Remote connected", pending: &pendingReplay))
        var gopro = x3
        gopro.brand = .gopro
        gopro.model = .goproHero13Black
        precondition(!CameraStopReplayPolicy.consumeIfReady(camera: gopro, detail: "BLE connected", pending: &pendingReplay))
        precondition(CameraStopReplayPolicy.consumeIfReady(camera: gopro, detail: "Open GoPro protocol ready", pending: &pendingReplay))
        precondition(!CameraStopReplayPolicy.consumeIfReady(camera: gopro, detail: "Open GoPro protocol ready", pending: &pendingReplay))
        x3.insta360UsesSDK = true
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
        precondition(CameraStopProgress.confirmationTimeout(for: gopro) == 15)
        x3.insta360UsesSDK = true
        precondition(CameraStopProgress.confirmationTimeout(for: x3) == 25)
        var sdkProgress = CameraStopProgress()
        sdkProgress.begin(x3.id, at: 0, timeout: CameraStopProgress.confirmationTimeout(for: x3))
        precondition(sdkProgress.expire(at: 15).isEmpty,
            "SDK Stop must not report failure while its 25-second confirmation is still pending")
        precondition(sdkProgress.expire(at: 24.9).isEmpty)
        precondition(sdkProgress.expire(at: 25) == [x3.id])
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

        var nano = DiscoveredCamera(id: front, name: "Nano", brand: .dji, model: .djiOsmoNano,
            rssi: -40, capabilities: [.record, .mode, .status], connectionState: .connected,
            recordingState: .recording, isPaired: true, isSelected: true, lastSeen: Date())
        precondition(CameraStopProgress.confirmationTimeout(for: nano) == 15)
        progress.begin(front, at: 200, timeout: CameraStopProgress.confirmationTimeout(for: nano))
        let missingReply = stop(front)
        progress.attach(missingReply)
        precondition(progress.showsRecordingStatus(for: nano))
        nano.recordingState = .unknown
        precondition(progress.showsRecordingStatus(for: nano), "Pending Stop must not flash Connected on unknown status")
        precondition(progress.expire(at: 202.9).isEmpty)
        precondition(progress.expire(at: 203).isEmpty, "Nano must not offer Record merely because three seconds elapsed")
        precondition(progress.contains(front))
        precondition(progress.expire(at: 214.9).isEmpty)
        precondition(progress.expire(at: 215) == [front])
        precondition(!progress.contains(front), "A missing Nano confirmation must still have a bounded deadline")
        precondition(progress.isUnconfirmed(for: nano), "Missing confirmation must stay distinct from Stopped")
        precondition(nano.recordingState == .unknown, "UI expiry must not synthesize a camera state")
        precondition(!progress.finish(front, matching: missingReply.id), "Late command outcomes cannot erase an unconfirmed Stop")
        precondition(!progress.observe(front, state: .recording, canClearActiveRecording: true))
        precondition(!progress.observe(front, state: .stopped, canClearActiveRecording: false))
        precondition(progress.isUnconfirmed(for: nano))
        precondition(nano.primaryRecordCommand == .startRecording,
            "A missing confirmation cannot indefinitely block a new explicit action")
        precondition(progress.observe(front, state: .stopped, canClearActiveRecording: true), "Late trusted confirmation must clear the warning")
        precondition(!progress.isUnconfirmed(front))

        // GPS Remote cannot explicitly confirm Stop. Its presentation returns
        // to Connected while its underlying recording state remains unknown.
        x3.insta360UsesSDK = false
        x3.recordingState = .recording
        progress.begin(x3.id, at: 210, timeout: CameraStopProgress.confirmationTimeout(for: x3))
        let remoteStop = stop(x3.id)
        progress.attach(remoteStop)
        precondition(progress.didSend(remoteStop, for: x3, at: 210))
        precondition(!progress.showsRecordingStatus(for: x3))
        x3.recordingState = .unknown
        precondition(progress.markUnconfirmed(x3.id))
        precondition(!progress.contains(x3.id))
        precondition(!progress.isUnconfirmed(for: x3), "Expected GPS Remote silence must not show a missing-confirmation warning")
        precondition(!progress.showsRecordingStatus(for: x3))
        precondition(x3.recordingState == .unknown)
        precondition(x3.primaryRecordCommand == .startRecording, "Unknown GPS Remote status must still allow an explicit new Record action")
        precondition(progress.finish(x3.id), "A new capture or disconnect must clear GPS Remote presentation state")
        x3.recordingState = .recording
        precondition(progress.showsRecordingStatus(for: x3), "A later recording must appear red again")

        precondition(CameraStopProgress.confirmationTimeout(for: x3) == 5)
        progress.begin(x3.id, at: 215, timeout: CameraStopProgress.confirmationTimeout(for: x3))
        let freshRemoteStop = stop(x3.id)
        progress.attach(freshRemoteStop)
        precondition(progress.didSend(freshRemoteStop, for: x3, at: 215))
        precondition(!progress.showsRecordingStatus(for: x3))
        precondition(progress.observe(x3, state: .recording, canClearActiveRecording: true),
            "Fresh GPS Remote Recording feedback must clear Stop even before the UI expiry timer runs")
        precondition(!progress.contains(x3.id))
        precondition(progress.showsRecordingStatus(for: x3))
        progress.begin(x3.id, at: 216, timeout: CameraStopProgress.confirmationTimeout(for: x3))
        x3.recordingState = .unknown
        precondition(progress.observe(x3, state: .unknown, canClearActiveRecording: true))
        x3.recordingState = .recording
        precondition(progress.observe(x3, state: .recording, canClearActiveRecording: true))
        precondition(progress.showsRecordingStatus(for: x3), "Fresh feedback must also clear the expired GPS Remote display mask")

        progress.begin(front, at: 220, timeout: 3)
        precondition(progress.expire(at: 223) == [front])
        progress.begin(front, at: 224, timeout: 3)
        precondition(!progress.isUnconfirmed(front), "An explicit Stop retry starts a fresh confirmation window")
        precondition(progress.finish(front))
        nano.recordingState = .recording
        progress.begin(front, at: 230, timeout: CameraStopProgress.confirmationTimeout(for: nano))
        precondition(!progress.observe(nano, state: .recording, canClearActiveRecording: true))
        precondition(progress.contains(front), "Continued Nano Recording status must leave Stop pending")
        nano.recordingState = .stopped
        precondition(progress.observe(nano, state: .stopped, canClearActiveRecording: true))
        precondition(!progress.contains(front), "Confirmed Nano Stop must finish immediately without waiting for the deadline")
        precondition(nano.primaryRecordCommand == .startRecording)

        // A queued GPS Remote Stop must keep its entire shutter cooldown after
        // Bluetooth accepts it, rather than measuring from the original tap.
        x3.recordingState = .recording
        progress.begin(x3.id, at: 300, timeout: CameraStopProgress.confirmationTimeout(for: x3))
        var queuedStop = stop(x3.id, status: .queued)
        progress.attach(queuedStop)
        precondition(progress.showsRecordingStatus(for: x3), "An unsent Stop must not hide an active recording")
        precondition(!progress.observe(x3, state: .recording, canClearActiveRecording: true))
        precondition(progress.contains(x3.id), "Recording timers before transmission must not cancel a queued Stop")
        precondition(!progress.didSend(queuedStop, for: x3, at: 300))
        queuedStop.status = .sent
        precondition(progress.didSend(queuedStop, for: x3, at: 301.5))
        precondition(!progress.showsRecordingStatus(for: x3))
        precondition(progress.expire(at: 303).isEmpty,
            "The old three-second deadline must not expose Record")
        precondition(progress.expire(at: 305).isEmpty,
            "The original tap deadline must not expose Record during the transport cooldown")
        precondition(!progress.didSend(queuedStop, for: x3, at: 306),
            "Duplicate delivery callbacks must not prolong the cooldown")
        precondition(progress.expire(at: 306.49).isEmpty)
        precondition(progress.expire(at: 306.5) == [x3.id])
        precondition(progress.finish(x3.id))
        progress.begin(x3.id, at: 310, timeout: CameraStopProgress.confirmationTimeout(for: x3))
        progress.attach(stop(x3.id, status: .queued))
        precondition(!progress.didSend(queuedStop, for: x3, at: 311),
            "An older Stop delivery must not change a newer request's deadline")
        precondition(progress.expire(at: 313).isEmpty)
        precondition(progress.expire(at: 315) == [x3.id])
        checkStopRecoveryAfterConnectionLoss()
        await checkRetiredClientCallbacks()
        print("Stop progress checks passed: confirmation, unknown state, rejected duplicates, late results, failures, connection-loss recovery, independent cameras, deadlines, and cleanup.")
    }

    private static func checkStopRecoveryAfterConnectionLoss() {
        for model in [CameraModel.goproHero13Black, .djiOsmoAction5Pro, .djiOsmoNano] {
            var camera = DiscoveredCamera(id: UUID(), name: model.rawValue, brand: model.brand, model: model,
                rssi: -40, capabilities: [.record, .status], connectionState: .connected,
                recordingState: .unknown, isPaired: true, isSelected: true, lastSeen: Date())
            for status in [CameraCommandStatus.queued, .sent] {
                var progress = CameraStopProgress()
                progress.begin(camera.id, at: 0, timeout: 15)
                let stop = CameraCommandResult(cameraID: camera.id, cameraName: camera.name, command: .stopRecording,
                    status: status, message: "Requested", timestamp: Date())
                progress.attach(stop)
                func needsRecovery(pendingStart: Bool = false, disconnected: Bool = false) -> Bool {
                    CameraStopReplayPolicy.shouldRetainAfterConnectionLoss(camera: camera, progress: progress,
                        hasPendingExplicitStart: pendingStart, userDisconnected: disconnected)
                }
                precondition(needsRecovery(), "Queued and acknowledged Stop both require observed Stopped")
                precondition(!needsRecovery(pendingStart: true), "A new explicit Start supersedes Stop")
                precondition(!needsRecovery(disconnected: true), "Manual Disconnect must never trigger recovery")
                precondition(!progress.observe(camera, state: .stopped, canClearActiveRecording: false))
                precondition(needsRecovery(), "An advisory Stopped report cannot abandon Stop")
                precondition(progress.expire(at: 15) == [camera.id])
                precondition(needsRecovery(), "The UI deadline must not discard recovery intent")

                var pending: Set<UUID> = []
                if needsRecovery() { pending.insert(camera.id) }
                progress.finish(camera.id) // The store clears connection-specific UI progress after retaining intent.
                precondition(!needsRecovery())
                camera.connectionState = .disconnected
                let ready = camera.brand == .gopro ? "Open GoPro protocol ready" : "DJI Nano protocol ready"
                precondition(!CameraStopReplayPolicy.consumeIfReady(camera: camera, detail: ready, pending: &pending))
                camera.connectionState = .connected
                precondition(CameraStopReplayPolicy.consumeIfReady(camera: camera, detail: ready, pending: &pending))
                precondition(!CameraStopReplayPolicy.consumeIfReady(camera: camera, detail: ready, pending: &pending))
                progress.begin(camera.id, at: 20, timeout: 15)
                precondition(progress.expire(at: 34.9).isEmpty, "Reconnect Stop gets a fresh confirmation deadline")
                precondition(progress.observe(camera, state: .stopped, canClearActiveRecording: true))
                precondition(!needsRecovery(), "Observed Stopped must end recovery")
            }
        }
        for usesSDK in [false, true] {
            let camera = DiscoveredCamera(id: UUID(), name: "X3", brand: .insta360, model: .insta360X3,
                rssi: -40, capabilities: [.record, .status], connectionState: .connected,
                recordingState: .unknown, isPaired: true, isSelected: true, lastSeen: Date(), insta360UsesSDK: usesSDK)
            var progress = CameraStopProgress()
            progress.begin(camera.id, at: 0, timeout: 15)
            precondition(!CameraStopReplayPolicy.shouldRetainAfterConnectionLoss(camera: camera, progress: progress,
                hasPendingExplicitStart: false, userDisconnected: false), "Uncertain Insta360 capture cannot be replayed")
        }
    }

    @MainActor
    private static func checkRetiredClientCallbacks() async {
        var applied: [String] = []
        var archived = 0
        let old = CameraClientEventSession()
        old.deliver({ applied.append("old queued status") }, onDiscard: { archived += 1 })
        old.invalidate() // Disconnect/replacement happens before the queued callback runs.
        let current = CameraClientEventSession()
        current.deliver { applied.append("current status") }
        old.deliver({ applied.append("old disconnect request") }, onDiscard: { archived += 1 })
        let otherCamera = CameraClientEventSession()
        otherCamera.deliver { applied.append("other camera") }
        let deadline = Date().addingTimeInterval(2)
        while applied.count < 2 || archived < 2, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(applied.sorted() == ["current status", "other camera"],
            "A retired connection must not change status or close its replacement")
        precondition(archived == 2, "Discarded control callbacks can still preserve command-history outcomes")
        current.invalidate()
        current.deliver({ applied.append("after manual Disconnect") }, onDiscard: { archived += 1 })
        while archived < 3, Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        precondition(archived == 3 && applied.count == 2, "Manual Disconnect invalidates queued callbacks")
    }
}
