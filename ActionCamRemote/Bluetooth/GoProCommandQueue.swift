import Foundation

enum GoProResponseChannel { case command, settings, query, management }

/// Classic replies echo a command ID. Protobuf replies echo the feature and
/// response action (request action | 0x80). Status subscriptions are not replies.
struct GoProResponseExpectation {
    var channel: GoProResponseChannel
    var prefix: Data

    init(channel: GoProResponseChannel, payload: Data) {
        self.channel = channel
        if payload.count >= 2, channel == .management || payload.first.map({ $0 >= 0xF0 }) == true {
            prefix = Data([payload[0], payload[1] | 0x80])
        } else {
            prefix = Data(payload.prefix(1))
        }
    }

    func matches(_ payload: Data, channel: GoProResponseChannel) -> Bool {
        self.channel == channel && !prefix.isEmpty && payload.count >= 2 && payload.starts(with: prefix)
    }
}

struct GoProReplyWaiter {
    var expectation: GoProResponseExpectation
    private(set) var writeCompleted = false
    private(set) var response: Data?

    var isComplete: Bool { writeCompleted && response != nil }

    mutating func didWrite() { writeCompleted = true }

    mutating func receive(_ payload: Data, channel: GoProResponseChannel) {
        guard expectation.matches(payload, channel: channel) else { return }
        response = payload
    }
}

enum GoProWriteFragmenter {
    static func fragments(_ packet: Data, maximumLength: Int) -> [Data] {
        guard maximumLength > 1, !packet.isEmpty else { return [] }
        var fragments = [Data(packet.prefix(maximumLength))]
        var offset = fragments[0].count
        var counter: UInt8 = 0
        while offset < packet.count {
            let end = min(offset + maximumLength - 1, packet.count)
            fragments.append(Data([0x80 | counter]) + packet[offset..<end])
            counter = (counter + 1) & 0x0F
            offset = end
        }
        return fragments
    }
}

/// Tracks unsent writes and the command waiting for the camera to become idle.
/// The active GATT write belongs to the client and is always followed by Stop.
struct GoProCommandQueue<Write> {
    private struct Entry {
        var write: Write
        var command: CameraCommand?
    }
    private var entries: [Entry] = []
    private var deferredCommand: CameraCommand?
    private var startRequestedAt: Date?
    static var startLifetime: TimeInterval { 10 }

    var hasPendingStart: Bool {
        deferredCommand == .startRecording || entries.contains { $0.command == .startRecording }
    }

    func remainingStartLifetime(at now: Date) -> TimeInterval? {
        guard hasPendingStart, let startRequestedAt else { return nil }
        return Self.startLifetime - now.timeIntervalSince(startRequestedAt)
    }

    var isEmpty: Bool { entries.isEmpty }

    @discardableResult
    mutating func prepare(for command: CameraCommand, at now: Date = .now) -> [Write] {
        let removed = entries.filter {
            if command == .startRecording { return $0.command == .startRecording }
            if command == .stopRecording { return Self.canStartCapture($0.command) }
            if case .loadGoProPreset = command { return Self.isReplacedByPreset($0.command) }
            return false
        }.map(\.write)
        if command == .startRecording {
            if deferredCommand == .startRecording { deferredCommand = nil }
            entries.removeAll { $0.command == .startRecording }
            startRequestedAt = now
        } else if command == .stopRecording {
            if Self.canStartCapture(deferredCommand) { deferredCommand = nil }
            entries.removeAll { Self.canStartCapture($0.command) }
            startRequestedAt = nil
        } else if case .loadGoProPreset = command {
            if Self.isReplacedByPreset(deferredCommand) { deferredCommand = nil }
            entries.removeAll { Self.isReplacedByPreset($0.command) }
            startRequestedAt = nil
        }
        return removed
    }

    /// The same deadline spans busy deferral and queued GATT writes.
    mutating func expireUnsentStart(at now: Date) -> Bool {
        guard hasPendingStart, let startRequestedAt else { return false }
        let age = now.timeIntervalSince(startRequestedAt)
        guard age < 0 || age >= Self.startLifetime else { return false }
        if deferredCommand == .startRecording { deferredCommand = nil }
        entries.removeAll { $0.command == .startRecording }
        self.startRequestedAt = nil
        return true
    }

    mutating func deferUntilIdle(_ command: CameraCommand) {
        deferredCommand = command
        if command == .startRecording, startRequestedAt == nil { startRequestedAt = .now }
        if !hasPendingStart { startRequestedAt = nil }
    }

    mutating func takeDeferredCommand(isBusy: Bool) -> CameraCommand? {
        guard !isBusy else { return nil }
        let command = deferredCommand
        deferredCommand = nil
        return command
    }

    mutating func append(_ write: Write, command: CameraCommand? = nil) {
        entries.append(.init(write: write, command: command))
        if command == .startRecording, startRequestedAt == nil { startRequestedAt = .now }
    }

    func contains(where predicate: (Write) -> Bool) -> Bool {
        entries.contains { predicate($0.write) }
    }

    mutating func removeFirst() -> Write { removeFirstEntry().write }

    mutating func removeFirstEntry() -> (write: Write, command: CameraCommand?) {
        removeEntry(at: 0)
    }

    /// Hold an unsent start until the latest camera status confirms idle Video
    /// mode. Other writes must still pass so queries can refresh that status.
    mutating func removeFirstReadyEntry(
        isBusy: Bool?,
        captureMode: CaptureMode?,
        isReady: (Write) -> Bool = { _ in true }
    ) -> (write: Write, command: CameraCommand?)? {
        guard let index = entries.firstIndex(where: {
            isReady($0.write) && ($0.command != .startRecording || (isBusy == false && captureMode == .video))
        }) else { return nil }
        return removeEntry(at: index)
    }

    private mutating func removeEntry(at index: Int) -> (write: Write, command: CameraCommand?) {
        let entry = entries.remove(at: index)
        if entry.command == .startRecording, !hasPendingStart { startRequestedAt = nil }
        return (entry.write, entry.command)
    }

    mutating func removeAll() {
        entries.removeAll()
        deferredCommand = nil
        startRequestedAt = nil
    }

    private static func canStartCapture(_ command: CameraCommand?) -> Bool {
        switch command {
        case .startRecording, .capturePhoto, .toggleRecording: true
        default: false
        }
    }

    private static func isReplacedByPreset(_ command: CameraCommand?) -> Bool {
        switch command {
        case .startRecording, .capturePhoto, .toggleRecording, .setMode, .cycleMode, .loadGoProPreset: true
        default: false
        }
    }
}
