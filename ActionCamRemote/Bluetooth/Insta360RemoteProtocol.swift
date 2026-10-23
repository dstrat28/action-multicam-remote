import Foundation

enum Insta360RemoteAssignmentMatch: String, Equatable {
    case cameraSerialIdentifier = "camera serial identifier"
    case exactPeerIdentifier = "exact peer identifier"
    case requestOrderFallback = "request-order fallback"

    var authorityRank: Int {
        switch self {
        case .cameraSerialIdentifier: 3
        case .exactPeerIdentifier: 2
        case .requestOrderFallback: 1
        }
    }
}

struct Insta360RemoteAssignment: Equatable {
    var cameraID: UUID
    var match: Insta360RemoteAssignmentMatch
}

struct Insta360RemoteRecordingStatus {
    private(set) var state: CameraRecordingState = .unknown
    private(set) var revision = 0
    private(set) var lastTimerAt: Date?
    private var awaitingFeedbackSince: Date?

    func rejectionReason(for command: CameraCommand) -> String? {
        switch command {
        case .startRecording where state == .recording:
            return "The Insta360 camera is already recording; no shutter toggle was sent."
        case .stopRecording where state != .recording:
            return "Insta360 recording is not currently confirmed; the stop toggle was not sent. Check the camera before using its shutter."
        case .capturePhoto where state == .recording:
            return "The Insta360 camera is recording; a photo shutter would stop recording."
        default:
            return nil
        }
    }

    mutating func shutterSent(at now: Date) {
        awaitingFeedbackSince = now
        revision += 1
    }

    @discardableResult
    mutating func observeTimer(at now: Date) -> Bool {
        lastTimerAt = now
        awaitingFeedbackSince = nil
        guard state != .recording else { return false }
        state = .recording
        revision += 1
        return true
    }

    @discardableResult
    mutating func expire(at now: Date) -> Bool {
        guard let lastObservation = awaitingFeedbackSince ?? lastTimerAt,
              now.timeIntervalSince(lastObservation) > Insta360RemoteProtocol.recordingStatusTimeout else {
            return false
        }
        self.lastTimerAt = nil
        awaitingFeedbackSince = nil
        // Silence can mean stopped recording, lost traffic, or a suspended app.
        // The GPS Remote protocol does not give us an authoritative stop event.
        state = .unknown
        revision += 1
        return true
    }
}

struct Insta360RemotePendingCommand {
    static let lifetime: TimeInterval = 2

    let data: Data
    let result: CameraCommandResult
    let peerID: UUID
    let sessionID: UUID
    let recordingRevision: Int
    let enqueuedAt: Date

    func discardReason(
        now: Date,
        peerID: UUID?,
        sessionID: UUID?,
        recordingRevision: Int?
    ) -> String? {
        let age = now.timeIntervalSince(enqueuedAt)
        guard age >= 0, age < Self.lifetime else {
            return "The queued Insta360 command expired; no delayed shutter toggle was sent."
        }
        guard self.peerID == peerID, self.sessionID == sessionID else {
            return "The Insta360 connection changed; the queued command was discarded."
        }
        guard self.recordingRevision == recordingRevision else {
            return "Recording status changed while the Insta360 command was queued; no toggle was sent."
        }
        return nil
    }
}

struct Insta360RemoteCommandQueue {
    private(set) var commands: [Insta360RemotePendingCommand] = []

    var first: Insta360RemotePendingCommand? { commands.first }

    @discardableResult
    mutating func enqueue(_ command: Insta360RemotePendingCommand) -> [Insta360RemotePendingCommand] {
        let superseded = remove(for: command.result.cameraID)
        commands.append(command)
        return superseded
    }

    @discardableResult
    mutating func removeFirst() -> Insta360RemotePendingCommand {
        commands.removeFirst()
    }

    @discardableResult
    mutating func remove(for cameraID: UUID) -> [Insta360RemotePendingCommand] {
        let removed = commands.filter { $0.result.cameraID == cameraID }
        commands.removeAll { $0.result.cameraID == cameraID }
        return removed
    }

    mutating func removeAll() -> [Insta360RemotePendingCommand] {
        let removed = commands
        commands.removeAll()
        return removed
    }

    mutating func discardInvalid(
        reasonForCommand: (Insta360RemotePendingCommand) -> String?
    ) -> [(command: Insta360RemotePendingCommand, reason: String)] {
        var discarded: [(command: Insta360RemotePendingCommand, reason: String)] = []
        commands.removeAll { command in
            guard let reason = reasonForCommand(command) else { return false }
            discarded.append((command, reason))
            return true
        }
        return discarded
    }
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
    static func cameraID(
        matching identifier: Data,
        cameraNamesByID: [UUID: String],
        requestedCameraIDs: [UUID]
    ) -> UUID? {
        requestedCameraIDs.first { cameraID in
            guard let cameraName = cameraNamesByID[cameraID] else { return false }
            return Insta360RemoteProtocol.wakeIdentifier(from: cameraName) == identifier
        }
    }

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
        recordingTimeLabel(from: data) != nil
    }

    static func recordingTimeLabel(from data: Data) -> String? {
        guard data.count >= 18 else { return nil }
        // Keep whole printable tokens so malformed times cannot be accepted
        // by matching a valid-looking substring inside another value.
        let tokens = data.split { byte in
            !(0x21 ... 0x7E).contains(byte)
        }
        for token in tokens {
            guard token.allSatisfy({ $0 == 0x3A || (0x30 ... 0x39).contains($0) }) else { continue }
            let components = token.split(separator: 0x3A, omittingEmptySubsequences: false)
            guard components.count == 2 || components.count == 3,
                  components.allSatisfy({ !$0.isEmpty }),
                  components.dropFirst().allSatisfy({ component in
                      guard component.count == 2,
                            let value = Int(String(decoding: component, as: UTF8.self)) else { return false }
                      return value < 60
                  }) else {
                continue
            }
            return String(decoding: token, as: UTF8.self)
        }
        return nil
    }

    static func wakeIdentifier(from cameraName: String) -> Data? {
        let trimmed = cameraName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return nil }
        let suffix = trimmed.suffix(6)
        guard suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return Data(suffix.utf8)
    }

    static func cameraIdentifier(from data: Data) -> Data? {
        // The GPS Remote handshake identifies the camera with a CE81 packet shaped as:
        // FE EF FE 07 00 06 <six ASCII identifier bytes>.
        guard data.count >= 12,
              data.starts(with: [0xFE, 0xEF, 0xFE, 0x07, 0x00, 0x06]) else {
            return nil
        }
        let identifier = data.subdata(in: 6 ..< 12)
        guard identifier.allSatisfy({ byte in
            (0x30 ... 0x39).contains(byte)
                || (0x41 ... 0x5A).contains(byte)
                || (0x61 ... 0x7A).contains(byte)
        }) else {
            return nil
        }
        return identifier
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
        case .insta360Ace, .insta360X6, .insta360X5, .insta360X4, .insta360X3:
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
        if signature.hasPrefix("x6") {
            return .insta360X6
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
