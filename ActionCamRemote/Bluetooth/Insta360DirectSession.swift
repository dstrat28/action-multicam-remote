import Foundation

/// One serial direct-control session per camera. Capture commands are sent once; only
/// read-only status requests are repeated when a camera is slow to respond.
final class Insta360DirectSession {
    private struct Request {
        var id: UInt32
        var command: Insta360DirectCommand
        var expiresAt: TimeInterval
        var writeCompleted = false
        var reply: Insta360DirectMessage?
    }

    private struct Capture {
        var result: CameraCommandResult
        var command: Insta360DirectCommand
        var target: Insta360DirectRecordingState
        var expiresAt: TimeInterval
        var sent = false
        var requestID: UInt32?
    }

    let profile: Insta360DirectProfile
    let cameraID: UUID
    let cameraName: String
    var onWrite: ((Data, UInt32) -> Void)?
    var onStatus: ((CameraStatusUpdate) -> Void)?
    var onCompletion: ((CameraCommandResult) -> Void)?
    var onLog: ((String) -> Void)?
    var onTransportFailure: ((String) -> Void)?

    private(set) var isReady = false
    private(set) var recordingState = Insta360DirectRecordingState.unknown
    private(set) var hasConfirmedProtocol = false
    private var hasSentCapture = false
    var mayUseGPSRemoteFallback: Bool { profile == .x5 && !hasConfirmedProtocol && !hasSentCapture }
    private var request: Request?
    private var capture: Capture?
    private var nextID: UInt32
    private var auxiliaryWrite: (id: UInt32, expiresAt: TimeInterval)?
    private var needsSync = false
    private var nextHeartbeatAt: TimeInterval = 0
    private var sequence: UInt8 = 0
    private var nextStatusAt: TimeInterval = 0
    private var nextTelemetryAt: TimeInterval = 0
    private var statusAt: TimeInterval?
    private var beganAt: TimeInterval = 0
    private var lastValidStatusAt: TimeInterval?
    private var elapsed: UInt32?
    private var telemetry: Insta360X6Telemetry?
    private var telemetryAt: TimeInterval?
    private var battery: Int?
    private var batteryAt: TimeInterval?
    private var lastPublishedStatus: CameraStatusUpdate?

    init(cameraID: UUID, cameraName: String, profile: Insta360DirectProfile = .x6, firstMessageID: UInt32? = nil) {
        self.profile = profile
        self.cameraID = cameraID
        self.cameraName = cameraName
        nextID = firstMessageID ?? UInt32.random(in: 1...profile.maximumMessageID)
    }

    func begin(at now: TimeInterval) {
        end()
        isReady = true
        hasConfirmedProtocol = false
        hasSentCapture = false
        beganAt = now
        lastValidStatusAt = nil
        needsSync = profile == .x5
        nextHeartbeatAt = now + 2
        nextStatusAt = now
        nextTelemetryAt = now
        publish(at: now)
        pump(at: now)
    }

    func end() {
        isReady = false
        request = nil
        auxiliaryWrite = nil
        needsSync = false
        finishCapture(status: .failed, message: "\(profile.name) disconnected before the recording state was confirmed.")
        recordingState = .unknown
        statusAt = nil
        lastValidStatusAt = nil
        elapsed = nil
        telemetry = nil
        telemetryAt = nil
        battery = nil
        batteryAt = nil
        lastPublishedStatus = nil
    }

    func send(_ command: CameraCommand, at now: TimeInterval) -> CameraCommandResult {
        var result = CameraCommandResult(cameraID: cameraID, cameraName: cameraName,
            command: command, status: .skipped, message: "\(profile.name) Bluetooth control is not ready.", timestamp: Date())
        guard isReady else { return result }
        expire(at: now)
        guard isReady else { return result }

        let wireCommand: Insta360DirectCommand
        switch command {
        case .startRecording: wireCommand = .start
        case .stopRecording: wireCommand = .stop
        case .toggleRecording:
            guard recordingState != .unknown else {
                result.message = "Waiting for \(profile.name) recording status. Check the camera is in normal Video mode."
                nextStatusAt = now
                pump(at: now)
                return result
            }
            wireCommand = recordingState == .recording ? .stop : .start
        case .keepAlive:
            nextStatusAt = now
            pump(at: now)
            result.status = .sent
            result.message = "Requested \(profile.name) recording status."
            return result
        default:
            result.status = .unsupported
            result.message = "\(profile.name) Bluetooth supports normal-video recording and status. Set modes and settings on the camera."
            return result
        }

        if let capture, capture.command == wireCommand || wireCommand == .start {
            result.message = "Waiting for the previous \(profile.name) recording command to finish."
            return result
        }
        if wireCommand == .start, !hasFreshStoppedStatus(at: now) {
            result.message = "Waiting for \(profile.name) to confirm it is stopped. Check the camera is in normal Video mode."
            nextStatusAt = now
            pump(at: now)
            return result
        }
        if wireCommand == .stop, hasFreshStoppedStatus(at: now), capture == nil {
            result.message = "\(profile.name) already reports that recording is stopped."
            return result
        }

        // STOP replaces an unsent START, or follows an already transmitted START.
        // It never cancels a partially written frame or causes START to be resent.
        finishCapture(status: .skipped, message: "A newer \(profile.name) Stop replaced the previous recording request.")
        result.status = .queued
        result.message = "\(profile.name) recording request queued; waiting for camera confirmation."
        capture = Capture(result: result, command: wireCommand,
            target: wireCommand == .start ? .recording : .stopped,
            expiresAt: now + (wireCommand == .stop ? 25 : 15))
        pump(at: now)
        return result
    }

    func tick(at now: TimeInterval) {
        guard isReady else { return }
        expire(at: now)
        guard isReady else { return }
        publish(at: now)
        pump(at: now)
    }

    /// Called only after all ATT chunks for this frame have been acknowledged.
    func didWrite(id: UInt32, at now: TimeInterval) {
        if auxiliaryWrite?.id == id {
            auxiliaryWrite = nil
            pump(at: now)
            return
        }
        guard request?.id == id else { return }
        request?.writeCompleted = true
        if let reply = request?.reply { receive(reply, at: now) }
    }

    func transportFailed(_ message: String) {
        guard isReady else { return }
        end()
        onStatus?(CameraStatusUpdate(recordingState: .unknown, telemetry: CameraTelemetry(), replacesTelemetry: true))
        onTransportFailure?(message)
    }

    func receive(_ message: Insta360DirectMessage, at now: TimeInterval) {
        guard isReady else { return }
        expire(at: now)
        guard isReady else { return }
        if message.type == 5 || message.type == 6 { return } // Observed heartbeat; no reply is required.
        if message.code == 8195, profile == .x6 {
            do {
                battery = try Insta360X6Telemetry.decodeBatteryNotification(message.body)
                batteryAt = now
                publish(at: now)
            } catch { onLog?("\(profile.name) invalid battery event: \(error)") }
            return
        }
        if message.code == 8208 {
            // Read the authoritative status envelope; events cannot complete requests.
            nextStatusAt = now
            pump(at: now)
            return
        }
        // Other unsolicited events use the same ID space. Even an ID collision
        // must not turn an event into a camera rejection or request completion.
        guard message.code < 0x2000 else { return }
        guard let active = request, message.id == active.id else { return }
        guard active.writeCompleted else {
            request?.reply = message
            return
        }
        request = nil
        let body = message.body.prefix(96).map { String(format: "%02x", $0) }.joined()
        onLog?("\(profile.name) response code=\(message.code) id=\(message.id) request=\(active.command.rawValue) body=\(body)")
        if message.code != 200 {
            if (active.command == .start || active.command == .stop), capture?.requestID == active.id {
                finishCapture(status: .failed, message: "\(profile.name) rejected the recording command (\(message.code)).")
                recordingState = .unknown
                statusAt = nil
            }
            nextStatusAt = now + 1
            publish(at: now)
            pump(at: now)
            return
        }
        do {
            switch active.command {
            case .status:
                let status = try Insta360DirectCaptureStatus.decodeResponse(message.body)
                hasConfirmedProtocol = true
                recordingState = status.recording
                statusAt = now
                lastValidStatusAt = now
                elapsed = status.elapsed.flatMap(UInt32.init(exactly:))
                if let capture, capture.sent, capture.target == recordingState {
                    finishCapture(status: .sent, message: recordingState == .recording
                        ? "\(profile.name) confirmed recording started." : "\(profile.name) confirmed recording stopped.")
                }
                nextStatusAt = now + 1
            case .telemetry:
                telemetry = try Insta360X6Telemetry.decodeResponse(message.body)
                telemetryAt = now
                battery = telemetry?.batteryPercent
                batteryAt = now
            case .start, .stop:
                // Code 200 acknowledges the command, not the resulting state.
                nextStatusAt = now
            }
        } catch {
            onLog?("\(profile.name) invalid response for \(active.command.rawValue): \(error)")
            if active.command == .status {
                recordingState = .unknown
                statusAt = nil
                nextStatusAt = now + 1
            }
        }
        publish(at: now)
        pump(at: now)
    }

    private func expire(at now: TimeInterval) {
        if now - (lastValidStatusAt ?? beganAt) >= 30 {
            transportFailed("\(profile.name) has not returned a valid capture status for 30 seconds; reconnect to restore control.")
            return
        }
        if let auxiliaryWrite, now >= auxiliaryWrite.expiresAt {
            transportFailed("\(profile.name) Bluetooth heartbeat/sync write timed out; reconnect to restore the stream.")
            return
        }
        if let request, now >= request.expiresAt {
            if !request.writeCompleted {
                // A late ATT callback cannot be assigned safely to a new write.
                transportFailed("\(profile.name) Bluetooth write timed out; reconnect to restore the command stream.")
                return
            }
            onLog?("\(profile.name) response timed out for request=\(request.command.rawValue) id=\(request.id); capture commands are not retried.")
            self.request = nil
            nextStatusAt = now
        }
        if let statusAt, now - statusAt > 6 {
            recordingState = .unknown
            elapsed = nil
        }
        if let capture, now >= capture.expiresAt {
            finishCapture(status: .failed, message: "\(profile.name) recording state could not be confirmed. Check the camera; the command was not repeated.")
            recordingState = .unknown
            statusAt = nil
        }
    }

    private func hasFreshStoppedStatus(at now: TimeInterval) -> Bool {
        recordingState == .stopped && statusAt.map { (0...6).contains(now - $0) } == true
    }

    private func pump(at now: TimeInterval) {
        guard isReady, auxiliaryWrite == nil else { return }
        if profile == .x5, needsSync || (now >= nextHeartbeatAt && (request == nil || request?.writeCompleted == true)) {
            let id = nextMessageID()
            let data = needsSync ? Insta360X5Protocol.sync : Insta360X5Protocol.heartbeat
            needsSync = false
            nextHeartbeatAt = now + 2
            auxiliaryWrite = (id, now + 4)
            onWrite?(Data(data), id)
            return
        }
        guard request == nil else { return }
        let command: Insta360DirectCommand
        if let capture, !capture.sent {
            guard now < capture.expiresAt else { return }
            if capture.command == .start, !hasFreshStoppedStatus(at: now) {
                finishCapture(status: .skipped, message: "\(profile.name) Start expired without a fresh stopped state. Tap Record again after status recovers.")
                publish(at: now)
                return
            }
            command = capture.command
            hasSentCapture = true
            self.capture?.sent = true
            recordingState = .unknown
            statusAt = nil
            nextStatusAt = now
            publish(at: now)
        } else if now >= nextStatusAt {
            command = .status
            nextStatusAt = now + 1
        } else if profile == .x6, capture == nil, now >= nextTelemetryAt {
            command = .telemetry
            nextTelemetryAt = now + 30
        } else { return }

        let id = nextMessageID()
        if command == .start || command == .stop { capture?.requestID = id }
        sequence &+= 1
        do {
            let bytes = try profile.encode(command, id: id, sequence: sequence)
            request = Request(id: id, command: command,
                expiresAt: now + (command == .start || command == .stop ? 8 : 4))
            onLog?("\(profile.name) request=\(command.rawValue) id=\(id)")
            onWrite?(Data(bytes), id)
        } catch { transportFailed("\(profile.name) command encoding failed: \(error)") }
    }

    private func nextMessageID() -> UInt32 {
        let id = nextID
        nextID = nextID >= profile.maximumMessageID ? 1 : nextID + 1
        return id
    }

    private func finishCapture(status: CameraCommandStatus, message: String) {
        guard var result = capture?.result else { return }
        capture = nil
        result.status = status
        result.message = message
        result.timestamp = Date()
        onCompletion?(result)
    }

    private func publish(at now: TimeInterval) {
        var info = CameraTelemetry()
        if let batteryAt, (0...75).contains(now - batteryAt) { info.batteryPercent = battery }
        if let telemetryAt, (0...75).contains(now - telemetryAt), let telemetry {
            info.storageFreeMB = telemetry.freeBytes.flatMap { UInt32(exactly: $0 / 1_000_000) }
            info.storageTotalMB = telemetry.totalBytes.flatMap { UInt32(exactly: $0 / 1_000_000) }
            switch telemetry.cardState {
            case 1: info.storageState = "No card"
            case 2: info.storageState = "Storage full"
            case 3, 4, 5: info.storageState = "Storage error"
            default: break
            }
        }
        info.recordingElapsedSeconds = recordingState == .recording ? elapsed : nil
        let state: CameraRecordingState
        switch recordingState {
        case .recording: state = capture?.command == .stop ? .unknown : .recording
        case .stopped: state = capture?.command == .start && capture?.sent == true ? .starting : .stopped
        case .unknown: state = capture?.command == .start && capture?.sent == true ? .starting : .unknown
        }
        let update = CameraStatusUpdate(recordingState: state, telemetry: info, replacesTelemetry: true)
        guard update != lastPublishedStatus else { return }
        lastPublishedStatus = update
        onStatus?(update)
    }
}
