import Foundation

@main
enum CommandResultArchiveRegression {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MulticamCommands-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await checkCompletionAndRelaunch(in: directory)
        try await checkLimits(in: directory)
        try await checkResetAndExport(in: directory)
        try await checkStorageFailure(in: directory)
        await checkDemoIsolation()
        print("Command history checks passed: relaunch, completion updates, count/byte limits, reset ordering, full export, support attachment, storage recovery, and demo isolation.")
    }

    private static func result(_ index: Int = 0, message: String = "Sent to camera") -> CameraCommandResult {
        CameraCommandResult(
            cameraID: UUID(), cameraName: "Camera \(index)", command: .startRecording,
            status: .queued, message: message,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
        )
    }

    private static func checkCompletionAndRelaunch(in directory: URL) async throws {
        let location = directory.appendingPathComponent("completion")
        let archive = CommandResultArchive(directory: location)
        var first = result()
        let second = result(1)
        archive.record(first) { _ in }
        archive.record(second) { _ in }
        first.status = .failed
        first.message = "Expired before delivery"
        archive.record(first) { _ in }
        let snapshot = await archive.snapshot()
        precondition(snapshot.results.map(\.id) == [second.id, first.id], "Completing an older command must not reorder user actions or add a duplicate")
        precondition(snapshot.results.last?.status == .failed)
        precondition(snapshot.storageError == nil)

        let file = location.appendingPathComponent("commands.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"timestamp\":".utf8))
        try handle.close()
        let relaunched = CommandResultArchive(directory: location)
        precondition(relaunched.initialSnapshot.results.map(\.id) == [second.id, first.id])
        precondition(relaunched.initialSnapshot.results.last?.message == "Expired before delivery")
        _ = await relaunched.snapshot()
    }

    private static func checkLimits(in directory: URL) async throws {
        let location = directory.appendingPathComponent("count")
        let archive = CommandResultArchive(directory: location, maximumCount: 3)
        for index in 0..<8 { archive.record(result(index)) { _ in } }
        let limited = await archive.snapshot()
        precondition(limited.results.map(\.cameraName) == ["Camera 7", "Camera 6", "Camera 5"])
        precondition(CommandResultArchive(directory: location).initialSnapshot.results.count == 3)

        let byteLocation = directory.appendingPathComponent("bytes")
        let bytes = CommandResultArchive(directory: byteLocation, maximumBytes: 1_024)
        for index in 0..<8 { bytes.record(result(index, message: String(repeating: "x", count: 150))) { _ in } }
        let before = await bytes.snapshot()
        precondition(!before.results.isEmpty && before.results.count < 8)
        let fileBytes = try Data(contentsOf: byteLocation.appendingPathComponent("commands.jsonl"))
        precondition(fileBytes.count <= 1_024)
        bytes.record(result(9, message: String(repeating: "x", count: 2_048))) { _ in }
        let after = await bytes.snapshot()
        precondition(after.results.map(\.id) == before.results.map(\.id), "An oversized result must not evict history")

        let defaults = CommandResultArchive(directory: nil)
        for index in 0..<505 { defaults.record(result(index)) { _ in } }
        let defaultSnapshot = await defaults.snapshot()
        precondition(defaultSnapshot.results.count == 500)
    }

    private static func checkResetAndExport(in directory: URL) async throws {
        let location = directory.appendingPathComponent("reset")
        let commands = CommandResultArchive(directory: location)
        let logs = DiagnosticLogArchive(directory: location)
        logs.append(DiagnosticLogEntry(timestamp: .now, message: "Bluetooth connection kept")) { _ in }
        commands.record(result(0, message: "Before reset")) { _ in }
        commands.clear { _ in }
        for index in 1...25 { commands.record(result(index, message: "After reset · caméra \(index)")) { _ in } }
        let snapshot = await commands.snapshot()
        precondition(snapshot.results.count == 25 && !snapshot.reportSection.contains("Before reset"))
        let file = try await logs.export(context: "Diagnostics Context\n\n" + snapshot.reportSection, directory: directory)
        let report = try String(contentsOf: file, encoding: .utf8)
        precondition(report.contains("Command Results (newest first)") && report.contains("Bluetooth Log (newest first)"))
        precondition(report.contains("caméra 1\n") && report.contains("caméra 25"), "Export must include retained commands beyond the six displayed and old twenty-command export limit")
        precondition(report.contains("Bluetooth connection kept"), "Resetting commands must leave Bluetooth logs intact")
        let draft = try SupportEmailDraft(diagnosticsURL: file, version: "1.2.2 (43)")
        precondition(draft.attachmentData == Data(report.utf8), "The support email must attach the entire UTF-8 diagnostics report")
        precondition(draft.attachmentName == file.lastPathComponent && draft.attachmentMIMEType == "text/plain")
        precondition(draft.subject.contains("1.2.2 (43)"))
        do {
            _ = try SupportEmailDraft(diagnosticsURL: directory.appendingPathComponent("missing.txt"), version: "1.2.2")
            preconditionFailure("An attachment read failure must prevent preparing an incomplete email")
        } catch {}

        commands.clear { _ in }
        let cleared = await commands.snapshot()
        precondition(cleared.results.isEmpty && cleared.reportSection.contains("No saved commands."))
        precondition(CommandResultArchive(directory: location).initialSnapshot.results.isEmpty)
    }

    private static func checkStorageFailure(in directory: URL) async throws {
        let location = directory.appendingPathComponent("blocked")
        try Data("Blocked directory".utf8).write(to: location)
        let archive = CommandResultArchive(directory: location)
        archive.record(result()) { _ in }
        let failed = await archive.snapshot()
        precondition(failed.results.count == 1 && failed.storageError != nil)
        precondition(failed.reportSection.contains("Command archive storage error:"))
        try FileManager.default.removeItem(at: location)
        let recovered = await archive.snapshot()
        precondition(recovered.storageError == nil)
        precondition(CommandResultArchive(directory: location).initialSnapshot.results.count == 1)
    }

    private static func checkDemoIsolation() async {
        let archive = CommandResultArchive(directory: nil)
        archive.record(result()) { _ in }
        let snapshot = await archive.snapshot()
        precondition(snapshot.results.count == 1)
        precondition(CommandResultArchive(directory: nil).initialSnapshot.results.isEmpty)
    }
}
