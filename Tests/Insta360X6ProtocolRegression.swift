import Foundation

private struct Fixture: Decodable {
    struct Response: Decodable {
        struct Message: Decodable { let code: UInt16; let id: UInt32; let type: UInt8; let bodyHex: String }
        let name: String
        let hex: String
        let messages: [Message]
    }
    struct Request: Decodable { let command: UInt16; let id: UInt32; let sequence: UInt8; let hex: String }
    let responses: [Response]
    let requests: [Request]
}

private func bytes(_ hex: String) -> [UInt8] {
    let chars = Array(hex)
    precondition(chars.count.isMultiple(of: 2))
    return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0..<$0 + 2]), radix: 16)! }
}

private func check(_ condition: @autoclosure () throws -> Bool) throws {
    let valid = try condition()
    precondition(valid)
}

private func rejects(_ block: () throws -> Void) {
    do { try block(); preconditionFailure("Expected invalid input to be rejected") } catch { }
}

private final class SessionHarness {
    let session: Insta360DirectSession
    var writes: [(command: UInt16, id: UInt32, data: Data)] = []
    var updates: [CameraStatusUpdate] = []
    var completions: [CameraCommandResult] = []
    var failures: [String] = []

    init(firstID: UInt32 = 1) {
        session = Insta360DirectSession(cameraID: UUID(), cameraName: "X6 ABC123", firstMessageID: firstID)
        session.onWrite = { [weak self] data, id in
            self?.writes.append((UInt16(data[12]) | UInt16(data[13]) << 8, id, data))
        }
        session.onStatus = { [weak self] in self?.updates.append($0) }
        session.onCompletion = { [weak self] in self?.completions.append($0) }
        session.onTransportFailure = { [weak self] in self?.failures.append($0) }
        session.begin(at: 0)
    }

    func reply(_ body: [UInt8], at now: TimeInterval, code: UInt16 = 200) {
        let id = writes.last!.id
        session.didWrite(id: id, at: now)
        session.receive(Insta360DirectMessage(code: code, id: id, body: body, type: 4), at: now)
    }

    func ready() {
        reply(bytes("0a06080010005000"), at: 0.01)
        precondition(writes.last?.command == 8)
        reply([0x12, 0], at: 0.02)
        precondition(updates.last?.recordingState == .stopped)
    }
}

@main
enum Insta360X6ProtocolRegression {
    static func main() throws {
        let fixtureURL = URL(fileURLWithPath: "Tests/Fixtures/insta360-x6-v1.1.7.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        for request in fixture.requests {
            let encoded = try Insta360X6Protocol.encode(Insta360DirectCommand(rawValue: request.command)!,
                id: request.id, sequence: request.sequence)
            precondition(encoded == bytes(request.hex), "Captured request mismatch")
        }
        for response in fixture.responses {
            let packet = bytes(response.hex)
            let expected = response.messages.map { Insta360DirectMessage(code: $0.code, id: $0.id,
                body: bytes($0.bodyHex), type: $0.type) }
            for split in 0...packet.count {
                var decoder = Insta360X6Decoder()
                let first = try decoder.feed(Array(packet.prefix(split)))
                let second = try decoder.feed(Array(packet.dropFirst(split)))
                precondition(first + second == expected, "Notification split failed: \(response.name)/\(split)")
            }
        }
        var decoder = Insta360X6Decoder()
        let joined = fixture.responses.flatMap { bytes($0.hex) }
        try check(try decoder.feed(joined).count == fixture.responses.count)
        var corrupt = bytes(fixture.responses[0].hex)
        corrupt[corrupt.count - 1] ^= 1
        rejects { _ = try decoder.feed(corrupt) }
        try check(try decoder.feed(bytes(fixture.responses[0].hex)).count == 1)
        rejects { _ = try decoder.feed([UInt8](repeating: 0, count: 140_000)) }
        rejects { _ = try Insta360X6Protocol.encode(.start, id: 0, sequence: 0) }
        rejects { _ = try Insta360DirectCaptureStatus.decodeResponse([]) }
        rejects { _ = try Insta360DirectCaptureStatus.decodeResponse(bytes("0a0208000a020800")) }
        rejects { _ = try Insta360DirectCaptureStatus.decodeResponse(bytes("0a0408000801")) }
        rejects { _ = try Insta360DirectCaptureStatus.decodeResponse(bytes("0d08000000")) }
        rejects { _ = try Insta360DirectProtobuf.fields(bytes("08ffffffffffffffffffff02")) }
        try check(try Insta360DirectCaptureStatus.decodeResponse(bytes("0a00")).recording == .unknown)
        try check(try Insta360DirectCaptureStatus.decodeResponse(bytes("0a020802")).recording == .unknown)
        let running = try Insta360DirectCaptureStatus.decodeResponse(bytes("0a06080110085000"))
        precondition(running.recording == .recording && running.elapsed == 8)
        try check(try Insta360X6Telemetry.decodeBatteryNotification(bytes("0a0408001064")) == 100)
        try check(try Insta360X6Telemetry.decodeBatteryNotification(bytes("0a00")) == nil)
        // Synthetic schema cases: explicit scale permits proto3 omitted zero battery;
        // positive capacity permits omitted zero free space. These are not captures.
        try check(try Insta360X6Telemetry.decodeBatteryNotification(bytes("0a021864")) == 0)
        let emptyStorage = try Insta360X6Telemetry.decodeResponse(bytes("1205a201021864"))
        precondition(emptyStorage.freeBytes == 0 && emptyStorage.totalBytes == 100)
        try check(try Insta360X6Telemetry.decodeResponse(bytes("1203a20100")).freeBytes == nil)

        let h = SessionHarness()
        precondition(h.session.send(.startRecording, at: 0).status == .skipped)
        h.ready()
        let start = h.session.send(.startRecording, at: 0.1)
        precondition(start.status == .queued && h.writes.last?.command == 4)
        let startID = h.writes.last!.id
        h.session.didWrite(id: startID, at: 0.11)
        precondition(h.completions.isEmpty, "ATT acknowledgement is not capture confirmation")
        h.session.receive(Insta360DirectMessage(code: 200, id: startID, body: [], type: 4), at: 0.12)
        precondition(h.completions.isEmpty && h.writes.last?.command == 15)
        let statusID = h.writes.last!.id
        h.session.receive(Insta360DirectMessage(code: 200, id: statusID + 100, body: bytes("0a06080110085000"), type: 4), at: 0.13)
        h.session.receive(Insta360DirectMessage(code: 8208, id: statusID, body: bytes("08011008"), type: 4), at: 0.14)
        h.session.receive(Insta360DirectMessage(code: 8215, id: statusID, body: [], type: 4), at: 0.15)
        precondition(h.completions.isEmpty, "Events and unmatched replies cannot acknowledge a request")
        h.reply(bytes("0a06080110085000"), at: 0.2)
        precondition(h.completions.last?.id == start.id && h.completions.last?.status == .sent)
        precondition(h.updates.last?.recordingState == .recording)
        precondition(h.updates.last?.telemetry?.recordingElapsedSeconds == 8)

        let stop = h.session.send(.stopRecording, at: 0.3)
        precondition(stop.status == .queued && h.writes.last?.command == 5)
        h.session.didWrite(id: h.writes.last!.id, at: 0.31)
        h.session.tick(at: 8.4) // Lost camera acknowledgement after STOP.
        precondition(h.writes.last?.command == 15)
        h.session.didWrite(id: h.writes.last!.id, at: 8.41)
        h.session.tick(at: 12.5)
        h.reply(bytes("0a06080010005000"), at: 13)
        precondition(h.completions.last?.id == stop.id && h.completions.last?.status == .sent)
        precondition(h.writes.filter { $0.command == 4 }.count == 1)
        precondition(h.writes.filter { $0.command == 5 }.count == 1, "STOP must never be retried automatically")
        precondition(h.updates.last?.recordingState == .stopped)

        let replace = SessionHarness()
        replace.reply(bytes("0a06080010005000"), at: 0.01) // Telemetry read now pending.
        replace.session.didWrite(id: replace.writes.last!.id, at: 0.02)
        let unsent = replace.session.send(.startRecording, at: 0.1)
        _ = replace.session.send(.stopRecording, at: 0.2)
        replace.reply([0x12, 0], at: 0.3)
        precondition(replace.completions.first?.id == unsent.id && replace.completions.first?.status == .skipped)
        precondition(!replace.writes.contains { $0.command == 4 })
        precondition(replace.writes.last?.command == 5)

        let stale = SessionHarness()
        stale.ready()
        stale.session.tick(at: 7)
        precondition(stale.updates.last?.recordingState == .unknown)
        precondition(stale.session.send(.startRecording, at: 7).status == .skipped)

        let earlyReply = SessionHarness()
        let earlyID = earlyReply.writes.last!.id
        earlyReply.session.receive(Insta360DirectMessage(code: 200, id: earlyID,
            body: bytes("0a06080010005000"), type: 4), at: 0.01)
        precondition(earlyReply.writes.count == 1 && earlyReply.updates.last?.recordingState == .unknown)
        earlyReply.session.didWrite(id: earlyID, at: 0.02)
        precondition(earlyReply.writes.last?.command == 8 && earlyReply.updates.last?.recordingState == .stopped)

        let superseded = SessionHarness()
        superseded.ready()
        let oldStart = superseded.session.send(.startRecording, at: 0.1)
        let newStop = superseded.session.send(.stopRecording, at: 0.2)
        superseded.reply([], at: 0.3, code: 403) // Rejection belongs to the replaced START.
        precondition(superseded.writes.last?.command == 5)
        precondition(superseded.completions.count == 1 && superseded.completions[0].id == oldStart.id)
        superseded.reply([], at: 0.4)
        superseded.reply(bytes("0a06080010005000"), at: 0.5)
        precondition(superseded.completions.last?.id == newStop.id && superseded.completions.last?.status == .sent)

        let unconfirmed = SessionHarness()
        unconfirmed.ready()
        let unconfirmedStart = unconfirmed.session.send(.startRecording, at: 0.1)
        unconfirmed.reply([], at: 0.2)
        unconfirmed.session.didWrite(id: unconfirmed.writes.last!.id, at: 0.21)
        unconfirmed.session.tick(at: 15.2)
        precondition(unconfirmed.completions.last?.id == unconfirmedStart.id && unconfirmed.completions.last?.status == .failed)
        precondition(unconfirmed.updates.last?.recordingState == .unknown)
        precondition(unconfirmed.writes.filter { $0.command == 4 }.count == 1)

        let readings = SessionHarness()
        readings.reply(bytes("0a06080010005000"), at: 0.01)
        readings.reply(bytes("120f5a021064a2010810a0c21e18c0843d"), at: 0.02)
        precondition(readings.updates.last?.telemetry?.storageTotalMB == 1)
        for time in [25.0, 50.0, 70.0] {
            readings.session.tick(at: time)
            readings.reply(bytes("0a06080010005000"), at: time + 0.01)
            if readings.writes.last?.command == 8 { readings.reply([0xFF], at: time + 0.02) }
        }
        readings.session.receive(Insta360DirectMessage(code: 8195, id: 999,
            body: bytes("0a0408001064"), type: 4), at: 70.03)
        readings.session.tick(at: 76)
        precondition(readings.updates.last?.telemetry?.batteryPercent == 100)
        precondition(readings.updates.last?.telemetry?.storageTotalMB == nil)
        precondition(readings.updates.last?.replacesTelemetry == true, "A battery event must not keep old storage readings fresh")

        let neverReady = SessionHarness()
        precondition(!neverReady.session.hasConfirmedProtocol)
        neverReady.session.didWrite(id: neverReady.writes.last!.id, at: 0.01)
        for time in stride(from: 4.1, through: 28.7, by: 4.1) {
            neverReady.session.tick(at: time)
            neverReady.session.didWrite(id: neverReady.writes.last!.id, at: time + 0.01)
        }
        neverReady.session.tick(at: 30)
        precondition(!neverReady.session.isReady && neverReady.failures.count == 1,
                     "ATT acknowledgements alone cannot keep an unresponsive X6 connected forever")
        neverReady.session.tick(at: 35)
        precondition(neverReady.failures.count == 1)

        let lostWrite = SessionHarness()
        let oldID = lostWrite.writes[0].id
        lostWrite.session.tick(at: 4)
        precondition(!lostWrite.session.isReady && lostWrite.failures.count == 1)
        lostWrite.session.begin(at: 5)
        let newID = lostWrite.writes.last!.id
        lostWrite.session.didWrite(id: oldID, at: 5.01)
        lostWrite.session.receive(Insta360DirectMessage(code: 200, id: oldID, body: bytes("0a06080010005000"), type: 4), at: 5.02)
        precondition(oldID != newID && lostWrite.updates.last?.recordingState == .unknown)
        lostWrite.reply(bytes("0a06080010005000"), at: 5.03)
        precondition(lostWrite.updates.last?.recordingState == .stopped)

        let independent = SessionHarness(firstID: 100)
        independent.ready()
        h.session.end()
        precondition(independent.session.isReady && independent.session.recordingState == .stopped)
        precondition(independent.session.send(.startRecording, at: 0.1).cameraID != start.cameraID)

        var camera = DiscoveredCamera(id: UUID(), name: "X6 ABC123", brand: .insta360,
            model: .insta360X6, rssi: -50, capabilities: [.record, .status],
            connectionState: .connected, recordingState: .unknown, isPaired: true,
            isSelected: true, lastSeen: Date())
        precondition(camera.isSupportedByApp && !camera.usesInsta360GPSRemote)
        precondition(camera.behavior.kind == .insta360Direct && !camera.canStartRecording)
        precondition(!camera.isReadyForMulticamStart)
        camera.recordingState = .stopped
        precondition(camera.canStartRecording && camera.isReadyForMulticamStart)
        camera.connectionState = .disconnected
        precondition(camera.canConnectFromCurrentState && !camera.canWakeFromSleep)
        print("Insta360 X6 protocol and command-session regression checks passed.")
    }
}
