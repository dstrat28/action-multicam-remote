import Foundation
import WatchConnectivity

@MainActor
final class CameraStore {
    var cameras: [DiscoveredCamera] = []
    var readyConnectedCameras: [DiscoveredCamera] { cameras.filter { $0.connectionState == .connected } }
    var canAddHighlight = false
    func startWatchRecording() -> Bool { true }
    func stopWatchRecording() -> Bool { true }
    func addHighlight() {}
}

@main
@MainActor
enum WatchCameraTelemetryRegression {
    static func main() async throws {
        let store = CameraStore()
        let phone = WatchConnectivityController(store: store)
        let watch = WatchSessionModel()
        let inner = CameraStorageVolume(location: .internalStorage, freeMB: 32_768, totalMB: 65_536)
        let sd = CameraStorageVolume(location: .sdCard, freeMB: 51_200, totalMB: 131_072)
        let cases: [(CameraModel, CameraTelemetry)] = [
            (.insta360X6, CameraTelemetry(batteryPercent: 84, storageVolumes: [inner, sd])),
            (.insta360X3, CameraTelemetry(batteryPercent: 0, storageFreeMB: 51_200,
                                        storageTotalMB: 131_072, storageVolumes: [sd])),
            (.djiOsmoNano, CameraTelemetry(batteryPercent: 87, isExternalPowerConnected: true,
                                         storageFreeMB: 32_768, storageTotalMB: 65_536, storageVolumes: [inner])),
            (.goproHero13Black, CameraTelemetry(batteryPercent: 82, isExternalPowerConnected: true,
                                               storageFreeMB: 51_200, storageTotalMB: 131_072)),
            (.djiOsmoAction6, CameraTelemetry(batteryPercent: 70, storageFreeMB: 0)),
            (.insta360Go3, CameraTelemetry()) // Legacy GPS Remote has no battery/storage.
        ]
        for (model, telemetry) in cases {
            store.cameras = [makeCamera(model: model, telemetry: telemetry)]
            let snapshot = await snapshot(from: phone)
            for _ in 0..<8 {
                let repeated = await self.snapshot(from: phone)
                precondition((repeated as NSDictionary).isEqual(snapshot as NSDictionary),
                             "Unchanged metadata must not generate new state versions or Watch traffic")
            }
            _ = try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
            let row = (snapshot["cameras"] as! [[String: Any]])[0]
            let decoded = WatchCamera(snapshot: row)!
            precondition(decoded.storageVolumes == telemetry.storageVolumes, model.rawValue)
            precondition(decoded.batteryPercent == telemetry.batteryPercent, model.rawValue)
            precondition(decoded.isExternalPowerConnected == telemetry.isExternalPowerConnected, model.rawValue)
            precondition(decoded.storageFreeMB == telemetry.storageFreeMB.map(Int.init), model.rawValue)
            if model == .insta360X6 {
                precondition(decoded.storageVolumes?.map(\.valueDescription) == ["32GB free", "50GB free"])
                precondition(decoded.storageFreeMB == nil && decoded.storageVolumeForRing == sd)
                precondition(decoded.storageProgress == 1 - Double(sd.freeMB!) / Double(sd.totalMB!))
                precondition(decoded.storageRingTitle == "SD Card", "The ring must identify its SD preference")
                let legacySummary = row["storageState"] as! String
                precondition(legacySummary.contains("Internal Storage: 32GB free")
                    && legacySummary.contains("SD Card: 50GB free"), "Older Watch apps need both readings")
            } else if model == .djiOsmoNano {
                precondition(decoded.storageProgress == 0.5)
            } else if model == .goproHero13Black {
                precondition(decoded.storageProgress != nil)
            }
            watch.session(WCSession.default, didReceiveApplicationContext: snapshot)
            await waitUntil { watch.cameras.first?.id == decoded.id }
            precondition(watch.cameras.first == decoded, "Exercise the actual Watch context consumer")
        }

        // A new snapshot must replace stale volumes/status, including an explicit clear.
        let id = UUID()
        for volumes in [[inner, sd], [inner], [inner, .init(location: .sdCard, state: .notInserted)],
                        [inner, .init(location: .sdCard, freeMB: 0, totalMB: 131_072)],
                        [inner, .init(location: .sdCard, state: .unavailable)],
                        [.init(location: .sdCard, freeMB: 0, totalMB: 131_072)],
                        [.init(location: .sdCard, state: .unavailable)], []] {
            store.cameras = [makeCamera(id: id, model: .insta360X6,
                telemetry: CameraTelemetry(batteryPercent: 84, storageVolumes: volumes))]
            let snapshot = await snapshot(from: phone)
            watch.session(WCSession.default, didReceiveApplicationContext: snapshot)
            await waitUntil { watch.cameras.first?.storageVolumes == volumes }
            let decoded = watch.cameras[0]
            precondition(decoded.storageVolumes == volumes)
            if decoded.storageVolumeForRing?.state != .available {
                precondition(decoded.storageProgress == nil)
            } else if decoded.storageVolumeForRing?.freeMB == 0 {
                precondition(decoded.storageProgress == 1)
            } else if decoded.storageVolumeForRing?.location == .internalStorage {
                precondition(decoded.storageProgress == 0.5 && decoded.storageRingTitle == "Internal")
            }
        }
        store.cameras[0].recordingState = .recording
        store.cameras[0].telemetry = CameraTelemetry(remainingVideoSeconds: 120,
            remainingPhotos: 12, storageVolumes: [])
        watch.session(WCSession.default, didReceiveApplicationContext: await snapshot(from: phone))
        await waitUntil { watch.isRecording }
        precondition(watch.cameras[0].isRecording && watch.cameras[0].modeName == "Video")
        precondition(watch.cameras[0].remainingVideoSeconds == 120 && watch.cameras[0].remainingPhotos == 12)
        store.cameras[0].telemetry = nil
        watch.session(WCSession.default, didReceiveApplicationContext: await snapshot(from: phone))
        await waitUntil { watch.cameras.first?.storageVolumes == nil }
        precondition(watch.cameras[0].storageState == nil && watch.cameras[0].batteryPercent == nil)
        precondition(watch.isRecording && watch.cameras[0].isRecording,
                     "Missing optional metadata must not remove the camera or its recording status")

        var oldPhone: [String: Any] = ["id": "legacy", "name": "GoPro", "model": "HERO13 Black",
            "batteryBars": 3, "storageFreeMB": 1024, "storageTotalMB": 2048, "storageState": "Ready"]
        precondition(WatchCamera(snapshot: oldPhone)?.storageProgress == 0.5)
        precondition(WatchCamera(snapshot: oldPhone)?.batteryBars == 3)
        oldPhone["storageVolumes"] = Data([255])
        precondition(WatchCamera(snapshot: oldPhone)?.storageState == "Ready",
                     "Malformed/newer data must retain the legacy fallback")
        oldPhone["storageVolumes"] = try JSONEncoder().encode([CameraStorageVolume]())
        precondition(WatchCamera(snapshot: oldPhone)?.storageProgress == nil,
                     "An explicit empty volume snapshot must not revive stale legacy metrics")
        oldPhone.removeValue(forKey: "storageVolumes")
        oldPhone["storageTotalMB"] = Int(UInt32.max)
        precondition(WatchCamera(snapshot: oldPhone)?.storageProgress == nil)
        print("Watch camera telemetry passed: actual phone/Watch round trips, all brands, partial/empty/full/missing volumes, legacy compatibility and battery/power.")
    }

    private static func snapshot(from phone: WatchConnectivityController) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            phone.session(WCSession.default, didReceiveMessage: ["command": "refresh"],
                          replyHandler: { continuation.resume(returning: $0) })
        }
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        precondition(condition(), "Watch did not apply the expected snapshot")
    }

    private static func makeCamera(id: UUID = UUID(), model: CameraModel, telemetry: CameraTelemetry) -> DiscoveredCamera {
        DiscoveredCamera(id: id, name: model.rawValue, brand: model.brand, model: model, rssi: -48,
            capabilities: [.record, .status], connectionState: .connected, recordingState: .stopped,
            currentMode: .video, telemetry: telemetry, isPaired: true, isSelected: true, lastSeen: Date())
    }
}
