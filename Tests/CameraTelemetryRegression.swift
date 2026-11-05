import Foundation

@main
enum CameraTelemetryRegression {
    static func main() throws {
        let internalVolume = CameraStorageVolume(location: .internalStorage, freeMB: 32_768, totalMB: 65_536)
        let sd = CameraStorageVolume(location: .sdCard, freeMB: 51_200, totalMB: 131_072)
        var telemetry = CameraTelemetry(batteryPercent: 84, storageVolumes: [internalVolume, sd])
        precondition(internalVolume.valueDescription == "32GB free")
        precondition(sd.valueDescription == "50GB free")
        precondition(CameraStorageVolume(location: .sdCard, freeMB: 0, totalMB: 1024).valueDescription == "0MB free")
        precondition(CameraStorageVolume(location: .sdCard, state: .notInserted).valueDescription == "Not inserted")
        for invalid in [
            CameraStorageVolume(location: .sdCard, freeMB: .max),
            CameraStorageVolume(location: .sdCard, freeMB: 100, totalMB: 50),
            CameraStorageVolume(location: .sdCard, freeMB: 0, totalMB: 0),
            CameraStorageVolume(location: .sdCard, freeMB: 10, totalMB: .max)
        ] {
            precondition(invalid.valueDescription == "Unavailable")
        }
        let encoded = try JSONEncoder().encode(telemetry)
        let decoded = try JSONDecoder().decode(CameraTelemetry.self, from: encoded)
        precondition(decoded == telemetry)
        let legacy = try JSONDecoder().decode(CameraTelemetry.self,
            from: Data(#"{"batteryPercent":50,"storageFreeMB":1024}"#.utf8))
        precondition(legacy.batteryPercent == 50 && legacy.storageVolumes == nil)
        telemetry.merge(CameraTelemetry(batteryPercent: 83))
        precondition(telemetry.storageVolumes == [internalVolume, sd])
        telemetry.storageFreeMB = 999
        telemetry.storageTotalMB = 1000
        telemetry.storageState = "Old card"
        telemetry.merge(CameraTelemetry(storageVolumes: [internalVolume]))
        precondition(telemetry.storageVolumes == [internalVolume])
        precondition(telemetry.storageFreeMB == nil && telemetry.storageTotalMB == nil && telemetry.storageState == nil)
        telemetry.merge(CameraTelemetry(storageVolumes: []))
        precondition(telemetry.storageVolumes == [] && !CameraTelemetry(storageVolumes: []).isEmpty)
        print("Camera telemetry regressions passed: separate volumes, zero/full, invalid capacities, legacy decoding and snapshot replacement.")
    }
}
