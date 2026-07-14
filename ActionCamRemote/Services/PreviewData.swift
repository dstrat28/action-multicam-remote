import Foundation

extension CameraStore {
    func loadDemoCameras() {
        cameras = Self.demoCandidates.map { makeCamera in
            var camera = makeCamera()
            if camera.supportsBatchRecord {
                camera.connectionState = .connected
                camera.recordingState = .stopped
                camera.currentMode = .video
                camera.telemetry = Self.demoTelemetry(for: camera)
                camera.isPaired = true
                camera.isSelected = true
            }
            return camera
        }
        eventLog = [
            "[9:41:02 AM] GoPro HERO13: command characteristic is ready.",
            "[9:40:58 AM] DJI Action 6: discovered 4 candidate services.",
            "[9:40:54 AM] Simulator demo mode loaded sample cameras."
        ]
    }

    static var preview: CameraStore {
        let store = CameraStore(demoMode: false)
        store.loadDemoCameras()
        return store
    }

    static func demoTelemetry(for camera: DiscoveredCamera) -> CameraTelemetry {
        switch camera.brand {
        case .gopro:
            CameraTelemetry(
                batteryPercent: 82,
                remainingVideoSeconds: 7_560,
                storageFreeMB: 94_000,
                storageTotalMB: 128_000,
                videoResolution: "5.3K",
                frameRate: "60fps",
                framing: "16:9",
                lens: "Wide",
                hypersmooth: "AutoBoost",
                lastUpdated: Date()
            )
        case .dji:
            CameraTelemetry(
                batteryPercent: 76,
                remainingVideoSeconds: 5_420,
                storageFreeMB: 94_000,
                storageTotalMB: 128_000,
                lastUpdated: Date()
            )
        case .unknown:
            CameraTelemetry()
        }
    }
}
