import Foundation

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

    mutating func prepare(for command: CameraCommand, at now: Date = .now) {
        if command == .startRecording {
            if deferredCommand == .startRecording { deferredCommand = nil }
            entries.removeAll { $0.command == .startRecording }
            startRequestedAt = now
        } else if command == .stopRecording {
            if Self.canStartCapture(deferredCommand) { deferredCommand = nil }
            entries.removeAll { Self.canStartCapture($0.command) }
            startRequestedAt = nil
        }
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
        let entry = entries.removeFirst()
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
}
