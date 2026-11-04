import Foundation

private func hex(_ text: String) -> [UInt8] {
    let chars = Array(text)
    return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0..<$0 + 2]), radix: 16)! }
}
private func check(_ condition: @autoclosure () throws -> Bool) throws {
    let value = try condition(); precondition(value)
}

@main
enum Insta360X5ProtocolRegression {
    static func main() throws {
        // Complete START request/ACK, SYNC echo, and heartbeat published from
        // X5 hardware captures in docs/x5-ble-protocol.md. Other cases are synthetic.
        let start = hex("10000000040000040002010000800000")
        let ack = hex("10000000040000c80002010000800000")
        try check(try Insta360X5Protocol.encode(.start, id: 1) == start)
        let stream = Insta360X5Protocol.sync + ack + Insta360X5Protocol.heartbeat
        for split in 0...stream.count {
            var decoder = Insta360X5Decoder()
            let first = try decoder.feed(Array(stream.prefix(split)))
            let second = try decoder.feed(Array(stream.dropFirst(split)))
            let messages = first + second
            precondition(messages.count == 3 && messages[0].type == 6 && messages[2].type == 5)
            precondition(messages[1].id == 1 && messages[1].code == 200)
        }
        var decoder = Insta360X5Decoder()
        do { _ = try decoder.feed([0xff, 0xff, 0xff, 0xff]); preconditionFailure() } catch {}
        try check(try decoder.feed(ack).count == 1)
        do { _ = try Insta360X5Protocol.encode(.start, id: 0x1000000); preconditionFailure() } catch {}

        let session = Insta360DirectSession(cameraID: UUID(), cameraName: "X5 ABC123", profile: .x5, firstMessageID: 1)
        var writes: [(data: Data, id: UInt32)] = []
        var updates: [CameraStatusUpdate] = []
        var completed: [CameraCommandResult] = []
        session.onWrite = { writes.append(($0, $1)) }
        session.onStatus = { updates.append($0) }
        session.onCompletion = { completed.append($0) }
        precondition(session.mayUseGPSRemoteFallback)
        session.begin(at: 0)
        precondition(Array(writes.last!.data) == Insta360X5Protocol.sync)
        session.didWrite(id: writes.last!.id, at: 0.01)
        precondition(writes.last!.data[7] == 15)
        let initialStatusID = writes.last!.id
        session.didWrite(id: initialStatusID, at: 0.02)
        session.receive(Insta360DirectMessage(code: 200, id: initialStatusID,
            body: hex("0a06080010005000"), type: 4), at: 0.03)
        precondition(updates.last?.recordingState == .stopped)
        precondition(!session.mayUseGPSRemoteFallback, "A confirmed direct protocol must never switch to shutter toggles")
        let record = session.send(.startRecording, at: 0.1)
        precondition(writes.last!.data[7] == 4)
        session.didWrite(id: writes.last!.id, at: 0.11)
        session.receive(Insta360DirectMessage(code: 200, id: writes.last!.id, body: [], type: 4), at: 0.12)
        let statusID = writes.last!.id
        session.didWrite(id: statusID, at: 0.13)
        session.tick(at: 2.1)
        let heartbeatID = writes.last!.id
        precondition(Array(writes.last!.data) == Insta360X5Protocol.heartbeat)
        session.receive(Insta360DirectMessage(code: 200, id: statusID,
            body: hex("0a06080110085000"), type: 4), at: 2.11)
        precondition(completed.last?.id == record.id && completed.last?.status == .sent)
        let stop = session.send(.stopRecording, at: 2.12)
        precondition(writes.last!.id == heartbeatID, "A response must not overlap a heartbeat write")
        session.didWrite(id: heartbeatID, at: 2.13)
        precondition(writes.last!.data[7] == 5)
        session.didWrite(id: writes.last!.id, at: 2.14)
        session.receive(Insta360DirectMessage(code: 200, id: writes.last!.id, body: [], type: 4), at: 2.15)
        session.didWrite(id: writes.last!.id, at: 2.16)
        session.receive(Insta360DirectMessage(code: 200, id: writes.last!.id,
            body: hex("0a06080010005000"), type: 4), at: 2.17)
        precondition(completed.last?.id == stop.id && completed.last?.status == .sent)
        precondition(!writes.contains { $0.data.count >= 16 && $0.data[4] == 4 && $0.data[7] == 8 },
            "X6 telemetry request bodies have not been verified on X5")
        precondition(writes.filter { $0.data.count == 16 && $0.data[7] == 4 }.count == 1)
        precondition(writes.filter { $0.data.count == 16 && $0.data[7] == 5 }.count == 1)
        session.end()
        let beforeCapture = Insta360DirectSession(cameraID: UUID(), cameraName: "X5", profile: .x5, firstMessageID: 1)
        var fallbackWrites: [(Data, UInt32)] = []
        beforeCapture.onWrite = { fallbackWrites.append(($0, $1)) }
        beforeCapture.begin(at: 0)
        beforeCapture.didWrite(id: fallbackWrites.last!.1, at: 0.01)
        beforeCapture.didWrite(id: fallbackWrites.last!.1, at: 0.02)
        _ = beforeCapture.send(.stopRecording, at: 0.03)
        beforeCapture.tick(at: 4.1)
        beforeCapture.didWrite(id: fallbackWrites.last!.1, at: 4.11) // heartbeat before queued Stop
        precondition(fallbackWrites.last!.0[7] == 5)
        precondition(!beforeCapture.mayUseGPSRemoteFallback, "A transmitted capture command rules out GPS fallback")
        beforeCapture.end()
        precondition(!beforeCapture.mayUseGPSRemoteFallback)

        var camera = DiscoveredCamera(id: UUID(), name: "X5 ABC123", brand: .insta360,
            model: .insta360X5, rssi: -40, capabilities: [.record, .status],
            connectionState: .disconnected, recordingState: .unknown, isPaired: true,
            isSelected: false, lastSeen: Date())
        precondition(!camera.usesInsta360GPSRemote && camera.needsKnownStoppedStateForMulticam)
        camera.insta360UsesGPSRemoteFallback = true
        precondition(camera.usesInsta360GPSRemote && !camera.needsKnownStoppedStateForMulticam)
        precondition(camera.canWakeFromSleep)
        let restored = try JSONDecoder().decode(DiscoveredCamera.self, from: JSONEncoder().encode(camera))
        precondition(restored.usesInsta360GPSRemote, "Preserve an established GPS Remote route across launches")
        print("Insta360 X5 checks passed: captured framing, chunk boundaries, sync, heartbeat interleaving, and confirmed capture state.")
    }
}
