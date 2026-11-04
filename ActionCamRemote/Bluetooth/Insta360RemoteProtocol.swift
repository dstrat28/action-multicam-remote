import Foundation

/// X4 remote captures show a connection-local button counter advancing by two.
/// Advance only after CoreBluetooth accepts the notification, not on backpressure.
struct Insta360RemoteButtonSequence {
    private(set) var value: UInt8 = 0

    func packet(_ template: Data) -> Data {
        guard template.count == 9, template.starts(with: [0xFC, 0xEF, 0xFE, 0x86]) else { return template }
        var packet = template
        packet[4] = value
        return packet
    }

    mutating func didSend() { value &+= 2 }
}

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
    private(set) var awaitingStopFeedback = false

    func rejectionReason(for command: CameraCommand) -> String? {
        if awaitingFeedbackSince != nil {
            switch command {
            case .startRecording, .stopRecording, .capturePhoto, .toggleRecording:
                return "Waiting for camera feedback from the previous Insta360 shutter press. No second toggle was sent."
            default: break
            }
        }
        if state == .unknown, lastTimerAt != nil {
            switch command {
            case .startRecording, .capturePhoto, .toggleRecording:
                return "The camera may still be recording; wait for updated camera feedback before another shutter press."
            default: break
            }
        }
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
        awaitingStopFeedback = state == .recording
        awaitingFeedbackSince = now
        revision += 1
    }

    @discardableResult
    mutating func observeTimer(at now: Date) -> Bool {
        lastTimerAt = now
        // A timer can confirm Start, but a trailing timer cannot confirm Stop.
        // Keep Stop blocked until the feedback window expires.
        guard !awaitingStopFeedback else { return false }
        awaitingFeedbackSince = nil
        guard state != .recording else { return false }
        state = .recording
        revision += 1
        return true
    }

    @discardableResult
    mutating func expire(at now: Date) -> Bool {
        guard let lastObservation = awaitingFeedbackSince ?? lastTimerAt else { return false }
        let elapsed = now.timeIntervalSince(lastObservation)
        let expired = awaitingStopFeedback
            ? elapsed >= Insta360RemoteProtocol.stopFeedbackCooldown
            : elapsed > Insta360RemoteProtocol.recordingStatusTimeout
        guard expired else {
            return false
        }
        // Trailing timers cannot confirm Stop. Once its short cooldown ends,
        // allow a new explicit shutter action without requiring proof of Stop.
        // A new timer after this point can establish Recording again.
        lastTimerAt = nil
        awaitingFeedbackSince = nil
        awaitingStopFeedback = false
        // Expiry cannot distinguish stopped recording from lost traffic or a
        // suspended app; pre-expiry timers cannot settle the Stop request.
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
    static let stopFeedbackCooldown: TimeInterval = 3

    static func isRecordingTimerPacket(_ data: Data) -> Bool {
        recordingTimeLabel(from: data) != nil
    }

    static func recordingTimeLabel(from data: Data) -> String? {
        let text: Data
        let isDisplayFrame = data.starts(with: [0xFE, 0xEF, 0xFE])
        if isDisplayFrame {
            // CE81 display frame: FE EF FE 10 <flag> <payload length>,
            // then four display-control bytes and the elapsed-time text.
            guard data.count >= 10, data[data.startIndex + 3] == 0x10 else { return nil }
            let payloadLength = Int(data[data.startIndex + 5])
            guard payloadLength > 4, data.count >= 6 + payloadLength else { return nil }
            text = Data(data.dropFirst(10).prefix(payloadLength - 4))
        } else {
            guard data.count >= 18 else { return nil }
            text = data
        }
        // Keep whole printable tokens so malformed times cannot be accepted
        // by matching a valid-looking substring inside another value.
        let tokens = text.split { byte in
            !(0x21 ... 0x7E).contains(byte)
        }
        for token in tokens {
            // GPS Remote timers can carry a leading '.' display marker.
            // Only strip it inside a complete display frame, never from
            // arbitrary binary traffic or from the middle of another token.
            let timer = isDisplayFrame && token.first == 0x2E ? token.dropFirst() : token
            guard timer.allSatisfy({ $0 == 0x3A || (0x30 ... 0x39).contains($0) }) else { continue }
            let components = timer.split(separator: 0x3A, omittingEmptySubsequences: false)
            guard components.count == 2 || components.count == 3,
                  components.allSatisfy({ !$0.isEmpty }),
                  components.dropFirst().allSatisfy({ component in
                      guard component.count == 2,
                            let value = Int(String(decoding: component, as: UTF8.self)) else { return false }
                      return value < 60
                  }) else {
                continue
            }
            return String(decoding: timer, as: UTF8.self)
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

        var words = name
            .split { !$0.isLetter && !$0.isNumber }
            .map { $0.lowercased() }
        if words.first == "insta360" { words.removeFirst() }
        let modelWords = Array(words.dropLast())
        let prefixes: [[String]]
        switch model {
        case .insta360AcePro2:
            prefixes = [["ace", "pro", "2"]]
        case .insta360AcePro:
            prefixes = [["ace", "pro"]]
        case .insta360Ace:
            prefixes = [["ace"]]
        case .insta360X6: prefixes = [["x6"]]
        case .insta360X5: prefixes = [["x5"]]
        case .insta360X4Air: prefixes = [["x4", "air"]]
        case .insta360X4: prefixes = [["x4"]]
        case .insta360X3: prefixes = [["x3"]]
        case .insta360X2: prefixes = [["x2"], ["one", "x2"]]
        case .insta360OneX: prefixes = [["one", "x"]]
        case .insta360OneR: prefixes = [["one", "r"]]
        case .insta360OneRS: prefixes = [["one", "rs"], ["rs"]]
        case .insta360OneRS1Inch:
            prefixes = [["one", "rs", "1", "inch"], ["one", "rs", "1", "inch", "360"],
                        ["one", "rs", "1", "inch", "360", "edition"]]
        case .insta360GoUltra: prefixes = [["go", "ultra"]]
        case .insta360Go3S: prefixes = [["go", "3s"]]
        case .insta360Go3: prefixes = [["go", "3"]]
        default:
            return false
        }
        return prefixes.contains(modelWords)
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
        if signature.hasPrefix("x2") || signature.hasPrefix("onex2") {
            return .insta360X2
        }
        if signature.hasPrefix("onex") {
            return .insta360OneX
        }
        if signature.hasPrefix("oners1inch") {
            return .insta360OneRS1Inch
        }
        if signature.hasPrefix("oners") || signature.hasPrefix("rs") {
            return .insta360OneRS
        }
        if signature.hasPrefix("oner") {
            return .insta360OneR
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
            let value = name.lowercased().filter { $0.isLetter || $0.isNumber }
            normalized = value.hasPrefix("insta360") ? String(value.dropFirst("insta360".count)) : value
        }

        func contains(_ value: String) -> Bool {
            normalized.contains(value)
        }

        func hasPrefix(_ value: String) -> Bool {
            normalized.hasPrefix(value)
        }
    }
}
