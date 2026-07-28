import Foundation

@main
enum DJIWakeEligibilityRegression {
    static func main() {
        for model in [CameraModel.djiOsmoAction4, .djiOsmoAction5Pro, .djiOsmoAction6] {
            let camera = makeCamera(model: model, state: .discovered)
            precondition(!camera.supportsExperimentalDJISleepWake, "\(model.rawValue) must not expose the unsuccessful DJI wake experiment")
            precondition(camera.supportsDJIPhoneGPS, "\(model.rawValue) should expose opt-in phone GPS")
            precondition(!camera.canSelectForBatch, "\(model.rawValue) must not remain selectable while sleeping")
            precondition(camera.displayConnectionLabel == "Not Connected", "\(model.rawValue) should show Not Connected while sleeping")
        }

        let disconnectedAction5 = makeCamera(model: .djiOsmoAction5Pro, state: .disconnected)
        precondition(!disconnectedAction5.canSelectForBatch, "An ordinary disconnected DJI camera must not be selectable")

        let nano = makeCamera(model: .djiOsmoNano, state: .discovered)
        precondition(!nano.supportsExperimentalDJISleepWake, "Nano wake behavior remains isolated from the Action wake experiment")
        precondition(!nano.supportsDJIPhoneGPS, "Nano must not expose the incompatible R SDK GPS option")
        precondition(nano.displayConnectionLabel == "Not Connected", "Nano must not show an Available state")

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
        precondition(!goPro.canSelectForBatch, "An advertising GoPro must not be selectable before protocol connection")
        precondition(goPro.displayConnectionLabel == "Not Connected", "An advertising GoPro must not expose Available")

        goPro.connectionState = .connected
        precondition(goPro.canSelectForBatch, "A connected GoPro should remain selectable")

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
