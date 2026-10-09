import Foundation

struct DiagnosticLogEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    let timestamp: Date
    let message: String

    var formattedLine: String {
        "[\(timestamp.ISO8601Format(.init(includingFractionalSeconds: true)))] \(message)"
    }
}

struct DiagnosticLogSnapshot: Sendable {
    let entries: [DiagnosticLogEntry]
    let storageError: String?
}

// All mutable state and file access are confined to queue. Appends and exports
// use the same queue so sharing includes every event submitted before the tap.
final class DiagnosticLogArchive: @unchecked Sendable {
    static let defaultMaximumBytes = 5 * 1_024 * 1_024

    private struct Record {
        let entry: DiagnosticLogEntry
        let data: Data
    }

    private let queue = DispatchQueue(label: "com.ds.ActionCamRemote.diagnostic-logs", qos: .utility)
    private let fileURL: URL?
    private let maximumBytes: Int
    private var records: [Record] = []
    private var byteCount = 0
    private var needsRewrite = false
    private var storageError: String?
    private var shouldPreserveUnreadArchive = false
    let initialSnapshot: DiagnosticLogSnapshot

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "DiagnosticLogs", directoryHint: .isDirectory)
    }

    // A nil directory keeps simulator demos and previews out of the real archive.
    init(directory: URL?, maximumBytes: Int = DiagnosticLogArchive.defaultMaximumBytes) {
        precondition(maximumBytes > 0)
        self.fileURL = directory?.appendingPathComponent("events.jsonl")
        self.maximumBytes = maximumBytes
        self.initialSnapshot = Self.load(fileURL: fileURL, maximumBytes: maximumBytes)
        let encoder = JSONEncoder()
        records = initialSnapshot.entries.compactMap { entry in
            guard var data = try? encoder.encode(entry) else { return nil }
            data.append(0x0A)
            return Record(entry: entry, data: data)
        }
        byteCount = records.reduce(0) { $0 + $1.data.count }
        storageError = initialSnapshot.storageError
        shouldPreserveUnreadArchive = initialSnapshot.storageError != nil
        // Rewrite once after loading to remove incomplete records.
        needsRewrite = true
        queue.async { self.persist() }
    }

    func append(_ entry: DiagnosticLogEntry, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do {
                var data = try JSONEncoder().encode(entry)
                data.append(0x0A)
                // An anomalously large packet must not evict the entire history.
                guard data.count <= self.maximumBytes else {
                    completion(self.storageError)
                    return
                }
                self.records.append(Record(entry: entry, data: data))
                self.byteCount += data.count
                self.trimToSize()
                self.persist(appending: data)
            } catch {
                self.storageError = error.localizedDescription
            }
            completion(self.storageError)
        }
    }

    func clear(completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            self.records.removeAll()
            self.byteCount = 0
            self.shouldPreserveUnreadArchive = false
            self.needsRewrite = true
            self.persist()
            completion(self.storageError)
        }
    }

    func snapshot() async -> DiagnosticLogSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                self.persist()
                continuation.resume(returning: DiagnosticLogSnapshot(
                    entries: self.records.map(\.entry),
                    storageError: self.storageError
                ))
            }
        }
    }

    func export(context: String, now: Date = .now, directory: URL? = nil) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    self.persist()
                    let exportDirectory = directory ?? FileManager.default.temporaryDirectory
                        .appendingPathComponent("MulticamDiagnostics", isDirectory: true)
                    try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
                    // Exports are immutable while the share sheet is using them.
                    // Only clean up old files in this app-owned temporary folder.
                    if directory == nil {
                        self.removeOldExports(in: exportDirectory, now: now)
                    }
                    let filenameDate = now.ISO8601Format().replacingOccurrences(of: ":", with: "-")
                    let url = exportDirectory.appendingPathComponent("Multicam-Diagnostics-\(filenameDate)-\(UUID().uuidString.prefix(8)).txt")
                    var sections = [context]
                    if let error = self.storageError {
                        sections.append("Log archive storage error: \(error). Logs from this launch are included from memory.")
                    }
                    sections.append((
                        ["Bluetooth Log (newest first)"] + self.records.reversed().map { $0.entry.formattedLine }
                    ).joined(separator: "\n"))
                    let report = sections.joined(separator: "\n\n") + "\n"
                    try report.write(to: url, atomically: true, encoding: .utf8)
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func load(fileURL: URL?, maximumBytes: Int) -> DiagnosticLogSnapshot {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            return DiagnosticLogSnapshot(entries: [], storageError: nil)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            var entries: [DiagnosticLogEntry] = []
            var bytes = 0
            // Decode each line independently so an interrupted final write does
            // not discard the connection attempt that preceded it.
            for line in data.split(separator: 0x0A).reversed() {
                guard line.count + 1 <= maximumBytes,
                      let entry = try? decoder.decode(DiagnosticLogEntry.self, from: Data(line)) else { continue }
                guard bytes + line.count + 1 <= maximumBytes else { break }
                entries.append(entry)
                bytes += line.count + 1
            }
            return DiagnosticLogSnapshot(entries: entries.reversed(), storageError: nil)
        } catch {
            return DiagnosticLogSnapshot(entries: [], storageError: error.localizedDescription)
        }
    }

    private func trimToSize() {
        guard byteCount > maximumBytes else { return }
        // Leave headroom so a busy connection does not rewrite the archive on
        // every packet once it reaches its cap.
        let targetBytes = maximumBytes * 9 / 10
        var removeCount = 0
        while byteCount > targetBytes && removeCount < records.count - 1 {
            byteCount -= records[removeCount].data.count
            removeCount += 1
        }
        records.removeFirst(removeCount)
        needsRewrite = true
    }

    private func persist(appending data: Data? = nil) {
        // If the existing archive could not be read, keep it intact for a later
        // launch and continue collecting shareable logs in memory.
        guard let fileURL, !shouldPreserveUnreadArchive else { return }
        do {
            if needsRewrite {
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var directoryValues = URLResourceValues()
                directoryValues.isExcludedFromBackup = true
                var mutableDirectory = directory
                try mutableDirectory.setResourceValues(directoryValues)
                let contents = records.reduce(into: Data()) { $0.append($1.data) }
                try contents.write(to: fileURL, options: .atomic)
                needsRewrite = false
            } else if let data {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            needsRewrite = true
        }
    }

    private func removeOldExports(in directory: URL, now: Date) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in urls where url.pathExtension == "txt" {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < now.addingTimeInterval(-24 * 60 * 60) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
