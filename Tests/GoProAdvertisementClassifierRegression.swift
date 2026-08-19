import Foundation

@main
enum GoProAdvertisementClassifierRegression {
    static func main() {
        let goProManufacturerData = Data([0xF2, 0x02, 0x01, 0x05, 0x41])

        precondition(
            GoProAdvertisementClassifier.isCredibleCamera(
                name: "Stage Left",
                advertisesControlService: false,
                manufacturerData: goProManufacturerData
            ),
            "A custom GoPro name should be discovered from manufacturer data."
        )
        precondition(
            GoProAdvertisementClassifier.isCredibleCamera(
                name: "Stage Right",
                advertisesControlService: true,
                manufacturerData: nil
            ),
            "The GoPro control service should remain a discovery signal."
        )
        precondition(
            GoProAdvertisementClassifier.isCredibleCamera(
                name: "GoPro 1234",
                advertisesControlService: false,
                manufacturerData: nil
            ),
            "The existing GoPro name fallback should remain supported."
        )
        precondition(
            !GoProAdvertisementClassifier.isCredibleCamera(
                name: "Desk Speaker",
                advertisesControlService: false,
                manufacturerData: Data([0x34, 0x12, 0x01, 0x05, 0x41])
            ),
            "Unrelated Bluetooth devices should remain hidden."
        )
        precondition(
            !GoProAdvertisementClassifier.isCameraManufacturerData(Data([0xF2])),
            "Short manufacturer data should be rejected."
        )

        print("GoPro advertisement classifier regression checks passed.")
    }
}
