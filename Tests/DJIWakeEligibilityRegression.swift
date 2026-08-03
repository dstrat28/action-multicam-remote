import Foundation

@main
enum DJIWakeEligibilityRegression {
    static func main() {
        precondition(GoProAdvertisementStatus.isProcessorAwake(0x01), "GoPro processor state uses bit 0")
        precondition(!GoProAdvertisementStatus.isProcessorAwake(0x80), "GoPro reserved bits must not imply awake")
        precondition(GoProAdvertisementStatus.isPeripheralPairingEnabled(0x04), "GoPro pairing state uses bit 2")
        precondition(!GoProAdvertisementStatus.isPeripheralPairingEnabled(0x20), "GoPro reserved bits must not imply pairing")

        for model in [CameraModel.djiOsmoAction4, .djiOsmoAction5Pro, .djiOsmoAction6, .djiOsmo360] {
            let camera = makeCamera(model: model, state: .discovered)
            precondition(camera.isSupportedByApp, "\(model.rawValue) should use the shared DJI R SDK profile")
            precondition(camera.behavior.usesDJIRSDKControl, "\(model.rawValue) should use DJI R SDK control")
            precondition(!camera.behavior.usesLegacyDJIControl, "\(model.rawValue) must not use legacy DJI command fallbacks")
            precondition(!camera.supportsExperimentalDJISleepWake, "\(model.rawValue) must not expose the unsuccessful DJI wake experiment")
            precondition(camera.supportsDJIPhoneGPS, "\(model.rawValue) should expose opt-in phone GPS")
            precondition(!camera.canSelectForBatch, "\(model.rawValue) must not remain selectable while sleeping")
            precondition(camera.displayConnectionLabel == "Not Connected", "\(model.rawValue) should show Not Connected while sleeping")

            let connectedCamera = makeCamera(model: model, state: .connected)
            precondition(connectedCamera.supportsBatchRecord, "\(model.rawValue) should expose recording control")
            precondition(connectedCamera.canSelectForBatch, "\(model.rawValue) should be selectable after R SDK connection")
        }

        let disconnectedAction5 = makeCamera(model: .djiOsmoAction5Pro, state: .disconnected)
        precondition(!disconnectedAction5.canSelectForBatch, "An ordinary disconnected DJI camera must not be selectable")

        var nano = makeCamera(model: .djiOsmoNano, state: .discovered)
        nano.isPaired = false
        precondition(nano.supportsExperimentalDJISleepWake, "Nano should expose its model-specific GATT wake path")
        precondition(nano.behavior.usesLegacyDJIControl, "Nano should retain its verified legacy DJI control path")
        precondition(!nano.supportsDJIPhoneGPS, "Nano must not expose the incompatible R SDK GPS option")
        precondition(nano.displayConnectionLabel == "Not Connected", "Nano must not show an Available state")
        var pairedNano = nano
        pairedNano.isPaired = true
        precondition(pairedNano.canWakeFromSleep, "A paired, advertising Nano should expose Wake")
        precondition(pairedNano.displayConnectionLabel == "Available", "A wakeable Nano should show Available")

        var goPro = DiscoveredCamera(
            id: UUID(),
            name: "GoPro HERO13 Black",
            brand: .gopro,
            model: .goproHero13Black,
            rssi: -50,
            capabilities: [.record, .status],
            connectionState: .disconnected,
            recordingState: .unknown,
            isPaired: true,
            isSelected: true,
            lastSeen: Date()
        )
        precondition(!goPro.canSelectForBatch, "A disconnected GoPro must not remain selectable")
        precondition(goPro.displayConnectionLabel == "Not Connected", "A disconnected GoPro must show Not Connected")

        goPro.connectionState = .discovered
        goPro.advertisementAwake = true
        precondition(!goPro.canSelectForBatch, "An advertising GoPro must not be selectable before protocol connection")
        precondition(!goPro.canWakeFromSleep, "An awake GoPro must not expose Wake")
        precondition(goPro.displayConnectionLabel == "Not Connected", "An awake advertising GoPro must not expose Available")

        goPro.advertisementAwake = false
        precondition(goPro.canWakeFromSleep, "A paired low-power GoPro should expose Wake")
        precondition(goPro.displayConnectionLabel == "Available", "A paired low-power GoPro should show Available")

        goPro.isPaired = false
        precondition(!goPro.canWakeFromSleep, "An unpaired low-power GoPro must not expose Wake")
        precondition(goPro.displayConnectionLabel == "Not Connected", "An unpaired low-power GoPro must not show Available")

        goPro.isPaired = true
        goPro.connectionState = .connected
        precondition(goPro.canSelectForBatch, "A connected GoPro should remain selectable")

        var sortSamples = [
            makeCamera(model: .djiOsmoAction4, state: .disconnected),
            pairedNano,
            makeCamera(model: .djiOsmoAction5Pro, state: .connecting),
            makeCamera(model: .djiOsmoAction6, state: .connected),
            makeCamera(model: .djiOsmo360, state: .reconnecting)
        ]
        sortSamples.sort { $0.defaultSortRank < $1.defaultSortRank }
        precondition(sortSamples.map(\.defaultSortRank) == [0, 1, 1, 2, 3], "Camera status sort order regressed")

        print("Disconnected camera presentation regression checks passed.")
    }

    private static func makeCamera(
        model: CameraModel,
        state: CameraConnectionState
    ) -> DiscoveredCamera {
        DiscoveredCamera(
            id: UUID(),
            name: model.rawValue,
            brand: .dji,
            model: model,
            rssi: -50,
            capabilities: [.record, .status, .experimental],
            connectionState: state,
            recordingState: .unknown,
            isPaired: true,
            isSelected: true,
            lastSeen: Date()
        )
    }
}
