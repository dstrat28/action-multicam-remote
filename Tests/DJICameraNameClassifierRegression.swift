import Foundation

@main
enum DJICameraNameClassifierRegression {
    struct Expectation {
        var name: String
        var model: CameraModel
        var isCredibleCamera: Bool
    }

    static func main() {
        let expectations = [
            Expectation(name: "Nanoleaf Strip 06TD", model: .unknown, isCredibleCamera: false),
            Expectation(name: "UNAGI 87170", model: .unknown, isCredibleCamera: false),
            Expectation(name: "Action Figure 6", model: .unknown, isCredibleCamera: false),
            Expectation(name: "Osmosis Action 4", model: .unknown, isCredibleCamera: false),
            Expectation(name: "DJI Action 6", model: .djiOsmoAction6, isCredibleCamera: true),
            Expectation(name: "OA6", model: .djiOsmoAction6, isCredibleCamera: true),
            Expectation(name: "Osmo Action 5 Pro", model: .djiOsmoAction5Pro, isCredibleCamera: true),
            Expectation(name: "ACTION 4", model: .djiOsmoAction4, isCredibleCamera: true),
            Expectation(name: "Osmo 360", model: .djiOsmo360, isCredibleCamera: true),
            Expectation(name: "DJI360-A1B2", model: .djiOsmo360, isCredibleCamera: true),
            Expectation(name: "Osmo Nano", model: .djiOsmoNano, isCredibleCamera: true),
            Expectation(name: "NANO 06TD", model: .djiOsmoNano, isCredibleCamera: true),
            Expectation(name: "Pocket 3", model: .djiOsmoPocket3, isCredibleCamera: true),
            Expectation(name: "DJI Prototype", model: .unknown, isCredibleCamera: true)
        ]

        for expectation in expectations {
            let actualModel = DJICameraNameClassifier.model(for: expectation.name)
            precondition(
                actualModel == expectation.model,
                "\(expectation.name): expected \(expectation.model), got \(actualModel)"
            )

            let actualCredibility = DJICameraNameClassifier.isCredibleCameraName(expectation.name)
            precondition(
                actualCredibility == expectation.isCredibleCamera,
                "\(expectation.name): expected credibility \(expectation.isCredibleCamera), got \(actualCredibility)"
            )
        }

        print("DJI camera name classifier regression checks passed (\(expectations.count) cases).")
    }
}
