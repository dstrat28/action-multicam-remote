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

        precondition(!Insta360CameraNameClassifier.isCredibleCameraName("X5"))
        precondition(!Insta360CameraNameClassifier.isCredibleCameraName("X5 Speaker ABC123"))
        precondition(!Insta360CameraNameClassifier.isCredibleCameraName("GO 3S Speaker ABC123"))
        precondition(Insta360CameraNameClassifier.model(for: "GoPro HERO13 ABC123") == .unknown)

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

        print("Insta360 remote protocol regression checks passed (\(expectedModels.count) models).")
    }
}
