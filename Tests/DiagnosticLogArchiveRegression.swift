import Foundation
import Darwin

@main
enum DiagnosticLogArchiveRegression {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MulticamLogRegression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date.now

        try await checkRelaunchAndInterruptedWrite(in: directory, now: now)
        try await checkByteCap(in: directory, now: now)
        try await checkExportAndQueueOrder(in: directory, now: now)
        try await checkStorageFailureAndRecovery(in: directory, now: now)
        try await checkClearAndQueueOrder(in: directory, now: now)
        await checkMemoryOnlyArchive(now: now)
        print("Diagnostic archive regression checks passed: relaunch, interrupted write, byte cap, full ordered export, storage failure/recovery, clear, and demo isolation.")
    }

    private static func checkRelaunchAndInterruptedWrite(in directory: URL, now: Date) async throws {
        let location = directory.appendingPathComponent("relaunch", isDirectory: true)
        let archive = DiagnosticLogArchive(directory: location)
        let attempt = DiagnosticLogEntry(timestamp: now.addingTimeInterval(-30 * 24 * 60 * 60), message: "Camera connection failed\nHandshake timed out")
        archive.append(attempt) { _ in }
        let original = await archive.snapshot()
        precondition(original.storageError == nil)

        let url = location.appendingPathComponent("events.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"timestamp\":".utf8))
        try handle.close()

        let relaunched = DiagnosticLogArchive(directory: location)
        precondition(relaunched.initialSnapshot.entries.map(\.id) == [attempt.id], "An interrupted final write must preserve earlier logs")
        precondition(relaunched.initialSnapshot.entries.first?.message == attempt.message, "Multiline messages must survive relaunch")
        let recovered = await relaunched.snapshot()
        precondition(recovered.storageError == nil)
        let repaired = DiagnosticLogArchive(directory: location)
        let repairedSnapshot = await repaired.snapshot()
        precondition(repairedSnapshot.entries.map(\.id) == [attempt.id])
#if os(macOS)
        // macOS stores this Foundation flag in a metadata attribute; the iOS
        // resource-value getter does not round-trip it on macOS temporary URLs.
        let attributeSize = getxattr(location.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0)
        precondition(attributeSize > 0, "Diagnostic history must be marked for backup exclusion")
#else
        let excluded = try location.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        precondition(excluded == true, "Diagnostic history must be marked for backup exclusion")
#endif
    }

    private static func checkByteCap(in directory: URL, now: Date) async throws {
        let byteLocation = directory.appendingPathComponent("byte-cap", isDirectory: true)
        let byteLimited = DiagnosticLogArchive(directory: byteLocation, maximumBytes: 1_024)
        for index in 0..<15 {
            byteLimited.append(DiagnosticLogEntry(timestamp: now, message: "\(index) " + String(repeating: "x", count: 120))) { _ in }
        }
        let byteCapped = await byteLimited.snapshot()
        precondition(byteCapped.storageError == nil)
        precondition(byteCapped.entries.last?.message.hasPrefix("14 ") == true)
        let bytes = try Data(contentsOf: byteLocation.appendingPathComponent("events.jsonl")).count
        precondition(bytes <= 1_024, "The persisted file must respect the byte cap")
        let oversized = DiagnosticLogEntry(timestamp: now, message: String(repeating: "x", count: 2_048))
        byteLimited.append(oversized) { _ in }
        let oversizedSnapshot = await byteLimited.snapshot()
        precondition(oversizedSnapshot.entries.map(\.id) == byteCapped.entries.map(\.id), "An oversized packet must preserve earlier logs and respect the storage cap")
    }

    private static func checkExportAndQueueOrder(in directory: URL, now: Date) async throws {
        let location = directory.appendingPathComponent("export-history", isDirectory: true)
        let archive = DiagnosticLogArchive(directory: location)
        for index in 0..<10_100 {
            archive.append(DiagnosticLogEntry(timestamp: now, message: "Connection event \(index)")) { _ in }
        }
        // No explicit flush: export must wait for all previously submitted writes.
        let firstURL = try await archive.export(context: "App/device/camera context", now: now, directory: directory)
        let report = try String(contentsOf: firstURL, encoding: .utf8)
        precondition(firstURL.pathExtension == "txt")
        precondition(report.contains("App/device/camera context"))
        precondition(report.contains("Connection event 0\n"), "Export must include entries older than the recent UI buffer")
        precondition(report.contains("Connection event 10099"), "Export must include writes queued immediately before sharing")
        precondition(report.range(of: "Connection event 10099")!.lowerBound < report.range(of: "Connection event 0\n")!.lowerBound)
        precondition(report.contains(now.ISO8601Format(.init(includingFractionalSeconds: true))), "Exports must include full dates and a time zone")

        archive.append(DiagnosticLogEntry(timestamp: now, message: "Next share")) { _ in }
        let secondURL = try await archive.export(context: "New context", now: now, directory: directory)
        precondition(firstURL != secondURL, "Each share must get its own immutable file")
        let unchangedReport = try String(contentsOf: firstURL, encoding: .utf8)
        precondition(unchangedReport == report)
        let relaunched = DiagnosticLogArchive(directory: location)
        let saved = await relaunched.snapshot()
        precondition(saved.entries.count == 10_101)
    }

    private static func checkStorageFailureAndRecovery(in directory: URL, now: Date) async throws {
        let location = directory.appendingPathComponent("blocked-directory")
        try Data("A file is blocking the archive directory".utf8).write(to: location)
        let archive = DiagnosticLogArchive(directory: location)
        archive.append(DiagnosticLogEntry(timestamp: now, message: "Keep this failed connection in memory")) { _ in }
        let failed = await archive.snapshot()
        precondition(failed.storageError != nil, "Storage failures must be visible")
        precondition(failed.entries.count == 1, "A storage failure must not discard current logs")
        let export = try await archive.export(context: "Failure context", now: now, directory: directory)
        let report = try String(contentsOf: export, encoding: .utf8)
        precondition(report.contains("Log archive storage error:"))
        precondition(report.contains("Keep this failed connection in memory"))

        try FileManager.default.removeItem(at: location)
        archive.append(DiagnosticLogEntry(timestamp: now, message: "Storage restored")) { _ in }
        let recovered = await archive.snapshot()
        precondition(recovered.storageError == nil)
        let relaunched = DiagnosticLogArchive(directory: location)
        let saved = await relaunched.snapshot()
        precondition(saved.entries.count == 2, "Retry must persist logs accumulated during the failure")
    }

    private static func checkClearAndQueueOrder(in directory: URL, now: Date) async throws {
        let location = directory.appendingPathComponent("clear", isDirectory: true)
        let archive = DiagnosticLogArchive(directory: location)
        archive.append(DiagnosticLogEntry(timestamp: now, message: "Before clear")) { _ in }
        archive.clear { _ in }
        archive.append(DiagnosticLogEntry(timestamp: now, message: "After clear")) { _ in }
        let snapshot = await archive.snapshot()
        precondition(snapshot.storageError == nil)
        precondition(snapshot.entries.map(\.message) == ["After clear"], "Clear must remove prior entries while preserving later events")
        let export = try await archive.export(context: "Clear check", now: now, directory: directory)
        let report = try String(contentsOf: export, encoding: .utf8)
        precondition(!report.contains("Before clear"), "Share must not include cleared history")
        precondition(report.contains("After clear"))

        archive.clear { _ in }
        let cleared = await archive.snapshot()
        precondition(cleared.entries.isEmpty && cleared.storageError == nil)
        let contents = try Data(contentsOf: location.appendingPathComponent("events.jsonl"))
        precondition(contents.isEmpty, "Clear must empty the persisted archive")
        let relaunched = DiagnosticLogArchive(directory: location)
        precondition(relaunched.initialSnapshot.entries.isEmpty, "Cleared logs must not return after relaunch")
        _ = await relaunched.snapshot()
    }

    private static func checkMemoryOnlyArchive(now: Date) async {
        let demo = DiagnosticLogArchive(directory: nil)
        demo.append(DiagnosticLogEntry(timestamp: now, message: "Demo event")) { _ in }
        let demoSnapshot = await demo.snapshot()
        precondition(demoSnapshot.entries.count == 1)
        let anotherDemo = DiagnosticLogArchive(directory: nil)
        let freshSnapshot = await anotherDemo.snapshot()
        precondition(freshSnapshot.entries.isEmpty, "Demo logs must not leak into another launch")
    }
}
