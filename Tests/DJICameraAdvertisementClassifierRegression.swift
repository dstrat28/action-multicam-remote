import Foundation

@main
enum DJICameraAdvertisementClassifierRegression {
    static func main() {
        precondition(
            DJICameraAdvertisementClassifier.isRSDKCamera(Data([0xAA, 0x08, 0x00, 0x00, 0xFA])),
            "DJI R SDK manufacturer signature should be accepted."
        )
        precondition(
            DJICameraAdvertisementClassifier.isRSDKCamera(Data([0xAA, 0x08, 0x42, 0x10, 0xFA, 0x99])),
            "DJI R SDK signature should not depend on the camera name or variable payload bytes."
        )
        precondition(
            !DJICameraAdvertisementClassifier.isRSDKCamera(Data([0xAA, 0x08, 0x19, 0x00, 0xC0])),
            "DJI Nano advertisements should not be mistaken for R SDK advertisements."
        )
        precondition(
            !DJICameraAdvertisementClassifier.isRSDKCamera(Data([0xAA, 0x08, 0x00, 0x00])),
            "Short manufacturer data should be rejected."
        )
        precondition(
            !DJICameraAdvertisementClassifier.isRSDKCamera(Data([0xAB, 0x08, 0x00, 0x00, 0xFA])),
            "Unrelated manufacturer data should be rejected."
        )

        precondition(
            DJICameraAdvertisementClassifier.isNanoCamera(Data([0xAA, 0x08, 0x19, 0x00, 0xC0])),
            "DJI Nano manufacturer signature should be accepted independently of its name."
        )
        precondition(
            !DJICameraAdvertisementClassifier.isNanoCamera(Data([0xAA, 0x08, 0x18])),
            "Unrelated DJI manufacturer data should not be classified as Nano."
        )

        precondition(
            DJICameraAdvertisementClassifier.discoveryModel(
                name: "Stage Left",
                manufacturerData: Data([0xAA, 0x08, 0x42, 0x10, 0xFA])
            ) == .djiRSDKCamera,
            "A custom camera name should be discovered from the DJI R SDK signature."
        )
        precondition(
            DJICameraAdvertisementClassifier.discoveryModel(
                name: "Stage Right",
                manufacturerData: Data([0xAA, 0x08, 0x19, 0x00, 0xC0])
            ) == .djiOsmoNano,
            "A custom Nano name should be discovered from the Nano signature."
        )
        precondition(
            DJICameraAdvertisementClassifier.discoveryModel(
                name: "Desk Speaker",
                manufacturerData: Data([0x34, 0x12, 0x00, 0x00, 0x01])
            ) == nil,
            "An unrelated Bluetooth device with a custom name should remain hidden."
        )

        let modelsByEncodedDeviceID: [(UInt32, CameraModel)] = [
            (0xFF33_0000, .djiOsmoAction4),
            (0xFF44_0000, .djiOsmoAction5Pro),
            (0xFF55_0000, .djiOsmoAction6),
            (0xFF66_0000, .djiOsmo360)
        ]
        for (deviceID, expectedModel) in modelsByEncodedDeviceID {
            precondition(
                DJICameraAdvertisementClassifier.model(forEncodedRSDKDeviceID: deviceID) == expectedModel,
                "Expected encoded device ID \(String(deviceID, radix: 16)) to identify \(expectedModel.rawValue)."
            )
        }
        precondition(
            DJICameraAdvertisementClassifier.model(forEncodedRSDKDeviceID: 0xFF77_0000) == nil,
            "Unknown future R SDK models should remain unidentified."
        )

        print("DJI camera advertisement classifier regression checks passed.")
    }
}
