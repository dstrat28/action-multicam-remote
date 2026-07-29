import Foundation

@main
enum DJIModeSwitchRegression {
    static func main() {
        let action4 = makeCamera(model: .djiOsmoAction4)
        precondition(action4.availableCaptureModes == [.video, .photo, .slowMotion, .timelapse, .hyperlapse])
        precondition(!action4.availableCaptureModes.contains(.superNight))

        for model in [CameraModel.djiOsmoAction5Pro, .djiOsmoAction6] {
            let camera = makeCamera(model: model)
            precondition(camera.availableCaptureModes.contains(.superNight))
            assertRoundTrip(for: camera)
        }

        let osmo360 = makeCamera(model: .djiOsmo360)
        precondition(osmo360.availableCaptureModes.contains(.boostVideo))
        precondition(osmo360.availableCaptureModes.contains(.panoramicSuperNight))
        precondition(CaptureMode.video.djiRSDKValue(for: .djiOsmo360) == 0x38)
        precondition(CaptureMode.photo.djiRSDKValue(for: .djiOsmo360) == 0x3F)
        precondition(CaptureMode.hyperlapse.djiRSDKValue(for: .djiOsmo360) == 0x3A)
        assertRoundTrip(for: osmo360)

        let nano = makeCamera(model: .djiOsmoNano)
        precondition(nano.availableCaptureModes == [.video])
        precondition(!nano.canSwitchCaptureMode)

        var photoCamera = makeCamera(model: .djiOsmoAction5Pro)
        photoCamera.currentMode = .photo
        precondition(photoCamera.canCapturePhoto)
        precondition(photoCamera.primaryRecordCommand == .capturePhoto)
        precondition(photoCamera.primaryRecordTitle == "Capture")
        precondition(photoCamera.primaryRecordIcon == "camera")
        photoCamera.recordingState = .starting
        precondition(photoCamera.primaryRecordCommand == nil)
        precondition(photoCamera.primaryRecordTitle == "Capturing")

        var startingVideoCamera = makeCamera(model: .djiOsmoAction5Pro)
        startingVideoCamera.recordingState = .starting
        precondition(startingVideoCamera.primaryRecordTitle == "Starting")

        var renamedCamera = makeCamera(model: .djiOsmoAction6)
        precondition(renamedCamera.displayName == renamedCamera.name)
        renamedCamera.nickname = "  Finish Line  "
        precondition(renamedCamera.displayName == "Finish Line")
        let restoredCamera = try! JSONDecoder().decode(
            DiscoveredCamera.self,
            from: JSONEncoder().encode(renamedCamera)
        )
        precondition(restoredCamera.displayName == "Finish Line")
        precondition(restoredCamera.name == renamedCamera.name)

        let goProHardwarePayload = Data([
            0x3C, 0x00,
            0x04, 0x00, 0x00, 0x00, 0x41,
            0x0C, 0x48, 0x45, 0x52, 0x4F, 0x31, 0x33, 0x20, 0x42, 0x6C, 0x61, 0x63, 0x6B,
            0x04, 0x30, 0x78, 0x30, 0x35,
            0x0F, 0x48, 0x32, 0x34, 0x2E, 0x30, 0x31, 0x2E, 0x30, 0x32, 0x2E, 0x31, 0x30, 0x2E, 0x30, 0x30,
            0x0E, 0x43, 0x33, 0x35, 0x33, 0x34, 0x32, 0x35, 0x30, 0x32, 0x31, 0x33, 0x36, 0x37, 0x30,
            0x0C, 0x48, 0x45, 0x52, 0x4F, 0x31, 0x33, 0x20, 0x42, 0x6C, 0x61, 0x63, 0x6B,
            0x0C, 0x30, 0x36, 0x35, 0x37, 0x34, 0x37, 0x34, 0x39, 0x39, 0x37, 0x61, 0x37,
            0x01, 0x00, 0x01, 0x01, 0x01, 0x00, 0x02, 0x5B, 0x5D, 0x01, 0x01
        ])
        let goProHardwareInfo = GoProHardwareInfo(commandResponse: goProHardwarePayload)
        precondition(goProHardwareInfo?.modelName == "HERO13 Black")
        precondition(goProHardwareInfo?.serialNumber == "C3534250213670")
        precondition(goProHardwareInfo?.accessPointMACAddress == "0657474997a7")
        precondition(goProHardwareInfo?.hardwareIdentifier?.kind == .serialNumber)
        precondition(goProHardwareInfo?.hardwareIdentifier?.persistenceKey == "serialNumber:C3534250213670")

        var identifiedCamera = makeCamera(model: .goproHero13Black)
        identifiedCamera.hardwareIdentifier = goProHardwareInfo?.hardwareIdentifier
        let restoredIdentifiedCamera = try! JSONDecoder().decode(
            DiscoveredCamera.self,
            from: JSONEncoder().encode(identifiedCamera)
        )
        precondition(restoredIdentifiedCamera.hardwareIdentifier == identifiedCamera.hardwareIdentifier)

        var telemetry = CameraTelemetry(
            isExternalPowerConnected: true,
            modeName: "Video",
            videoResolution: "4K 16:9",
            frameRate: "60fps"
        )
        telemetry.mergeDJIRSDKStatus(
            CameraTelemetry(
                cameraStatus: "Ready",
                recordingElapsedSeconds: 0,
                storageFreeMB: 0,
                videoResolution: "Large",
                fieldOfViewType: 2,
                photoAspectRatio: "4:3",
                temperatureStatus: "Normal",
                userMode: "General"
            )
        )
        precondition(telemetry.frameRate == nil, "A full DJI status update must clear stale capture fields")
        precondition(telemetry.storageFreeMB == 0, "DJI status must preserve a valid zero-MB storage value")
        precondition(telemetry.fieldOfViewType == 2, "DJI status must retain the camera's FOV type byte")
        precondition(telemetry.isExternalPowerConnected == true, "DJI status must preserve charging detection")
        precondition(telemetry.modeName == "Video", "DJI status must preserve the separate 1D06 mode name")

        var goProTelemetry = CameraTelemetry(
            batteryPercent: 54,
            videoResolution: "4K 8:7",
            frameRate: "240fps",
            framing: "8:7",
            lens: "Wide",
            hypersmooth: "Off",
            captureSettingsUpdatedAt: Date()
        )
        goProTelemetry.mergeReplacingCaptureSettings(
            CameraTelemetry(
                lens: "Wide",
                photoAspectRatio: "4:3",
                captureSettingsUpdatedAt: Date()
            )
        )
        precondition(goProTelemetry.batteryPercent == 54, "Changing mode must preserve non-capture telemetry")
        precondition(goProTelemetry.videoResolution == nil, "Photo must not inherit the prior video resolution")
        precondition(goProTelemetry.frameRate == nil, "Photo must not inherit the prior video frame rate")
        precondition(goProTelemetry.hypersmooth == nil, "Photo must not inherit the prior video stabilization")
        precondition(goProTelemetry.photoAspectRatio == "4:3", "Photo must accept its fresh aspect ratio")

        print("DJI mode switch regression checks passed.")
    }

    private static func assertRoundTrip(for camera: DiscoveredCamera) {
        for mode in camera.availableCaptureModes {
            guard let encoded = mode.djiRSDKValue(for: camera.model) else {
                preconditionFailure("Missing DJI mode value for \(camera.model.rawValue) \(mode.rawValue)")
            }
            precondition(
                CaptureMode.djiRSDKMode(for: encoded, model: camera.model) == mode,
                "DJI mode mapping did not round-trip for \(camera.model.rawValue) \(mode.rawValue)"
            )
        }
    }

    private static func makeCamera(model: CameraModel) -> DiscoveredCamera {
        DiscoveredCamera(
            id: UUID(),
            name: model.rawValue,
            brand: model.brand,
            model: model,
            rssi: -50,
            capabilities: [.record, .mode, .status],
            connectionState: .connected,
            recordingState: .stopped,
            currentMode: .video,
            isPaired: true,
            isSelected: true,
            lastSeen: Date()
        )
    }
}
