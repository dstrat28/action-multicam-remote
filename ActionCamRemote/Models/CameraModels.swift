import Foundation

enum FeatureAvailability {
    static let djiPhoneGPS = true
}

enum CameraBrand: String, CaseIterable, Identifiable, Codable {
    case gopro = "GoPro"
    case dji = "DJI"
    case unknown = "Unknown"

    var id: String { rawValue }
}

enum CameraModel: String, Identifiable, Codable {
    case goproLitHero = "LIT HERO"
    case goproMax2 = "MAX 2"
    case goproHero13Black = "HERO13 Black"
    case goproHero = "HERO"
    case goproHero12Black = "HERO12 Black"
    case goproHero11BlackMini = "HERO11 Black Mini"
    case goproHero11Black = "HERO11 Black"
    case goproHero10Black = "HERO10 Black"
    case goproHero9Black = "HERO9 Black"
    case goproMax = "MAX"
    case goproHero8Black = "HERO8 Black"
    case djiOsmoAction5Pro = "Osmo Action 5 Pro"
    case djiOsmoAction6 = "Osmo Action 6"
    case djiOsmoNano = "Osmo Nano"
    case djiOsmo360 = "Osmo 360"
    case djiOsmoAction4 = "Osmo Action 4"
    case djiOsmoAction3 = "Osmo Action 3"
    case djiAction2 = "DJI Action 2"
    case djiOsmoAction = "Osmo Action"
    case djiOsmoPocket3 = "Osmo Pocket 3"
    case unknown = "Unknown Camera"

    var id: String { rawValue }

    var brand: CameraBrand {
        switch self {
        case .goproLitHero,
             .goproMax2,
             .goproHero13Black,
             .goproHero,
             .goproHero12Black,
             .goproHero11BlackMini,
             .goproHero11Black,
             .goproHero10Black,
             .goproHero9Black,
             .goproMax,
             .goproHero8Black:
            .gopro
        case .djiOsmoAction5Pro,
             .djiOsmoAction6,
             .djiOsmoNano,
             .djiOsmo360,
             .djiOsmoAction4,
             .djiOsmoAction3,
             .djiAction2,
             .djiOsmoAction,
             .djiOsmoPocket3:
            .dji
        case .unknown:
            .unknown
        }
    }
}

struct DJICameraNameClassifier {
    static func isCredibleCameraName(_ name: String) -> Bool {
        let signature = Signature(name)
        return signature.hasDJIBrand || model(for: name) != .unknown
    }

    static func model(for name: String) -> CameraModel {
        let signature = Signature(name)

        if signature.matches(["action5pro", "action5", "oa5"]) {
            return .djiOsmoAction5Pro
        }
        if signature.matches(["action6", "oa6"]) {
            return .djiOsmoAction6
        }
        if signature.words.contains("nano")
            || signature.normalized.contains("osmonano")
            || (signature.hasDJIBrand && signature.normalized.contains("nano")) {
            return .djiOsmoNano
        }
        if signature.matches(["osmo360", "dji360"]) {
            return .djiOsmo360
        }
        if signature.matches(["action4", "oa4"]) {
            return .djiOsmoAction4
        }
        if signature.matches(["action3", "oa3"]) {
            return .djiOsmoAction3
        }
        if signature.matches(["action2", "oa2"]) {
            return .djiAction2
        }
        if signature.matches(["pocket3", "op3"]) {
            return .djiOsmoPocket3
        }
        if signature.normalized == "action"
            || signature.normalized == "osmoaction"
            || signature.normalized == "djiosmoaction"
            || signature.normalized == "oa1" {
            return .djiOsmoAction
        }

        return .unknown
    }

    private struct Signature {
        var normalized: String
        var words: Set<String>

        init(_ name: String) {
            let lowercasedName = name.lowercased()
            normalized = lowercasedName.filter { $0.isLetter || $0.isNumber }
            words = Set(
                lowercasedName
                    .split { !$0.isLetter && !$0.isNumber }
                    .map(String.init)
            )
        }

        var hasDJIBrand: Bool {
            words.contains("dji") || normalized.hasPrefix("dji")
        }

        var hasCameraBrand: Bool {
            hasDJIBrand
                || words.contains("osmo")
                || normalized.hasPrefix("osmoaction")
                || normalized.hasPrefix("osmonano")
                || normalized.hasPrefix("osmo360")
                || normalized.hasPrefix("osmopocket")
        }

        func matches(_ aliases: [String]) -> Bool {
            if hasCameraBrand, aliases.contains(where: normalized.contains) {
                return true
            }
            return aliases.contains(where: normalized.hasPrefix)
        }
    }
}

extension CameraModel {
    var isOpenGoProCompatible: Bool {
        switch self {
        case .goproLitHero,
             .goproMax2,
             .goproHero13Black,
             .goproHero12Black,
             .goproHero11BlackMini,
             .goproHero11Black,
             .goproHero10Black,
             .goproHero9Black:
            true
        case .goproHero,
             .goproMax,
             .goproHero8Black,
             .djiOsmoAction5Pro,
             .djiOsmoAction6,
             .djiOsmoNano,
             .djiOsmo360,
             .djiOsmoAction4,
             .djiOsmoAction3,
             .djiAction2,
             .djiOsmoAction,
             .djiOsmoPocket3,
             .unknown:
            false
        }
    }
}

enum CameraCapability: String, CaseIterable, Identifiable, Codable {
    case record = "Record"
    case mode = "Mode"
    case settings = "Settings"
    case status = "Status"
    case keepAlive = "Keep Alive"
    case experimental = "Experimental"

    var id: String { rawValue }
}

enum CameraConnectionState: Equatable, Codable {
    case discovered
    case connecting
    case connected
    case disconnected
    case reconnecting
    case unsupported(String)
    case failed(String)

    var label: String {
        switch self {
        case .discovered:
            "Available"
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        case .disconnected:
            "Not Connected"
        case .reconnecting:
            "Reconnecting"
        case .unsupported:
            "Unsupported"
        case .failed:
            "Not Connected"
        }
    }

    var detail: String? {
        switch self {
        case let .unsupported(message), let .failed(message):
            message
        case .discovered, .connecting, .connected, .disconnected, .reconnecting:
            nil
        }
    }
}

enum CameraRecordingState: String, Identifiable, Codable {
    case unavailable = "Control Pending"
    case unknown = "Unknown"
    case ready = "Ready"
    case starting = "Starting"
    case stopped = "Stopped"
    case recording = "Recording"

    var id: String { rawValue }
}

enum CameraPowerState: Equatable {
    case awake
    case sleeping
}

struct CameraTelemetry: Equatable, Codable {
    var batteryPercent: Int? = nil
    var batteryBars: Int? = nil
    var isExternalPowerConnected: Bool? = nil
    var storageState: String? = nil
    var remainingVideoSeconds: UInt32? = nil
    var remainingPhotos: UInt32? = nil
    var sdCardCapacityMB: UInt32? = nil
    var storageFreeMB: UInt32? = nil
    var storageTotalMB: UInt32? = nil
    var videoResolution: String? = nil
    var frameRate: String? = nil
    var framing: String? = nil
    var lens: String? = nil
    var hypersmooth: String? = nil
    var lastUpdated: Date? = nil

    var isEmpty: Bool {
        batteryPercent == nil
            && batteryBars == nil
            && isExternalPowerConnected == nil
            && storageState == nil
            && remainingVideoSeconds == nil
            && remainingPhotos == nil
            && sdCardCapacityMB == nil
            && storageFreeMB == nil
            && storageTotalMB == nil
            && videoResolution == nil
            && frameRate == nil
            && framing == nil
            && lens == nil
            && hypersmooth == nil
    }

    var primarySummaryItems: [String] {
        var items: [String] = []

        if let batteryPercent {
            items.append("Battery \(batteryPercent)%")
        } else if let batteryBars {
            items.append("Battery \(batteryBars)/4")
        }

        if let remainingVideoSeconds {
            items.append("\(Self.durationLabel(seconds: remainingVideoSeconds)) left")
        }

        return items
    }

    var detailSummaryItems: [String] {
        var items: [String] = []

        if let remainingPhotos, remainingPhotos > 0 {
            items.append("\(remainingPhotos) photos left")
        }

        if let storageSummary {
            items.append(storageSummary)
        }

        if let videoSettingSummary {
            items.append(videoSettingSummary)
        }

        if let lens {
            items.append(lens)
        }

        if let hypersmooth {
            items.append("HS \(hypersmooth)")
        }

        return items
    }

    var summaryItems: [String] {
        primarySummaryItems + detailSummaryItems
    }

    var primarySummaryLine: String? {
        let items = primarySummaryItems
        return items.isEmpty ? nil : items.joined(separator: " · ")
    }

    var detailSummaryLine: String? {
        let items = detailSummaryItems
        return items.isEmpty ? nil : items.joined(separator: " · ")
    }

    var summaryLine: String? {
        let items = summaryItems
        return items.isEmpty ? nil : items.joined(separator: " · ")
    }

    mutating func merge(_ update: CameraTelemetry) {
        if let batteryPercent = update.batteryPercent { self.batteryPercent = batteryPercent }
        if let batteryBars = update.batteryBars { self.batteryBars = batteryBars }
        if let isExternalPowerConnected = update.isExternalPowerConnected {
            self.isExternalPowerConnected = isExternalPowerConnected
        }
        if let storageState = update.storageState { self.storageState = storageState }
        if let remainingVideoSeconds = update.remainingVideoSeconds { self.remainingVideoSeconds = remainingVideoSeconds }
        if let remainingPhotos = update.remainingPhotos { self.remainingPhotos = remainingPhotos }
        if let sdCardCapacityMB = update.sdCardCapacityMB { self.sdCardCapacityMB = sdCardCapacityMB }
        if let storageFreeMB = update.storageFreeMB { self.storageFreeMB = storageFreeMB }
        if let storageTotalMB = update.storageTotalMB { self.storageTotalMB = storageTotalMB }
        if let videoResolution = update.videoResolution { self.videoResolution = videoResolution }
        if let frameRate = update.frameRate { self.frameRate = frameRate }
        if let framing = update.framing { self.framing = framing }
        if let lens = update.lens { self.lens = lens }
        if let hypersmooth = update.hypersmooth { self.hypersmooth = hypersmooth }
        if !update.isEmpty { self.lastUpdated = update.lastUpdated ?? Date() }
    }

    private var storageSummary: String? {
        if let storageFreeMB, let storageTotalMB, storageTotalMB > 0 {
            return "Storage \(Self.storageLabel(mb: storageFreeMB))/\(Self.storageLabel(mb: storageTotalMB))"
        }

        if let sdCardCapacityMB, sdCardCapacityMB > 0 {
            return "SD \(Self.storageLabel(mb: sdCardCapacityMB))"
        }

        return storageState
    }

    private var videoSettingSummary: String? {
        let displayFraming = framingAlreadyIncludedInResolution ? nil : framing

        switch (videoResolution, frameRate, displayFraming) {
        case let (resolution?, frameRate?, framing?):
            return "\(resolution) \(frameRate) \(framing)"
        case let (resolution?, frameRate?, nil):
            return "\(resolution) \(frameRate)"
        case let (resolution?, nil, framing?):
            return "\(resolution) \(framing)"
        case let (nil, frameRate?, framing?):
            return "\(frameRate) \(framing)"
        case let (resolution?, nil, nil):
            return resolution
        case let (nil, frameRate?, nil):
            return frameRate
        case let (nil, nil, framing?):
            return framing
        case (nil, nil, nil):
            return nil
        }
    }

    private var framingAlreadyIncludedInResolution: Bool {
        guard let videoResolution, let framing else { return false }
        return videoResolution.contains(framing)
    }

    private static func durationLabel(seconds: UInt32) -> String {
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0, minutes > 0 {
            return "\(hours)h \(minutes)m"
        }

        if hours > 0 {
            return "\(hours)h"
        }

        return "\(max(1, minutes))m"
    }

    private static func storageLabel(mb: UInt32) -> String {
        guard mb >= 1024 else { return "\(mb) MB" }
        let gb = Double(mb) / 1024.0
        if gb >= 10 {
            return "\(Int(gb.rounded())) GB"
        }
        return String(format: "%.1f GB", gb)
    }
}

enum CameraBehaviorKind: Equatable {
    case goProOpen
    case djiOsmoAction4
    case djiOsmoAction5Pro
    case djiOsmoAction6
    case djiOsmoNano
    case djiOsmoPocket3
    case genericDJI
    case unknown
}

struct CameraBehaviorProfile: Equatable {
    var kind: CameraBehaviorKind
    var assumesRecordingAfterUnconfirmedDJIStart: Bool
    var preservesActiveDJIRecordingAcrossReconnect: Bool
    var trustsDJICompactRecordingStatus: Bool
    var trustsDJIFullRecordingStatus: Bool
    var trustsDJIRecordingTimerStatus: Bool
    var trustsDJIRecordingHints: Bool
    var trustsDJIStoppedStatusToClearActiveRecording: Bool

    static func resolve(
        brand: CameraBrand,
        model: CameraModel,
        name: String
    ) -> CameraBehaviorProfile {
        let normalizedName = name.lowercased().filter { $0.isLetter || $0.isNumber }
        let inferredDJIModel = DJICameraNameClassifier.model(for: name)

        if model.isOpenGoProCompatible
            || normalizedName.contains("hero13")
            || normalizedName.contains("hero12")
            || normalizedName.contains("hero11")
            || normalizedName.contains("hero10")
            || normalizedName.contains("hero9")
            || normalizedName.contains("13black")
            || normalizedName.contains("12black")
            || normalizedName.contains("11black")
            || normalizedName.contains("10black")
            || normalizedName.contains("9black")
            || normalizedName.contains("max2")
            || normalizedName.contains("lithero")
            || normalizedName.contains("h2503")
            || normalizedName.contains("h2402")
            || normalizedName.contains("h2401")
            || normalizedName.contains("h2301")
            || normalizedName.contains("h2203")
            || normalizedName.contains("h2201")
            || normalizedName.contains("h2101")
            || normalizedName.contains("hd901") {
            return CameraBehaviorProfile(
                kind: .goProOpen,
                assumesRecordingAfterUnconfirmedDJIStart: false,
                preservesActiveDJIRecordingAcrossReconnect: false,
                trustsDJICompactRecordingStatus: false,
                trustsDJIFullRecordingStatus: false,
                trustsDJIRecordingTimerStatus: false,
                trustsDJIRecordingHints: false,
                trustsDJIStoppedStatusToClearActiveRecording: false
            )
        }

        if model == .djiOsmoAction5Pro || inferredDJIModel == .djiOsmoAction5Pro {
            return CameraBehaviorProfile(
                kind: .djiOsmoAction5Pro,
                assumesRecordingAfterUnconfirmedDJIStart: false,
                preservesActiveDJIRecordingAcrossReconnect: false,
                trustsDJICompactRecordingStatus: false,
                trustsDJIFullRecordingStatus: true,
                trustsDJIRecordingTimerStatus: false,
                trustsDJIRecordingHints: false,
                trustsDJIStoppedStatusToClearActiveRecording: true
            )
        }

        if model == .djiOsmoAction4 || inferredDJIModel == .djiOsmoAction4 {
            return CameraBehaviorProfile(
                kind: .djiOsmoAction4,
                assumesRecordingAfterUnconfirmedDJIStart: false,
                preservesActiveDJIRecordingAcrossReconnect: false,
                trustsDJICompactRecordingStatus: false,
                trustsDJIFullRecordingStatus: true,
                trustsDJIRecordingTimerStatus: false,
                trustsDJIRecordingHints: false,
                trustsDJIStoppedStatusToClearActiveRecording: true
            )
        }

        if model == .djiOsmoAction6 || inferredDJIModel == .djiOsmoAction6 {
            return CameraBehaviorProfile(
                kind: .djiOsmoAction6,
                assumesRecordingAfterUnconfirmedDJIStart: true,
                preservesActiveDJIRecordingAcrossReconnect: true,
                trustsDJICompactRecordingStatus: false,
                trustsDJIFullRecordingStatus: true,
                trustsDJIRecordingTimerStatus: false,
                trustsDJIRecordingHints: false,
                trustsDJIStoppedStatusToClearActiveRecording: false
            )
        }

        if model == .djiOsmoNano || inferredDJIModel == .djiOsmoNano {
            return CameraBehaviorProfile(
                kind: .djiOsmoNano,
                assumesRecordingAfterUnconfirmedDJIStart: true,
                preservesActiveDJIRecordingAcrossReconnect: true,
                trustsDJICompactRecordingStatus: false,
                trustsDJIFullRecordingStatus: true,
                trustsDJIRecordingTimerStatus: false,
                trustsDJIRecordingHints: false,
                trustsDJIStoppedStatusToClearActiveRecording: true
            )
        }

        if model == .djiOsmoPocket3 || inferredDJIModel == .djiOsmoPocket3 {
            return CameraBehaviorProfile(
                kind: .djiOsmoPocket3,
                assumesRecordingAfterUnconfirmedDJIStart: false,
                preservesActiveDJIRecordingAcrossReconnect: false,
                trustsDJICompactRecordingStatus: false,
                trustsDJIFullRecordingStatus: true,
                trustsDJIRecordingTimerStatus: false,
                trustsDJIRecordingHints: false,
                trustsDJIStoppedStatusToClearActiveRecording: true
            )
        }

        if brand == .dji || model.brand == .dji {
            return CameraBehaviorProfile(
                kind: .genericDJI,
                assumesRecordingAfterUnconfirmedDJIStart: false,
                preservesActiveDJIRecordingAcrossReconnect: false,
                trustsDJICompactRecordingStatus: false,
                trustsDJIFullRecordingStatus: true,
                trustsDJIRecordingTimerStatus: false,
                trustsDJIRecordingHints: false,
                trustsDJIStoppedStatusToClearActiveRecording: true
            )
        }

        return CameraBehaviorProfile(
            kind: .unknown,
            assumesRecordingAfterUnconfirmedDJIStart: false,
            preservesActiveDJIRecordingAcrossReconnect: false,
            trustsDJICompactRecordingStatus: false,
            trustsDJIFullRecordingStatus: false,
            trustsDJIRecordingTimerStatus: false,
            trustsDJIRecordingHints: false,
            trustsDJIStoppedStatusToClearActiveRecording: false
        )
    }

    var supportsExperimentalDJISleepWake: Bool {
        false
    }
}

struct DiscoveredCamera: Identifiable, Equatable, Codable {
    static let unsupportedCameraReason = "Unsupported"

    let id: UUID
    var name: String
    var brand: CameraBrand
    var model: CameraModel
    var rssi: Int
    var capabilities: Set<CameraCapability>
    var connectionState: CameraConnectionState
    var recordingState: CameraRecordingState
    var currentMode: CaptureMode? = nil
    var telemetry: CameraTelemetry? = nil
    var isPaired: Bool
    var isSelected: Bool
    var lastSeen: Date
    var lastConnectableSeen: Date? = nil
    var isPairingAdvertisement: Bool? = nil

    var isSupportedByApp: Bool {
        unsupportedReason == nil
    }

    var unsupportedReason: String? {
        Self.unsupportedReason(brand: brand, model: model, name: name)
    }

    static func unsupportedReason(
        brand: CameraBrand,
        model: CameraModel,
        name: String
    ) -> String? {
        isSupportedModel(brand: brand, model: model, name: name) ? nil : unsupportedCameraReason
    }

    static func isSupportedModel(
        brand: CameraBrand,
        model: CameraModel,
        name: String
    ) -> Bool {
        switch model {
        case .goproLitHero,
             .goproMax2,
             .goproHero13Black,
             .goproHero12Black,
             .goproHero11BlackMini,
             .goproHero11Black,
             .goproHero10Black,
             .goproHero9Black,
             .djiOsmoAction4,
             .djiOsmoAction5Pro,
             .djiOsmoAction6,
             .djiOsmoNano:
            return true
        case .goproHero,
             .goproMax,
             .goproHero8Black,
             .djiOsmo360,
             .djiOsmoAction3,
             .djiAction2,
             .djiOsmoAction,
             .djiOsmoPocket3,
             .unknown:
            break
        }

        let normalizedName = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if brand == .gopro {
            return normalizedName.contains("hero13")
                || normalizedName.contains("hero12")
                || normalizedName.contains("hero11")
                || normalizedName.contains("hero10")
                || normalizedName.contains("hero9")
                || normalizedName.contains("13black")
                || normalizedName.contains("12black")
                || normalizedName.contains("11black")
                || normalizedName.contains("10black")
                || normalizedName.contains("9black")
                || normalizedName.contains("max2")
                || normalizedName.contains("lithero")
                || normalizedName.contains("h2503")
                || normalizedName.contains("h2402")
                || normalizedName.contains("h2401")
                || normalizedName.contains("h2301")
                || normalizedName.contains("h2203")
                || normalizedName.contains("h2201")
                || normalizedName.contains("h2101")
                || normalizedName.contains("hd901")
        }

        if brand == .dji {
            switch DJICameraNameClassifier.model(for: name) {
            case .djiOsmoAction4,
                 .djiOsmoAction5Pro,
                 .djiOsmoAction6,
                 .djiOsmoNano:
                return true
            case .goproLitHero,
                 .goproMax2,
                 .goproHero13Black,
                 .goproHero,
                 .goproHero12Black,
                 .goproHero11BlackMini,
                 .goproHero11Black,
                 .goproHero10Black,
                 .goproHero9Black,
                 .goproMax,
                 .goproHero8Black,
                 .djiOsmo360,
                 .djiOsmoAction3,
                 .djiAction2,
                 .djiOsmoAction,
                 .djiOsmoPocket3,
                 .unknown:
                return false
            }
        }

        return false
    }

    var supportsBatchRecord: Bool {
        isSupportedByApp && capabilities.contains(.record)
    }

    var isConnected: Bool {
        connectionState == .connected
    }

    var isAvailableToConnect: Bool {
        connectionState == .discovered
            && (brand == .gopro || supportsExperimentalDJISleepWake)
    }

    var needsGoProPairingMode: Bool {
        brand == .gopro
            && !isPaired
            && isPairingAdvertisement == false
    }

    var isControllable: Bool {
        isSupportedByApp && isConnected
    }

    var normalizedName: String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    var behavior: CameraBehaviorProfile {
        CameraBehaviorProfile.resolve(brand: brand, model: model, name: name)
    }

    var isKnownAction6: Bool {
        behavior.kind == .djiOsmoAction6
    }

    var isKnownAction5Pro: Bool {
        behavior.kind == .djiOsmoAction5Pro
    }

    var isKnownAction4: Bool {
        behavior.kind == .djiOsmoAction4
    }

    var supportsExperimentalDJISleepWake: Bool {
        behavior.supportsExperimentalDJISleepWake
    }

    var supportsDJIPhoneGPS: Bool {
        switch behavior.kind {
        case .djiOsmoAction4, .djiOsmoAction5Pro, .djiOsmoAction6:
            true
        case .goProOpen, .djiOsmoNano, .djiOsmoPocket3, .genericDJI, .unknown:
            false
        }
    }

    var displayConnectionLabel: String {
        guard isSupportedByApp else { return "Unsupported" }
        if connectionState == .discovered {
            return CameraConnectionState.disconnected.label
        }
        return connectionState.label
    }

    var canSelectForBatch: Bool {
        isSupportedByApp
            && isPaired
            && supportsBatchRecord
            && isControllable
    }

    var canStartRecording: Bool {
        isPaired
            && supportsBatchRecord
            && isControllable
            && canStartRecordingInCurrentMode
            && recordingState != .recording
            && recordingState != .starting
            && recordingState != .unavailable
    }

    var canSwitchToVideoMode: Bool {
        isPaired
            && isConnected
            && capabilities.contains(.mode)
            && currentMode != .video
            && recordingState != .recording
            && recordingState != .starting
    }

    var canStopRecording: Bool {
        isPaired && supportsBatchRecord && recordingState == .recording
    }

    var needsKnownStoppedStateForMulticam: Bool {
        false
    }

    var canStartRecordingInCurrentMode: Bool {
        !isConnected || currentMode == nil || currentMode == .video
    }

    var isReadyForMulticamStart: Bool {
        guard canSelectForBatch, recordingState != .recording, recordingState != .starting else { return false }
        guard canStartRecordingInCurrentMode || canSwitchToVideoMode else { return false }
        return !needsKnownStoppedStateForMulticam || recordingState == .stopped
    }

    var isWaitingForAuthoritativeRecordingStatus: Bool {
        canSelectForBatch && needsKnownStoppedStateForMulticam && recordingState == .unknown
    }

    var primaryRecordCommand: CameraCommand? {
        guard isPaired, supportsBatchRecord else { return nil }
        if recordingState == .recording {
            return .stopRecording
        }
        guard recordingState != .starting else { return nil }
        return (canStartRecording || canSwitchToVideoMode) ? .startRecording : nil
    }

    var primaryRecordTitle: String {
        recordingState == .recording ? "Stop" : "Record"
    }

    var primaryRecordIcon: String {
        switch recordingState {
        case .recording:
            return "stop.circle"
        case .starting:
            return "hourglass"
        case .unavailable, .unknown, .ready, .stopped:
            return "record.circle"
        }
    }

    var signalLabel: String {
        switch rssi {
        case -55 ... Int.max:
            "Strong"
        case -70 ..< -55:
            "Good"
        case -85 ..< -70:
            "Weak"
        default:
            "Very Weak"
        }
    }
}

enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case video = "Video"
    case photo = "Photo"
    case timelapse = "Timelapse"

    var id: String { rawValue }
}

struct CameraSetting: Equatable, Codable {
    var id: UInt8
    var value: UInt8
    var label: String
}

struct CameraStatusUpdate: Equatable {
    var recordingState: CameraRecordingState? = nil
    var currentMode: CaptureMode? = nil
    var telemetry: CameraTelemetry? = nil
    var model: CameraModel? = nil
    var powerState: CameraPowerState? = nil
    var canClearActiveRecording: Bool = true
    var shouldClearCurrentMode: Bool = false
}

enum CameraCommand: Equatable, Codable {
    case startRecording
    case stopRecording
    case toggleRecording
    case setMode(CaptureMode)
    case cycleMode
    case applySetting(CameraSetting)
    case keepAlive

    var label: String {
        switch self {
        case .startRecording:
            "Start Recording"
        case .stopRecording:
            "Stop Recording"
        case .toggleRecording:
            "Toggle Recording"
        case let .setMode(mode):
            "Set \(mode.rawValue)"
        case .cycleMode:
            "Cycle Mode"
        case let .applySetting(setting):
            "Set \(setting.label)"
        case .keepAlive:
            "Keep Alive"
        }
    }
}

enum CameraCommandStatus: String, Codable {
    case queued = "Queued"
    case sent = "Sent"
    case skipped = "Skipped"
    case unsupported = "Unsupported"
    case failed = "Failed"
}

struct CameraCommandResult: Identifiable, Codable {
    var id = UUID()
    var cameraID: UUID
    var cameraName: String
    var command: CameraCommand
    var status: CameraCommandStatus
    var message: String
    var timestamp: Date
}
