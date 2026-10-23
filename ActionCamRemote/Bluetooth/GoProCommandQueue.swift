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

    var isEmpty: Bool { entries.isEmpty }

    mutating func prepare(for command: CameraCommand) {
        guard command == .stopRecording else { return }
        if Self.canStartCapture(deferredCommand) { deferredCommand = nil }
        entries.removeAll { Self.canStartCapture($0.command) }
    }

    mutating func deferUntilIdle(_ command: CameraCommand) {
        deferredCommand = command
    }

    mutating func takeDeferredCommand(isBusy: Bool) -> CameraCommand? {
        guard !isBusy else { return nil }
        let command = deferredCommand
        deferredCommand = nil
        return command
    }

    mutating func append(_ write: Write, command: CameraCommand? = nil) {
        entries.append(.init(write: write, command: command))
    }

    func contains(where predicate: (Write) -> Bool) -> Bool {
        entries.contains { predicate($0.write) }
    }

    mutating func removeFirst() -> Write { entries.removeFirst().write }

    mutating func removeAll() {
        entries.removeAll()
        deferredCommand = nil
    }

    private static func canStartCapture(_ command: CameraCommand?) -> Bool {
        switch command {
        case .startRecording, .capturePhoto, .toggleRecording: true
        default: false
        }
    }
}
