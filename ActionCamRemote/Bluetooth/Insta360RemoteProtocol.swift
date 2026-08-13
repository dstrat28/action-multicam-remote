import Foundation

enum Insta360RemoteAssignmentMatch: String, Equatable {
    case exactPeerIdentifier = "exact peer identifier"
    case requestOrderFallback = "request-order fallback"
}

struct Insta360RemoteAssignment: Equatable {
    var cameraID: UUID
    var match: Insta360RemoteAssignmentMatch
}

enum Insta360RemoteSessionTimeoutDisposition: Equatable {
    case commandReady
    case activeAwaitingCommands
    case reset
    case waitingForCamera
}

enum Insta360RemoteSessionPolicy {
    static let activityFreshnessInterval: TimeInterval = 10
    static let duplicatePacketLogInterval: TimeInterval = 15

    static func timeoutDisposition(
        hasAssignedCentral: Bool,
        isSubscribed: Bool,
        lastActivity: Date?,
        now: Date
    ) -> Insta360RemoteSessionTimeoutDisposition {
        guard hasAssignedCentral else { return .waitingForCamera }
        if isSubscribed { return .commandReady }
        guard let lastActivity,
              now.timeIntervalSince(lastActivity) <= activityFreshnessInterval else {
            return .reset
        }
        return .activeAwaitingCommands
    }

    static func shouldLogPacket(lastLoggedAt: Date?, now: Date) -> Bool {
        guard let lastLoggedAt else { return true }
        return now.timeIntervalSince(lastLoggedAt) >= duplicatePacketLogInterval
    }
}

enum Insta360RemoteAssignmentStrategy {
    static func assignments(
        peerIdentifiers: [UUID],
        requestedCameraIDs: [UUID],
        assignedCameraIDs: Set<UUID>
    ) -> [UUID: Insta360RemoteAssignment] {
        var assignments: [UUID: Insta360RemoteAssignment] = [:]
        var assignedCameraIDs = assignedCameraIDs

        // Restore exact CoreBluetooth identities first so an unmatched peer cannot
        // consume a remembered camera that has an exact restored subscription.
        for peerIdentifier in peerIdentifiers where requestedCameraIDs.contains(peerIdentifier) {
            guard !assignedCameraIDs.contains(peerIdentifier) else { continue }
            assignments[peerIdentifier] = Insta360RemoteAssignment(
                cameraID: peerIdentifier,
                match: .exactPeerIdentifier
            )
            assignedCameraIDs.insert(peerIdentifier)
        }

        for peerIdentifier in peerIdentifiers where assignments[peerIdentifier] == nil {
            guard let cameraID = requestedCameraIDs.first(where: { !assignedCameraIDs.contains($0) }) else {
                break
            }
            assignments[peerIdentifier] = Insta360RemoteAssignment(
                cameraID: cameraID,
                match: .requestOrderFallback
            )
            assignedCameraIDs.insert(cameraID)
        }

        return assignments
    }

    static func assignment(
        peerIdentifier: UUID,
        requestedCameraIDs: [UUID],
        assignedCameraIDs: Set<UUID>
    ) -> Insta360RemoteAssignment? {
        if requestedCameraIDs.contains(peerIdentifier),
           !assignedCameraIDs.contains(peerIdentifier) {
            return Insta360RemoteAssignment(
                cameraID: peerIdentifier,
                match: .exactPeerIdentifier
            )
        }

        guard let cameraID = requestedCameraIDs.first(where: { !assignedCameraIDs.contains($0) }) else {
            return nil
        }
        return Insta360RemoteAssignment(
            cameraID: cameraID,
            match: .requestOrderFallback
        )
    }
}

enum Insta360RemoteProtocol {
    static let remoteName = "Insta360 GPS Remote"
    static let wakeAdvertisementDuration: TimeInterval = 4
    static let wakeMeasuredPower = -28

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

    static func wakeBeaconUUID(from cameraName: String) -> UUID? {
        guard let identifier = wakeIdentifier(from: cameraName) else { return nil }
        let bytes = Data([0x09, 0x4F, 0x52, 0x42, 0x49, 0x54, 0x09, 0xFF, 0x0F, 0x00]) + identifier
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        guard hex.count == 32 else { return nil }
        let part1 = String(hex.prefix(8))
        let part2 = String(hex.dropFirst(8).prefix(4))
        let part3 = String(hex.dropFirst(12).prefix(4))
        let part4 = String(hex.dropFirst(16).prefix(4))
        let part5 = String(hex.suffix(12))
        let uuidString = "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)"
        return UUID(uuidString: uuidString)
    }

    static func wakeManufacturerData(from cameraName: String) -> Data? {
        guard let identifier = wakeIdentifier(from: cameraName) else { return nil }
        return Data([
            0x4C, 0x00, 0x02, 0x15,
            0x09, 0x4F, 0x52, 0x42, 0x49, 0x54, 0x09, 0xFF, 0x0F, 0x00
        ]) + identifier + Data([0x00, 0x00, 0x00, 0x00, 0xE4])
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
        case .insta360AcePro,
             .insta360X4Air,
             .insta360OneRS,
             .insta360GoUltra,
             .insta360Go3S,
             .insta360Go3:
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
        if signature.hasPrefix("goultra") {
            return .insta360GoUltra
        }
        if signature.hasPrefix("go3s") {
            return .insta360Go3S
        }
        if signature.hasPrefix("go3") {
            return .insta360Go3
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
