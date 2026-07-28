import Foundation

@main
enum DJIGPSPayloadRegression {
    static func main() {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = .gmt
        let timestamp = utcCalendar.date(
            from: DateComponents(
                year: 2026,
                month: 1,
                day: 1,
                hour: 20,
                minute: 30,
                second: 5
            )
        )!

        let fix = DJIGPSFix(
            timestamp: timestamp,
            latitude: 37.7749,
            longitude: -122.4194,
            altitudeMeters: 15.25,
            horizontalAccuracyMeters: 4.75,
            verticalAccuracyMeters: 2.25,
            northVelocityMetersPerSecond: 1.25,
            eastVelocityMetersPerSecond: -0.5,
            downwardVelocityMetersPerSecond: 0.125,
            speedAccuracyMetersPerSecond: 0.3
        )
        let payload = DJIGPSPayloadEncoder.payload(for: fix)

        precondition(payload.count == 48, "DJI GPS payload must remain 48 bytes")
        precondition(payload.int32(at: 0) == 20_260_102, "UTC+8 date rollover is incorrect")
        precondition(payload.int32(at: 4) == 43_005, "UTC+8 time is incorrect")
        precondition(payload.int32(at: 8) == -1_224_194_000, "Longitude scaling is incorrect")
        precondition(payload.int32(at: 12) == 377_749_000, "Latitude scaling is incorrect")
        precondition(payload.int32(at: 16) == 15_250, "Altitude scaling is incorrect")
        precondition(payload.float(at: 20) == 125, "North velocity scaling is incorrect")
        precondition(payload.float(at: 24) == -50, "East velocity scaling is incorrect")
        precondition(payload.float(at: 28) == 12.5, "Downward velocity scaling is incorrect")
        precondition(payload.uint32(at: 32) == 2_250, "Vertical accuracy scaling is incorrect")
        precondition(payload.uint32(at: 36) == 4_750, "Horizontal accuracy scaling is incorrect")
        precondition(payload.uint32(at: 40) == 30, "Speed accuracy scaling is incorrect")
        precondition(payload.uint32(at: 44) == 0, "iOS must report unknown satellite count as zero")

        print("DJI GPS payload regression checks passed.")
    }
}

private extension Data {
    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[index(startIndex, offsetBy: offset)])
            | UInt32(self[index(startIndex, offsetBy: offset + 1)]) << 8
            | UInt32(self[index(startIndex, offsetBy: offset + 2)]) << 16
            | UInt32(self[index(startIndex, offsetBy: offset + 3)]) << 24
    }

    func int32(at offset: Int) -> Int32 {
        Int32(bitPattern: uint32(at: offset))
    }

    func float(at offset: Int) -> Float {
        Float(bitPattern: uint32(at: offset))
    }
}
