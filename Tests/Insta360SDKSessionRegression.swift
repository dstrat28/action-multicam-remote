import Foundation

@main
enum Insta360SDKSessionRegression {
    static func main() {
        let first = Insta360SDKSession(cameraID: UUID(), cameraName: "X5")
        let second = Insta360SDKSession(cameraID: UUID(), cameraName: "X6")
        var results: [CameraCommandResult] = []
        first.onCompletion = { results.append($0) }

        precondition(first.send(.startRecording, at: 0).status == .skipped)
        first.observe(state: .stopped, mode: .photo, at: 0, queryCommandID: nil, queryToken: first.observationToken)
        precondition(first.send(.startRecording, at: 0).status == .skipped)
        precondition(first.send(.setMode(.timelapse), at: 0).status == .skipped)
        precondition(first.send(.toggleRecording, at: 0).status == .skipped)
        precondition(first.send(.addHighlight, at: 0).status == .skipped)

        let mode = first.send(.setMode(.video), at: 1)
        precondition(mode.status == .queued)
        first.accepted(mode.id, error: nil, at: 1)
        precondition(results.isEmpty) // SDK acceptance does not confirm a mode change.
        first.observe(state: .stopped, mode: .video, at: 1, queryCommandID: nil, queryToken: first.observationToken)
        precondition(first.currentMode == .photo && results.isEmpty) // Pre-command reply ignored.
        first.observe(state: .stopped, mode: .video, at: 2, queryCommandID: mode.id, queryToken: first.observationToken)
        precondition(results.last?.id == mode.id && results.last?.status == .sent)

        let start = first.send(.startRecording, at: 3)
        precondition(start.status == .queued)
        precondition(first.send(.startRecording, at: 3).status == .skipped)
        first.observe(state: .recording, mode: .video, at: 3, queryCommandID: start.id, queryToken: first.observationToken)
        precondition(results.count == 1) // No confirmation until SDK accepts the command.
        first.accepted(start.id, error: nil, at: 3)
        first.observe(state: .recording, mode: nil, at: 3.5, queryCommandID: start.id, queryToken: first.observationToken)
        precondition(first.pendingID == start.id, "An incomplete mode response cannot confirm video Start")
        first.observe(state: .recording, mode: .video, at: 2.5, queryCommandID: start.id, queryToken: first.observationToken)
        precondition(results.count == 1) // A reply observed before acceptance cannot confirm it.
        first.observe(state: .recording, mode: .video, at: 4, queryCommandID: start.id, queryToken: first.observationToken)
        precondition(results.last?.id == start.id && results.last?.status == .sent)
        precondition(second.recordingState == .unknown && second.pendingID == nil)
        precondition(first.send(.capturePhoto, at: 4).status == .skipped)
        precondition(first.send(.setMode(.photo), at: 4).status == .skipped)

        first.tick(at: 10)
        precondition(first.recordingState == .unknown && first.currentMode == nil)
        precondition(first.send(.startRecording, at: 10).status == .skipped)
        let stop = first.send(.stopRecording, at: 10)
        precondition(stop.status == .queued) // Explicit Stop remains safe with unknown status.
        precondition(first.send(.stopRecording, at: 10).status == .skipped)
        precondition(first.pendingID == stop.id, "A duplicate Stop must preserve the first request's confirmation")
        first.accepted(stop.id, error: nil, at: 10)
        first.observe(state: .unknown, mode: .video, at: 11, queryCommandID: stop.id, queryToken: first.observationToken)
        precondition(first.pendingID == stop.id)
        first.observe(state: .stopped, mode: .video, at: 12, queryCommandID: stop.id, queryToken: first.observationToken)
        precondition(results.last?.id == stop.id && results.last?.status == .sent)

        let pendingStart = first.send(.startRecording, at: 13)
        let supersedingStop = first.send(.stopRecording, at: 14)
        precondition(results.last?.id == pendingStart.id && results.last?.status == .failed)
        precondition(supersedingStop.status == .queued)
        first.accepted(pendingStart.id, error: nil, at: 14)
        first.observe(state: .stopped, mode: .video, at: 14, queryCommandID: pendingStart.id, queryToken: first.observationToken)
        precondition(first.pendingID == supersedingStop.id)
        first.accepted(supersedingStop.id, error: nil, at: 14)
        first.observe(state: .stopped, mode: .video, at: 15, queryCommandID: supersedingStop.id, queryToken: first.observationToken)
        precondition(results.last?.id == supersedingStop.id && results.last?.status == .sent)

        let pendingMode = first.send(.setMode(.video), at: 15.1)
        first.accepted(pendingMode.id, error: nil, at: 15.1)
        first.observe(state: .recording, mode: .video, at: 15.2, queryCommandID: pendingMode.id,
            queryToken: first.observationToken)
        let stopDuringMode = first.send(.stopRecording, at: 15.3)
        precondition(stopDuringMode.status == .queued && first.pendingID == stopDuringMode.id)
        precondition(results.last?.id == pendingMode.id && results.last?.status == .failed)
        first.accepted(pendingMode.id, error: nil, at: 15.4)
        precondition(first.pendingID == stopDuringMode.id, "A late mode callback cannot consume explicit Stop")
        first.accepted(stopDuringMode.id, error: nil, at: 15.4)
        first.observe(state: .stopped, mode: .video, at: 15.5, queryCommandID: stopDuringMode.id,
            queryToken: first.observationToken)
        precondition(results.last?.id == stopDuringMode.id && results.last?.status == .sent)

        let timeout = first.send(.startRecording, at: 16)
        first.accepted(timeout.id, error: nil, at: 16)
        first.tick(at: 41)
        precondition(results.last?.id == timeout.id && results.last?.status == .failed)
        let completedCount = results.count
        first.accepted(timeout.id, error: nil, at: 42)
        first.observe(state: .recording, mode: .video, at: 42, queryCommandID: timeout.id, queryToken: first.observationToken)
        precondition(first.recordingState == .unknown && results.count == completedCount)

        first.observe(state: .stopped, mode: .photo, at: 43, queryCommandID: nil, queryToken: first.observationToken)
        let photo = first.send(.capturePhoto, at: 43)
        first.accepted(photo.id, error: nil, at: 43)
        precondition(results.last?.status == .sent && first.recordingState == .stopped)
        let failedPhoto = first.send(.capturePhoto, at: 44)
        first.accepted(failedPhoto.id, error: NSError(domain: "Camera", code: 1), at: 44)
        precondition(results.last?.id == failedPhoto.id && results.last?.status == .failed)
        precondition(first.recordingState == .unknown && first.statusAt == nil,
                     "A capture error must not preserve a fresh stopped state that could authorize another capture")

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
        for submode: UInt32 in 1...15 {
            precondition(Insta360SDKSession.mode(photoSubMode: 100, videoSubMode: submode) == .cameraVideo)
        }
        for submode: UInt32 in [16, 99, 100, 101, .max] {
            precondition(Insta360SDKSession.mode(photoSubMode: 100, videoSubMode: submode) == nil,
                "An undefined video submode must remain unknown")
        }
        precondition(Insta360SDKSession.mode(photoSubMode: 1, videoSubMode: 100) == nil)
        precondition(Insta360SDKSession.mode(photoSubMode: 0, videoSubMode: 7) == nil)

        let cameraVideo = Insta360SDKSession(cameraID: UUID(), cameraName: "Camera-selected video")
        var videoResults: [CameraCommandResult] = []
        cameraVideo.onCompletion = { videoResults.append($0) }
        cameraVideo.observe(state: .stopped, mode: .cameraVideo, at: 0,
            queryCommandID: nil, queryToken: cameraVideo.observationToken)
        precondition(cameraVideo.send(.setMode(.cameraVideo), at: 0).status == .skipped,
            "Camera Video is readback only, not an invented selectable vendor mode")
        let videoStart = cameraVideo.send(.startRecording, at: 0)
        precondition(videoStart.status == .queued)
        cameraVideo.accepted(videoStart.id, error: nil, at: 0)
        cameraVideo.observe(state: .recording, mode: .cameraVideo, at: 1,
            queryCommandID: videoStart.id, queryToken: cameraVideo.observationToken)
        precondition(videoResults.last?.id == videoStart.id && videoResults.last?.status == .sent)
        cameraVideo.observe(state: .stopped, mode: .cameraVideo, at: 2,
            queryCommandID: nil, queryToken: cameraVideo.observationToken)
        let normalVideo = cameraVideo.send(.setMode(.video), at: 2)
        cameraVideo.accepted(normalVideo.id, error: nil, at: 2)
        cameraVideo.observe(state: .stopped, mode: .cameraVideo, at: 3,
            queryCommandID: normalVideo.id, queryToken: cameraVideo.observationToken)
        precondition(cameraVideo.pendingID == normalVideo.id,
            "Explicit normal Video selection must not confirm from another video submode")
        cameraVideo.observe(state: .stopped, mode: .video, at: 4,
            queryCommandID: normalVideo.id, queryToken: cameraVideo.observationToken)
        precondition(videoResults.last?.id == normalVideo.id && videoResults.last?.status == .sent)
        precondition(Insta360SDKSession.recordingState(rawValue: 0) == .stopped)
        precondition(Insta360SDKSession.recordingState(rawValue: 1) == .recording)
        for state: UInt in [23, 24, 29, 30] {
            precondition(Insta360SDKSession.recordingState(rawValue: state) == .recording,
                "Documented active video state \(state) must confirm recording")
        }
        for state: UInt in [3, 4, 5, 6, 8, 10, 14, 15, 16, 19, 25, 27, 28, 31, 32] {
            precondition(Insta360SDKSession.recordingState(rawValue: state) == .unknown,
                "Photo, preparation, and unrecognized states must not confirm video recording")
        }
        precondition(Insta360SDKSession.recordingState(rawValue: 4) == .unknown)
        precondition(Insta360SDKSession.recordingState(rawValue: 999) == .unknown)
        let sdkModels: [CameraModel] = [.insta360X6, .insta360X5, .insta360X4Air, .insta360X4,
            .insta360X3, .insta360X2, .insta360OneX, .insta360OneR, .insta360OneRS, .insta360OneRS1Inch]
        for model in sdkModels {
            precondition(model.supportsInsta360SDK)
            precondition(model.brand == .insta360)
            precondition(!model.isOpenGoProCompatible && !model.supportsHighlight)
            var camera = DiscoveredCamera(id: UUID(), name: model.rawValue + " ABC123", brand: .insta360,
                model: model, rssi: -50, capabilities: [.record, .mode, .status], connectionState: .discovered,
                recordingState: .stopped, isPaired: true, isSelected: true, lastSeen: Date())
            precondition(camera.resolvedInsta360SDKSelection() == FeatureAvailability.insta360SDK,
                "Documented models must select the SDK automatically when this build includes it")
            precondition(camera.resolvedInsta360SDKSelection(sdkAvailable: true))
            precondition(!camera.resolvedInsta360SDKSelection(sdkAvailable: false))
            if model.requiresInsta360SDK && !FeatureAvailability.insta360SDK {
                precondition(!camera.isSupportedByApp)
                precondition(!camera.usesInsta360GPSRemote,
                    "SDK-only models must never prepare GPS Remote restoration in SDK-free builds")
            }
            for state: CameraConnectionState in [.connected, .connecting] {
                camera.connectionState = state
                for existingBackend in [false, true] {
                    camera.insta360UsesSDK = existingBackend
                    for available in [false, true] {
                        precondition(camera.resolvedInsta360SDKSelection(sdkAvailable: available) == existingBackend,
                            "Active links and in-flight handshakes must keep their backend")
                    }
                }
            }
            camera.insta360UsesSDK = true
            camera.connectionState = .disconnected
            precondition(camera.resolvedInsta360SDKSelection() == FeatureAvailability.insta360SDK)
            precondition(!camera.resolvedInsta360SDKSelection(sdkAvailable: false))
            camera.connectionState = .connected
            precondition(camera.behavior.kind == .insta360Direct)
            precondition(!camera.usesInsta360GPSRemote)
            precondition(camera.availableCaptureModes == [.video, .photo])
            precondition(camera.isSupportedByApp == (!model.requiresInsta360SDK || FeatureAvailability.insta360SDK))
            for mode: CaptureMode? in [.video, .cameraVideo, .photo, nil] {
                camera.currentMode = mode
                precondition(!camera.shouldSwitchToVideoBeforeRecording)
                let videoReady = mode == .video || mode == .cameraVideo
                precondition(camera.canStartRecordingInCurrentMode == videoReady)
                if camera.isSupportedByApp {
                    precondition(camera.isReadyForMulticamStart == videoReady)
                    precondition(camera.canSwitchCaptureMode, "Explicit mode selection must remain available")
                    precondition(camera.canSwitchToVideoMode == (mode != .video))
                }
            }
        }
        for model: CameraModel in [.insta360Ace, .insta360AcePro, .insta360AcePro2,
                                   .insta360Go3, .insta360Go3S, .insta360GoUltra,
                                   .goproHero13Black, .djiOsmoAction6, .djiOsmoNano, .unknown] {
            let camera = DiscoveredCamera(id: UUID(), name: model.rawValue + " ABC123", brand: model.brand,
                model: model, rssi: -50, capabilities: [.record, .status], connectionState: .discovered,
                recordingState: .unknown, isPaired: true, isSelected: false, lastSeen: Date())
            precondition(!model.supportsInsta360SDK)
            precondition(!camera.resolvedInsta360SDKSelection(sdkAvailable: true))
            if model.brand == .insta360 {
                precondition(camera.usesInsta360GPSRemote, "Ace and GO models must retain GPS Remote control")
            } else if model == .unknown {
                precondition(!camera.isSupportedByApp)
            }
        }

        for model: CameraModel in [.goproHero13Black, .djiOsmoAction6] {
            let camera = DiscoveredCamera(id: UUID(), name: model.rawValue, brand: model.brand,
                model: model, rssi: -50, capabilities: [.record, .mode, .status], connectionState: .connected,
                recordingState: .stopped, currentMode: .photo, isPaired: true, isSelected: true, lastSeen: Date())
            precondition(camera.shouldSwitchToVideoBeforeRecording && camera.isReadyForMulticamStart,
                "Preserve GoPro/DJI's existing automatic Video preparation")
        }

        let ordered = Insta360SDKSession(cameraID: UUID(), cameraName: "X3")
        let beforeCommand = ordered.observationToken
        let orderedStop = ordered.send(.stopRecording, at: 0)
        let beforeAcceptance = ordered.observationToken
        ordered.accepted(orderedStop.id, error: nil, at: 1)
        precondition(!ordered.observe(state: .stopped, mode: .video, at: 2,
            queryCommandID: orderedStop.id, queryToken: beforeAcceptance))
        ordered.tick(at: 26)
        precondition(!ordered.observe(state: .stopped, mode: .video, at: 27,
            queryCommandID: nil, queryToken: beforeCommand))
        precondition(ordered.recordingState == .unknown)

        var legacy = DiscoveredCamera(id: UUID(), name: "X5 ABC123", brand: .insta360,
            model: .insta360X5, rssi: -50, capabilities: [.record, .status], connectionState: .connected,
            recordingState: .recording, isPaired: true, isSelected: true, lastSeen: Date(),
            insta360UsesGPSRemoteFallback: true, insta360UsesSDK: false)
        precondition(!legacy.resolvedInsta360SDKSelection(sdkAvailable: true))
        legacy.connectionState = .disconnected
        legacy.insta360UsesSDK = legacy.resolvedInsta360SDKSelection(sdkAvailable: true)
        precondition(legacy.insta360UsesSDK == true && !legacy.usesInsta360GPSRemote,
            "A remembered legacy backend must not prevent automatic SDK selection on reconnect")
        legacy.connectionState = .failed("SDK capture or connection outcome is unknown")
        precondition(legacy.resolvedInsta360SDKSelection(sdkAvailable: true),
            "SDK failure must not trigger a GPS Remote fallback, even with a remembered X5 fallback")
        legacy.insta360UsesSDK = legacy.resolvedInsta360SDKSelection(sdkAvailable: false)
        precondition(legacy.usesInsta360GPSRemote && legacy.insta360UsesGPSRemoteFallback == true)

        let slowMode = Insta360SDKSession(cameraID: UUID(), cameraName: "X4")
        slowMode.observe(state: .stopped, mode: .video, at: 0, queryCommandID: nil, queryToken: slowMode.observationToken)
        slowMode.tick(at: 6) // A delayed mode callback preserves the capture observation's age.
        precondition(slowMode.send(.startRecording, at: 6).status == .skipped)
        print("Insta360 SDK session regressions passed (synthetic; no camera validation).")
    }
}
