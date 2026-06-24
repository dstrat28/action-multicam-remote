import Foundation

enum CameraBrand: String, CaseIterable, Identifiable, Codable {
    case gopro = "GoPro"
    case dji = "DJI"
    case unknown = "Unknown"

    var id: String { rawValue }
}

enum CameraModel: String, Identifiable, Codable {
    case goproHero13Black = "HERO13 Black"
    case djiOsmoAction6 = "Osmo Action 6"
    case djiOsmoNano = "Osmo Nano"
    case djiOsmoPocket3 = "Osmo Pocket 3"
    case unknown = "Unknown Camera"

    var id: String { rawValue }

    var brand: CameraBrand {
        switch self {
        case .goproHero13Black:
            .gopro
        case .djiOsmoAction6, .djiOsmoNano, .djiOsmoPocket3:
            .dji
        case .unknown:
            .unknown
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

enum CameraBehaviorKind: Equatable {
    case goProHero13Black
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

        if model == .goproHero13Black
            || normalizedName.contains("hero13")
            || normalizedName.contains("13black")
            || normalizedName.contains("h2401") {
            return CameraBehaviorProfile(
                kind: .goProHero13Black,
                assumesRecordingAfterUnconfirmedDJIStart: false,
                preservesActiveDJIRecordingAcrossReconnect: false,
                trustsDJICompactRecordingStatus: false,
                trustsDJIFullRecordingStatus: false,
                trustsDJIRecordingTimerStatus: false,
                trustsDJIRecordingHints: false,
                trustsDJIStoppedStatusToClearActiveRecording: false
            )
        }

        if model == .djiOsmoAction6
            || normalizedName.contains("action6")
            || normalizedName.contains("osmoaction6")
            || normalizedName.contains("oa6") {
            return CameraBehaviorProfile(
                kind: .djiOsmoAction6,
                assumesRecordingAfterUnconfirmedDJIStart: true,
                preservesActiveDJIRecordingAcrossReconnect: true,
                trustsDJICompactRecordingStatus: true,
                trustsDJIFullRecordingStatus: true,
                trustsDJIRecordingTimerStatus: true,
                trustsDJIRecordingHints: true,
                trustsDJIStoppedStatusToClearActiveRecording: false
            )
        }

        if model == .djiOsmoNano || normalizedName.contains("nano") {
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

        if model == .djiOsmoPocket3
            || normalizedName.contains("pocket3")
            || normalizedName.contains("osmopocket3")
            || normalizedName.contains("op3") {
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
    var isPaired: Bool
    var isSelected: Bool
    var lastSeen: Date
    var lastConnectableSeen: Date? = nil

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
        isTestedSupportedModel(brand: brand, model: model, name: name) ? nil : unsupportedCameraReason
    }

    static func isTestedSupportedModel(
        brand: CameraBrand,
        model: CameraModel,
        name: String
    ) -> Bool {
        switch model {
        case .goproHero13Black, .djiOsmoAction6, .djiOsmoNano:
            return true
        case .djiOsmoPocket3, .unknown:
            break
        }

        let normalizedName = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if brand == .gopro {
            return normalizedName.contains("hero13")
                || normalizedName.contains("13black")
                || normalizedName.contains("h2401")
        }

        if brand == .dji {
            return normalizedName.contains("action6")
                || normalizedName.contains("osmoaction6")
                || normalizedName.contains("oa6")
                || normalizedName.contains("nano")
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
    }

    var isControllable: Bool {
        isSupportedByApp && (isConnected || isAvailableToConnect)
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

    var canAttemptWakeFromNotConnected: Bool {
        false
    }

    var displayConnectionLabel: String {
        isSupportedByApp ? connectionState.label : "Unsupported"
    }

    var canSelectForBatch: Bool {
        isSupportedByApp
            && isPaired
            && supportsBatchRecord
            && (isControllable || canAttemptWakeFromNotConnected)
    }

    var canStartRecording: Bool {
        isPaired
            && supportsBatchRecord
            && (isControllable || canAttemptWakeFromNotConnected)
            && canStartRecordingInCurrentMode
            && recordingState != .recording
            && recordingState != .starting
            && recordingState != .unavailable
    }

    var canSwitchToVideoMode: Bool {
        isPaired
            && isConnected
            && brand != .dji
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
        guard canStartRecordingInCurrentMode else { return false }
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
        return canStartRecording ? .startRecording : nil
    }

    var primaryRecordTitle: String {
        if !isSupportedByApp {
            return "Unsupported"
        }

        if !canStartRecordingInCurrentMode,
           recordingState != .recording,
           recordingState != .starting {
            return "Video Only"
        }

        switch recordingState {
        case .recording:
            return "Stop"
        case .starting:
            return "Starting"
        case .unavailable, .unknown, .ready, .stopped:
            return "Record"
        }
    }

    var primaryRecordIcon: String {
        if !isSupportedByApp {
            return "nosign"
        }

        if !canStartRecordingInCurrentMode,
           recordingState != .recording,
           recordingState != .starting {
            return "video.slash"
        }

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
    var model: CameraModel? = nil
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
