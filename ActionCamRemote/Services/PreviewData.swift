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
        demoTelemetry(for: camera, mode: .video)
    }

    static func demoTelemetry(for camera: DiscoveredCamera, mode: CaptureMode) -> CameraTelemetry {
        switch camera.brand {
        case .gopro:
            CameraTelemetry(
                batteryPercent: 82,
                modeName: mode.displayName(for: camera.model),
                remainingVideoSeconds: 7_560,
                storageFreeMB: 94_000,
                storageTotalMB: 128_000,
                videoResolution: mode == .photo ? "27MP" : "5.3K",
                frameRate: mode == .photo ? nil : "60fps",
                framing: "16:9",
                lens: mode == .photo ? nil : "Wide",
                hypersmooth: mode == .photo ? nil : "AutoBoost",
                photoAspectRatio: mode == .photo ? "16:9" : nil,
                captureSettingsUpdatedAt: Date(),
                lastUpdated: Date()
            )
        case .dji:
            djiDemoTelemetry(for: camera, mode: mode)
        case .unknown:
            CameraTelemetry()
        }
    }

    private static func djiDemoTelemetry(
        for camera: DiscoveredCamera,
        mode: CaptureMode
    ) -> CameraTelemetry {
        let settings: CameraTelemetry
        switch mode {
        case .video:
            settings = CameraTelemetry(
                modeName: "Video",
                modeParameters: "4K60 Off",
                videoResolution: "4K 16:9",
                frameRate: "60fps",
                hypersmooth: "Off"
            )
        case .photo:
            settings = CameraTelemetry(
                modeName: "Photo",
                modeParameters: "M (16:9)",
                videoResolution: "Medium",
                photoAspectRatio: "16:9"
            )
        case .slowMotion:
            settings = CameraTelemetry(
                modeName: "SLO-MO",
                modeParameters: "1080P 8X",
                videoResolution: "1080p",
                frameRate: "240fps",
                hypersmooth: "Off"
            )
        case .timelapse:
            settings = CameraTelemetry(
                modeName: "TIME",
                modeParameters: "1080P30 2s",
                videoResolution: "1080p",
                frameRate: "30fps",
                timelapseIntervalTenths: 20,
                timelapseDurationSeconds: 600
            )
        case .hyperlapse:
            settings = CameraTelemetry(
                modeName: "HYPER",
                modeParameters: "1080P30 Auto",
                videoResolution: "1080p",
                frameRate: "30fps",
                hypersmooth: "Off",
                timelapseIntervalTenths: 0,
                timelapseDurationSeconds: 600
            )
        case .superNight:
            settings = CameraTelemetry(
                modeName: "SuperNight",
                modeParameters: "4K60",
                videoResolution: "4K 16:9",
                frameRate: "60fps",
                hypersmooth: "RS"
            )
        case .selfie, .boostVideo, .vortex, .panoramicSuperNight, .singleLensSuperNight:
            settings = CameraTelemetry(
                modeName: mode.displayName(for: camera.model),
                videoResolution: "4K 16:9",
                frameRate: "60fps",
                hypersmooth: "RS"
            )
        }

        var telemetry = CameraTelemetry(
            batteryPercent: 76,
            cameraStatus: "Ready",
            remainingVideoSeconds: 5_420,
            storageFreeMB: 94_000,
            storageTotalMB: 128_000,
            countdownRemainingSeconds: 0,
            loopRecordingSeconds: 0,
            temperatureStatus: "Normal",
            userMode: "General",
            lastUpdated: Date()
        )
        telemetry.merge(settings)
        telemetry.captureSettingsUpdatedAt = Date()
        return telemetry
    }
}
