import Foundation

@main
enum Insta360RemoteProtocolRegression {
    static func main() {
        let expectedModels: [(String, CameraModel)] = [
            ("Ace Pro 2 ABC123", .insta360AcePro2),
            ("ACE PRO X9Y8Z7", .insta360AcePro),
            ("Ace Q1W2E3", .insta360Ace),
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
        precondition(!Insta360CameraNameClassifier.isCredibleCameraName("X5 Speaker ABC123"))
        precondition(!Insta360CameraNameClassifier.isCredibleCameraName("GO 3S Speaker ABC123"))
        precondition(Insta360CameraNameClassifier.model(for: "GoPro HERO13 ABC123") == .unknown)

        let firstCameraID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondCameraID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
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
}
