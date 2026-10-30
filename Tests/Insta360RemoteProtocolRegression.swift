import Foundation

@main
enum Insta360RemoteProtocolRegression {
    static func main() {
        let expectedModels: [(String, CameraModel)] = [
            ("Ace Pro 2 ABC123", .insta360AcePro2),
            ("ACE PRO X9Y8Z7", .insta360AcePro),
            ("Ace Q1W2E3", .insta360Ace),
            ("X6 Z9Y8X7", .insta360X6),
            ("X5 A1B2C3", .insta360X5),
            ("X4 Air D4E5F6", .insta360X4Air),
            ("X4 G7H8J9", .insta360X4),
            ("X3 K1L2M3", .insta360X3),
            ("ONE RS N4P5Q6", .insta360OneRS),
            ("GO Ultra R7S8T9", .insta360GoUltra),
            ("GO 3S U1V2W3", .insta360Go3S),
            ("GO 3 X4Y5Z6", .insta360Go3)
        ]

        for (name, expectedModel) in expectedModels {
            precondition(Insta360CameraNameClassifier.model(for: name) == expectedModel)
            precondition(Insta360CameraNameClassifier.isCredibleCameraName(name))
            precondition(Insta360RemoteProtocol.wakeIdentifier(from: name) == Data(name.suffix(6).utf8))
        }

        precondition(
            Insta360RemoteProtocol.wakeBeaconUUID(from: "Ace Pro 2 263TAK")
                == UUID(uuidString: "094F5242-4954-09FF-0F00-32363354414B")
        )
        precondition(
            Insta360RemoteProtocol.wakeManufacturerData(from: "Ace Pro 2 263TAK")
                == Data([
                    0x4C, 0x00, 0x02, 0x15,
                    0x09, 0x4F, 0x52, 0x42, 0x49, 0x54, 0x09, 0xFF, 0x0F, 0x00,
                    0x32, 0x36, 0x33, 0x54, 0x41, 0x4B,
                    0x00, 0x00, 0x00, 0x00, 0xE4
                ])
        )
        precondition(Insta360RemoteProtocol.wakeBeaconUUID(from: "Ace Pro 2") == nil)

        let aceIdentifierPacket = Data([
            0xFE, 0xEF, 0xFE, 0x07, 0x00, 0x06,
            0x32, 0x36, 0x33, 0x54, 0x41, 0x4B
        ])
        precondition(
            Insta360RemoteProtocol.cameraIdentifier(from: aceIdentifierPacket)
                == Data("263TAK".utf8)
        )
        precondition(
            Insta360RemoteProtocol.cameraIdentifier(
                from: Data([0xFE, 0xEF, 0xFE, 0x07, 0x00, 0x06, 0x32, 0x36, 0x33, 0x00, 0x41, 0x4B])
            ) == nil
        )
        precondition(Insta360RemoteProtocol.cameraIdentifier(from: Insta360RemoteProtocol.shutterCommand) == nil)

        var wakeableCamera = DiscoveredCamera(
            id: UUID(),
            name: "Ace Pro 2 263TAK",
            brand: .insta360,
            model: .insta360AcePro2,
            rssi: -50,
            capabilities: [.record, .status],
            connectionState: .disconnected,
            recordingState: .unknown,
            isPaired: true,
            isSelected: false,
            lastSeen: Date()
        )
        precondition(wakeableCamera.canConnectFromCurrentState)
        precondition(wakeableCamera.displayConnectionLabel == "Available")
        precondition(wakeableCamera.defaultSortRank == 2)
        wakeableCamera.name = "Ace Pro 2"
        precondition(!wakeableCamera.canConnectFromCurrentState)
        precondition(wakeableCamera.displayConnectionLabel == "Not Connected")
        precondition(wakeableCamera.defaultSortRank == 3)

        precondition(!Insta360CameraNameClassifier.isCredibleCameraName("X5"))
        precondition(!Insta360CameraNameClassifier.isCredibleCameraName("X6"))
        precondition(!Insta360CameraNameClassifier.isCredibleCameraName("X6 Speaker ABC123"))
        precondition(!Insta360CameraNameClassifier.isCredibleCameraName("X5 Speaker ABC123"))
        precondition(!Insta360CameraNameClassifier.isCredibleCameraName("GO 3S Speaker ABC123"))
        precondition(Insta360CameraNameClassifier.model(for: "GoPro HERO13 ABC123") == .unknown)
        precondition(
            !DiscoveredCamera.isSupportedModel(
                brand: .insta360,
                model: .insta360X6,
                name: "X6 Z9Y8X7"
            )
        )
        precondition(
            DiscoveredCamera.unsupportedReason(
                brand: .insta360,
                model: .insta360X6,
                name: "X6 Z9Y8X7"
            ) == "Insta360 X6 uses a Bluetooth remote protocol that Multicam does not support."
        )

        let firstCameraID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondCameraID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        precondition(
            Insta360RemoteAssignmentStrategy.cameraID(
                matching: Data("263TAK".utf8),
                cameraNamesByID: [
                    firstCameraID: "X4 194DGB",
                    secondCameraID: "Ace Pro 2 263TAK"
                ],
                requestedCameraIDs: [firstCameraID, secondCameraID]
            ) == secondCameraID
        )
        precondition(
            Insta360RemoteAssignmentStrategy.cameraID(
                matching: Data("6PP7XT".utf8),
                cameraNamesByID: [secondCameraID: "Ace Pro 2 263TAK"],
                requestedCameraIDs: [secondCameraID]
            ) == nil
        )
        precondition(
            Insta360RemoteAssignmentMatch.cameraSerialIdentifier.authorityRank
                > Insta360RemoteAssignmentMatch.exactPeerIdentifier.authorityRank
        )
        precondition(
            Insta360RemoteAssignmentMatch.exactPeerIdentifier.authorityRank
                > Insta360RemoteAssignmentMatch.requestOrderFallback.authorityRank
        )
        precondition(
            Insta360RemoteAssignmentStrategy.assignment(
                peerIdentifier: secondCameraID,
                requestedCameraIDs: [firstCameraID, secondCameraID],
                assignedCameraIDs: []
            ) == Insta360RemoteAssignment(cameraID: secondCameraID, match: .exactPeerIdentifier)
        )
        precondition(
            Insta360RemoteAssignmentStrategy.assignment(
                peerIdentifier: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                requestedCameraIDs: [firstCameraID, secondCameraID],
                assignedCameraIDs: [firstCameraID]
            ) == Insta360RemoteAssignment(cameraID: secondCameraID, match: .requestOrderFallback)
        )
        precondition(
            Insta360RemoteAssignmentStrategy.assignment(
                peerIdentifier: firstCameraID,
                requestedCameraIDs: [firstCameraID],
                assignedCameraIDs: [firstCameraID]
            ) == nil
        )

        let unmatchedPeerID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let restoredAssignments = Insta360RemoteAssignmentStrategy.assignments(
            peerIdentifiers: [unmatchedPeerID, firstCameraID, secondCameraID],
            requestedCameraIDs: [firstCameraID, secondCameraID],
            assignedCameraIDs: []
        )
        precondition(
            restoredAssignments[firstCameraID]
                == Insta360RemoteAssignment(cameraID: firstCameraID, match: .exactPeerIdentifier)
        )
        precondition(
            restoredAssignments[secondCameraID]
                == Insta360RemoteAssignment(cameraID: secondCameraID, match: .exactPeerIdentifier)
        )
        precondition(restoredAssignments[unmatchedPeerID] == nil)

        precondition(
            Insta360RemoteProtocol.shutterCommand
                == Data([0xFC, 0xEF, 0xFE, 0x86, 0x00, 0x03, 0x01, 0x02, 0x00])
        )
        precondition(
            Insta360RemoteProtocol.cycleModeCommand
                == Data([0xFC, 0xEF, 0xFE, 0x86, 0x00, 0x03, 0x01, 0x01, 0x00])
        )

        let timerPacket = Data([0xFC, 0xEF, 0x00, 0x00, 0x00, 0x00])
            + Data("00:01:23".utf8)
            + Data(repeating: 0, count: 6)
        precondition(Insta360RemoteProtocol.isRecordingTimerPacket(timerPacket))
        precondition(Insta360RemoteProtocol.recordingTimeLabel(from: timerPacket) == "00:01:23")
        precondition(!Insta360RemoteProtocol.isRecordingTimerPacket(Data(repeating: 0, count: 20)))
        checkTimerValidation()
        checkDisplayTimerFrames()
        checkRecordingStatus()
        checkSuccessiveRecordingSessions()
        checkQueuedCommands()

        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        precondition(
            Insta360RemoteSessionPolicy.timeoutDisposition(
                hasAssignedCentral: false,
                isSubscribed: false,
                lastActivity: nil,
                now: now
            ) == .waitingForCamera
        )
        precondition(
            Insta360RemoteSessionPolicy.timeoutDisposition(
                hasAssignedCentral: true,
                isSubscribed: true,
                lastActivity: nil,
                now: now
            ) == .commandReady
        )
        precondition(
            Insta360RemoteSessionPolicy.timeoutDisposition(
                hasAssignedCentral: true,
                isSubscribed: false,
                lastActivity: now.addingTimeInterval(-5),
                now: now
            ) == .activeAwaitingCommands
        )
        precondition(
            Insta360RemoteSessionPolicy.timeoutDisposition(
                hasAssignedCentral: true,
                isSubscribed: false,
                lastActivity: now.addingTimeInterval(-11),
                now: now
            ) == .reset
        )
        precondition(Insta360RemoteSessionPolicy.shouldLogPacket(lastLoggedAt: nil, now: now))
        precondition(
            !Insta360RemoteSessionPolicy.shouldLogPacket(
                lastLoggedAt: now.addingTimeInterval(-14),
                now: now
            )
        )
        precondition(
            Insta360RemoteSessionPolicy.shouldLogPacket(
                lastLoggedAt: now.addingTimeInterval(-15),
                now: now
            )
        )

        print("Insta360 remote protocol regression checks passed (\(expectedModels.count) models).")
    }

    private static func packet(containing text: String) -> Data {
        Data(repeating: 0, count: 6) + Data(text.utf8) + Data(repeating: 0, count: 12)
    }

    private static func checkTimerValidation() {
        for time in ["00:01:23", "01:23", "1:23", "1:02:03", "123:45", "00:00:00", "23:59:59"] {
            precondition(Insta360RemoteProtocol.recordingTimeLabel(from: packet(containing: time)) == time)
        }
        let invalidTimers = [
            ":", "99:99:99", "12:60", "00:60:00", "12::34", ":12:34",
            "12:34:", "12:3", "12:34:56:78", "12:34.5", "-12:34", "status:armed"
        ]
        for invalid in invalidTimers {
            precondition(!Insta360RemoteProtocol.isRecordingTimerPacket(packet(containing: invalid)), invalid)
        }
        var binaryPacket = Data(repeating: 0xAA, count: 20)
        binaryPacket[10] = 0x3A
        precondition(!Insta360RemoteProtocol.isRecordingTimerPacket(binaryPacket))
        precondition(!Insta360RemoteProtocol.isRecordingTimerPacket(Data("00:01:23".utf8)))
    }

    private static func displayPacket(_ text: String) -> Data {
        Data([0xFE, 0xEF, 0xFE, 0x10, 0x80, UInt8(4 + text.utf8.count),
              0x01, 0x0E, 0x46, 0x01]) + Data(text.utf8)
    }

    private static func checkDisplayTimerFrames() {
        // X4 camera -> GPS Remote capture; the period is a display marker.
        // https://github.com/TheAngryRaven/DovesDataLogger/blob/0077141ea3a43de68e1d9dc2e761e6674d9e31b3/tests/insta360_protocol_test.cpp
        let captured = Data([
            0xFE, 0xEF, 0xFE, 0x10, 0x80, 0x0D,
            0x01, 0x0E, 0x46, 0x01,
            0x2E, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A, 0x30, 0x35,
        ])
        precondition(Insta360RemoteProtocol.recordingTimeLabel(from: captured) == "00:00:05")
        precondition(Insta360RemoteProtocol.isRecordingTimerPacket(captured))
        for time in [".0:05", ".00:00:05", "00:00:05"] {
            let expected = time.hasPrefix(".") ? String(time.dropFirst()) : time
            precondition(Insta360RemoteProtocol.recordingTimeLabel(from: displayPacket(time)) == expected)
        }
        for invalid in [".12:60", ".1:60:00", "..00:00:05", "junk.00:00:05", ".00:00:05junk", "4K|30|UW", " 13h09m"] {
            precondition(!Insta360RemoteProtocol.isRecordingTimerPacket(displayPacket(invalid)), invalid)
        }
        for length in 0 ..< captured.count {
            precondition(!Insta360RemoteProtocol.isRecordingTimerPacket(Data(captured.prefix(length))))
        }
        var wrongType = captured
        wrongType[3] = 0x07
        precondition(!Insta360RemoteProtocol.isRecordingTimerPacket(wrongType))
        precondition(!Insta360RemoteProtocol.isRecordingTimerPacket(
            displayPacket("4K|30|UW") + Data([0]) + Data("00:00:05".utf8)
        ), "A timer outside the declared display payload must not confirm recording")
    }

    private static func checkSuccessiveRecordingSessions() {
        let now = Date(timeIntervalSinceReferenceDate: 2_500)
        var status = Insta360RemoteRecordingStatus()
        for session in 0 ..< 2 {
            let start = now.addingTimeInterval(Double(session) * 20)
            precondition(status.rejectionReason(for: .startRecording) == nil)
            status.shutterSent(at: start)
            precondition(Insta360RemoteProtocol.isRecordingTimerPacket(displayPacket(".00:00:05")))
            status.observeTimer(at: start.addingTimeInterval(1))
            precondition(status.state == .recording)
            precondition(status.rejectionReason(for: .startRecording) != nil)
            precondition(status.rejectionReason(for: .stopRecording) == nil)
            status.shutterSent(at: start.addingTimeInterval(2))
            precondition(status.expire(at: start.addingTimeInterval(8)))
            precondition(status.state == .unknown, "Silence must not claim recording stopped")
        }
    }

    private static func checkRecordingStatus() {
        let now = Date(timeIntervalSinceReferenceDate: 2_000)
        var status = Insta360RemoteRecordingStatus()
        precondition(status.state == .unknown)
        precondition(status.rejectionReason(for: .stopRecording) != nil)
        precondition(status.rejectionReason(for: .startRecording) == nil)
        precondition(!status.expire(at: now))
        precondition(status.observeTimer(at: now))
        let recordingRevision = status.revision
        precondition(status.state == .recording)
        precondition(status.rejectionReason(for: .startRecording) != nil)
        precondition(status.rejectionReason(for: .capturePhoto) != nil)
        precondition(status.rejectionReason(for: .stopRecording) == nil)
        precondition(!status.expire(at: now.addingTimeInterval(5)))
        precondition(!status.observeTimer(at: now.addingTimeInterval(4)))
        precondition(status.revision == recordingRevision, "Routine timer refreshes must not invalidate a queued stop")
        precondition(!status.expire(at: now.addingTimeInterval(8)))
        precondition(status.expire(at: now.addingTimeInterval(10)))
        precondition(status.state == .unknown, "Missing packets must not claim recording stopped")
        precondition(status.revision > recordingRevision)
        precondition(!status.expire(at: now.addingTimeInterval(11)))
        precondition(status.observeTimer(at: now.addingTimeInterval(12)))
        precondition(status.state == .recording, "A fresh timer must recover recording status")

        var unconfirmedStart = Insta360RemoteRecordingStatus()
        unconfirmedStart.shutterSent(at: now)
        precondition(!unconfirmedStart.expire(at: now.addingTimeInterval(5)))
        precondition(unconfirmedStart.expire(at: now.addingTimeInterval(6)))
        precondition(unconfirmedStart.state == .unknown, "A sent shutter is not a recording confirmation")

        var pendingStop = Insta360RemoteRecordingStatus()
        pendingStop.observeTimer(at: now)
        let beforeStop = pendingStop.revision
        pendingStop.shutterSent(at: now.addingTimeInterval(4))
        precondition(pendingStop.revision > beforeStop)
        precondition(!pendingStop.expire(at: now.addingTimeInterval(6)))
        precondition(pendingStop.expire(at: now.addingTimeInterval(10)))
        precondition(pendingStop.state == .unknown)
    }

    private static func checkQueuedCommands() {
        let now = Date(timeIntervalSinceReferenceDate: 3_000)
        let cameraID = UUID()
        let secondCameraID = UUID()
        let peerID = UUID()
        let sessionID = UUID()
        var recording = Insta360RemoteRecordingStatus()
        recording.observeTimer(at: now)

        func queued(
            _ command: CameraCommand,
            cameraID: UUID,
            enqueuedAt: Date = now
        ) -> Insta360RemotePendingCommand {
            Insta360RemotePendingCommand(
                data: Insta360RemoteProtocol.shutterCommand,
                result: CameraCommandResult(
                    cameraID: cameraID,
                    cameraName: "Ace Pro 2 ABC123",
                    command: command,
                    status: .queued,
                    message: "Queued",
                    timestamp: now
                ),
                peerID: peerID,
                sessionID: sessionID,
                recordingRevision: recording.revision,
                enqueuedAt: enqueuedAt
            )
        }

        let stop = queued(.stopRecording, cameraID: cameraID)
        func reason(
            _ command: Insta360RemotePendingCommand,
            at date: Date = now,
            peer: UUID? = peerID,
            session: UUID? = sessionID
        ) -> String? {
            command.discardReason(now: date, peerID: peer, sessionID: session, recordingRevision: recording.revision)
        }
        precondition(reason(stop) == nil)
        precondition(reason(stop, at: now.addingTimeInterval(1.99)) == nil)
        precondition(reason(stop, at: now.addingTimeInterval(2)) != nil)
        precondition(reason(stop, at: now.addingTimeInterval(-1)) != nil)
        precondition(reason(stop, peer: UUID()) != nil)
        precondition(reason(stop, peer: nil) != nil)
        precondition(reason(stop, session: UUID()) != nil)
        precondition(reason(stop, session: nil) != nil)
        recording.observeTimer(at: now.addingTimeInterval(1))
        precondition(reason(stop, at: now.addingTimeInterval(1)) == nil)
        recording.expire(at: now.addingTimeInterval(7))
        precondition(reason(stop) != nil, "A state transition must invalidate the old stop toggle")
        recording.observeTimer(at: now.addingTimeInterval(8))
        precondition(reason(stop) != nil, "Returning to recording must not revive an obsolete toggle")

        var queue = Insta360RemoteCommandQueue()
        let start = queued(.startRecording, cameraID: cameraID)
        let other = queued(.startRecording, cameraID: secondCameraID)
        precondition(queue.enqueue(start).isEmpty)
        precondition(queue.enqueue(other).isEmpty)
        let replacement = queued(.stopRecording, cameraID: cameraID)
        precondition(queue.enqueue(replacement).map(\.result.id) == [start.result.id])
        precondition(queue.commands.map(\.result.id) == [other.result.id, replacement.result.id])
        precondition(queue.remove(for: cameraID).map(\.result.id) == [replacement.result.id])
        precondition(queue.first?.result.id == other.result.id, "Discarding one camera must not block another")
        precondition(queue.removeFirst().result.id == other.result.id)
        precondition(queue.first == nil)
        queue.enqueue(start)
        precondition(queue.removeAll().count == 1)
        precondition(queue.first == nil)

        // Expiry must be independent of the transport's readiness callback.
        let older = queued(.stopRecording, cameraID: cameraID)
        let newer = queued(.startRecording, cameraID: secondCameraID, enqueuedAt: now.addingTimeInterval(1))
        queue.enqueue(older)
        queue.enqueue(newer)
        let expired = queue.discardInvalid { reason($0, at: now.addingTimeInterval(2)) }
        precondition(expired.map(\.command.result.id) == [older.result.id])
        precondition(queue.first?.result.id == newer.result.id)
        precondition(queue.discardInvalid { reason($0, at: now.addingTimeInterval(3)) }.count == 1)
        precondition(queue.first == nil, "A late readiness callback must have no expired toggle left to send")

        // A stale command behind a valid head must also be discarded while busy.
        queue.enqueue(older)
        queue.enqueue(newer)
        let disconnected = queue.discardInvalid { command in
            reason(command, at: now.addingTimeInterval(1), session: command.result.cameraID == cameraID ? sessionID : nil)
        }
        precondition(disconnected.map(\.command.result.id) == [newer.result.id])
        precondition(queue.first?.result.id == older.result.id)
        precondition(queue.discardInvalid { _ in nil }.isEmpty)
    }
}
