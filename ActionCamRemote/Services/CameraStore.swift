import CoreBluetooth
import Darwin
import Foundation
import Observation
import OSLog
import UIKit

struct NanoPairingConfirmation: Equatable {
    var cameraID: UUID
    var cameraName: String
}

@MainActor
@Observable
final class CameraStore {
    var cameras: [DiscoveredCamera] = [] {
        didSet {
            recordingLiveActivityController.reconcile(cameras: cameras)
        }
    }
    var commandResults: [CameraCommandResult] = []
    var eventLog: [String] = []
    var isScanning = false
    var bluetoothStateLabel = "Unknown"
    var isDemoMode = false
    var cameraDiagnosticsByID: [UUID: String] = [:]
    var nanoPairingConfirmation: NanoPairingConfirmation?
    private(set) var djiPhoneGPSCameraIDs: Set<UUID> = []

    @ObservationIgnored private let scanner: BLECameraScanner
    @ObservationIgnored private var insta360Remote: Insta360RemoteService?
    @ObservationIgnored private let phoneGPSProvider = PhoneGPSProvider()
    @ObservationIgnored private let recordingLiveActivityController = RecordingLiveActivityController()
    @ObservationIgnored private var liveActivityStopObserver: NSObjectProtocol?
    @ObservationIgnored private var liveActivityHighlightObserver: NSObjectProtocol?
    @ObservationIgnored private var clients: [UUID: any BLECameraDeviceClient] = [:]
    @ObservationIgnored private var demoDiscoveryIndex = 0
    @ObservationIgnored private let pairedCamerasStorageKey = "pairedCameras.v1"
    @ObservationIgnored private let djiPhoneGPSStorageKey = "djiPhoneGPSCameraIDs.v1"
    @ObservationIgnored private var lastConnectionAttemptByID: [UUID: Date] = [:]
    @ObservationIgnored private let signalRefreshInterval: TimeInterval = 8
    @ObservationIgnored private let availabilityFreshnessInterval: TimeInterval = 10
    @ObservationIgnored private let djiWakeAdvertisementGapInterval: TimeInterval = 5
    @ObservationIgnored private let nanoPowerTransitionSettleInterval: TimeInterval = 3
    @ObservationIgnored private let nanoAwakeConfirmationInterval: TimeInterval = 1
    @ObservationIgnored private let autoConnectRetryCooldownInterval: TimeInterval = 12
    @ObservationIgnored private let goProDisconnectReconnectDelay: TimeInterval = 3
    @ObservationIgnored private let availabilityTimeoutDelay: Duration = .seconds(10)
    @ObservationIgnored private let action6ProtocolStalenessInterval: TimeInterval = 5
    @ObservationIgnored private let nanoProtocolStalenessInterval: TimeInterval = 12
    @ObservationIgnored private let goProProtocolStalenessInterval: TimeInterval = 12
    @ObservationIgnored private let modeSwitchDelay: Duration = .milliseconds(1600)
    @ObservationIgnored private let defaultConnectionTimeoutDelay: Duration = .seconds(9)
    @ObservationIgnored private let goProProtocolConnectionTimeoutDelay: Duration = .seconds(15)
    @ObservationIgnored private let action6PassiveConnectionTimeoutDelay: Duration = .seconds(6)
    @ObservationIgnored private let nanoPassiveConnectionTimeoutDelay: Duration = .seconds(15)
    @ObservationIgnored private let djiProtocolConnectionTimeoutDelay: Duration = .seconds(32)
    @ObservationIgnored private let defaultStartStateGuardInterval: TimeInterval = 5
    @ObservationIgnored private let maxManualPairConnectionFailures = 3
    @ObservationIgnored private let pocket3StartStateGuardInterval: TimeInterval = 1.5
    @ObservationIgnored private let defaultStopStateGuardInterval: TimeInterval = 2.5
    @ObservationIgnored private let nanoStopStateGuardInterval: TimeInterval = 8
    @ObservationIgnored private let maxExplicitGoProWakeConnectionFailures = 5
    @ObservationIgnored private var wakeRetryTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var startRecordingTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var photoCaptureResetTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var videoModeTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var connectionTimeoutTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var availabilityTimeoutTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var reconnectTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var manualPairRetryTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var connectedStalenessTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var modeSwitchAttemptsByCameraID: [UUID: Int] = [:]
    @ObservationIgnored private var pendingStartConnectionFailuresByCameraID: [UUID: Int] = [:]
    @ObservationIgnored private var manualPairConnectionFailuresByCameraID: [UUID: Int] = [:]
    @ObservationIgnored private var explicitGoProWakeConnectionFailuresByCameraID: [UUID: Int] = [:]
    @ObservationIgnored private var availabilitySuppressedUntilByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var autoConnectSuppressedUntilByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var lastWakeScanRefreshByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var lastProtocolActivityByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var lastDJIAdvertisementByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var awakeAdvertisementByCameraID: [UUID: Bool] = [:]
    @ObservationIgnored private var awakeAdvertisementSeenAtByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var nanoAwakeCandidateSinceByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var ignoreStoppedUntilByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var ignoreRecordingUntilByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var pendingStartCameraIDs: Set<UUID> = []
    @ObservationIgnored private var pendingStopCameraIDs: Set<UUID> = []
    @ObservationIgnored private var pendingManualPairCameraIDs: Set<UUID> = []
    @ObservationIgnored private var passiveDJIProbeCameraIDs: Set<UUID> = []
    @ObservationIgnored private var sleepingDJICameraIDs: Set<UUID> = []
    @ObservationIgnored private var nanoPassiveReconnectBlockedCameraIDs: Set<UUID> = []
    @ObservationIgnored private var explicitGoProWakeCameraIDs: Set<UUID> = []
    @ObservationIgnored private var explicitNanoWakeCameraIDs: Set<UUID> = []
    @ObservationIgnored private var nanoWakeProtocolReadyCameraIDs: Set<UUID> = []
    @ObservationIgnored private var isPairingModeActive = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.ds.ActionCamRemote", category: "camera")

    init(
        scanner: BLECameraScanner = BLECameraScanner(),
        demoMode: Bool? = nil
    ) {
        self.scanner = scanner
        let resolvedDemoMode = demoMode ?? ProcessInfo.processInfo.shouldUseCameraDemoMode
        isDemoMode = resolvedDemoMode
        bluetoothStateLabel = scanner.bluetoothState.displayName

        scanner.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        phoneGPSProvider.onTransmissionTick = { [weak self] fix in
            self?.pushPhoneGPS(fix)
        }

        liveActivityStopObserver = NotificationCenter.default.addObserver(
            forName: .stopRecordingFromLiveActivity,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopLiveActivityRecording()
            }
        }
        liveActivityHighlightObserver = NotificationCenter.default.addObserver(
            forName: .addHighlightFromLiveActivity,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.addHighlight()
            }
        }
#if DEBUG
        phoneGPSProvider.onDebugLog = { [weak self] message in
            self?.appendLog("GPS debug: \(message)")
        }
#endif

        loadDJIPhoneGPSCameraIDs()
        loadPairedCameras()
        syncKnownCamerasWithScanner()

        if resolvedDemoMode {
            bluetoothStateLabel = "Simulator Demo"
#if DEBUG
            if ProcessInfo.processInfo.shouldLoadConnectedCameraDemo {
                loadDemoCameras()
                appendLog("Simulator demo mode loaded connected sample cameras.")
            } else {
                appendLog("Simulator demo mode is ready. Use Connect Camera to add sample discoveries.")
            }
#else
            appendLog("Simulator demo mode is ready. Use Connect Camera to add sample discoveries.")
#endif
        } else if !pairedCameras.isEmpty {
            startScanning()
        }
    }

    private func insta360RemoteService() -> Insta360RemoteService {
        if let insta360Remote {
            return insta360Remote
        }

        let service = Insta360RemoteService()
        service.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleInsta360(event)
            }
        }
        insta360Remote = service
        return service
    }

    var selectedCameras: [DiscoveredCamera] {
        cameras.filter(\.isSelected)
    }

    func isDJIPhoneGPSEnabled(for camera: DiscoveredCamera) -> Bool {
        FeatureAvailability.djiPhoneGPS
            && camera.supportsDJIPhoneGPS
            && djiPhoneGPSCameraIDs.contains(camera.id)
    }

    func setDJIPhoneGPSEnabled(_ isEnabled: Bool, for camera: DiscoveredCamera) {
        guard FeatureAvailability.djiPhoneGPS, camera.supportsDJIPhoneGPS else { return }

        if isEnabled {
            djiPhoneGPSCameraIDs.insert(camera.id)
            phoneGPSProvider.requestWhenInUseAuthorization()
        } else {
            djiPhoneGPSCameraIDs.remove(camera.id)
        }

        persistDJIPhoneGPSCameraIDs()
        reconcilePhoneGPSStreaming()
#if DEBUG
        appendLog(
            "GPS debug: \(camera.name) \(isEnabled ? "enabled" : "disabled"), connection=\(camera.connectionState.label)"
        )
#endif
    }

    var pairedCameras: [DiscoveredCamera] {
        cameras.filter(\.isPaired)
    }

    var pairingCameras: [DiscoveredCamera] {
        cameras.filter { camera in
            if camera.isPaired { return true }

            switch camera.connectionState {
            case .discovered, .connecting, .connected, .reconnecting, .unsupported, .failed:
                return true
            case .disconnected:
                return isPairingModeActive && camera.brand == .dji && camera.isSupportedByApp
            }
        }
    }

    var connectedCameras: [DiscoveredCamera] {
        cameras.filter { $0.connectionState == .connected }
    }

    var readyConnectedCameras: [DiscoveredCamera] {
        connectedCameras.filter(isCameraReadyConnected)
    }

    var selectedConnectedCameras: [DiscoveredCamera] {
        cameras.filter { $0.isSelected && $0.connectionState == .connected }
    }

    var selectedControllableCameras: [DiscoveredCamera] {
        cameras.filter { $0.isSelected && $0.canSelectForBatch }
    }

    var connectedRecordCameras: [DiscoveredCamera] {
        connectedCameras.filter(\.supportsBatchRecord)
    }

    var diagnosticsText: String {
        var sections: [String] = [diagnosticsContext]

        if !commandResults.isEmpty {
            sections.append(
                (
                    ["Command Results"]
                        + commandResults.prefix(20).map { result in
                            "\(result.timestamp.formatted(date: .omitted, time: .standard)) \(result.cameraName) \(result.command.label) [\(result.status.rawValue)]: \(result.message)"
                        }
                ).joined(separator: "\n")
            )
        }

        if !eventLog.isEmpty {
            sections.append((["Bluetooth Log"] + eventLog).joined(separator: "\n"))
        }

        return sections.isEmpty ? "No diagnostics yet." : sections.joined(separator: "\n\n")
    }

    private var diagnosticsContext: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let device = UIDevice.current
        let cameraLines = cameras.map { camera in
            let identifier = String(camera.id.uuidString.prefix(8))
            return "Camera: \(camera.displayName) [\(camera.model.rawValue)] id \(identifier), "
                + "state \(camera.displayConnectionLabel), paired \(camera.isPaired ? "yes" : "no"), "
                + "selected \(camera.isSelected ? "yes" : "no")"
        }

        return (
            [
                "Diagnostics Context",
                "Captured: \(Date.now.formatted(date: .numeric, time: .standard))",
                "App: \(version) (\(build))",
                "Device: \(device.model) \(Self.hardwareModelIdentifier)",
                "System: \(device.systemName) \(device.systemVersion)",
                "Bluetooth: \(bluetoothStateLabel)"
            ] + (cameraLines.isEmpty ? ["Cameras: none"] : cameraLines)
        ).joined(separator: "\n")
    }

    private static var hardwareModelIdentifier: String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "unknown" }
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    var controllableRecordCameras: [DiscoveredCamera] {
        cameras.filter(\.canSelectForBatch)
    }

    var canStartMulticamRecording: Bool {
        if isPhotoMulticamSession {
            return !selectedControllableCameras.isEmpty
                && selectedControllableCameras.allSatisfy(\.isReadyForPhotoCapture)
        }

        return !selectedControllableCameras.isEmpty
            && selectedControllableCameras.allSatisfy(\.isReadyForMulticamStart)
    }

    var canStopMulticamRecording: Bool {
        selectedConnectedCameras.contains { camera in
            camera.supportsBatchRecord
                && camera.recordingState == .recording
                && !camera.isInPhotoMode
        }
    }

    var recordingHighlightCameras: [DiscoveredCamera] {
        readyConnectedCameras.filter {
            $0.supportsHighlight && $0.recordingState == .recording
        }
    }

    var canAddHighlight: Bool {
        !recordingHighlightCameras.isEmpty
    }

    var isPhotoMulticamSession: Bool {
        !connectedRecordCameras.isEmpty
            && connectedRecordCameras.allSatisfy(\.isInPhotoMode)
    }

    var multicamReadinessMessage: String {
        guard !controllableRecordCameras.isEmpty else {
            return "Connect cameras to start multicam recording."
        }

        if selectedControllableCameras.isEmpty {
            return "Select the cameras you want to control."
        }

        if isPhotoMulticamSession {
            if selectedControllableCameras.contains(where: {
                $0.recordingState == .starting || $0.recordingState == .recording
            }) {
                return "Waiting for cameras to finish capturing."
            }
            return "Ready. Capture will take a photo on each selected camera."
        }

        if canStopMulticamRecording {
            return "Stop multicam will stop the selected recording cameras."
        }

        if selectedControllableCameras.contains(where: { $0.recordingState == .starting }) {
            return "Waiting for cameras to start recording."
        }

        if selectedControllableCameras.contains(where: { $0.recordingState == .recording }) {
            return "Stop recording cameras individually before multicam start."
        }

        if selectedControllableCameras.contains(where: {
            $0.isConnected && !$0.canStartRecordingInCurrentMode && !$0.canSwitchToVideoMode
        }) {
            return "Switch cameras to Video mode before recording."
        }

        if selectedControllableCameras.contains(where: { $0.isConnected && $0.canSwitchToVideoMode }) {
            return "Ready. Start will switch selected cameras to Video first."
        }

        return "Ready. Multicam start will record selected cameras."
    }

    func startScanning() {
        isScanning = true

        guard !isDemoMode else {
            discoverNextDemoCamera()
            isScanning = false
            return
        }

        scanner.start()
        connectRememberedCamerasIfResolvable()
    }

    func resumeCameraConnections() {
        guard !isDemoMode else { return }

        insta360Remote?.reconcileKnownSessions()

        let retryCandidates = pairedCameras.filter {
            $0.connectionState != .connected && $0.connectionState != .connecting
        }
        guard !retryCandidates.isEmpty else { return }

        for camera in retryCandidates {
            lastConnectionAttemptByID.removeValue(forKey: camera.id)
            availabilitySuppressedUntilByCameraID.removeValue(forKey: camera.id)
            autoConnectSuppressedUntilByCameraID.removeValue(forKey: camera.id)
        }

        appendLog("App active; refreshing Bluetooth camera connections.")
        startScanning()
    }

    func stopScanning() {
        isScanning = false

        guard !isDemoMode else {
            appendLog("Stopped simulator demo scan.")
            return
        }

        scanner.stop()
    }

    func setPairingModeActive(_ isActive: Bool) {
        isPairingModeActive = isActive
        if !isActive {
            cancelManualPairRetries()
        }
    }

    func toggleScanning() {
        isScanning ? stopScanning() : startScanning()
    }

    func toggleSelection(for camera: DiscoveredCamera) {
        guard let index = cameras.firstIndex(where: { $0.id == camera.id }) else { return }
        guard cameras[index].canSelectForBatch || cameras[index].isSelected else { return }
        cameras[index].isSelected.toggle()
    }

    func renameCamera(_ camera: DiscoveredCamera, to proposedName: String) {
        guard let index = cameras.firstIndex(where: { $0.id == camera.id }) else { return }

        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        cameras[index].nickname = trimmedName.isEmpty || trimmedName == cameras[index].name
            ? nil
            : trimmedName
        sortCamerasForEditing()
        persistPairedCameras()
    }

    func selectAllSupported() {
        for index in cameras.indices {
            cameras[index].isSelected = cameras[index].canSelectForBatch
                && cameras[index].isControllable
        }
    }

    func cameraDiagnosticDetail(for camera: DiscoveredCamera) -> String? {
        cameraDiagnosticsByID[camera.id]
    }

    func isCameraReadyConnected(_ camera: DiscoveredCamera) -> Bool {
        camera.connectionState == .connected
    }

    func isCameraConnectInProgress(_ camera: DiscoveredCamera) -> Bool {
        !passiveDJIProbeCameraIDs.contains(camera.id)
            && (camera.connectionState == .connecting || camera.connectionState == .reconnecting)
    }

    func clearSelection() {
        for index in cameras.indices {
            cameras[index].isSelected = false
        }
    }

    func connect(_ camera: DiscoveredCamera) {
        if let unsupportedReason = camera.unsupportedReason {
            setCameraDiagnostic(unsupportedReason, for: camera)
            updateCamera(camera.id, state: .unsupported(unsupportedReason), detail: nil)
            return
        }

        if camera.needsGoProPairingMode {
            let message = "Put the GoPro in pairing mode from the camera UI, then tap Pair again."
            appendLog("\(camera.name): \(message)")
            setCameraDiagnostic(message, for: camera)
            updateCamera(camera.id, state: .discovered, detail: message)
            return
        }

        if let deferredDJIMessage = djiConnectionDeferralMessage(for: camera) {
            appendLog("\(camera.name): \(deferredDJIMessage)")
            setCameraDiagnostic(deferredDJIMessage, for: camera)
            clearPendingStartIfDJIUnavailable(for: camera)
            updateCamera(camera.id, state: .disconnected, detail: deferredDJIMessage)
            refreshWakeScan(for: camera)
            return
        }

        if isDemoMode {
            markCameraAsPaired(camera.id)
            if let index = cameras.firstIndex(where: { $0.id == camera.id }) {
                cameras[index].telemetry = Self.demoTelemetry(for: cameras[index])
            }
            updateCamera(camera.id, state: .connected, detail: "Demo connection established.")
            return
        }

        if camera.connectionState == .connecting {
            if pendingStartCameraIDs.contains(camera.id) {
                refreshWakeScan(for: camera)
                scheduleConnectionTimeout(for: camera.id)
                setCameraDiagnostic(
                    "\(camera.brand.rawValue) wake start is queued onto an existing BLE connection attempt.",
                    for: camera
                )
            }
            return
        }


        if camera.brand == .insta360 {
            lastConnectionAttemptByID[camera.id] = Date()
            updateCamera(camera.id, state: .connecting, detail: nil)
            setCameraDiagnostic(
                "On the camera, open Bluetooth Remote settings and connect to \(Insta360RemoteProtocol.remoteName). Keep Multicam open while pairing.",
                for: camera
            )
            scheduleConnectionTimeout(for: camera.id)
            insta360RemoteService().requestConnection(cameraID: camera.id, cameraName: camera.name)
            return
        }

        if !camera.isPaired, isPairingModeActive {
            if !pendingManualPairCameraIDs.contains(camera.id) {
                manualPairConnectionFailuresByCameraID[camera.id] = 0
            }
            pendingManualPairCameraIDs.insert(camera.id)
        }

        let lookup = scanner.peripheralLookup(for: camera.id)
        guard let peripheral = lookup.peripheral else {
            refreshWakeScan(for: camera)
            let missingPeripheralMessage = missingPeripheralDiagnostic(for: camera)
            setCameraDiagnostic(missingPeripheralMessage, for: camera)
            if camera.isPaired {
                updateCamera(
                    camera.id,
                    state: .disconnected,
                    detail: "Waiting for this camera to advertise before reconnecting."
                )
            } else {
                updateCamera(camera.id, state: .failed("Bluetooth peripheral is no longer available."), detail: nil)
            }
            return
        }

        setCameraDiagnostic(connectionRequestDiagnostic(for: camera, lookupState: lookup.state), for: camera)

        let client: any BLECameraDeviceClient
        switch camera.brand {
        case .gopro:
            client = GoProBLEClient(
                cameraID: camera.id,
                cameraName: camera.name,
                peripheral: peripheral,
                shouldSendAppPowerOnStart: explicitGoProWakeCameraIDs.contains(camera.id),
                onStatus: { [weak self] id, state, detail in
                    Task { @MainActor in self?.updateCamera(id, state: state, detail: detail) }
                },
                onCameraStatus: { [weak self] id, update in
                    Task { @MainActor in self?.updateCameraStatus(id, update: update) }
                },
                onLog: { [weak self] message in
                    Task { @MainActor in self?.appendLog(message) }
                }
            )
        case .dji:
            client = DJIExperimentalBLEClient(
                cameraID: camera.id,
                cameraName: camera.name,
                cameraModel: camera.model,
                peripheral: peripheral,
                onStatus: { [weak self] id, state, detail in
                    Task { @MainActor in self?.updateCamera(id, state: state, detail: detail) }
                },
                onCameraStatus: { [weak self] id, update in
                    Task { @MainActor in self?.updateCameraStatus(id, update: update) }
                },
                onProtocolActivity: { [weak self] id in
                    Task { @MainActor in self?.noteProtocolActivity(for: id) }
                },
                onNanoPairingStatus: { [weak self] id, status in
                    Task { @MainActor in self?.handleNanoPairingStatus(status, for: id) }
                },
                hasConfirmedAwakeNanoAdvertisement: camera.behavior.kind == .djiOsmoNano
                    && freshAwakeAdvertisement(for: camera.id, now: Date()) == true,
                onLog: { [weak self] message in
                    Task { @MainActor in self?.appendLog(message) }
                }
            )
        case .insta360:
            return
        case .unknown:
            updateCamera(camera.id, state: .unsupported("Unknown camera brand."), detail: nil)
            return
        }

        do {
            clients[camera.id] = client
            lastConnectionAttemptByID[camera.id] = Date()
            scheduleConnectionTimeout(for: camera.id)
            let shouldForceGoProWakeConnection = camera.brand == .gopro
                && (pendingStartCameraIDs.contains(camera.id)
                    || explicitGoProWakeCameraIDs.contains(camera.id))
                && freshAwakeAdvertisement(for: camera.id, now: Date()) != true
            try scanner.connect(
                to: camera.id,
                client: client,
                enableAutoReconnect: shouldEnableSystemAutoReconnect(for: camera),
                forceReconnect: shouldForceGoProWakeConnection
            )
        } catch {
            cancelConnectionTimeout(for: camera.id)
            updateCamera(camera.id, state: .failed(error.localizedDescription), detail: nil)
        }
    }

    func disconnect(_ camera: DiscoveredCamera) {
        if isDemoMode {
            updateCamera(camera.id, state: .disconnected, detail: "Demo camera disconnected.")
            return
        }

        if camera.brand == .insta360 {
            insta360Remote?.release(cameraID: camera.id)
            updateCamera(camera.id, state: .disconnected, detail: "Insta360 remote control released.")
        } else {
            scanner.disconnect(from: camera.id)
        }
    }

    func wake(_ camera: DiscoveredCamera) {
        guard camera.canWakeFromSleep else {
            appendLog("\(camera.name): wake is not available without a fresh sleeping-camera advertisement.")
            refreshWakeScan(for: camera)
            return
        }

        if camera.brand == .gopro {
            explicitGoProWakeCameraIDs.insert(camera.id)
            explicitGoProWakeConnectionFailuresByCameraID[camera.id] = 0
            lastConnectionAttemptByID.removeValue(forKey: camera.id)
            appendLog("\(camera.name): starting explicit Open GoPro BLE wake connection.")
            setCameraDiagnostic("Waking over Bluetooth.", for: camera)
            connect(camera)
            return
        }

        explicitNanoWakeCameraIDs.insert(camera.id)
        nanoWakeProtocolReadyCameraIDs.remove(camera.id)
        appendLog("\(camera.name): starting explicit Nano GATT wake sequence.")
        setCameraDiagnostic(
            "Waking over Bluetooth. If asked, choose Accept for \(DJINanoProtocol.pairingDisplayName). The camera may show \(DJINanoProtocol.pairingToken), short for Multicam.",
            for: camera
        )
        connect(camera)
    }

    func dismissNanoPairingConfirmation() {
        nanoPairingConfirmation = nil
    }

    func remove(_ camera: DiscoveredCamera) {
        cancelStartRecording(for: camera.id)
        cancelPhotoCaptureReset(for: camera.id)
        cancelVideoModeSwitch(for: camera.id)
        cancelConnectionTimeout(for: camera.id)
        cancelAvailabilityTimeout(for: camera.id)
        cancelConnectedStalenessTimeout(for: camera.id)
        cancelManualPairRetry(for: camera.id)
        modeSwitchAttemptsByCameraID.removeValue(forKey: camera.id)
        pendingStartConnectionFailuresByCameraID.removeValue(forKey: camera.id)
        passiveDJIProbeCameraIDs.remove(camera.id)
        manualPairConnectionFailuresByCameraID.removeValue(forKey: camera.id)
        availabilitySuppressedUntilByCameraID.removeValue(forKey: camera.id)
        lastWakeScanRefreshByCameraID.removeValue(forKey: camera.id)
        lastProtocolActivityByCameraID.removeValue(forKey: camera.id)
        lastDJIAdvertisementByCameraID.removeValue(forKey: camera.id)
        awakeAdvertisementByCameraID.removeValue(forKey: camera.id)
        awakeAdvertisementSeenAtByCameraID.removeValue(forKey: camera.id)
        nanoAwakeCandidateSinceByCameraID.removeValue(forKey: camera.id)
        nanoPassiveReconnectBlockedCameraIDs.remove(camera.id)
        explicitGoProWakeCameraIDs.remove(camera.id)
        explicitGoProWakeConnectionFailuresByCameraID.removeValue(forKey: camera.id)
        explicitNanoWakeCameraIDs.remove(camera.id)
        nanoWakeProtocolReadyCameraIDs.remove(camera.id)
        if nanoPairingConfirmation?.cameraID == camera.id {
            nanoPairingConfirmation = nil
        }
        clearStateGuards(for: camera.id)
        pendingStartCameraIDs.remove(camera.id)
        pendingStopCameraIDs.remove(camera.id)
        pendingManualPairCameraIDs.remove(camera.id)
        sleepingDJICameraIDs.remove(camera.id)
        if camera.connectionState == .connected || camera.connectionState == .connecting {
            disconnect(camera)
        }

        clients[camera.id] = nil

        if let index = cameras.firstIndex(where: { $0.id == camera.id }) {
            cameras.remove(at: index)
        }

        if djiPhoneGPSCameraIDs.remove(camera.id) != nil {
            persistDJIPhoneGPSCameraIDs()
        }

        sortCamerasForEditing()
        persistPairedCameras()
        reconcilePhoneGPSStreaming()
        appendLog("Removed \(camera.name).")
    }

    func startMulticamRecording() {
        guard canStartMulticamRecording else {
            appendLog(multicamReadinessMessage)
            return
        }

        if isPhotoMulticamSession {
            capturePhotos(with: selectedControllableCameras)
        } else {
            startRecordingSequence(for: selectedControllableCameras)
        }
    }

    func stopMulticamRecording() {
        let targets = selectedConnectedCameras.filter { camera in
            camera.supportsBatchRecord
                && camera.recordingState == .recording
                && !camera.isInPhotoMode
        }

        guard !targets.isEmpty else {
            appendLog("No selected recording cameras for Stop Multicam.")
            return
        }

        for camera in targets {
            cancelStartRecording(for: camera.id)
            pendingStartCameraIDs.remove(camera.id)
            cancelWakeRetry(for: camera.id)
            protectStopTransition(for: camera)
        }

        send(.stopRecording, to: targets)
    }

    @discardableResult
    func addHighlight() -> Bool {
        let targets = recordingHighlightCameras
        guard !targets.isEmpty else {
            appendLog("No supported cameras are recording for Highlight.")
            return false
        }

        send(.addHighlight, to: targets)
        return true
    }

    @discardableResult
    func startAllRecording() -> Bool {
        let targets = readyConnectedCameras.filter {
            $0.supportsBatchRecord && $0.isReadyForMulticamStart
        }
        guard !targets.isEmpty else {
            appendLog("No connected cameras are ready to start recording.")
            return false
        }
        startRecordingSequence(for: targets)
        return true
    }

    @discardableResult
    func stopAllRecording() -> Bool {
        let targets = cameras.filter {
            $0.supportsBatchRecord
                && ($0.recordingState == .recording || $0.recordingState == .starting)
        }
        guard !targets.isEmpty else {
            appendLog("No cameras are recording.")
            return false
        }

        recordingLiveActivityController.markStopping(cameras: cameras)
        targets.forEach(stopRecording)
        return true
    }

    @discardableResult
    func startWatchRecording() -> Bool {
        startAllRecording()
    }

    @discardableResult
    func stopWatchRecording() -> Bool {
        stopAllRecording()
    }

    func stopLiveActivityRecording() {
        _ = stopAllRecording()
    }

    func startRecording(_ camera: DiscoveredCamera) {
        if camera.isInPhotoMode {
            capturePhotos(with: [camera])
        } else {
            startRecordingSequence(for: [camera])
        }
    }

    func stopRecording(_ camera: DiscoveredCamera) {
        cancelStartRecording(for: camera.id)
        pendingStartCameraIDs.remove(camera.id)
        pendingStartConnectionFailuresByCameraID.removeValue(forKey: camera.id)
        cancelWakeRetry(for: camera.id)
        guard camera.connectionState == .connected else {
            queueStopRecording(for: camera, reason: "Camera is not connected.")
            scheduleReconnect(for: camera.id, attemptsRemaining: pendingStopReconnectAttempts(for: camera))
            return
        }

        protectStopTransition(for: camera)
        send(.stopRecording, to: [camera])
    }

    func switchToVideo(_ camera: DiscoveredCamera) {
        guard camera.canSwitchToVideoMode else {
            appendLog("\(camera.name): Video mode switch is not available right now.")
            return
        }

        appendLog("\(camera.name): switching to Video mode.")
        setCameraDiagnostic("Switching this camera to Video mode.", for: camera)
        cancelStartRecording(for: camera.id)
        cancelVideoModeSwitch(for: camera.id)
        modeSwitchAttemptsByCameraID[camera.id] = 0
        sendVideoModeCommandAttempt(for: camera, attemptsAlreadySent: 0)
        modeSwitchAttemptsByCameraID[camera.id] = 1
        scheduleVideoModeSwitchConfirmation(for: camera.id)
    }

    func switchMode(_ mode: CaptureMode, for camera: DiscoveredCamera) {
        guard camera.canSwitchCaptureMode,
              camera.availableCaptureModes.contains(mode) else {
            appendLog("\(camera.name): \(mode.rawValue) mode is not available right now.")
            return
        }

        let modeName = mode.displayName(for: camera.model)
        appendLog("\(camera.name): switching to \(modeName) mode.")
        setCameraDiagnostic("Switching this camera to \(modeName) mode.", for: camera)
        cancelStartRecording(for: camera.id)
        cancelVideoModeSwitch(for: camera.id)
        send(.setMode(mode), to: [camera])
    }

    func probeStatus(_ camera: DiscoveredCamera) {
        guard camera.connectionState == .connected else {
            appendLog("\(camera.name): status probe skipped because the camera is not connected.")
            return
        }

        send(.keepAlive, to: [camera])
    }
}

private extension CameraStore {
    func handle(_ event: BLEScannerEvent) {
        switch event {
        case let .bluetoothStateChanged(state):
            guard !isDemoMode else {
                bluetoothStateLabel = "Simulator Demo"
                return
            }
            bluetoothStateLabel = state.displayName
            appendLog("Bluetooth state: \(state.displayName)")
            if state == .poweredOn {
                connectRememberedCamerasIfResolvable()
            }
        case let .discovered(candidate):
            merge(candidate)
        case let .connectionChanged(id, state):
            updateCamera(id, state: state, detail: nil)
        case let .log(message):
            appendLog(message)
        }
    }

    func handleInsta360(_ event: Insta360RemoteEvent) {
        switch event {
        case let .bluetoothStateChanged(state):
            if state != .poweredOn {
                appendLog("Insta360 remote Bluetooth state: \(state.displayName).")
            }
        case let .cameraSessionActive(id):
            guard let camera = cameras.first(where: { $0.id == id }),
                  camera.connectionState != .connected else {
                break
            }
            setCameraDiagnostic(
                "Camera link is active. Waiting for the Insta360 CE82 command channel before enabling controls.",
                for: camera
            )
            updateCamera(id, state: .connecting, detail: nil)
        case let .cameraConnected(id):
            cancelConnectionTimeout(for: id)
            updateCamera(
                id,
                state: .connected,
                detail: "Insta360 GPS Remote connected. Recording status is confirmed from camera timer packets."
            )
        case let .cameraDisconnected(id):
            updateCamera(id, state: .disconnected, detail: "Insta360 camera left the GPS Remote service.")
        case let .cameraStatus(id, update):
            updateCameraStatus(id, update: update)
        case let .log(message):
            appendLog(message)
        }
    }

    func merge(_ candidate: DiscoveredCameraCandidate) {
        var shouldAutoConnect = false
        var shouldSort = false
        let now = Date()
        let candidateBehavior = CameraBehaviorProfile.resolve(
            brand: candidate.brand,
            model: candidate.model,
            name: candidate.name
        )
        let supportsExperimentalDJISleepWake = candidateBehavior.supportsExperimentalDJISleepWake
        if candidate.brand == .dji {
            let canTreatAdvertisementAsWake = candidate.model == .djiOsmoNano
                ? candidate.isAwake == true
                : !supportsExperimentalDJISleepWake
            if canTreatAdvertisementAsWake,
               sleepingDJICameraIDs.contains(candidate.id),
               let previousAdvertisement = lastDJIAdvertisementByCameraID[candidate.id],
               now.timeIntervalSince(previousAdvertisement) >= djiWakeAdvertisementGapInterval {
                sleepingDJICameraIDs.remove(candidate.id)
                availabilitySuppressedUntilByCameraID.removeValue(forKey: candidate.id)
                autoConnectSuppressedUntilByCameraID.removeValue(forKey: candidate.id)
                appendLog("\(candidate.name): fresh DJI advertisement after sleep; reconnecting is available.")
            }
            lastDJIAdvertisementByCameraID[candidate.id] = now
        }
        let isConnectable = candidate.isConnectable ?? true
        let isConnectionFreshnessAdvertisement = candidate.brand == .dji
            ? candidate.isConnectable == true
            : isConnectable
        var isAvailabilitySuppressed = (
            sleepingDJICameraIDs.contains(candidate.id)
                && !supportsExperimentalDJISleepWake
        )
            || (availabilitySuppressedUntilByCameraID[candidate.id] ?? .distantPast) > now
        let previousAwakeAdvertisement = awakeAdvertisementByCameraID[candidate.id]
        let isNanoAdvertisement = candidate.model == .djiOsmoNano
            || cameras.first(where: { $0.id == candidate.id })?.behavior.kind == .djiOsmoNano
        let hadExplicitNanoWakeIntent = explicitNanoWakeCameraIDs.contains(candidate.id)
        if isNanoAdvertisement {
            if candidate.isAwake == true {
                if nanoAwakeCandidateSinceByCameraID[candidate.id] == nil {
                    nanoAwakeCandidateSinceByCameraID[candidate.id] = now
                }
            } else if candidate.isAwake == false {
                nanoAwakeCandidateSinceByCameraID.removeValue(forKey: candidate.id)
            }
        }
        let hasConfirmedNanoAwakeAdvertisement = isNanoAdvertisement
            && DJINanoProtocol.hasStableAwakeAdvertisement(
                isAwake: candidate.isAwake,
                observedSince: nanoAwakeCandidateSinceByCameraID[candidate.id],
                now: now,
                minimumDuration: nanoAwakeConfirmationInterval
            )
        if let isAwake = candidate.isAwake {
            awakeAdvertisementByCameraID[candidate.id] = isAwake
            awakeAdvertisementSeenAtByCameraID[candidate.id] = now
            if isAwake, isNanoAdvertisement {
                sleepingDJICameraIDs.remove(candidate.id)
                availabilitySuppressedUntilByCameraID.removeValue(forKey: candidate.id)
                if explicitNanoWakeCameraIDs.remove(candidate.id) != nil {
                    autoConnectSuppressedUntilByCameraID.removeValue(forKey: candidate.id)
                    appendLog("\(candidate.name): awake advertisement confirmed the explicit wake.")
                }
                isAvailabilitySuppressed = false
                if DJINanoProtocol.confirmsFreshPowerOn(
                    previousAdvertisementAwake: previousAwakeAdvertisement,
                    currentAdvertisementAwake: isAwake
                ) {
                    nanoPassiveReconnectBlockedCameraIDs.remove(candidate.id)
                    lastConnectionAttemptByID.removeValue(forKey: candidate.id)
                }
            } else if !isAwake, isNanoAdvertisement {
                sleepingDJICameraIDs.insert(candidate.id)
                nanoPassiveReconnectBlockedCameraIDs.insert(candidate.id)
                if supportsExperimentalDJISleepWake {
                    availabilitySuppressedUntilByCameraID.removeValue(forKey: candidate.id)
                    autoConnectSuppressedUntilByCameraID[candidate.id] = now.addingTimeInterval(
                        nanoPowerTransitionSettleInterval
                    )
                    isAvailabilitySuppressed = false
                } else {
                    availabilitySuppressedUntilByCameraID[candidate.id] = now.addingTimeInterval(
                        availabilityFreshnessInterval
                    )
                    autoConnectSuppressedUntilByCameraID[candidate.id] = now.addingTimeInterval(
                        availabilityFreshnessInterval
                    )
                    isAvailabilitySuppressed = true
                }

                if let existingCamera = cameras.first(where: { $0.id == candidate.id }),
                   existingCamera.connectionState == .connected
                    || existingCamera.connectionState == .connecting
                    || existingCamera.connectionState == .reconnecting {
                    handleSleepingDJIProtocolStatus(for: candidate.id)
                }
            } else if isAwake, isAvailabilitySuppressed {
                availabilitySuppressedUntilByCameraID.removeValue(forKey: candidate.id)
                isAvailabilitySuppressed = false
            }
            if isAwake, previousAwakeAdvertisement == false, !isNanoAdvertisement {
                autoConnectSuppressedUntilByCameraID.removeValue(forKey: candidate.id)
            }
        }

        if let index = cameras.firstIndex(where: { $0.id == candidate.id }) {
            let previousSortRank = cameras[index].defaultSortRank
            let resolvedModel = candidate.model == .unknown ? cameras[index].model : candidate.model
            let capabilities = normalizedCapabilities(
                candidate.capabilities,
                brand: candidate.brand,
                model: resolvedModel,
                name: candidate.name
            )
            let unsupportedReason = unsupportedReason(
                brand: candidate.brand,
                model: resolvedModel,
                name: candidate.name
            )

            if cameras[index].name != candidate.name {
                cameras[index].name = candidate.name
                shouldSort = true
            }
            if cameras[index].brand != candidate.brand {
                cameras[index].brand = candidate.brand
                shouldSort = true
            }
            if candidate.model != .unknown, cameras[index].model != resolvedModel {
                cameras[index].model = resolvedModel
                shouldSort = true
            }
            if cameras[index].capabilities != capabilities {
                cameras[index].capabilities = capabilities
            }
            if candidate.brand == .gopro {
                cameras[index].isPairingAdvertisement = candidate.isPairing
            }
            cameras[index].advertisementAwake = candidate.isAwake

            if let unsupportedReason {
                if cameras[index].connectionState == .connected || cameras[index].connectionState == .connecting {
                    scanner.disconnect(from: candidate.id)
                    clients[candidate.id] = nil
                }
                cameras[index].connectionState = .unsupported(unsupportedReason)
                cameras[index].recordingState = .unavailable
                cameras[index].currentMode = nil
                cameras[index].isSelected = false
                cancelAvailabilityTimeout(for: candidate.id)
                cancelConnectionTimeout(for: candidate.id)
                cancelWakeRetry(for: candidate.id)
                pendingStartCameraIDs.remove(candidate.id)
                pendingStopCameraIDs.remove(candidate.id)
                clearStateGuards(for: candidate.id)
                shouldAutoConnect = false
            } else {
                let shouldRefreshSignal = now.timeIntervalSince(cameras[index].lastSeen) >= signalRefreshInterval
                    || abs(cameras[index].rssi - candidate.rssi) >= 12
                if cameras[index].connectionState != .connected {
                    cameras[index].lastSeen = now
                    if isConnectionFreshnessAdvertisement {
                        cameras[index].lastConnectableSeen = now
                    }
                    if shouldRefreshSignal {
                        cameras[index].rssi = candidate.rssi
                    }
                }

                switch cameras[index].connectionState {
                case .disconnected, .failed, .reconnecting:
                    if isConnectable, !isAvailabilitySuppressed || isPairingModeActive {
                        let isExplicitWakeTarget = cameras[index].supportsExperimentalDJISleepWake
                            && sleepingDJICameraIDs.contains(candidate.id)
                        let isAwakeGoPro = candidate.brand == .gopro && candidate.isAwake == true
                        let isWakeableGoPro = candidate.brand == .gopro
                            && cameras[index].isPaired
                            && candidate.isAwake == false
                        let isAvailableInsta360 = candidate.brand == .insta360
                        cameras[index].connectionState = isAwakeGoPro || isWakeableGoPro || isExplicitWakeTarget || isAvailableInsta360
                            ? .discovered
                            : .disconnected
                        clearSelectionIfNotConnected(at: index)
                        if cameras[index].isPaired,
                           cameras[index].supportsBatchRecord,
                           !pendingStartCameraIDs.contains(candidate.id),
                           cameras[index].recordingState != .recording {
                            cameras[index].recordingState = candidate.brand == .gopro ? .stopped : .unknown
                        }
                    }
                case .discovered, .connecting, .connected, .unsupported:
                    let shouldKeepDJIWakeTargetAvailable = cameras[index].supportsExperimentalDJISleepWake
                        && sleepingDJICameraIDs.contains(candidate.id)
                    if candidate.brand == .dji,
                       cameras[index].connectionState == .discovered,
                       !shouldKeepDJIWakeTargetAvailable {
                        cameras[index].connectionState = .disconnected
                        clearSelectionIfNotConnected(at: index)
                        cameras[index].recordingState = cameras[index].supportsBatchRecord ? .unknown : .unavailable
                        cameras[index].currentMode = nil
                    }
                    if !isConnectable, cameras[index].connectionState == .discovered {
                        cameras[index].connectionState = .disconnected
                        clearSelectionIfNotConnected(at: index)
                        cameras[index].recordingState = cameras[index].supportsBatchRecord ? .unknown : .unavailable
                        cameras[index].currentMode = nil
                    }
                    if candidate.brand == .gopro,
                       candidate.isAwake != true,
                       !(cameras[index].isPaired && candidate.isAwake == false),
                       cameras[index].connectionState == .discovered {
                        cameras[index].connectionState = .disconnected
                        clearSelectionIfNotConnected(at: index)
                        cameras[index].recordingState = cameras[index].supportsBatchRecord ? .unknown : .unavailable
                        cameras[index].currentMode = nil
                    }
                    break
                }

                shouldAutoConnect = cameras[index].isPaired
                    && cameras[index].connectionState != .connected
                    && cameras[index].connectionState != .connecting
                    && !isAvailabilitySuppressed
                    && isConnectionFreshnessAdvertisement
                    && canAttemptAutoConnect(
                        to: cameras[index],
                        now: now,
                        currentAdvertisementAwake: isNanoAdvertisement
                            ? (hasConfirmedNanoAwakeAdvertisement ? true : nil)
                            : candidate.isAwake,
                        hadExplicitNanoWakeIntent: hadExplicitNanoWakeIntent
                    )

            }
            if cameras[index].defaultSortRank != previousSortRank {
                shouldSort = true
            }
        } else {
            let capabilities = normalizedCapabilities(
                candidate.capabilities,
                brand: candidate.brand,
                model: candidate.model,
                name: candidate.name
            )
            let unsupportedReason = unsupportedReason(
                brand: candidate.brand,
                model: candidate.model,
                name: candidate.name
            )
            cameras.append(
                DiscoveredCamera(
                    id: candidate.id,
                    name: candidate.name,
                    brand: candidate.brand,
                    model: candidate.model,
                    rssi: candidate.rssi,
                    capabilities: capabilities,
                    connectionState: unsupportedReason.map(CameraConnectionState.unsupported)
                        ?? (((candidate.brand == .gopro && candidate.isAwake == true)
                                || candidate.brand == .insta360) && isConnectable
                            ? .discovered
                            : .disconnected),
                    recordingState: unsupportedReason == nil && capabilities.contains(.record) ? .unknown : .unavailable,
                    isPaired: false,
                    isSelected: false,
                    lastSeen: Date(),
                    lastConnectableSeen: isConnectionFreshnessAdvertisement ? Date() : nil,
                    isPairingAdvertisement: candidate.brand == .gopro ? candidate.isPairing : nil,
                    advertisementAwake: candidate.isAwake
                )
            )
            shouldSort = true
        }

        if shouldSort {
            sortCamerasForEditing()
        }

        if hasConfirmedNanoAwakeAdvertisement,
           nanoWakeProtocolReadyCameraIDs.remove(candidate.id) != nil {
            updateCamera(candidate.id, state: .connected, detail: "DJI Nano protocol ready.")
        }

        let shouldTrackDiscoverableAvailability = candidate.brand == .gopro
            || candidate.brand == .insta360
            || (isNanoAdvertisement && candidate.isAwake == false)
        if cameras.first(where: { $0.id == candidate.id })?.isSupportedByApp == true,
           shouldTrackDiscoverableAvailability,
           isConnectable, !isAvailabilitySuppressed || isPairingModeActive {
            scheduleAvailabilityTimeout(for: candidate.id)
        }

        if shouldAutoConnect, let camera = cameras.first(where: { $0.id == candidate.id }) {
            appendLog("Auto-connecting \(camera.name).")
            beginPassiveDJIProbeIfNeeded(for: camera)
            connect(camera)
        }
    }

    func canAttemptAutoConnect(
        to camera: DiscoveredCamera,
        now: Date,
        currentAdvertisementAwake: Bool? = nil,
        hadExplicitNanoWakeIntent: Bool = false
    ) -> Bool {
        if camera.brand == .insta360 {
            let hasQueuedCommand = pendingStartCameraIDs.contains(camera.id)
                || pendingStopCameraIDs.contains(camera.id)
            guard camera.isPaired || hasQueuedCommand else { return false }
            if let lastAttempt = lastConnectionAttemptByID[camera.id],
               now.timeIntervalSince(lastAttempt) < autoConnectRetryCooldownInterval {
                return false
            }
            return camera.isAvailableToConnect
        }

        if camera.brand == .dji {
            let hasQueuedCommand = pendingStartCameraIDs.contains(camera.id)
                || pendingStopCameraIDs.contains(camera.id)
                || explicitNanoWakeCameraIDs.contains(camera.id)
                || hadExplicitNanoWakeIntent
            guard camera.isPaired || hasQueuedCommand else {
                return false
            }
            if camera.behavior.kind == .djiOsmoNano {
                guard DJINanoProtocol.permitsAutomaticConnection(
                    currentAdvertisementAwake: currentAdvertisementAwake,
                    passiveReconnectBlocked: nanoPassiveReconnectBlockedCameraIDs.contains(camera.id),
                    hasUserInitiatedWakeIntent: hasQueuedCommand
                ) else {
                    return false
                }
            }

            if !hasQueuedCommand {
                if let lastAttempt = lastConnectionAttemptByID[camera.id],
                   now.timeIntervalSince(lastAttempt) < autoConnectRetryCooldownInterval {
                    return false
                }

                if let suppressedUntil = autoConnectSuppressedUntilByCameraID[camera.id] {
                    if suppressedUntil > now {
                        return false
                    }
                    autoConnectSuppressedUntilByCameraID.removeValue(forKey: camera.id)
                }
            }
            return djiConnectionDeferralMessage(for: camera, now: now) == nil
        }

        if pendingStartCameraIDs.contains(camera.id)
            || pendingStopCameraIDs.contains(camera.id)
            || explicitGoProWakeCameraIDs.contains(camera.id) {
            return true
        }

        guard camera.isPaired else { return false }

        if let lastAttempt = lastConnectionAttemptByID[camera.id],
           now.timeIntervalSince(lastAttempt) < autoConnectRetryCooldownInterval {
            return false
        }

        if let suppressedUntil = autoConnectSuppressedUntilByCameraID[camera.id] {
            if suppressedUntil > now {
                return false
            }
            autoConnectSuppressedUntilByCameraID.removeValue(forKey: camera.id)
        }

        if camera.brand == .gopro {
            // Auto-connect only after the camera advertises that its processor is awake.
            return camera.isAvailableToConnect
                && freshAwakeAdvertisement(for: camera.id, now: now) == true
        }

        return false
    }

    func djiConnectionDeferralMessage(for camera: DiscoveredCamera, now: Date = Date()) -> String? {
        guard !isDemoMode,
              camera.brand == .dji else {
            return nil
        }

        if hasFreshDJIConnectableAdvertisement(for: camera, now: now) {
            return nil
        }

        if (pendingStartCameraIDs.contains(camera.id)
                || explicitNanoWakeCameraIDs.contains(camera.id)),
           camera.supportsExperimentalDJISleepWake,
           sleepingDJICameraIDs.contains(camera.id),
           scanner.peripheral(for: camera.id) != nil {
            return nil
        }

        if camera.supportsExperimentalDJISleepWake {
            return "Waiting for a fresh \(camera.model.rawValue) Bluetooth advertisement before connecting."
        }

        return "Waiting for a fresh DJI Bluetooth advertisement before connecting."
    }

    func djiConnectionFreshnessInterval(for camera: DiscoveredCamera) -> TimeInterval {
        camera.isKnownAction6 ? djiWakeAdvertisementGapInterval : availabilityFreshnessInterval
    }

    func hasFreshDJIConnectableAdvertisement(for camera: DiscoveredCamera, now: Date) -> Bool {
        guard let lastConnectableSeen = camera.lastConnectableSeen else {
            return false
        }

        return now.timeIntervalSince(lastConnectableSeen) <= djiConnectionFreshnessInterval(for: camera)
    }

    func freshAwakeAdvertisement(for id: UUID, now: Date) -> Bool? {
        guard let isAwake = awakeAdvertisementByCameraID[id],
              let seenAt = awakeAdvertisementSeenAtByCameraID[id],
              now.timeIntervalSince(seenAt) <= availabilityFreshnessInterval else {
            return nil
        }

        return isAwake
    }

    func hasConfirmedAwakeNanoAdvertisement(for id: UUID, now: Date) -> Bool {
        DJINanoProtocol.hasStableAwakeAdvertisement(
            isAwake: awakeAdvertisementByCameraID[id],
            observedSince: nanoAwakeCandidateSinceByCameraID[id],
            now: now,
            minimumDuration: nanoAwakeConfirmationInterval
        )
    }

    func protectStartTransition(for camera: DiscoveredCamera) {
        ignoreStoppedUntilByCameraID[camera.id] = Date().addingTimeInterval(startStateGuardInterval(for: camera))
        ignoreRecordingUntilByCameraID.removeValue(forKey: camera.id)
    }

    func startStateGuardInterval(for camera: DiscoveredCamera) -> TimeInterval {
        camera.behavior.kind == .djiOsmoPocket3 ? pocket3StartStateGuardInterval : defaultStartStateGuardInterval
    }

    func protectStopTransition(for camera: DiscoveredCamera) {
        ignoreRecordingUntilByCameraID[camera.id] = Date().addingTimeInterval(stopStateGuardInterval(for: camera))
        ignoreStoppedUntilByCameraID.removeValue(forKey: camera.id)
    }

    func stopStateGuardInterval(for camera: DiscoveredCamera) -> TimeInterval {
        camera.behavior.kind == .djiOsmoNano
            ? nanoStopStateGuardInterval
            : defaultStopStateGuardInterval
    }

    func clearStateGuards(for id: UUID) {
        ignoreStoppedUntilByCameraID.removeValue(forKey: id)
        ignoreRecordingUntilByCameraID.removeValue(forKey: id)
    }

    func connectRememberedCamerasIfResolvable() {
        guard scanner.bluetoothState == .poweredOn else { return }
        let now = Date()
        for camera in pairedCameras
            where camera.connectionState != .connected
                && camera.connectionState != .connecting
                && canAttemptAutoConnect(to: camera, now: now) {
            guard scanner.peripheral(for: camera.id) != nil else { continue }
            appendLog("\(camera.name): trying remembered Bluetooth connection.")
            beginPassiveDJIProbeIfNeeded(for: camera)
            connect(camera)
        }
    }

    func beginPassiveDJIProbeIfNeeded(for camera: DiscoveredCamera) {
        guard camera.brand == .dji,
              !pendingStartCameraIDs.contains(camera.id),
              !pendingStopCameraIDs.contains(camera.id) else {
            return
        }

        passiveDJIProbeCameraIDs.insert(camera.id)
        setCameraDiagnostic(
            "Silently checking the DJI advertisement; the card stays Not Connected until the camera confirms it is awake.",
            for: camera
        )
    }

    func shouldEnableSystemAutoReconnect(for camera: DiscoveredCamera) -> Bool {
        pendingStartCameraIDs.contains(camera.id)
            || pendingStopCameraIDs.contains(camera.id)
    }

    func queueStopRecording(for camera: DiscoveredCamera, reason: String) {
        let inserted = pendingStopCameraIDs.insert(camera.id).inserted
        if inserted {
            appendLog("\(camera.name): stop queued until the camera reconnects. \(reason)")
        }
        ensureScanning()
    }

    func queueStartRecording(for camera: DiscoveredCamera, reason: String) {
        let inserted = pendingStartCameraIDs.insert(camera.id).inserted
        if inserted {
            appendLog("\(camera.name): start queued until the camera reconnects. \(reason)")
        }
        protectStartTransition(for: camera)
        updateCameraStatus(camera.id, update: pendingStartStatusUpdate(for: camera))
        refreshWakeScan(for: camera)
        ensureScanning()
    }

    func clearPendingStartIfDJIUnavailable(for camera: DiscoveredCamera) {
        guard camera.brand == .dji,
              pendingStartCameraIDs.remove(camera.id) != nil else {
            return
        }

        cancelStartRecording(for: camera.id)
        cancelWakeRetry(for: camera.id)
        clearStateGuards(for: camera.id)
        pendingStartConnectionFailuresByCameraID.removeValue(forKey: camera.id)
        reconnectTasksByCameraID[camera.id]?.cancel()
        reconnectTasksByCameraID[camera.id] = nil

        if let index = cameras.firstIndex(where: { $0.id == camera.id }) {
            cameras[index].recordingState = cameras[index].supportsBatchRecord ? .unknown : .unavailable
            cameras[index].currentMode = nil
        }
    }

    func ensureScanning() {
        if !isScanning {
            startScanning()
        }
    }

    func refreshWakeScan(for camera: DiscoveredCamera) {
        guard !isDemoMode else { return }
        guard scanner.bluetoothState == .poweredOn else {
            isScanning = true
            scanner.start()
            return
        }

        let now = Date()
        let lastRefresh = lastWakeScanRefreshByCameraID[camera.id] ?? .distantPast
        guard now.timeIntervalSince(lastRefresh) >= 3 else { return }

        lastWakeScanRefreshByCameraID[camera.id] = now
        isScanning = true
        scanner.start()
    }

    func scheduleConnectionTimeout(for id: UUID) {
        connectionTimeoutTasksByCameraID[id]?.cancel()
        let delay = connectionTimeoutDelay(for: id)
        connectionTimeoutTasksByCameraID[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard let latest = self.cameras.first(where: { $0.id == id }) else { return }
                let isPassiveDJIProbe = self.passiveDJIProbeCameraIDs.contains(id)
                guard latest.connectionState == .connecting || isPassiveDJIProbe else {
                    self.connectionTimeoutTasksByCameraID[id] = nil
                    return
                }

                if latest.brand == .insta360 {
                    let disposition = self.insta360Remote?.resolveConnectionTimeout(cameraID: id)
                        ?? .waitingForCamera
                    switch disposition {
                    case .commandReady:
                        self.connectionTimeoutTasksByCameraID[id] = nil
                        return
                    case .activeAwaitingCommands:
                        self.setCameraDiagnostic(
                            "Camera link is active. Waiting for the Insta360 CE82 command channel before enabling controls.",
                            for: latest
                        )
                        self.connectionTimeoutTasksByCameraID[id] = nil
                        self.scheduleConnectionTimeout(for: id)
                        return
                    case .reset, .waitingForCamera:
                        break
                    }
                } else {
                    self.scanner.disconnect(from: id)
                }
                self.clients[id] = nil

                if isPassiveDJIProbe {
                    self.passiveDJIProbeCameraIDs.remove(id)
                    self.autoConnectSuppressedUntilByCameraID[id] = Date().addingTimeInterval(
                        self.autoConnectRetryCooldownInterval
                    )
                    if let index = self.cameras.firstIndex(where: { $0.id == id }) {
                        self.cameras[index].connectionState = .disconnected
                        self.cameras[index].recordingState = self.cameras[index].supportsBatchRecord
                            ? .unknown
                            : .unavailable
                    }
                    self.setCameraDiagnostic(
                        "DJI did not confirm an awake protocol session; remaining Not Connected.",
                        for: latest
                    )
                    self.connectionTimeoutTasksByCameraID[id] = nil
                    return
                }

                if self.pendingStartCameraIDs.contains(id) {
                    self.lastConnectionAttemptByID[id] = nil
                    let failures = (self.pendingStartConnectionFailuresByCameraID[id] ?? 0) + 1
                    self.pendingStartConnectionFailuresByCameraID[id] = failures
                    if latest.brand == .gopro {
                        self.setCameraDiagnostic(
                            "GoPro wake attempt \(failures)/\(self.maxPendingStartConnectionFailures(for: latest)) timed out; retrying BLE wake connection.",
                            for: latest
                        )
                    } else if latest.supportsExperimentalDJISleepWake {
                        self.setCameraDiagnostic(
                            "\(latest.model.rawValue) wake attempt \(failures)/\(self.maxPendingStartConnectionFailures(for: latest)) timed out; retrying BLE wake connection.",
                            for: latest
                        )
                    } else {
                        self.appendLog("\(latest.name): connection timed out; retrying.")
                    }
                    if failures >= self.maxPendingStartConnectionFailures(for: latest) {
                        self.abortPendingStart(for: id, reason: self.pendingStartFailureReason(for: latest))
                        self.connectionTimeoutTasksByCameraID[id] = nil
                        return
                    }
                } else {
                    if latest.behavior.kind == .djiOsmoNano {
                        self.sleepingDJICameraIDs.insert(id)
                        self.lastDJIAdvertisementByCameraID[id] = Date()
                        self.availabilitySuppressedUntilByCameraID[id] = Date().addingTimeInterval(
                            self.availabilityFreshnessInterval
                        )
                        self.autoConnectSuppressedUntilByCameraID[id] = Date().addingTimeInterval(
                            self.autoConnectRetryCooldownInterval
                        )
                    }

                    if self.shouldRetryManualPairConnection(for: latest) {
                        let failures = (self.manualPairConnectionFailuresByCameraID[id] ?? 0) + 1
                        self.manualPairConnectionFailuresByCameraID[id] = failures
                        if failures < self.maxManualPairConnectionFailures {
                            self.lastConnectionAttemptByID[id] = nil
                            self.setCameraDiagnostic(
                                "GoPro pairing attempt \(failures)/\(self.maxManualPairConnectionFailures) timed out while iOS was connecting; retrying.",
                                for: latest
                            )
                            self.updateCamera(id, state: .reconnecting, detail: nil)
                            self.scheduleManualPairRetry(for: id)
                            self.connectionTimeoutTasksByCameraID[id] = nil
                            return
                        }

                        self.pendingManualPairCameraIDs.remove(id)
                        self.manualPairConnectionFailuresByCameraID.removeValue(forKey: id)
                        self.appendLog("\(latest.name): GoPro pairing timed out after \(self.maxManualPairConnectionFailures) attempts.")
                        self.setCameraDiagnostic(
                            "GoPro BLE pairing timed out. Make sure the camera is not connected to another phone, iPad, or Quik, then tap Pair again.",
                            for: latest
                        )
                        self.updateCamera(
                            id,
                            state: .failed("GoPro BLE pairing timed out."),
                            detail: nil
                        )
                        self.connectionTimeoutTasksByCameraID[id] = nil
                        return
                    }

                    if latest.brand == .insta360 {
                        self.appendLog(
                            "\(latest.name): still waiting for the camera's GPS Remote handshake; late connections remain enabled."
                        )
                        self.setCameraDiagnostic(
                            "Still waiting for the camera to finish connecting to Insta360 GPS Remote. Multicam remains available for a late handshake.",
                            for: latest
                        )
                        self.updateCamera(id, state: .discovered, detail: nil)
                    } else {
                        self.appendLog("\(latest.name): connection timed out before the camera became ready.")
                        self.setCameraDiagnostic(
                            "BLE connection timed out before the camera command service was ready. Will retry on a fresh advertisement.",
                            for: latest
                        )
                        self.updateCamera(
                            id,
                            state: .disconnected,
                            detail: nil
                        )
                    }
                    self.connectionTimeoutTasksByCameraID[id] = nil
                    return
                }

                self.updateCamera(id, state: .reconnecting, detail: nil)
                self.scheduleReconnect(
                    for: id,
                    attemptsRemaining: self.pendingStartReconnectAttempts(for: latest)
                )
                self.connectionTimeoutTasksByCameraID[id] = nil
            }
        }
    }

    func shouldRetryManualPairConnection(for camera: DiscoveredCamera) -> Bool {
        pendingManualPairCameraIDs.contains(camera.id)
            && isPairingModeActive
            && camera.brand == .gopro
            && !camera.isPaired
    }

    func scheduleManualPairRetry(for id: UUID) {
        manualPairRetryTasksByCameraID[id]?.cancel()
        manualPairRetryTasksByCameraID[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.isPairingModeActive,
                      let latest = self.cameras.first(where: { $0.id == id }),
                      self.shouldRetryManualPairConnection(for: latest) else {
                    self.manualPairRetryTasksByCameraID[id] = nil
                    return
                }

                if latest.connectionState != .connected,
                   latest.connectionState != .connecting {
                    self.appendLog("\(latest.name): retrying GoPro pairing connection.")
                    self.connect(latest)
                }
                self.manualPairRetryTasksByCameraID[id] = nil
            }
        }
    }

    func cancelManualPairRetry(for id: UUID) {
        manualPairRetryTasksByCameraID[id]?.cancel()
        manualPairRetryTasksByCameraID[id] = nil
    }

    func cancelManualPairRetries() {
        for task in manualPairRetryTasksByCameraID.values {
            task.cancel()
        }
        manualPairRetryTasksByCameraID.removeAll()
        pendingManualPairCameraIDs.removeAll()
        manualPairConnectionFailuresByCameraID.removeAll()
    }

    func connectionTimeoutDelay(for id: UUID) -> Duration {
        guard let camera = cameras.first(where: { $0.id == id }) else {
            return defaultConnectionTimeoutDelay
        }

        if camera.isKnownAction6,
           !pendingStartCameraIDs.contains(id),
           !pendingStopCameraIDs.contains(id),
           !pendingManualPairCameraIDs.contains(id) {
            return action6PassiveConnectionTimeoutDelay
        }

        if camera.behavior.kind == .djiOsmoNano,
           !pendingStartCameraIDs.contains(id),
           !pendingStopCameraIDs.contains(id),
           !pendingManualPairCameraIDs.contains(id) {
            return nanoPassiveConnectionTimeoutDelay
        }

        if camera.brand == .dji {
            return djiProtocolConnectionTimeoutDelay
        }

        if camera.brand == .gopro {
            if explicitGoProWakeCameraIDs.contains(id) {
                return .seconds(10)
            }
            return goProProtocolConnectionTimeoutDelay
        }

        if camera.brand == .insta360 {
            return .seconds(30)
        }

        return defaultConnectionTimeoutDelay
    }

    func missingPeripheralDiagnostic(for camera: DiscoveredCamera) -> String {
        guard pendingStartCameraIDs.contains(camera.id) else {
            return "Waiting for this camera to advertise."
        }

        let attempt = (pendingStartConnectionFailuresByCameraID[camera.id] ?? 0) + 1
        if camera.brand == .gopro {
            return "GoPro wake attempt \(attempt)/\(maxPendingStartConnectionFailures(for: camera)): iOS has no BLE peripheral yet. Waiting for a sleeping GoPro advertisement."
        }

        if camera.supportsExperimentalDJISleepWake {
            return "\(camera.model.rawValue) wake attempt \(attempt)/\(maxPendingStartConnectionFailures(for: camera)): iOS has no BLE peripheral yet. Waiting for an advertisement or restored peripheral."
        }

        return "Waiting for this camera to advertise."
    }

    func connectionRequestDiagnostic(
        for camera: DiscoveredCamera,
        lookupState: BLEPeripheralLookupState
    ) -> String {
        guard pendingStartCameraIDs.contains(camera.id) else {
            return "BLE peripheral \(lookupState.label); requesting connection."
        }

        let attempt = (pendingStartConnectionFailuresByCameraID[camera.id] ?? 0) + 1
        if camera.brand == .gopro {
            return "GoPro wake attempt \(attempt)/\(maxPendingStartConnectionFailures(for: camera)): BLE peripheral \(lookupState.label); requesting connection."
        }

        if camera.supportsExperimentalDJISleepWake {
            return "\(camera.model.rawValue) wake attempt \(attempt)/\(maxPendingStartConnectionFailures(for: camera)): BLE peripheral \(lookupState.label); requesting connection."
        }

        return "BLE peripheral \(lookupState.label); requesting connection."
    }

    func cancelConnectionTimeout(for id: UUID) {
        connectionTimeoutTasksByCameraID[id]?.cancel()
        connectionTimeoutTasksByCameraID[id] = nil
    }

    func scheduleAvailabilityTimeout(for id: UUID) {
        availabilityTimeoutTasksByCameraID[id]?.cancel()
        let delay = availabilityTimeoutDelay
        availabilityTimeoutTasksByCameraID[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard let latest = self.cameras.first(where: { $0.id == id }) else { return }
                guard latest.connectionState == .discovered else {
                    self.availabilityTimeoutTasksByCameraID[id] = nil
                    return
                }

                let lastAvailableSeen = latest.lastConnectableSeen ?? .distantPast
                guard Date().timeIntervalSince(lastAvailableSeen) >= self.availabilityFreshnessInterval else {
                    self.scheduleAvailabilityTimeout(for: id)
                    return
                }

                self.updateCamera(id, state: .disconnected, detail: nil)
                self.availabilityTimeoutTasksByCameraID[id] = nil
            }
        }
    }

    func cancelAvailabilityTimeout(for id: UUID) {
        availabilityTimeoutTasksByCameraID[id]?.cancel()
        availabilityTimeoutTasksByCameraID[id] = nil
    }

    func noteProtocolActivity(for id: UUID, at timestamp: Date = Date()) {
        guard !isDemoMode,
              let index = cameras.firstIndex(where: { $0.id == id }),
              protocolStalenessInterval(for: cameras[index]) != nil else {
            return
        }

        cameras[index].lastSeen = timestamp
        lastProtocolActivityByCameraID[id] = timestamp
        scheduleConnectedStalenessTimeoutIfNeeded(for: id)
    }

    func protocolStalenessInterval(for camera: DiscoveredCamera) -> TimeInterval? {
        if camera.behavior.kind == .djiOsmoNano {
            return nanoProtocolStalenessInterval
        }

        if camera.isKnownAction6 {
            return action6ProtocolStalenessInterval
        }

        if camera.brand == .gopro {
            return goProProtocolStalenessInterval
        }

        return nil
    }

    func scheduleConnectedStalenessTimeoutIfNeeded(for id: UUID) {
        guard let camera = cameras.first(where: { $0.id == id }),
              let delay = protocolStalenessInterval(for: camera),
              camera.connectionState == .connected else {
            cancelConnectedStalenessTimeout(for: id)
            return
        }

        connectedStalenessTasksByCameraID[id]?.cancel()
        connectedStalenessTasksByCameraID[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      let latest = self.cameras.first(where: { $0.id == id }) else { return }
                guard let currentDelay = self.protocolStalenessInterval(for: latest),
                      latest.connectionState == .connected else {
                    self.cancelConnectedStalenessTimeout(for: id)
                    return
                }

                if self.shouldDeferProtocolStalenessDisconnect(for: latest) {
                    self.scheduleConnectedStalenessTimeoutIfNeeded(for: id)
                    return
                }

                let lastActivity = self.lastProtocolActivityByCameraID[id] ?? .distantPast
                guard Date().timeIntervalSince(lastActivity) >= currentDelay else {
                    self.scheduleConnectedStalenessTimeoutIfNeeded(for: id)
                    return
                }

                self.appendLog("\(latest.name): no recent protocol status; showing as Not Connected.")
                if let index = self.cameras.firstIndex(where: { $0.id == id }) {
                    self.cameras[index].lastConnectableSeen = nil
                }
                self.scanner.disconnect(from: id)
                self.updateCamera(id, state: .disconnected, detail: "No recent camera status.")
                self.connectedStalenessTasksByCameraID[id] = nil
            }
        }
    }

    func shouldDeferProtocolStalenessDisconnect(for camera: DiscoveredCamera) -> Bool {
        guard camera.brand == .dji else { return false }

        return (camera.supportsExperimentalDJISleepWake && sleepingDJICameraIDs.contains(camera.id))
            || pendingStartCameraIDs.contains(camera.id)
            || pendingStopCameraIDs.contains(camera.id)
            || modeSwitchAttemptsByCameraID[camera.id] != nil
            || camera.recordingState == .starting
    }

    func cancelConnectedStalenessTimeout(for id: UUID) {
        connectedStalenessTasksByCameraID[id]?.cancel()
        connectedStalenessTasksByCameraID[id] = nil
    }

    func handleSleepingDJIProtocolStatus(for id: UUID) {
        guard let camera = cameras.first(where: { $0.id == id }),
              camera.brand == .dji else {
            return
        }

        if camera.supportsExperimentalDJISleepWake {
            let wasAlreadySleeping = sleepingDJICameraIDs.contains(id)
            sleepingDJICameraIDs.insert(id)
            availabilitySuppressedUntilByCameraID.removeValue(forKey: id)
            autoConnectSuppressedUntilByCameraID[id] = Date().addingTimeInterval(
                nanoPowerTransitionSettleInterval
            )
            cancelConnectedStalenessTimeout(for: id)
            pendingStopCameraIDs.remove(id)

            let hasExplicitWakeIntent = explicitNanoWakeCameraIDs.contains(id)
                || pendingStartCameraIDs.contains(id)
            if hasExplicitWakeIntent {
                let message = "Wake requested; waiting for the Osmo Nano to accept the Bluetooth session."
                setCameraDiagnostic(message, for: camera)
                if !wasAlreadySleeping {
                    appendLog("\(camera.name): \(message)")
                }
                return
            }

            if !pendingStartCameraIDs.contains(id), camera.recordingState != .starting {
                cancelStartRecording(for: id)
                cancelVideoModeSwitch(for: id)
                cancelWakeRetry(for: id)
                modeSwitchAttemptsByCameraID.removeValue(forKey: id)
                clearStateGuards(for: id)
            }

            if let index = cameras.firstIndex(where: { $0.id == id }) {
                cameras[index].lastSeen = Date()
                if cameras[index].recordingState != .starting {
                    cameras[index].recordingState = .unknown
                }
                cameras[index].currentMode = nil
            }

            scanner.disconnect(from: id)
            clients[id] = nil

            updateCamera(
                id,
                state: .discovered,
                detail: "DJI Nano is sleeping and advertising for an explicit GATT wake."
            )

            if !wasAlreadySleeping {
                let message = "Camera is asleep and advertising; Wake is available."
                appendLog("\(camera.name): \(message)")
                setCameraDiagnostic(message, for: camera)
            }
            return
        }

        appendLog("\(camera.name): DJI status reports sleep/off; closing the control session.")
        clearPendingStartIfDJIUnavailable(for: camera)
        pendingStopCameraIDs.remove(id)
        cancelStartRecording(for: id)
        cancelVideoModeSwitch(for: id)
        cancelWakeRetry(for: id)
        reconnectTasksByCameraID[id]?.cancel()
        reconnectTasksByCameraID[id] = nil
        modeSwitchAttemptsByCameraID.removeValue(forKey: id)
        clearStateGuards(for: id)
        cancelConnectedStalenessTimeout(for: id)
        lastProtocolActivityByCameraID.removeValue(forKey: id)
        sleepingDJICameraIDs.insert(id)
        lastDJIAdvertisementByCameraID[id] = Date()
        availabilitySuppressedUntilByCameraID[id] = Date().addingTimeInterval(availabilityFreshnessInterval)
        autoConnectSuppressedUntilByCameraID[id] = Date().addingTimeInterval(availabilityFreshnessInterval)
        if let index = cameras.firstIndex(where: { $0.id == id }) {
            cameras[index].lastConnectableSeen = nil
            cameras[index].recordingState = cameras[index].supportsBatchRecord ? .unknown : .unavailable
            cameras[index].currentMode = nil
        }

        scanner.disconnect(from: id)
        updateCamera(id, state: .disconnected, detail: "Camera is asleep or off.")
    }

    func handleNanoPairingStatus(_ status: DJINanoProtocol.PairingStatus, for id: UUID) {
        guard let camera = cameras.first(where: { $0.id == id }) else { return }

        switch status {
        case .approvalRequired:
            nanoPairingConfirmation = NanoPairingConfirmation(
                cameraID: id,
                cameraName: camera.name
            )
            let message = "On your Osmo Nano, choose Accept for \(DJINanoProtocol.pairingDisplayName). The camera may show \(DJINanoProtocol.pairingToken), short for Multicam."
            appendLog("\(camera.name): Nano pairing approval requested.")
            setCameraDiagnostic(message, for: camera)
        case .alreadyPaired:
            if nanoPairingConfirmation?.cameraID == id {
                nanoPairingConfirmation = nil
            }
            appendLog("\(camera.name): Action Multicam is already approved on this Nano.")
        case .approved:
            if nanoPairingConfirmation?.cameraID == id {
                nanoPairingConfirmation = nil
            }
            let message = "Action Multicam was approved on the Osmo Nano."
            appendLog("\(camera.name): \(message)")
            setCameraDiagnostic(message, for: camera)
        case let .unexpected(value):
            let message = "The Osmo Nano returned an unexpected pairing status (0x\(String(format: "%02X", value)))."
            appendLog("\(camera.name): \(message)")
            setCameraDiagnostic(message, for: camera)
        }
    }

    func scheduleReconnect(for id: UUID, attemptsRemaining: Int) {
        reconnectTasksByCameraID[id]?.cancel()
        reconnectTasksByCameraID[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard let latest = self.cameras.first(where: { $0.id == id }) else { return }
                guard latest.isPaired else {
                    self.reconnectTasksByCameraID[id] = nil
                    return
                }

                if latest.connectionState == .connected {
                    self.replayPendingStopIfReady(for: id, detail: nil)
                    self.reconnectTasksByCameraID[id] = nil
                    return
                }

                if latest.connectionState != .connecting {
                    self.appendLog("\(latest.name): trying to reconnect.")
                    self.connect(latest)
                }

                if attemptsRemaining > 1 {
                    self.scheduleReconnect(for: id, attemptsRemaining: attemptsRemaining - 1)
                } else {
                    if let latest = self.cameras.first(where: { $0.id == id }),
                       self.pendingStartCameraIDs.contains(id),
                       latest.connectionState != .connected,
                       latest.connectionState != .connecting {
                        self.abortPendingStart(for: id, reason: self.pendingStartFailureReason(for: latest))
                        return
                    }
                    if self.explicitNanoWakeCameraIDs.remove(id) != nil {
                        self.nanoWakeProtocolReadyCameraIDs.remove(id)
                        self.appendLog("\(latest.name): Nano wake reconnect window ended.")
                        self.updateCamera(
                            id,
                            state: self.sleepingDJICameraIDs.contains(id) ? .discovered : .disconnected,
                            detail: "The Nano did not finish waking. Tap Wake to try again."
                        )
                        return
                    }
                    self.reconnectTasksByCameraID[id] = nil
                }
            }
        }
    }

    func pendingStartReconnectAttempts(for camera: DiscoveredCamera) -> Int {
        if camera.brand == .gopro {
            return 45
        }

        if camera.supportsExperimentalDJISleepWake {
            return 18
        }

        return 8
    }

    func pendingStopReconnectAttempts(for camera: DiscoveredCamera) -> Int {
        if camera.behavior.kind == .djiOsmoNano {
            return 24
        }

        if camera.brand == .dji {
            return 12
        }

        return 6
    }

    func maxPendingStartConnectionFailures(for camera: DiscoveredCamera) -> Int {
        if camera.brand == .gopro {
            return 3
        }

        return camera.supportsExperimentalDJISleepWake ? 4 : 8
    }

    func availabilitySuppressionInterval(for camera: DiscoveredCamera) -> TimeInterval {
        if camera.brand == .gopro {
            return 90
        }

        return camera.supportsExperimentalDJISleepWake ? 120 : 30
    }

    func pendingStartFailureReason(for camera: DiscoveredCamera) -> String {
        if camera.brand == .gopro {
            return "GoPro did not advertise or accept a BLE wake connection. Turn it on before recording."
        }

        if camera.supportsExperimentalDJISleepWake {
            return "\(camera.model.rawValue) did not accept a BLE wake connection. Turn it on before recording."
        }
        return "Could not connect to this camera."
    }

    func abortPendingStart(for id: UUID, reason: String) {
        guard let latest = cameras.first(where: { $0.id == id }) else { return }
        appendLog("\(latest.name): \(reason)")
        setCameraDiagnostic(reason, for: latest)
        cancelStartRecording(for: id)
        cancelWakeRetry(for: id)
        clearStateGuards(for: id)
        pendingStartCameraIDs.remove(id)
        pendingStartConnectionFailuresByCameraID.removeValue(forKey: id)
        availabilitySuppressedUntilByCameraID[id] = Date().addingTimeInterval(availabilitySuppressionInterval(for: latest))
        reconnectTasksByCameraID[id]?.cancel()
        reconnectTasksByCameraID[id] = nil
        if let index = cameras.firstIndex(where: { $0.id == id }) {
            cameras[index].connectionState = .failed(reason)
            clearSelectionIfNotConnected(at: index)
            cameras[index].recordingState = cameras[index].supportsBatchRecord ? .unknown : .unavailable
            cameras[index].currentMode = nil
        }
    }

    func replayPendingStopIfReady(for id: UUID, detail: String?) {
        guard pendingStopCameraIDs.contains(id) else { return }
        guard isDJIControlReady(detail: detail) else { return }
        guard let latest = cameras.first(where: { $0.id == id }), latest.connectionState == .connected else { return }

        appendLog("\(latest.name): sending queued stop after reconnect.")
        send(.stopRecording, to: [latest])
    }

    func replayPendingStartIfReady(for id: UUID, detail: String?) {
        guard pendingStartCameraIDs.contains(id) else { return }
        guard let latest = cameras.first(where: { $0.id == id }), latest.connectionState == .connected else { return }

        let isReady: Bool
        switch latest.brand {
        case .gopro:
            isReady = detail?.contains("Open GoPro protocol ready") == true
        case .dji:
            isReady = isDJIControlReady(detail: detail)
        case .insta360:
            isReady = detail?.contains("Insta360 GPS Remote connected") == true
        case .unknown:
            isReady = false
        }
        guard isReady else { return }

        appendLog("\(latest.name): sending queued start after reconnect.")
        scheduleRecordAfterModeSwitch(for: [latest.id])
    }

    func isDJIControlReady(detail: String?) -> Bool {
        guard let detail else { return false }
        return detail.contains("DJI record characteristics ready")
            || detail.contains("DJI R SDK protocol ready")
    }

    func startRecordingSequence(for cameras: [DiscoveredCamera]) {
        guard !cameras.isEmpty else {
            appendLog("No selected cameras for Start Recording.")
            return
        }

        var connectedCamerasForStart: [DiscoveredCamera] = []
        for camera in cameras {
            startRecordingTasksByCameraID[camera.id]?.cancel()
            videoModeTasksByCameraID[camera.id]?.cancel()
            modeSwitchAttemptsByCameraID[camera.id] = 0
            pendingStartConnectionFailuresByCameraID[camera.id] = 0
            availabilitySuppressedUntilByCameraID.removeValue(forKey: camera.id)
            autoConnectSuppressedUntilByCameraID.removeValue(forKey: camera.id)
            lastWakeScanRefreshByCameraID.removeValue(forKey: camera.id)
            protectStartTransition(for: camera)

            if camera.connectionState == .connected {
                pendingStartCameraIDs.insert(camera.id)
                updateCameraStatus(camera.id, update: pendingStartStatusUpdate(for: camera))
                let isSleepingActionWakeAttempt = camera.supportsExperimentalDJISleepWake
                    && sleepingDJICameraIDs.contains(camera.id)
                if !isSleepingActionWakeAttempt,
                   camera.currentMode != .video,
                   camera.canSwitchToVideoMode {
                    sendVideoModeCommandAttempt(for: camera, attemptsAlreadySent: 0)
                    modeSwitchAttemptsByCameraID[camera.id] = 1
                }
                connectedCamerasForStart.append(camera)
            } else {
                pendingStartCameraIDs.insert(camera.id)
                updateCameraStatus(camera.id, update: pendingStartStatusUpdate(for: camera))
                if camera.brand == .gopro {
                    setCameraDiagnostic("Record from off requested; preparing GoPro BLE wake connection.", for: camera)
                } else if camera.supportsExperimentalDJISleepWake {
                    setCameraDiagnostic(
                        "Record from sleep requested; preparing \(camera.model.rawValue) BLE wake connection.",
                        for: camera
                    )
                }
                queueStartRecording(for: camera, reason: "Camera is not connected.")
                lastConnectionAttemptByID[camera.id] = nil
                connect(camera)
            }
        }

        guard !connectedCamerasForStart.isEmpty else { return }
        scheduleRecordAfterModeSwitch(for: connectedCamerasForStart.map(\.id))
    }

    func capturePhotos(with cameras: [DiscoveredCamera]) {
        guard !cameras.isEmpty else {
            appendLog("No selected cameras for Capture Photo.")
            return
        }

        let readyCameras = cameras.filter(\.isReadyForPhotoCapture)
        guard readyCameras.count == cameras.count else {
            appendLog("Photo capture skipped because one or more cameras are not ready in Photo mode.")
            return
        }

        for camera in readyCameras {
            cancelStartRecording(for: camera.id)
            cancelVideoModeSwitch(for: camera.id)
            cancelWakeRetry(for: camera.id)
            cancelPhotoCaptureReset(for: camera.id)
            pendingStartCameraIDs.remove(camera.id)
            pendingStartConnectionFailuresByCameraID.removeValue(forKey: camera.id)
            clearStateGuards(for: camera.id)
            updateCameraStatus(camera.id, update: CameraStatusUpdate(recordingState: .starting))
            schedulePhotoCaptureReset(for: camera.id)
        }

        send(.capturePhoto, to: readyCameras)
    }

    func schedulePhotoCaptureReset(for id: UUID) {
        photoCaptureResetTasksByCameraID[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard let latest = self.cameras.first(where: { $0.id == id }),
                      latest.isInPhotoMode,
                      latest.recordingState == .starting || latest.recordingState == .recording else {
                    self.photoCaptureResetTasksByCameraID[id] = nil
                    return
                }

                self.appendLog("\(latest.name): photo capture status timed out; returning the shutter control to ready.")
                self.updateCameraStatus(id, update: CameraStatusUpdate(recordingState: .stopped))
                self.photoCaptureResetTasksByCameraID[id] = nil
            }
        }
    }

    func cancelPhotoCaptureReset(for id: UUID) {
        photoCaptureResetTasksByCameraID[id]?.cancel()
        photoCaptureResetTasksByCameraID[id] = nil
    }

    func scheduleRecordAfterModeSwitch(for ids: [UUID]) {
        for id in ids {
            let delay = modeSwitchDelay
            startRecordingTasksByCameraID[id] = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    guard let latest = self.cameras.first(where: { $0.id == id }) else { return }
                    guard self.startRecordingTasksByCameraID[id] != nil else { return }
                    guard latest.connectionState == .connected,
                          latest.recordingState != .recording,
                          latest.recordingState != .unavailable else {
                        self.startRecordingTasksByCameraID[id] = nil
                        return
                    }

                    let isSleepingActionWakeAttempt = latest.supportsExperimentalDJISleepWake
                        && self.sleepingDJICameraIDs.contains(latest.id)
                    if !isSleepingActionWakeAttempt,
                       latest.currentMode != .video,
                       latest.canSwitchToVideoMode {
                        let attempts = self.modeSwitchAttemptsByCameraID[id] ?? 0
                        if attempts >= 6 {
                            self.appendLog("\(latest.name): recording skipped because the camera did not confirm Video mode.")
                            self.setCameraDiagnostic("Switch this camera to Video mode, then try recording again.", for: latest)
                            self.pendingStartCameraIDs.remove(id)
                            self.modeSwitchAttemptsByCameraID.removeValue(forKey: id)
                            self.updateCameraStatus(id, update: CameraStatusUpdate(recordingState: .stopped))
                            self.startRecordingTasksByCameraID[id] = nil
                            return
                        }

                        self.appendLog("\(latest.name): waiting for Video mode status before recording.")
                        self.sendVideoModeCommandAttempt(for: latest, attemptsAlreadySent: attempts)
                        self.modeSwitchAttemptsByCameraID[id] = attempts + 1
                        self.scheduleRecordAfterModeSwitch(for: [id])
                        return
                    }

                    guard latest.canStartRecordingInCurrentMode else {
                        self.appendLog("\(latest.name): recording skipped because the camera is not in Video mode.")
                        self.setCameraDiagnostic("Switch this camera to Video mode, then try recording again.", for: latest)
                        self.pendingStartCameraIDs.remove(id)
                        self.modeSwitchAttemptsByCameraID.removeValue(forKey: id)
                        self.updateCameraStatus(id, update: CameraStatusUpdate(recordingState: .stopped))
                        self.startRecordingTasksByCameraID[id] = nil
                        return
                    }

                    if latest.brand == .dji {
                        self.send(.startRecording, to: [latest])
                        self.scheduleWakeRetryIfNeeded(for: [latest])
                        self.modeSwitchAttemptsByCameraID.removeValue(forKey: id)
                        self.startRecordingTasksByCameraID[id] = nil
                        return
                    }

                    self.send(.startRecording, to: [latest])
                    self.scheduleWakeRetryIfNeeded(for: [latest])
                    self.modeSwitchAttemptsByCameraID.removeValue(forKey: id)
                    self.startRecordingTasksByCameraID[id] = nil
                }
            }
        }
    }

    func scheduleWakeRetryIfNeeded(for cameras: [DiscoveredCamera]) {
        for camera in cameras where camera.brand == .dji && camera.recordingState != .recording {
            let isSleepingActionWakeAttempt = camera.supportsExperimentalDJISleepWake
                && sleepingDJICameraIDs.contains(camera.id)
            guard camera.behavior.assumesRecordingAfterUnconfirmedDJIStart
                || isSleepingActionWakeAttempt else {
                continue
            }
            cancelWakeRetry(for: camera.id)
            scheduleWakeRetry(for: camera.id, attemptsRemaining: 2)
        }
    }

    func scheduleWakeRetry(for id: UUID, attemptsRemaining: Int) {
        wakeRetryTasksByCameraID[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard let latest = self.cameras.first(where: { $0.id == id }) else { return }
                guard latest.recordingState != .recording else {
                    self.wakeRetryTasksByCameraID[id] = nil
                    return
                }

                if attemptsRemaining > 0 {
                    if latest.connectionState == .connected {
                        self.appendLog("\(latest.name): retrying wake-and-record.")
                        self.send(.startRecording, to: [latest])
                    } else if (latest.behavior.assumesRecordingAfterUnconfirmedDJIStart
                        || (latest.supportsExperimentalDJISleepWake
                            && self.sleepingDJICameraIDs.contains(latest.id))),
                        latest.recordingState == .starting {
                        self.appendLog("\(latest.name): waiting for BLE reconnect after wake-and-record.")
                    } else {
                        self.wakeRetryTasksByCameraID[id] = nil
                        return
                    }
                    self.scheduleWakeRetry(for: latest.id, attemptsRemaining: attemptsRemaining - 1)
                } else {
                    if latest.recordingState == .starting {
                        let shouldAssumeRecording = latest.behavior.assumesRecordingAfterUnconfirmedDJIStart
                        self.appendLog("\(latest.name): no DJI recording confirmation received.")
                        self.setCameraDiagnostic(
                            shouldAssumeRecording
                                ? "No recording confirmation received. Showing Stop so you can recover if the camera is recording."
                                : "No recording confirmation received. Leaving this camera stopped until trusted status says otherwise.",
                            for: latest
                        )
                        self.pendingStartCameraIDs.remove(latest.id)
                        self.clearStateGuards(for: latest.id)
                        self.updateCameraStatus(
                            latest.id,
                            update: CameraStatusUpdate(
                                recordingState: shouldAssumeRecording ? .recording : .stopped
                            )
                        )
                    }
                    self.wakeRetryTasksByCameraID[latest.id] = nil
                }
            }
        }
    }

    func cancelWakeRetry(for id: UUID) {
        wakeRetryTasksByCameraID[id]?.cancel()
        wakeRetryTasksByCameraID[id] = nil
    }

    func cancelStartRecording(for id: UUID) {
        startRecordingTasksByCameraID[id]?.cancel()
        startRecordingTasksByCameraID[id] = nil
        modeSwitchAttemptsByCameraID.removeValue(forKey: id)
    }

    func cancelVideoModeSwitch(for id: UUID) {
        videoModeTasksByCameraID[id]?.cancel()
        videoModeTasksByCameraID[id] = nil
    }

    func scheduleVideoModeSwitchConfirmation(for id: UUID) {
        videoModeTasksByCameraID[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard let latest = self.cameras.first(where: { $0.id == id }) else { return }
                guard self.videoModeTasksByCameraID[id] != nil else { return }

                guard latest.connectionState == .connected,
                      latest.recordingState != .recording,
                      latest.recordingState != .starting else {
                    self.videoModeTasksByCameraID[id] = nil
                    return
                }

                if latest.currentMode == .video {
                    self.appendLog("\(latest.name): Video mode confirmed.")
                    self.setCameraDiagnostic("Video mode confirmed.", for: latest)
                    self.modeSwitchAttemptsByCameraID.removeValue(forKey: id)
                    self.videoModeTasksByCameraID[id] = nil
                    return
                }

                let attempts = self.modeSwitchAttemptsByCameraID[id] ?? 0
                if attempts >= 6 {
                    self.appendLog("\(latest.name): Video mode switch did not confirm.")
                    self.setCameraDiagnostic("Video mode did not confirm. Try switching on the camera, then retry.", for: latest)
                    self.modeSwitchAttemptsByCameraID.removeValue(forKey: id)
                    self.videoModeTasksByCameraID[id] = nil
                    return
                }

                self.sendVideoModeCommandAttempt(for: latest, attemptsAlreadySent: attempts)
                self.modeSwitchAttemptsByCameraID[id] = attempts + 1
                self.scheduleVideoModeSwitchConfirmation(for: id)
            }
        }
    }

    func sendVideoModeCommandAttempt(for camera: DiscoveredCamera, attemptsAlreadySent: Int) {
        appendLog("\(camera.name): sending Video mode command.")
        send(.setMode(.video), to: [camera])
    }

    func pendingStartStatusUpdate(for camera: DiscoveredCamera) -> CameraStatusUpdate {
        CameraStatusUpdate(
            recordingState: .starting
        )
    }

    func send(_ command: CameraCommand, to cameras: [DiscoveredCamera]) {
        guard !cameras.isEmpty else {
            appendLog("No selected cameras for \(command.label).")
            return
        }

        if isDemoMode {
            sendDemo(command, to: cameras)
            return
        }

        for camera in cameras {
            if camera.brand == .insta360 {
                let result = insta360RemoteService().send(command, to: camera.id, cameraName: camera.name)
                commandResults.insert(result, at: 0)
                handleCommandResult(result, for: camera)
                continue
            }

            guard let client = clients[camera.id] else {
                commandResults.insert(
                    CameraCommandResult(
                        cameraID: camera.id,
                        cameraName: camera.name,
                        command: command,
                        status: .skipped,
                        message: "Connect this camera before sending commands.",
                        timestamp: Date()
                    ),
                    at: 0
                )
                if command == .startRecording {
                    queueStartRecording(for: camera, reason: "No active BLE client.")
                    scheduleReconnect(
                        for: camera.id,
                        attemptsRemaining: pendingStartReconnectAttempts(for: camera)
                    )
                } else if command == .capturePhoto {
                    cancelPhotoCaptureReset(for: camera.id)
                    updateCameraStatus(camera.id, update: CameraStatusUpdate(recordingState: .stopped))
                } else if camera.brand == .dji, command == .stopRecording {
                    queueStopRecording(for: camera, reason: "No active BLE client.")
                    scheduleReconnect(for: camera.id, attemptsRemaining: pendingStopReconnectAttempts(for: camera))
                }
                continue
            }

            let result = client.send(command)
            commandResults.insert(result, at: 0)
            handleCommandResult(result, for: camera)
        }
    }

    func handleCommandResult(_ result: CameraCommandResult, for camera: DiscoveredCamera) {
        let wasSent = result.status == .sent || result.status == .queued

        if wasSent, case .setMode = result.command,
           let index = cameras.firstIndex(where: { $0.id == camera.id }) {
            cameras[index].telemetry?.clearCaptureSettings()
        }

        if !wasSent, result.command == .capturePhoto {
            cancelPhotoCaptureReset(for: camera.id)
            updateCameraStatus(camera.id, update: CameraStatusUpdate(recordingState: .stopped))
            return
        }

        if !wasSent, result.command == .startRecording {
            queueStartRecording(for: camera, reason: result.message)
            scheduleReconnect(
                for: camera.id,
                attemptsRemaining: pendingStartReconnectAttempts(for: camera)
            )
            return
        }

        if wasSent, result.command == .startRecording {
            pendingStartCameraIDs.remove(camera.id)
            pendingStartConnectionFailuresByCameraID.removeValue(forKey: camera.id)
        }

        guard camera.brand == .dji else { return }

        guard wasSent else {
            if result.command == .stopRecording {
                queueStopRecording(for: camera, reason: result.message)
                scheduleReconnect(for: camera.id, attemptsRemaining: pendingStopReconnectAttempts(for: camera))
            }
            return
        }

        switch result.command {
        case .startRecording:
            protectStartTransition(for: camera)
            updateCameraStatus(
                camera.id,
                update: CameraStatusUpdate(recordingState: .starting)
            )
        case .capturePhoto:
            clearStateGuards(for: camera.id)
            updateCameraStatus(camera.id, update: CameraStatusUpdate(recordingState: .starting))
        case .stopRecording:
            protectStopTransition(for: camera)
            pendingStopCameraIDs.remove(camera.id)
            pendingStartConnectionFailuresByCameraID.removeValue(forKey: camera.id)
            reconnectTasksByCameraID[camera.id]?.cancel()
            reconnectTasksByCameraID[camera.id] = nil
            updateCameraStatus(camera.id, update: CameraStatusUpdate(recordingState: .stopped))
        case .setMode:
            break
        case .addHighlight, .toggleRecording, .cycleMode, .applySetting, .keepAlive:
            break
        }
    }

    func sendDemo(_ command: CameraCommand, to cameras: [DiscoveredCamera]) {
        for camera in cameras {
            let status: CameraCommandStatus
            let message: String

            let isSupportedDJIDemoCommand: Bool
            switch command {
            case .startRecording, .capturePhoto, .stopRecording:
                isSupportedDJIDemoCommand = true
            case .addHighlight:
                isSupportedDJIDemoCommand = camera.supportsHighlight
            case let .setMode(mode):
                isSupportedDJIDemoCommand = camera.availableCaptureModes.contains(mode)
            case .toggleRecording, .cycleMode, .applySetting, .keepAlive:
                isSupportedDJIDemoCommand = false
            }

            if camera.brand == .dji, !isSupportedDJIDemoCommand {
                status = .unsupported
                message = "This DJI command is not available for \(camera.model.rawValue)."
            } else {
                status = .sent
                message = "Simulated \(command.label.lowercased()) in demo mode."
            }

            commandResults.insert(
                {
                    let result = CameraCommandResult(
                        cameraID: camera.id,
                        cameraName: camera.name,
                        command: command,
                        status: status,
                        message: message,
                        timestamp: Date()
                    )
                    updateDemoState(from: result)
                    return result
                }(),
                at: 0
            )
        }

        appendLog("Demo command: \(command.label) sent to \(cameras.count) cameras.")
    }

    func updateDemoState(from result: CameraCommandResult) {
        guard result.status == .sent || result.status == .queued else { return }
        guard let index = cameras.firstIndex(where: { $0.id == result.cameraID }) else { return }

        switch result.command {
        case .startRecording:
            cameras[index].recordingState = .recording
            cameras[index].currentMode = .video
        case .capturePhoto:
            cameras[index].recordingState = .stopped
        case .stopRecording:
            cameras[index].recordingState = .stopped
        case .toggleRecording:
            cameras[index].recordingState = cameras[index].recordingState == .recording ? .stopped : .recording
        case let .setMode(mode):
            cameras[index].currentMode = mode
            cameras[index].telemetry = Self.demoTelemetry(for: cameras[index], mode: mode)
        case .cycleMode:
            cameras[index].currentMode = nil
        case .addHighlight, .applySetting, .keepAlive:
            break
        }
    }

    func logAction6RecordingStatusDecision(
        camera: DiscoveredCamera,
        incoming: CameraRecordingState?,
        previous: CameraRecordingState,
        decision: String?,
        canClearActiveRecording: Bool
    ) {
        guard camera.behavior.kind == .djiOsmoAction6, incoming != nil else { return }

        let incomingLabel = incoming?.rawValue ?? "nil"
        let decisionLabel = decision ?? "no recording-state change"
        let canClearLabel = canClearActiveRecording ? "yes" : "no"
        appendLog(
            "\(camera.name): Action 6 UI status \(incomingLabel) -> \(decisionLabel), was \(previous.rawValue), now \(camera.recordingState.rawValue), canClear \(canClearLabel)."
        )
    }

    func updateCameraStatus(_ id: UUID, update: CameraStatusUpdate) {
        guard let index = cameras.firstIndex(where: { $0.id == id }) else { return }

        if cameras[index].brand == .dji, update.powerState == .sleeping {
            handleSleepingDJIProtocolStatus(for: id)
            return
        }

        if cameras[index].brand == .dji, update.powerState == .awake {
            sleepingDJICameraIDs.remove(id)
            availabilitySuppressedUntilByCameraID.removeValue(forKey: id)
            autoConnectSuppressedUntilByCameraID.removeValue(forKey: id)
        }

        var shouldSort = false
        var shouldPersist = false
        let previousRecordingState = cameras[index].recordingState
        let previousCaptureMode = cameras[index].currentMode
        var recordingStateToApply = update.recordingState
        var recordingDecision: String?

        noteProtocolActivity(for: id)

        if let recordingState = recordingStateToApply {
            let now = Date()
            if recordingState == .stopped,
               cameras[index].recordingState == .starting || cameras[index].recordingState == .recording,
               (ignoreStoppedUntilByCameraID[id] ?? .distantPast) > now {
                recordingStateToApply = nil
                recordingDecision = "ignored stale stopped during start guard"
            } else if recordingState == .recording,
                      cameras[index].recordingState == .stopped,
                      (ignoreRecordingUntilByCameraID[id] ?? .distantPast) > now {
                recordingStateToApply = nil
                recordingDecision = "ignored stale recording during stop guard"
            }
        }

        if let recordingState = recordingStateToApply {
            if recordingState == .ready, cameras[index].recordingState == .recording {
                cancelWakeRetry(for: id)
                recordingDecision = "kept recording on ready"
            } else if recordingState == .stopped,
                      !update.canClearActiveRecording,
                      cameras[index].recordingState == .recording,
                      !cameras[index].isInPhotoMode {
                cancelWakeRetry(for: id)
                recordingDecision = "kept recording because stopped cannot clear active recording"
            } else if recordingState == .stopped,
                      !update.canClearActiveRecording,
                      cameras[index].recordingState == .starting,
                      !cameras[index].isInPhotoMode {
                logAction6RecordingStatusDecision(
                    camera: cameras[index],
                    incoming: update.recordingState,
                    previous: previousRecordingState,
                    decision: "ignored stopped while starting because it cannot clear active recording",
                    canClearActiveRecording: update.canClearActiveRecording
                )
                return
            } else {
                cameras[index].recordingState = recordingState
                recordingDecision = "applied \(recordingState.rawValue)"
                if recordingState == .recording,
                   (ignoreStoppedUntilByCameraID[id] ?? .distantPast) <= Date() {
                    ignoreStoppedUntilByCameraID.removeValue(forKey: id)
                } else if recordingState == .stopped,
                          (ignoreRecordingUntilByCameraID[id] ?? .distantPast) <= Date() {
                    ignoreRecordingUntilByCameraID.removeValue(forKey: id)
                }
                if recordingState != .unknown {
                    cancelWakeRetry(for: id)
                }
                if recordingState == .stopped, cameras[index].isInPhotoMode {
                    cancelPhotoCaptureReset(for: id)
                }
            }
        }

        logAction6RecordingStatusDecision(
            camera: cameras[index],
            incoming: update.recordingState,
            previous: previousRecordingState,
            decision: recordingDecision,
            canClearActiveRecording: update.canClearActiveRecording
        )

        if let currentMode = update.currentMode {
            cameras[index].currentMode = currentMode
        }

        if let currentMode = update.currentMode, currentMode != previousCaptureMode {
            cameras[index].telemetry?.clearCaptureSettings()
        }

        if let telemetry = update.telemetry {
            var mergedTelemetry = cameras[index].telemetry ?? CameraTelemetry()
            if update.replacesDJIRSDKStatus {
                mergedTelemetry.mergeDJIRSDKStatus(telemetry)
            } else if update.replacesCaptureSettings {
                mergedTelemetry.mergeReplacingCaptureSettings(telemetry)
            } else {
                mergedTelemetry.merge(telemetry)
            }
            cameras[index].telemetry = mergedTelemetry.isEmpty ? nil : mergedTelemetry
        }

        if let model = update.model, model != .unknown, cameras[index].model != model {
            cameras[index].model = model
            shouldSort = true
            shouldPersist = cameras[index].isPaired
        }

        if let hardwareIdentifier = update.hardwareIdentifier,
           cameras[index].hardwareIdentifier != hardwareIdentifier {
            cameras[index].hardwareIdentifier = hardwareIdentifier
            shouldPersist = shouldPersist || cameras[index].isPaired
        }

        if shouldSort {
            sortCamerasForEditing()
        }

        if shouldPersist {
            persistPairedCameras()
        }

    }

    func updateCamera(_ id: UUID, state: CameraConnectionState, detail: String?) {
        guard let index = cameras.firstIndex(where: { $0.id == id }) else { return }
        if cameras[index].brand == .gopro {
            switch state {
            case .connected:
                explicitGoProWakeCameraIDs.remove(id)
                explicitGoProWakeConnectionFailuresByCameraID.removeValue(forKey: id)
            case .disconnected, .failed:
                if explicitGoProWakeCameraIDs.contains(id) {
                    let failures = (explicitGoProWakeConnectionFailuresByCameraID[id] ?? 0) + 1
                    explicitGoProWakeConnectionFailuresByCameraID[id] = failures
                    lastConnectionAttemptByID.removeValue(forKey: id)

                    if failures < maxExplicitGoProWakeConnectionFailures {
                        setCameraDiagnostic(
                            "GoPro wake connection attempt \(failures)/\(maxExplicitGoProWakeConnectionFailures) did not complete; retrying.",
                            for: cameras[index]
                        )
                        ensureScanning()
                        scheduleReconnect(for: id, attemptsRemaining: 2)
                    } else {
                        explicitGoProWakeCameraIDs.remove(id)
                        explicitGoProWakeConnectionFailuresByCameraID.removeValue(forKey: id)
                        setCameraDiagnostic(
                            "The GoPro did not accept a Bluetooth wake connection. Tap Wake to try again.",
                            for: cameras[index]
                        )
                    }
                }
            case .discovered, .connecting, .reconnecting, .unsupported:
                break
            }
        }
        if passiveDJIProbeCameraIDs.contains(id) {
            switch state {
            case .connecting, .reconnecting:
                // Action 4/5/6 and Osmo 360 may advertise while asleep. Keep this transport
                // probe invisible until the protocol reports an awake camera.
                return
            case .connected:
                let isProtocolReady = isDJIControlReady(detail: detail)
                    || detail?.contains("DJI Nano protocol ready") == true
                if cameras[index].behavior.kind == .djiOsmoNano,
                   isProtocolReady,
                   !hasConfirmedAwakeNanoAdvertisement(for: id, now: Date()) {
                    nanoWakeProtocolReadyCameraIDs.insert(id)
                    return
                }
                guard isProtocolReady else { return }
                passiveDJIProbeCameraIDs.remove(id)
            case .disconnected, .failed:
                passiveDJIProbeCameraIDs.remove(id)
                cancelConnectionTimeout(for: id)
                clients[id] = nil
                autoConnectSuppressedUntilByCameraID[id] = Date().addingTimeInterval(
                    autoConnectRetryCooldownInterval
                )
                cameras[index].connectionState = .disconnected
                cameras[index].recordingState = cameras[index].supportsBatchRecord ? .unknown : .unavailable
                cameras[index].currentMode = nil
                reconcilePhoneGPSStreaming()
                return
            case .discovered, .unsupported:
                passiveDJIProbeCameraIDs.remove(id)
            }
        }

        if case .failed = state,
           pendingStartCameraIDs.contains(id) {
            let failures = (pendingStartConnectionFailuresByCameraID[id] ?? 0) + 1
            pendingStartConnectionFailuresByCameraID[id] = failures
            if failures >= maxPendingStartConnectionFailures(for: cameras[index]) {
                abortPendingStart(for: id, reason: pendingStartFailureReason(for: cameras[index]))
                return
            }
        }

        let previousState = cameras[index].connectionState
        let previousRecordingState = cameras[index].recordingState
        var requestedState = state
        if cameras[index].brand == .gopro,
           explicitGoProWakeCameraIDs.contains(id) {
            switch state {
            case .disconnected, .failed:
                requestedState = .reconnecting
            case .discovered, .connecting, .connected, .reconnecting, .unsupported:
                break
            }
        }
        if cameras[index].behavior.kind == .djiOsmoNano {
            switch state {
            case .connected where !hasConfirmedAwakeNanoAdvertisement(for: id, now: Date()):
                nanoWakeProtocolReadyCameraIDs.insert(id)
                requestedState = .connecting
            case .disconnected, .failed:
                if explicitNanoWakeCameraIDs.contains(id) {
                    nanoWakeProtocolReadyCameraIDs.remove(id)
                    requestedState = .reconnecting
                }
            case .discovered, .connecting, .connected, .reconnecting, .unsupported:
                break
            }
        }
        let appliedState = appliedConnectionState(for: cameras[index], requestedState: requestedState)
        cameras[index].connectionState = appliedState

        switch appliedState {
        case .connected:
            nanoPassiveReconnectBlockedCameraIDs.remove(id)
            explicitNanoWakeCameraIDs.remove(id)
            nanoWakeProtocolReadyCameraIDs.remove(id)
            cancelConnectionTimeout(for: id)
            cancelAvailabilityTimeout(for: id)
            cancelManualPairRetry(for: id)
            pendingManualPairCameraIDs.remove(id)
            manualPairConnectionFailuresByCameraID.removeValue(forKey: id)
            cameras[index].isPaired = true
            if cameras[index].supportsBatchRecord, previousState != .connected {
                if pendingStartCameraIDs.contains(id) {
                    cameras[index].recordingState = .starting
                } else if cameras[index].brand == .dji,
                          cameras[index].behavior.preservesActiveDJIRecordingAcrossReconnect,
                          previousRecordingState == .recording || previousRecordingState == .starting {
                    cameras[index].recordingState = previousRecordingState
                } else if cameras[index].brand == .dji {
                    cameras[index].recordingState = .unknown
                    cameras[index].currentMode = nil
                } else if previousRecordingState == .starting {
                    cameras[index].recordingState = .starting
                } else {
                    cameras[index].recordingState = .unknown
                    cameras[index].currentMode = nil
                }
                cameras[index].isSelected = true
            } else if !cameras[index].supportsBatchRecord {
                cameras[index].recordingState = .unavailable
                cameras[index].isSelected = false
            }
            persistPairedCameras()
            replayPendingStartIfReady(for: id, detail: detail)
            replayPendingStopIfReady(for: id, detail: detail)
            noteProtocolActivity(for: id)
        case .reconnecting:
            cancelConnectedStalenessTimeout(for: id)
            cancelAvailabilityTimeout(for: id)
            cancelConnectionTimeout(for: id)
            if !shouldKeepWakeRetryDuringConnectionChurn(
                for: cameras[index],
                previousRecordingState: previousRecordingState
            ) {
                cancelWakeRetry(for: id)
            }
            if pendingStartCameraIDs.contains(id) {
                cameras[index].recordingState = .starting
                lastConnectionAttemptByID[id] = nil
                ensureScanning()
                scheduleReconnect(
                    for: id,
                    attemptsRemaining: pendingStartReconnectAttempts(for: cameras[index])
                )
            } else if cameras[index].behavior.kind == .djiOsmoNano,
                      explicitNanoWakeCameraIDs.contains(id) {
                cameras[index].recordingState = .unknown
                cameras[index].currentMode = nil
                lastConnectionAttemptByID[id] = nil
                ensureScanning()
                scheduleReconnect(for: id, attemptsRemaining: 8)
            } else if cameras[index].brand == .dji {
                switch previousRecordingState {
                case .recording, .starting:
                    cameras[index].recordingState = cameras[index].behavior.preservesActiveDJIRecordingAcrossReconnect
                        ? previousRecordingState
                        : .stopped
                case .ready, .stopped:
                    cameras[index].recordingState = .stopped
                case .unknown, .unavailable:
                    cameras[index].recordingState = cameras[index].supportsBatchRecord ? .stopped : .unavailable
                }
                lastConnectionAttemptByID[id] = nil
                ensureScanning()
                if pendingStopCameraIDs.contains(id)
                    || (cameras[index].behavior.preservesActiveDJIRecordingAcrossReconnect
                        && (previousRecordingState == .recording || previousRecordingState == .starting)) {
                    scheduleReconnect(
                        for: id,
                        attemptsRemaining: pendingStopReconnectAttempts(for: cameras[index])
                    )
                }
            } else {
                cameras[index].recordingState = cameras[index].supportsBatchRecord ? .unknown : .unavailable
                cameras[index].currentMode = nil
            }
        case .disconnected, .failed:
            if cameras[index].behavior.kind == .djiOsmoNano {
                awakeAdvertisementByCameraID.removeValue(forKey: id)
                awakeAdvertisementSeenAtByCameraID.removeValue(forKey: id)
                nanoAwakeCandidateSinceByCameraID.removeValue(forKey: id)

                let hasUserInitiatedWakeIntent = explicitNanoWakeCameraIDs.contains(id)
                    || pendingStartCameraIDs.contains(id)
                    || pendingStopCameraIDs.contains(id)
                if previousState == .connected, !hasUserInitiatedWakeIntent {
                    nanoPassiveReconnectBlockedCameraIDs.insert(id)
                    appendLog(
                        "\(cameras[index].name): blocking passive Nano reconnect until a fresh power-on or explicit Wake."
                    )
                }
            }
            explicitNanoWakeCameraIDs.remove(id)
            nanoWakeProtocolReadyCameraIDs.remove(id)
            if cameras[index].behavior.kind == .djiOsmoNano,
               previousState == .connected {
                autoConnectSuppressedUntilByCameraID[id] = Date().addingTimeInterval(
                    nanoPowerTransitionSettleInterval
                )
            }
            cancelConnectedStalenessTimeout(for: id)
            lastProtocolActivityByCameraID.removeValue(forKey: id)
            cancelConnectionTimeout(for: id)
            cancelAvailabilityTimeout(for: id)
            if !shouldKeepWakeRetryDuringConnectionChurn(
                for: cameras[index],
                previousRecordingState: previousRecordingState
            ) {
                cancelWakeRetry(for: id)
            }
            if cameras[index].brand == .gopro,
               previousState == .connected,
               !pendingStartCameraIDs.contains(id),
               !pendingStopCameraIDs.contains(id) {
                autoConnectSuppressedUntilByCameraID[id] = Date().addingTimeInterval(
                    goProDisconnectReconnectDelay
                )
            }
            if pendingStartCameraIDs.contains(id) {
                cameras[index].recordingState = .starting
                lastConnectionAttemptByID[id] = nil
                ensureScanning()
                scheduleReconnect(
                    for: id,
                    attemptsRemaining: pendingStartReconnectAttempts(for: cameras[index])
                )
            } else if cameras[index].brand == .dji,
                      cameras[index].behavior.preservesActiveDJIRecordingAcrossReconnect,
                      previousRecordingState == .recording || previousRecordingState == .starting {
                cameras[index].recordingState = .recording
                lastConnectionAttemptByID[id] = nil
                ensureScanning()
                scheduleReconnect(
                    for: id,
                    attemptsRemaining: pendingStopReconnectAttempts(for: cameras[index])
                )
            } else {
                cameras[index].recordingState = cameras[index].supportsBatchRecord ? .unknown : .unavailable
                cameras[index].currentMode = nil
            }
        case .unsupported:
            cancelConnectedStalenessTimeout(for: id)
            lastProtocolActivityByCameraID.removeValue(forKey: id)
            cancelConnectionTimeout(for: id)
            cancelAvailabilityTimeout(for: id)
            cancelWakeRetry(for: id)
            cameras[index].recordingState = cameras[index].supportsBatchRecord ? .unknown : .unavailable
            cameras[index].currentMode = nil
        case .connecting:
            cancelConnectedStalenessTimeout(for: id)
            cancelAvailabilityTimeout(for: id)
            if previousState != .connecting, cameras[index].behavior.kind == .djiOsmoNano {
                cameras[index].telemetry = nil
            }
        case .discovered:
            cancelConnectedStalenessTimeout(for: id)
            cancelConnectionTimeout(for: id)
            cancelWakeRetry(for: id)
            if cameras[index].supportsBatchRecord, !pendingStartCameraIDs.contains(id) {
                cameras[index].recordingState = .stopped
            }
            scheduleAvailabilityTimeout(for: id)
        }

        clearSelectionIfNotConnected(at: index)

        if let detail {
            cameraDiagnosticsByID[id] = detail
            appendLog("\(cameras[index].name): \(detail)")
        }

        if previousState != appliedState, cameras[index].isPaired {
            sortCamerasForEditing()
        }

        reconcilePhoneGPSStreaming()
    }

    func appliedConnectionState(
        for camera: DiscoveredCamera,
        requestedState state: CameraConnectionState
    ) -> CameraConnectionState {
        if let unsupportedReason = camera.unsupportedReason {
            return .unsupported(unsupportedReason)
        }

        guard camera.isPaired else { return state }

        switch state {
        case .failed, .disconnected:
            let hasQueuedCommand = pendingStartCameraIDs.contains(camera.id)
                || pendingStopCameraIDs.contains(camera.id)
            let shouldPreserveActiveDJIConnection = camera.brand == .dji
                && camera.behavior.preservesActiveDJIRecordingAcrossReconnect
                && (camera.recordingState == .recording || camera.recordingState == .starting)
            if hasQueuedCommand || shouldPreserveActiveDJIConnection {
                return .reconnecting
            }

            if camera.supportsExperimentalDJISleepWake,
               sleepingDJICameraIDs.contains(camera.id) {
                return .discovered
            }

            if camera.brand == .gopro,
               let lastConnectableSeen = camera.lastConnectableSeen,
               Date().timeIntervalSince(lastConnectableSeen) <= availabilityFreshnessInterval {
                return .discovered
            }
            return .disconnected
        case .discovered:
            if camera.brand == .gopro
                || camera.brand == .insta360
                || (camera.supportsExperimentalDJISleepWake
                    && sleepingDJICameraIDs.contains(camera.id)) {
                return .discovered
            }
            return .disconnected
        case .connecting, .connected, .reconnecting, .unsupported:
            return state
        }
    }

    func shouldKeepWakeRetryDuringConnectionChurn(
        for camera: DiscoveredCamera,
        previousRecordingState: CameraRecordingState
    ) -> Bool {
        camera.brand == .dji
            && (camera.behavior.assumesRecordingAfterUnconfirmedDJIStart
                || (camera.supportsExperimentalDJISleepWake
                    && sleepingDJICameraIDs.contains(camera.id)))
            && previousRecordingState == .starting
    }

    func clearSelectionIfNotConnected(at index: Int) {
        guard cameras.indices.contains(index),
              cameras[index].connectionState != .connected else {
            return
        }

        cameras[index].isSelected = false
    }

    func markCameraAsPaired(_ id: UUID) {
        guard let index = cameras.firstIndex(where: { $0.id == id }) else { return }
        cancelWakeRetry(for: id)
        cameras[index].isPaired = true
        persistPairedCameras()
    }

    func loadPairedCameras() {
        guard let data = UserDefaults.standard.data(forKey: pairedCamerasStorageKey) else { return }

        do {
            cameras = try JSONDecoder().decode([DiscoveredCamera].self, from: data).map { saved in
                var camera = saved
                camera.capabilities = normalizedCapabilities(
                    camera.capabilities,
                    brand: camera.brand,
                    model: camera.model,
                    name: camera.name
                )
                camera.connectionState = camera.unsupportedReason.map(CameraConnectionState.unsupported) ?? .disconnected
                camera.recordingState = camera.supportsBatchRecord ? .unknown : .unavailable
                camera.currentMode = nil
                camera.isPaired = true
                camera.isSelected = false
                camera.lastSeen = .distantPast
                camera.lastConnectableSeen = nil
                camera.advertisementAwake = nil
                camera.telemetry = nil
                return camera
            }
            appendLog("Loaded \(cameras.count) remembered cameras.")
            sortCamerasForEditing()
        } catch {
            appendLog("Could not load remembered cameras: \(error.localizedDescription)")
        }
    }

    func loadDJIPhoneGPSCameraIDs() {
        let storedIDs = UserDefaults.standard.stringArray(forKey: djiPhoneGPSStorageKey) ?? []
        djiPhoneGPSCameraIDs = Set(storedIDs.compactMap(UUID.init(uuidString:)))
    }

    func persistDJIPhoneGPSCameraIDs() {
        let storedIDs = djiPhoneGPSCameraIDs.map(\.uuidString).sorted()
        UserDefaults.standard.set(storedIDs, forKey: djiPhoneGPSStorageKey)
    }

    func reconcilePhoneGPSStreaming() {
        guard FeatureAvailability.djiPhoneGPS else {
            phoneGPSProvider.setActive(false)
            return
        }

        let hasConnectedTarget = cameras.contains { camera in
            camera.supportsDJIPhoneGPS
                && camera.connectionState == .connected
                && djiPhoneGPSCameraIDs.contains(camera.id)
        }
        phoneGPSProvider.setActive(hasConnectedTarget)
    }

    func pushPhoneGPS(_ fix: DJIGPSFix) {
        for camera in cameras where camera.supportsDJIPhoneGPS
            && camera.connectionState == .connected
            && djiPhoneGPSCameraIDs.contains(camera.id) {
            (clients[camera.id] as? DJIExperimentalBLEClient)?.sendPhoneGPS(fix)
        }
    }

    func persistPairedCameras() {
        let saved = cameras.filter(\.isPaired).map { camera in
            var copy = camera
            copy.connectionState = .disconnected
            copy.recordingState = copy.supportsBatchRecord ? .unknown : .unavailable
            copy.currentMode = nil
            copy.isSelected = false
            copy.lastConnectableSeen = nil
            copy.advertisementAwake = nil
            copy.telemetry = nil
            return copy
        }

        do {
            let data = try JSONEncoder().encode(saved)
            UserDefaults.standard.set(data, forKey: pairedCamerasStorageKey)
            syncKnownCamerasWithScanner()
        } catch {
            appendLog("Could not save remembered cameras: \(error.localizedDescription)")
        }
    }

    func syncKnownCamerasWithScanner() {
        scanner.rememberKnownCameras(cameras)
    }

    func normalizedCapabilities(
        _ capabilities: Set<CameraCapability>,
        brand: CameraBrand,
        model: CameraModel,
        name: String
    ) -> Set<CameraCapability> {
        if unsupportedReason(brand: brand, model: model, name: name) != nil {
            return [.experimental]
        }

        var normalized = capabilities
        if brand == .dji {
            normalized.insert(.record)
            normalized.insert(.mode)
            normalized.insert(.experimental)
        }
        if brand == .insta360 {
            normalized.insert(.record)
            normalized.insert(.status)
            normalized.insert(.experimental)
            normalized.remove(.mode)
            normalized.remove(.settings)
            normalized.remove(.keepAlive)
        }
        return normalized
    }

    func unsupportedReason(
        brand: CameraBrand,
        model: CameraModel,
        name: String
    ) -> String? {
        DiscoveredCamera.unsupportedReason(brand: brand, model: model, name: name)
    }

    func discoverNextDemoCamera() {
        guard demoDiscoveryIndex < Self.demoCandidates.count else {
            appendLog("No more simulator demo cameras to discover.")
            return
        }

        let camera = Self.demoCandidates[demoDiscoveryIndex]()
        demoDiscoveryIndex += 1
        cameras.append(camera)
        sortCamerasForEditing()
        appendLog("Discovered \(camera.name).")
    }

    func appendLog(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        logger.info("\(message, privacy: .public)")
        print(message)
        eventLog.insert("[\(timestamp)] \(message)", at: 0)
        eventLog = Array(eventLog.prefix(400))
    }

    func setCameraDiagnostic(_ message: String, for camera: DiscoveredCamera) {
        cameraDiagnosticsByID[camera.id] = message
        appendLog("\(camera.name): \(message)")
    }

    func sortCamerasForEditing() {
        cameras.sort { lhs, rhs in
            if lhs.defaultSortRank != rhs.defaultSortRank {
                return lhs.defaultSortRank < rhs.defaultSortRank
            }

            let lhsName = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if lhsName != .orderedSame {
                return lhsName == .orderedAscending
            }

            let lhsModel = lhs.model.rawValue.localizedStandardCompare(rhs.model.rawValue)
            if lhsModel != .orderedSame {
                return lhsModel == .orderedAscending
            }

            if lhs.brand.rawValue != rhs.brand.rawValue {
                return lhs.brand.rawValue < rhs.brand.rawValue
            }

            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

extension CameraStore {
    static var demoCandidates: [() -> DiscoveredCamera] {
        [
            {
                DiscoveredCamera(
                    id: UUID(),
                    name: "GoPro HERO13",
                    brand: .gopro,
                    model: .goproHero13Black,
                    rssi: -48,
                    capabilities: [.record, .mode, .settings, .status, .keepAlive],
                    connectionState: .discovered,
                    recordingState: .unknown,
                    isPaired: false,
                    isSelected: false,
                    lastSeen: Date()
                )
            },
            {
                DiscoveredCamera(
                    id: UUID(),
                    name: "DJI Action 6",
                    brand: .dji,
                    model: .djiOsmoAction6,
                    rssi: -62,
                    capabilities: [.record, .mode, .settings, .status, .experimental],
                    connectionState: .discovered,
                    recordingState: .unknown,
                    isPaired: false,
                    isSelected: false,
                    lastSeen: Date()
                )
            },
            {
                DiscoveredCamera(
                    id: UUID(),
                    name: "Osmo Nano",
                    brand: .dji,
                    model: .djiOsmoNano,
                    rssi: -74,
                    capabilities: [.record, .experimental],
                    connectionState: .discovered,
                    recordingState: .unknown,
                    isPaired: false,
                    isSelected: false,
                    lastSeen: Date()
                )
            }
        ]
    }
}

private extension ProcessInfo {
    var shouldUseCameraDemoMode: Bool {
        arguments.contains("--demo-cameras")
            || arguments.contains("--demo-connected-cameras")
            || environment["ACTION_CAM_REMOTE_DEMO"] == "1"
    }

    var shouldLoadConnectedCameraDemo: Bool {
        arguments.contains("--demo-connected-cameras")
    }
}

private extension CBManagerState {
    var displayName: String {
        switch self {
        case .unknown:
            "Unknown"
        case .resetting:
            "Resetting"
        case .unsupported:
            "Unsupported"
        case .unauthorized:
            "Unauthorized"
        case .poweredOff:
            "Powered Off"
        case .poweredOn:
            "Powered On"
        @unknown default:
            "Unknown"
        }
    }
}
