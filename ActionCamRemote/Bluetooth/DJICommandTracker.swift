import Foundation

/// Track camera acknowledgements independently of transport delivery. Expired
/// commands are reported and discarded; mutation commands are never replayed.
struct DJICommandTracker {
    struct Entry {
        var sequence: UInt16
        var commandID: UInt8
        var result: CameraCommandResult
        var expiresAt: TimeInterval
        var wasSent = false
    }
    private var entries: [UInt16: Entry] = [:]
    var isEmpty: Bool { entries.isEmpty }
    private var latestCaptureSequence: UInt16?

    func isLatestCapture(sequence: UInt16) -> Bool { latestCaptureSequence == sequence }

    mutating func register(sequence: UInt16, commandID: UInt8, result: CameraCommandResult, at now: TimeInterval) {
        entries[sequence] = Entry(sequence: sequence, commandID: commandID, result: result, expiresAt: now + 5)
        if commandID == 0x03 { latestCaptureSequence = sequence }
    }

    func canSend(sequence: UInt16, at now: TimeInterval) -> Bool {
        guard let entry = entries[sequence] else { return false }
        return !entry.wasSent && now < entry.expiresAt
    }

    mutating func didSend(sequence: UInt16, at now: TimeInterval) {
        guard entries[sequence] != nil else { return }
        entries[sequence]?.wasSent = true
        entries[sequence]?.expiresAt = now + 3
    }

    mutating func acknowledge(sequence: UInt16, commandID: UInt8, returnCode: UInt8, at now: TimeInterval) -> CameraCommandResult? {
        guard let entry = entries[sequence], entry.commandID == commandID, entry.wasSent, now < entry.expiresAt else { return nil }
        entries.removeValue(forKey: sequence)
        return completed(entry, status: returnCode == 0 ? .sent : .failed,
            message: returnCode == 0 ? "DJI acknowledged \(entry.result.command.label); camera status confirms the result."
                : "DJI rejected \(entry.result.command.label) (\(returnCode)).")
    }

    mutating func expire(at now: TimeInterval) -> [Entry] {
        let expired = entries.values.filter { now >= $0.expiresAt }
        for entry in expired { entries.removeValue(forKey: entry.sequence) }
        return expired
    }

    mutating func cancelUnsentStarts() -> [Entry] {
        let cancelled = entries.values.filter {
            !$0.wasSent && ($0.result.command == .startRecording || $0.result.command == .capturePhoto)
        }
        for entry in cancelled { entries.removeValue(forKey: entry.sequence) }
        return cancelled
    }

    mutating func removeAll() -> [Entry] {
        let removed = Array(entries.values)
        entries.removeAll()
        latestCaptureSequence = nil
        return removed
    }

    func completed(_ entry: Entry, status: CameraCommandStatus, message: String) -> CameraCommandResult {
        var result = entry.result
        result.status = status
        result.message = message
        result.timestamp = Date()
        return result
    }
}
