import Foundation

struct CommandResultSnapshot {
    let results: [CameraCommandResult]
    let storageError: String?
    let revision: UInt64

    var reportSection: String {
        var lines = ["Command Results (newest first)"]
        if let storageError {
            lines.append("Command archive storage error: \(storageError). Current results are included from memory.")
        }
        if results.isEmpty {
            lines.append("No saved commands.")
        } else {
            lines += results.map { result in
                "\(result.timestamp.ISO8601Format(.init(includingFractionalSeconds: true))) \(result.cameraName) \(result.command.label) [\(result.status.rawValue)]: \(result.message)"
            }
        }
        return lines.joined(separator: "\n")
    }
}

// The queue orders command completions, resets, and snapshots. Restored history
// is diagnostic data only; it must never become pending camera-control state.
final class CommandResultArchive: @unchecked Sendable {
    static let defaultMaximumCount = 500
    static let defaultMaximumBytes = 512 * 1_024

    private struct Record {
        let result: CameraCommandResult
        let data: Data
    }

    private let queue = DispatchQueue(label: "com.ds.ActionCamRemote.command-history", qos: .utility)
    private let fileURL: URL?
    private let maximumCount: Int
    private let maximumBytes: Int
    private var records: [Record] = []
    private var byteCount = 0
    private var storageError: String?
    private var shouldPreserveUnreadArchive = false
    private var revision: UInt64 = 0
    let initialSnapshot: CommandResultSnapshot

    init(directory: URL?, maximumCount: Int = defaultMaximumCount, maximumBytes: Int = defaultMaximumBytes) {
        precondition(maximumCount > 0 && maximumBytes > 0)
        self.fileURL = directory?.appendingPathComponent("commands.jsonl")
        self.maximumCount = maximumCount
        self.maximumBytes = maximumBytes
        var loaded: [Record] = []
        var error: String?
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                var seen: Set<UUID> = []
                var bytes = 0
                for line in data.split(separator: 0x0A) {
                    guard line.count + 1 <= maximumBytes,
                          let result = try? JSONDecoder().decode(CameraCommandResult.self, from: Data(line)),
                          seen.insert(result.id).inserted else { continue }
                    guard loaded.count < maximumCount, bytes + line.count + 1 <= maximumBytes else { break }
                    var encoded = Data(line)
                    encoded.append(0x0A)
                    loaded.append(Record(result: result, data: encoded))
                    bytes += encoded.count
                }
            } catch let failure {
                error = failure.localizedDescription
            }
        }
        self.records = loaded
        self.byteCount = loaded.reduce(0) { $0 + $1.data.count }
        self.storageError = error
        self.shouldPreserveUnreadArchive = error != nil
        self.initialSnapshot = CommandResultSnapshot(results: loaded.map(\.result), storageError: error, revision: 0)
        queue.async { self.persist() }
    }

    func record(_ result: CameraCommandResult, completion: @escaping (CommandResultSnapshot) -> Void) {
        queue.async {
            do {
                var data = try JSONEncoder().encode(result)
                data.append(0x0A)
                // One malformed result must not evict the entire history.
                guard data.count <= self.maximumBytes else {
                    completion(self.currentSnapshot)
                    return
                }
                let record = Record(result: result, data: data)
                if let index = self.records.firstIndex(where: { $0.result.id == result.id }) {
                    self.byteCount -= self.records[index].data.count
                    self.records[index] = record
                } else {
                    self.records.insert(record, at: 0)
                }
                self.byteCount += data.count
                while self.records.count > self.maximumCount || self.byteCount > self.maximumBytes {
                    self.byteCount -= self.records.removeLast().data.count
                }
                self.revision += 1
                self.persist()
            } catch {
                self.storageError = error.localizedDescription
            }
            completion(self.currentSnapshot)
        }
    }

    func clear(completion: @escaping (CommandResultSnapshot) -> Void) {
        queue.async {
            self.records.removeAll()
            self.byteCount = 0
            self.shouldPreserveUnreadArchive = false
            self.revision += 1
            self.persist()
            completion(self.currentSnapshot)
        }
    }

    func snapshot() async -> CommandResultSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                self.persist()
                continuation.resume(returning: self.currentSnapshot)
            }
        }
    }

    private var currentSnapshot: CommandResultSnapshot {
        CommandResultSnapshot(results: records.map(\.result), storageError: storageError, revision: revision)
    }

    private func persist() {
        guard let fileURL, !shouldPreserveUnreadArchive else { return }
        do {
            var directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let data = records.reduce(into: Data()) { $0.append($1.data) }
            try data.write(to: fileURL, options: .atomic)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }
}
