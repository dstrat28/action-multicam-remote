import Foundation

enum Insta360RemoteProtocol {
    static let remoteName = "Insta360 GPS Remote"

    static let shutterCommand = Data([0xFC, 0xEF, 0xFE, 0x86, 0x00, 0x03, 0x01, 0x02, 0x00])
    static let cycleModeCommand = Data([0xFC, 0xEF, 0xFE, 0x86, 0x00, 0x03, 0x01, 0x01, 0x00])
    static let toggleScreenCommand = Data([0xFC, 0xEF, 0xFE, 0x86, 0x00, 0x03, 0x01, 0x00, 0x00])
    static let powerOffCommand = Data([0xFC, 0xEF, 0xFE, 0x86, 0x00, 0x03, 0x01, 0x00, 0x03])

    static let recordingStatusTimeout: TimeInterval = 5

    static func isRecordingTimerPacket(_ data: Data) -> Bool {
        data.count >= 18 && data.contains(0x3A)
    }

    static func recordingTimeLabel(from data: Data) -> String? {
        guard isRecordingTimerPacket(data) else { return nil }

        let printable = data.map { byte -> Character in
            if (0x20 ... 0x7E).contains(byte), let scalar = UnicodeScalar(Int(byte)) {
                return Character(scalar)
            }
            return " "
        }
        let text = String(printable)
        return text
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
            .first(where: { token in
                let components = token.split(separator: ":")
                return components.count >= 2
                    && components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            })
    }

    static func wakeIdentifier(from cameraName: String) -> Data? {
        let trimmed = cameraName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return nil }
        let suffix = trimmed.suffix(6)
        guard suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return Data(suffix.utf8)
    }
}

struct Insta360CameraNameClassifier {
    static func isCredibleCameraName(_ name: String) -> Bool {
        let model = model(for: name)
        guard model != .unknown,
              Insta360RemoteProtocol.wakeIdentifier(from: name) != nil else {
            return false
        }

        let words = name
            .split { !$0.isLetter && !$0.isNumber }
            .map { $0.lowercased() }
        let expectedWordCount: Int
        switch model {
        case .insta360AcePro2:
            expectedWordCount = 4
        case .insta360AcePro, .insta360X4Air, .insta360OneRS:
            expectedWordCount = 3
        case .insta360Ace, .insta360X5, .insta360X4, .insta360X3:
            expectedWordCount = 2
        default:
            return false
        }
        return words.count == expectedWordCount
    }

    static func model(for name: String) -> CameraModel {
        let signature = Signature(name)

        if signature.contains("acepro2") {
            return .insta360AcePro2
        }
        if signature.contains("acepro") {
            return .insta360AcePro
        }
        if signature.hasPrefix("ace") {
            return .insta360Ace
        }
        if signature.contains("x4air") {
            return .insta360X4Air
        }
        if signature.hasPrefix("x5") {
            return .insta360X5
        }
        if signature.hasPrefix("x4") {
            return .insta360X4
        }
        if signature.hasPrefix("x3") {
            return .insta360X3
        }
        if signature.hasPrefix("oners") || signature.hasPrefix("rs") {
            return .insta360OneRS
        }

        return .unknown
    }

    private struct Signature {
        let normalized: String

        init(_ name: String) {
            normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        func contains(_ value: String) -> Bool {
            normalized.contains(value)
        }

        func hasPrefix(_ value: String) -> Bool {
            normalized.hasPrefix(value)
        }
    }
}
