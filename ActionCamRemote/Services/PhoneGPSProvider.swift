import CoreLocation
import Foundation

struct DJIGPSFix: Equatable {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double
    var horizontalAccuracyMeters: Double
    var verticalAccuracyMeters: Double
    var northVelocityMetersPerSecond: Double
    var eastVelocityMetersPerSecond: Double
    var downwardVelocityMetersPerSecond: Double
    var speedAccuracyMetersPerSecond: Double
    var satelliteCount: UInt32

    init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double,
        horizontalAccuracyMeters: Double,
        verticalAccuracyMeters: Double,
        northVelocityMetersPerSecond: Double,
        eastVelocityMetersPerSecond: Double,
        downwardVelocityMetersPerSecond: Double,
        speedAccuracyMetersPerSecond: Double,
        satelliteCount: UInt32 = 0
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.verticalAccuracyMeters = verticalAccuracyMeters
        self.northVelocityMetersPerSecond = northVelocityMetersPerSecond
        self.eastVelocityMetersPerSecond = eastVelocityMetersPerSecond
        self.downwardVelocityMetersPerSecond = downwardVelocityMetersPerSecond
        self.speedAccuracyMetersPerSecond = speedAccuracyMetersPerSecond
        self.satelliteCount = satelliteCount
    }

    init(location: CLLocation) {
        let speed = location.speed >= 0 ? location.speed : 0
        let hasDirection = location.course >= 0 && speed > 0
        let courseRadians = hasDirection ? location.course * .pi / 180 : 0

        timestamp = location.timestamp
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitudeMeters = location.altitude
        horizontalAccuracyMeters = max(location.horizontalAccuracy, 0)
        verticalAccuracyMeters = max(location.verticalAccuracy, 0)
        northVelocityMetersPerSecond = hasDirection ? speed * cos(courseRadians) : 0
        eastVelocityMetersPerSecond = hasDirection ? speed * sin(courseRadians) : 0
        downwardVelocityMetersPerSecond = 0
        speedAccuracyMetersPerSecond = max(location.speedAccuracy, 0)
        // Core Location does not expose satellite count, but DJI rejects zero
        // as an invalid fix. Four is the minimum plausible count for a 3D fix.
        satelliteCount = 4
    }
}

enum DJIGPSPayloadEncoder {
    static func payload(for fix: DJIGPSFix) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60) ?? .gmt
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fix.timestamp
        )

        let yearMonthDay = Int32(
            (components.year ?? 0) * 10_000
                + (components.month ?? 0) * 100
                + (components.day ?? 0)
        )
        let hourMinuteSecond = Int32(
            (components.hour ?? 0) * 10_000
                + (components.minute ?? 0) * 100
                + (components.second ?? 0)
        )

        var payload = Data()
        payload.appendGPSLittleEndian(yearMonthDay)
        payload.appendGPSLittleEndian(hourMinuteSecond)
        payload.appendGPSLittleEndian(scaledInt32(fix.longitude, multiplier: 10_000_000))
        payload.appendGPSLittleEndian(scaledInt32(fix.latitude, multiplier: 10_000_000))
        payload.appendGPSLittleEndian(scaledInt32(fix.altitudeMeters, multiplier: 1_000))
        payload.appendGPSLittleEndian(Float(fix.northVelocityMetersPerSecond * 100))
        payload.appendGPSLittleEndian(Float(fix.eastVelocityMetersPerSecond * 100))
        payload.appendGPSLittleEndian(Float(fix.downwardVelocityMetersPerSecond * 100))
        payload.appendGPSLittleEndian(scaledUInt32(fix.verticalAccuracyMeters, multiplier: 1_000))
        payload.appendGPSLittleEndian(scaledUInt32(fix.horizontalAccuracyMeters, multiplier: 1_000))
        payload.appendGPSLittleEndian(scaledUInt32(fix.speedAccuracyMetersPerSecond, multiplier: 100))
        payload.appendGPSLittleEndian(fix.satelliteCount)
        return payload
    }

    private static func scaledInt32(_ value: Double, multiplier: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        let scaled = (value * multiplier).rounded()
        return Int32(max(Double(Int32.min), min(Double(Int32.max), scaled)))
    }

    private static func scaledUInt32(_ value: Double, multiplier: Double) -> UInt32 {
        guard value.isFinite, value > 0 else { return 0 }
        let scaled = (value * multiplier).rounded()
        return UInt32(min(Double(UInt32.max), scaled))
    }
}

enum PhoneGPSAuthorizationState: Equatable {
    case notDetermined
    case authorized
    case denied
}

@MainActor
final class PhoneGPSProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    var onTransmissionTick: ((DJIGPSFix) -> Void)?
#if DEBUG
    var onDebugLog: ((String) -> Void)?
#endif

    private let locationManager: CLLocationManager
    private var transmissionTimer: Timer?
    private var latestFix: DJIGPSFix?
    private var wantsLocationUpdates = false
    private let maximumTransmissionAge: TimeInterval = 2
#if DEBUG
    private var lastFixDebugLogDate = Date.distantPast
    private var lastWaitingDebugLogDate = Date.distantPast
    private var lastStaleDebugLogDate = Date.distantPast
    private let debugLogInterval: TimeInterval = 5
#endif

    override init() {
        let manager = CLLocationManager()
        locationManager = manager
        super.init()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorizationState: PhoneGPSAuthorizationState {
        Self.authorizationState(for: locationManager.authorizationStatus)
    }

    func requestWhenInUseAuthorization() {
        guard locationManager.authorizationStatus == .notDetermined else {
            reconcileLocationUpdates()
            return
        }
        locationManager.requestWhenInUseAuthorization()
    }

    func setActive(_ isActive: Bool) {
        guard wantsLocationUpdates != isActive else { return }
        wantsLocationUpdates = isActive
#if DEBUG
        onDebugLog?("provider active=\(isActive), authorization=\(authorizationState.debugLabel)")
#endif
        reconcileLocationUpdates()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
#if DEBUG
        onDebugLog?("authorization changed to \(authorizationState.debugLabel)")
#endif
        reconcileLocationUpdates()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: Self.isUsableLocation) else { return }
        let fix = DJIGPSFix(location: location)
        latestFix = fix
#if DEBUG
        let now = Date()
        if now.timeIntervalSince(lastFixDebugLogDate) >= debugLogInterval {
            lastFixDebugLogDate = now
            let age = max(0, now.timeIntervalSince(fix.timestamp))
            onDebugLog?(
                String(
                    format: "fix received: lat=%.7f, lon=%.7f, altitude=%.1fm, hAcc=%.1fm, vAcc=%.1fm, age=%.2fs",
                    fix.latitude,
                    fix.longitude,
                    fix.altitudeMeters,
                    fix.horizontalAccuracyMeters,
                    fix.verticalAccuracyMeters,
                    age
                )
            )
        }
#endif
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
#if DEBUG
        onDebugLog?("Core Location error: \(error.localizedDescription)")
#endif
        guard let locationError = error as? CLError, locationError.code == .denied else { return }
        stopLocationUpdates()
    }

    private func reconcileLocationUpdates() {
        guard wantsLocationUpdates, authorizationState == .authorized else {
            stopLocationUpdates()
            return
        }

        locationManager.startUpdatingLocation()
        startTransmissionTimerIfNeeded()
    }

    private func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
        transmissionTimer?.invalidate()
        transmissionTimer = nil
    }

    private func startTransmissionTimerIfNeeded() {
        guard transmissionTimer == nil else { return }

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.transmitLatestFixIfFresh()
            }
        }
        transmissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func transmitLatestFixIfFresh(now: Date = Date()) {
#if DEBUG
        guard let latestFix else {
            if now.timeIntervalSince(lastWaitingDebugLogDate) >= debugLogInterval {
                lastWaitingDebugLogDate = now
                onDebugLog?("waiting for the first usable phone location fix")
            }
            return
        }

        let age = now.timeIntervalSince(latestFix.timestamp)
        guard abs(age) <= maximumTransmissionAge else {
            if now.timeIntervalSince(lastStaleDebugLogDate) >= debugLogInterval {
                lastStaleDebugLogDate = now
                onDebugLog?(String(format: "latest phone fix is stale (age %.2fs); not transmitting", age))
            }
            return
        }
#else
        guard let latestFix,
              abs(now.timeIntervalSince(latestFix.timestamp)) <= maximumTransmissionAge else {
            return
        }
#endif
        onTransmissionTick?(latestFix)
    }

    private static func isUsableLocation(_ location: CLLocation) -> Bool {
        let coordinate = location.coordinate
        return CLLocationCoordinate2DIsValid(coordinate)
            && coordinate.latitude.isFinite
            && coordinate.longitude.isFinite
            && location.horizontalAccuracy >= 0
            && abs(Date().timeIntervalSince(location.timestamp)) <= 10
    }

    private static func authorizationState(for status: CLAuthorizationStatus) -> PhoneGPSAuthorizationState {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            .authorized
        case .notDetermined:
            .notDetermined
        case .denied, .restricted:
            .denied
        @unknown default:
            .denied
        }
    }
}

#if DEBUG
private extension PhoneGPSAuthorizationState {
    var debugLabel: String {
        switch self {
        case .notDetermined:
            "not determined"
        case .authorized:
            "authorized"
        case .denied:
            "denied"
        }
    }
}
#endif

private extension Data {
    mutating func appendGPSLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendGPSLittleEndian(_ value: Int32) {
        appendGPSLittleEndian(UInt32(bitPattern: value))
    }

    mutating func appendGPSLittleEndian(_ value: Float) {
        appendGPSLittleEndian(value.bitPattern)
    }
}
