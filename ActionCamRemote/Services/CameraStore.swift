import CoreBluetooth
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class CameraStore {
    var cameras: [DiscoveredCamera] = []
    var commandResults: [CameraCommandResult] = []
    var eventLog: [String] = []
    var isScanning = false
    var bluetoothStateLabel = "Unknown"
    var isDemoMode = false
    var cameraDiagnosticsByID: [UUID: String] = [:]

    @ObservationIgnored private let scanner: BLECameraScanner
    @ObservationIgnored private var clients: [UUID: any BLECameraDeviceClient] = [:]
    @ObservationIgnored private var demoDiscoveryIndex = 0
    @ObservationIgnored private let pairedCamerasStorageKey = "pairedCameras.v1"
    @ObservationIgnored private var lastConnectionAttemptByID: [UUID: Date] = [:]
    @ObservationIgnored private let signalRefreshInterval: TimeInterval = 8
    @ObservationIgnored private let availabilityFreshnessInterval: TimeInterval = 10
    @ObservationIgnored private let autoConnectRetryCooldownInterval: TimeInterval = 12
    @ObservationIgnored private let availabilityTimeoutDelay: Duration = .seconds(10)
    @ObservationIgnored private let modeSwitchDelay: Duration = .milliseconds(1600)
    @ObservationIgnored private let defaultConnectionTimeoutDelay: Duration = .seconds(9)
    @ObservationIgnored private let goProWakeConnectionTimeoutDelay: Duration = .seconds(30)
    @ObservationIgnored private let action6WakeConnectionTimeoutDelay: Duration = .seconds(28)
    @ObservationIgnored private let defaultStartStateGuardInterval: TimeInterval = 5
    @ObservationIgnored private let pocket3StartStateGuardInterval: TimeInterval = 1.5
    @ObservationIgnored private let stopStateGuardInterval: TimeInterval = 2.5
    @ObservationIgnored private var wakeRetryTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var startRecordingTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var videoModeTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var connectionTimeoutTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var availabilityTimeoutTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var reconnectTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var djiIdleDisconnectTasksByCameraID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var modeSwitchAttemptsByCameraID: [UUID: Int] = [:]
    @ObservationIgnored private var pendingStartConnectionFailuresByCameraID: [UUID: Int] = [:]
    @ObservationIgnored private var availabilitySuppressedUntilByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var autoConnectSuppressedUntilByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var lastWakeScanRefreshByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var lastDJIProbeByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var awakeAdvertisementByCameraID: [UUID: Bool] = [:]
    @ObservationIgnored private var awakeAdvertisementSeenAtByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var ignoreStoppedUntilByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var ignoreRecordingUntilByCameraID: [UUID: Date] = [:]
    @ObservationIgnored private var pendingStartCameraIDs: Set<UUID> = []
    @ObservationIgnored private var pendingStopCameraIDs: Set<UUID> = []
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

        loadPairedCameras()
        syncKnownCamerasWithScanner()

        if resolvedDemoMode {
            bluetoothStateLabel = "Simulator Demo"
            appendLog("Simulator demo mode is ready. Use Connect Camera to add sample discoveries.")
        } else if !pairedCameras.isEmpty {
            startScanning()
        }
    }

    var selectedCameras: [DiscoveredCamera] {
        cameras.filter(\.isSelected)
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
                return false
            }
        }
    }

    var connectedCameras: [DiscoveredCamera] {
        cameras.filter { $0.connectionState == .connected }
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
        var sections: [String] = []

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

    var controllableRecordCameras: [DiscoveredCamera] {
        cameras.filter(\.canSelectForBatch)
    }

    var canStartMulticamRecording: Bool {
        !selectedControllableCameras.isEmpty
            && connectedRecordCameras.allSatisfy(\.isReadyForMulticamStart)
            && selectedControllableCameras.allSatisfy(\.isReadyForMulticamStart)
    }

    var canStopMulticamRecording: Bool {
        selectedConnectedCameras.contains { camera in
            camera.supportsBatchRecord
                && camera.recordingState == .recording
        }
    }

    var multicamReadinessMessage: String {
        guard !controllableRecordCameras.isEmpty else {
            return "Connect cameras to start multicam recording."
        }

        if selectedControllableCameras.isEmpty {
            return "Select the cameras you want to control."
        }

        if canStopMulticamRecording {
            return "Stop multicam will stop the selected recording cameras."
        }

        if selectedControllableCameras.contains(where: { $0.recordingState == .starting }) {
            return "Waiting for cameras to start recording."
        }

        if connectedRecordCameras.contains(where: { $0.recordingState == .recording }) {
            return "Stop recording cameras individually before multicam start."
        }

        if selectedControllableCameras.contains(where: { $0.isConnected && !$0.canStartRecordingInCurrentMode }) {
            return "Switch cameras to Video mode before recording."
        }

        if selectedControllableCameras.contains(where: { $0.brand != .dji && $0.isConnected && $0.currentMode != .video }) {
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
    }

    func toggleScanning() {
        isScanning ? stopScanning() : startScanning()
    }

    func toggleSelection(for camera: DiscoveredCamera) {
        guard let index = cameras.firstIndex(where: { $0.id == camera.id }) else { return }
        guard cameras[index].canSelectForBatch || cameras[index].isSelected else { return }
        cameras[index].isSelected.toggle()
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

        if isDemoMode {
            markCameraAsPaired(camera.id)
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
                onLog: { [weak self] message in
                    Task { @MainActor in self?.appendLog(message) }
                }
            )
        case .unknown:
            updateCamera(camera.id, state: .unsupported("Unknown camera brand."), detail: nil)
            return
        }

        do {
            clients[camera.id] = client
            lastConnectionAttemptByID[camera.id] = Date()
            if camera.brand == .dji,
               !pendingStartCameraIDs.contains(camera.id),
               !pendingStopCameraIDs.contains(camera.id) {
                lastDJIProbeByCameraID[camera.id] = Date()
            }
            scheduleConnectionTimeout(for: camera.id)
            try scanner.connect(
                to: camera.id,
                client: client,
                enableAutoReconnect: shouldEnableSystemAutoReconnect(for: camera)
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

        scanner.disconnect(from: camera.id)
    }

    func remove(_ camera: DiscoveredCamera) {
        cancelStartRecording(for: camera.id)
        cancelVideoModeSwitch(for: camera.id)
        cancelConnectionTimeout(for: camera.id)
        cancelAvailabilityTimeout(for: camera.id)
        cancelDJIIdleDisconnect(for: camera.id)
        modeSwitchAttemptsByCameraID.removeValue(forKey: camera.id)
        pendingStartConnectionFailuresByCameraID.removeValue(forKey: camera.id)
        availabilitySuppressedUntilByCameraID.removeValue(forKey: camera.id)
        lastWakeScanRefreshByCameraID.removeValue(forKey: camera.id)
        lastDJIProbeByCameraID.removeValue(forKey: camera.id)
        awakeAdvertisementByCameraID.removeValue(forKey: camera.id)
        awakeAdvertisementSeenAtByCameraID.removeValue(forKey: camera.id)
        clearStateGuards(for: camera.id)
        pendingStartCameraIDs.remove(camera.id)
        pendingStopCameraIDs.remove(camera.id)
        if camera.connectionState == .connected || camera.connectionState == .connecting {
            disconnect(camera)
        }

        clients[camera.id] = nil

        if let index = cameras.firstIndex(where: { $0.id == camera.id }) {
            cameras.remove(at: index)
        }

        sortCamerasForEditing()
        persistPairedCameras()
        appendLog("Removed \(camera.name).")
    }

    func startMulticamRecording() {
        guard canStartMulticamRecording else {
            appendLog(multicamReadinessMessage)
            return
        }

        startRecordingSequence(for: selectedControllableCameras)
    }

    func stopMulticamRecording() {
        let targets = selectedConnectedCameras.filter { camera in
            camera.supportsBatchRecord
                && camera.recordingState == .recording
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

    func startRecording(_ camera: DiscoveredCamera) {
        startRecordingSequence(for: [camera])
    }

    func stopRecording(_ camera: DiscoveredCamera) {
        cancelStartRecording(for: camera.id)
        pendingStartCameraIDs.remove(camera.id)
        pendingStartConnectionFailuresByCameraID.removeValue(forKey: camera.id)
        cancelWakeRetry(for: camera.id)
        guard camera.connectionState == .connected else {
            queueStopRecording(for: camera, reason: "Camera is not connected.")
            scheduleReconnect(for: camera.id, attemptsRemaining: 6)
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

    func merge(_ candidate: DiscoveredCameraCandidate) {
        var shouldAutoConnect = false
        var shouldSort = false
        let now = Date()
        let isConnectable = candidate.isConnectable ?? true
        var isAvailabilitySuppressed = (availabilitySuppressedUntilByCameraID[candidate.id] ?? .distantPast) > now
        if let isAwake = candidate.isAwake {
            awakeAdvertisementByCameraID[candidate.id] = isAwake
            awakeAdvertisementSeenAtByCameraID[candidate.id] = now
            if isAwake, isAvailabilitySuppressed {
                availabilitySuppressedUntilByCameraID.removeValue(forKey: candidate.id)
                isAvailabilitySuppressed = false
            }
        }

        if let index = cameras.firstIndex(where: { $0.id == candidate.id }) {
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
                    if isConnectable {
                        cameras[index].lastConnectableSeen = now
                    }
                    if shouldRefreshSignal {
                        cameras[index].rssi = candidate.rssi
                    }
                }

                switch cameras[index].connectionState {
                case .disconnected, .failed, .reconnecting:
                    if isConnectable, !isAvailabilitySuppressed || isPairingModeActive {
                        cameras[index].connectionState = .discovered
                        clearSelectionIfNotConnected(at: index)
                        if cameras[index].isPaired,
                           cameras[index].supportsBatchRecord,
                           !pendingStartCameraIDs.contains(candidate.id),
                           cameras[index].recordingState != .recording {
                            cameras[index].recordingState = .stopped
                        }
                    }
                case .discovered, .connecting, .connected, .unsupported:
                    if !isConnectable, cameras[index].connectionState == .discovered {
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
                    && isConnectable
                    && canAttemptAutoConnect(to: cameras[index], now: now)

                if candidate.brand == .dji, candidate.isAwake != nil {
                    scheduleDJIIdleDisconnectIfNeeded(for: candidate.id)
                }
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
                        ?? (isConnectable ? .discovered : .disconnected),
                    recordingState: unsupportedReason == nil && capabilities.contains(.record) ? .unknown : .unavailable,
                    isPaired: false,
                    isSelected: false,
                    lastSeen: Date(),
                    lastConnectableSeen: isConnectable ? Date() : nil
                )
            )
            shouldSort = true
        }

        if shouldSort {
            sortCamerasForEditing()
        }

        if cameras.first(where: { $0.id == candidate.id })?.isSupportedByApp == true,
           isConnectable, !isAvailabilitySuppressed || isPairingModeActive {
            scheduleAvailabilityTimeout(for: candidate.id)
        }

        if shouldAutoConnect, let camera = cameras.first(where: { $0.id == candidate.id }) {
            appendLog("Auto-connecting \(camera.name).")
            connect(camera)
        }
    }

    func canAttemptAutoConnect(to camera: DiscoveredCamera, now: Date) -> Bool {
        if pendingStartCameraIDs.contains(camera.id)
            || pendingStopCameraIDs.contains(camera.id) {
            return true
        }

        guard camera.isPaired, camera.isAvailableToConnect else { return false }

        if let lastAttempt = lastConnectionAttemptByID[camera.id],
           now.timeIntervalSince(lastAttempt) < autoConnectRetryCooldownInterval {
            return false
        }

        if camera.brand == .gopro {
            // A GoPro BLE connection wakes or keeps the camera awake, so only connect
            // for an explicit queued command rather than a passive scan advertisement.
            return false
        }

        if camera.brand == .dji,
           let lastConnectableSeen = camera.lastConnectableSeen,
           now.timeIntervalSince(lastConnectableSeen) <= availabilityFreshnessInterval {
            if let isAwake = freshAwakeAdvertisement(for: camera.id, now: now) {
                return isAwake
            }
            if camera.behavior.kind == .djiOsmoNano {
                return false
            }
            return true
        }

        return false
    }

    func freshAwakeAdvertisement(for id: UUID, now: Date) -> Bool? {
        guard let isAwake = awakeAdvertisementByCameraID[id],
              let seenAt = awakeAdvertisementSeenAtByCameraID[id],
              now.timeIntervalSince(seenAt) <= availabilityFreshnessInterval else {
            return nil
        }

        return isAwake
    }

    func protectStartTransition(for camera: DiscoveredCamera) {
        ignoreStoppedUntilByCameraID[camera.id] = Date().addingTimeInterval(startStateGuardInterval(for: camera))
        ignoreRecordingUntilByCameraID.removeValue(forKey: camera.id)
    }

    func startStateGuardInterval(for camera: DiscoveredCamera) -> TimeInterval {
        camera.behavior.kind == .djiOsmoPocket3 ? pocket3StartStateGuardInterval : defaultStartStateGuardInterval
    }

    func protectStopTransition(for camera: DiscoveredCamera) {
        ignoreRecordingUntilByCameraID[camera.id] = Date().addingTimeInterval(stopStateGuardInterval)
        ignoreStoppedUntilByCameraID.removeValue(forKey: camera.id)
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
            connect(camera)
        }
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
                guard latest.connectionState == .connecting else {
                    self.connectionTimeoutTasksByCameraID[id] = nil
                    return
                }

                self.scanner.disconnect(from: id)
                self.clients[id] = nil

                if self.pendingStartCameraIDs.contains(id) {
                    self.lastConnectionAttemptByID[id] = nil
                    let failures = (self.pendingStartConnectionFailuresByCameraID[id] ?? 0) + 1
                    self.pendingStartConnectionFailuresByCameraID[id] = failures
                    if latest.brand == .gopro {
                        self.setCameraDiagnostic(
                            "GoPro wake attempt \(failures)/\(self.maxPendingStartConnectionFailures(for: latest)) timed out; retrying BLE wake connection.",
                            for: latest
                        )
                    } else if latest.isKnownAction6 {
                        self.setCameraDiagnostic(
                            "Action 6 wake attempt \(failures)/\(self.maxPendingStartConnectionFailures(for: latest)) timed out; retrying BLE wake connection.",
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
                    self.appendLog("\(latest.name): connection timed out before the camera became ready.")
                    self.setCameraDiagnostic(
                        "BLE connection timed out before the camera command service was ready. Will retry on a fresh advertisement.",
                        for: latest
                    )
                    self.updateCamera(
                        id,
                        state: self.freshAvailableState(for: latest) ?? .disconnected,
                        detail: nil
                    )
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

    func connectionTimeoutDelay(for id: UUID) -> Duration {
        guard let camera = cameras.first(where: { $0.id == id }),
              pendingStartCameraIDs.contains(id) else {
            return defaultConnectionTimeoutDelay
        }

        if camera.brand == .gopro {
            return goProWakeConnectionTimeoutDelay
        }

        if camera.isKnownAction6 {
            return action6WakeConnectionTimeoutDelay
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

        if camera.isKnownAction6 {
            return "Action 6 wake attempt \(attempt)/\(maxPendingStartConnectionFailures(for: camera)): iOS has no BLE peripheral yet. Waiting for an advertisement or restored peripheral."
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

        if camera.isKnownAction6 {
            return "Action 6 wake attempt \(attempt)/\(maxPendingStartConnectionFailures(for: camera)): BLE peripheral \(lookupState.label); requesting connection."
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

    func scheduleDJIIdleDisconnectIfNeeded(for id: UUID) {
        guard let camera = cameras.first(where: { $0.id == id }),
              camera.brand == .dji,
              camera.connectionState == .connected,
              !shouldHoldDJIConnection(camera) else {
            cancelDJIIdleDisconnect(for: id)
            return
        }

        djiIdleDisconnectTasksByCameraID[id]?.cancel()
        djiIdleDisconnectTasksByCameraID[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      let latest = self.cameras.first(where: { $0.id == id }) else { return }
                guard latest.brand == .dji,
                      latest.connectionState == .connected,
                      !self.shouldHoldDJIConnection(latest) else {
                    self.cancelDJIIdleDisconnect(for: id)
                    return
                }

                if let index = self.cameras.firstIndex(where: { $0.id == id }) {
                    self.cameras[index].lastConnectableSeen = Date()
                }
                self.scanner.disconnect(from: id)
                self.djiIdleDisconnectTasksByCameraID[id] = nil
            }
        }
    }

    func cancelDJIIdleDisconnect(for id: UUID) {
        djiIdleDisconnectTasksByCameraID[id]?.cancel()
        djiIdleDisconnectTasksByCameraID[id] = nil
    }

    func shouldHoldDJIConnection(_ camera: DiscoveredCamera) -> Bool {
        if awakeAdvertisementByCameraID[camera.id] != false {
            return true
        }

        return pendingStartCameraIDs.contains(camera.id)
            || pendingStopCameraIDs.contains(camera.id)
            || camera.recordingState == .recording
            || camera.recordingState == .starting
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
                    self.reconnectTasksByCameraID[id] = nil
                }
            }
        }
    }

    func pendingStartReconnectAttempts(for camera: DiscoveredCamera) -> Int {
        if camera.brand == .gopro {
            return 45
        }

        if camera.isKnownAction6 {
            return 18
        }

        return 8
    }

    func maxPendingStartConnectionFailures(for camera: DiscoveredCamera) -> Int {
        if camera.brand == .gopro {
            return 3
        }

        return camera.isKnownAction6 ? 4 : 8
    }

    func availabilitySuppressionInterval(for camera: DiscoveredCamera) -> TimeInterval {
        if camera.brand == .gopro {
            return 90
        }

        return camera.isKnownAction6 ? 120 : 30
    }

    func pendingStartFailureReason(for camera: DiscoveredCamera) -> String {
        if camera.brand == .gopro {
            return "GoPro did not advertise or accept a BLE wake connection. Turn it on before recording."
        }

        if camera.isKnownAction6 {
            return "Action 6 did not accept a BLE wake connection. Turn it on before recording."
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
        guard detail?.contains("DJI record characteristics ready") == true else { return }
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
            isReady = detail?.contains("GoPro command characteristic is ready") == true
        case .dji:
            isReady = detail?.contains("DJI record characteristics ready") == true
        case .unknown:
            isReady = false
        }
        guard isReady else { return }

        appendLog("\(latest.name): sending queued start after reconnect.")
        scheduleRecordAfterModeSwitch(for: [latest.id])
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
                if camera.brand != .dji, camera.currentMode != .video {
                    sendVideoModeCommandAttempt(for: camera, attemptsAlreadySent: 0)
                    modeSwitchAttemptsByCameraID[camera.id] = 1
                }
                connectedCamerasForStart.append(camera)
            } else {
                pendingStartCameraIDs.insert(camera.id)
                updateCameraStatus(camera.id, update: pendingStartStatusUpdate(for: camera))
                if camera.brand == .gopro {
                    setCameraDiagnostic("Record from off requested; preparing GoPro BLE wake connection.", for: camera)
                } else if camera.isKnownAction6 {
                    setCameraDiagnostic("Record from off requested; preparing Action 6 BLE wake connection.", for: camera)
                }
                queueStartRecording(for: camera, reason: "Camera is not connected.")
                lastConnectionAttemptByID[camera.id] = nil
                connect(camera)
            }
        }

        guard !connectedCamerasForStart.isEmpty else { return }
        scheduleRecordAfterModeSwitch(for: connectedCamerasForStart.map(\.id))
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

                    if latest.brand == .dji {
                        self.updateCameraStatus(id, update: CameraStatusUpdate(shouldClearCurrentMode: true))
                        self.send(.startRecording, to: [latest])
                        self.scheduleWakeRetryIfNeeded(for: [latest])
                        self.modeSwitchAttemptsByCameraID.removeValue(forKey: id)
                        self.startRecordingTasksByCameraID[id] = nil
                        return
                    }

                    if latest.currentMode != .video {
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

                    self.send(.startRecording, to: [latest])
                    self.scheduleWakeRetryIfNeeded(for: [latest])
                    self.modeSwitchAttemptsByCameraID.removeValue(forKey: id)
                    self.startRecordingTasksByCameraID[id] = nil
                }
            }
        }
    }

    func scheduleWakeRetryIfNeeded(for cameras: [DiscoveredCamera]) {
        for camera in cameras
            where camera.brand == .dji
                && camera.behavior.assumesRecordingAfterUnconfirmedDJIStart
                && camera.recordingState != .recording {
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
                guard latest.connectionState == .connected, latest.recordingState != .recording else {
                    self.wakeRetryTasksByCameraID[id] = nil
                    return
                }

                if attemptsRemaining > 0 {
                    self.appendLog("\(latest.name): retrying wake-and-record.")
                    self.send(.startRecording, to: [latest])
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
                                recordingState: shouldAssumeRecording ? .recording : .stopped,
                                shouldClearCurrentMode: true
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
        if camera.brand == .gopro {
            appendLog("\(camera.name): cycling GoPro mode toward Video.")
            send(.cycleMode, to: [camera])
        } else {
            appendLog("\(camera.name): sending Video mode command.")
            send(.setMode(.video), to: [camera])
        }
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
                } else if camera.brand == .dji, command == .stopRecording {
                    queueStopRecording(for: camera, reason: "No active BLE client.")
                    scheduleReconnect(for: camera.id, attemptsRemaining: 6)
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
                scheduleReconnect(for: camera.id, attemptsRemaining: 6)
            }
            return
        }

        switch result.command {
        case .startRecording:
            protectStartTransition(for: camera)
            updateCameraStatus(
                camera.id,
                update: CameraStatusUpdate(recordingState: .starting, shouldClearCurrentMode: true)
            )
        case .stopRecording:
            protectStopTransition(for: camera)
            pendingStopCameraIDs.remove(camera.id)
            pendingStartConnectionFailuresByCameraID.removeValue(forKey: camera.id)
            reconnectTasksByCameraID[camera.id]?.cancel()
            reconnectTasksByCameraID[camera.id] = nil
            updateCameraStatus(camera.id, update: CameraStatusUpdate(recordingState: .stopped))
        case .setMode:
            break
        case .toggleRecording, .cycleMode, .applySetting, .keepAlive:
            break
        }
    }

    func sendDemo(_ command: CameraCommand, to cameras: [DiscoveredCamera]) {
        for camera in cameras {
            let status: CameraCommandStatus
            let message: String

            if camera.brand == .dji,
               command != .startRecording,
               command != .stopRecording,
               command != .setMode(.video) {
                status = .unsupported
                message = "DJI settings and mode control still require hardware command mapping."
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
        case .stopRecording:
            cameras[index].recordingState = .stopped
        case .toggleRecording:
            cameras[index].recordingState = cameras[index].recordingState == .recording ? .stopped : .recording
        case let .setMode(mode):
            cameras[index].currentMode = mode
        case .cycleMode:
            cameras[index].currentMode = nil
        case .applySetting, .keepAlive:
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
        var shouldSort = false
        var shouldPersist = false
        let previousRecordingState = cameras[index].recordingState
        var recordingStateToApply = update.recordingState
        var recordingDecision: String?

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
                      cameras[index].recordingState == .recording {
                cancelWakeRetry(for: id)
                recordingDecision = "kept recording because stopped cannot clear active recording"
            } else if recordingState == .stopped,
                      !update.canClearActiveRecording,
                      cameras[index].recordingState == .starting {
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
            }
        }

        logAction6RecordingStatusDecision(
            camera: cameras[index],
            incoming: update.recordingState,
            previous: previousRecordingState,
            decision: recordingDecision,
            canClearActiveRecording: update.canClearActiveRecording
        )

        if update.shouldClearCurrentMode {
            cameras[index].currentMode = nil
        } else if let currentMode = update.currentMode {
            cameras[index].currentMode = currentMode
        }

        if let model = update.model, model != .unknown, cameras[index].model != model {
            cameras[index].model = model
            shouldSort = true
            shouldPersist = cameras[index].isPaired
        }

        if shouldSort {
            sortCamerasForEditing()
        }

        if shouldPersist {
            persistPairedCameras()
        }

        if cameras[index].brand == .dji {
            scheduleDJIIdleDisconnectIfNeeded(for: id)
        }
    }

    func updateCamera(_ id: UUID, state: CameraConnectionState, detail: String?) {
        guard let index = cameras.firstIndex(where: { $0.id == id }) else { return }
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
        let appliedState = appliedConnectionState(for: cameras[index], requestedState: state)
        cameras[index].connectionState = appliedState

        switch appliedState {
        case .connected:
            cancelConnectionTimeout(for: id)
            cancelAvailabilityTimeout(for: id)
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
            scheduleDJIIdleDisconnectIfNeeded(for: id)
        case .reconnecting:
            cancelDJIIdleDisconnect(for: id)
            cancelConnectionTimeout(for: id)
            cancelAvailabilityTimeout(for: id)
            cancelWakeRetry(for: id)
            if pendingStartCameraIDs.contains(id) {
                cameras[index].recordingState = .starting
                lastConnectionAttemptByID[id] = nil
                ensureScanning()
                scheduleReconnect(
                    for: id,
                    attemptsRemaining: pendingStartReconnectAttempts(for: cameras[index])
                )
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
                    scheduleReconnect(for: id, attemptsRemaining: 6)
                }
            } else {
                cameras[index].recordingState = cameras[index].supportsBatchRecord ? .unknown : .unavailable
                cameras[index].currentMode = nil
            }
        case .disconnected, .failed:
            cancelDJIIdleDisconnect(for: id)
            cancelConnectionTimeout(for: id)
            cancelAvailabilityTimeout(for: id)
            cancelWakeRetry(for: id)
            if cameras[index].brand == .gopro,
               previousState == .connected,
               !pendingStartCameraIDs.contains(id),
               !pendingStopCameraIDs.contains(id) {
                autoConnectSuppressedUntilByCameraID[id] = Date().addingTimeInterval(90)
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
                scheduleReconnect(for: id, attemptsRemaining: 6)
            } else {
                cameras[index].recordingState = cameras[index].supportsBatchRecord ? .unknown : .unavailable
                cameras[index].currentMode = nil
            }
        case .unsupported:
            cancelDJIIdleDisconnect(for: id)
            cancelConnectionTimeout(for: id)
            cancelAvailabilityTimeout(for: id)
            cancelWakeRetry(for: id)
            cameras[index].recordingState = cameras[index].supportsBatchRecord ? .unknown : .unavailable
            cameras[index].currentMode = nil
        case .connecting:
            cancelDJIIdleDisconnect(for: id)
            cancelAvailabilityTimeout(for: id)
        case .discovered:
            cancelDJIIdleDisconnect(for: id)
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

            if let lastConnectableSeen = camera.lastConnectableSeen,
               Date().timeIntervalSince(lastConnectableSeen) <= availabilityFreshnessInterval {
                return .discovered
            }
            return .disconnected
        case .discovered, .connecting, .connected, .reconnecting, .unsupported:
            return state
        }
    }

    func clearSelectionIfNotConnected(at index: Int) {
        guard cameras.indices.contains(index),
              cameras[index].connectionState != .connected else {
            return
        }

        cameras[index].isSelected = false
    }

    func freshAvailableState(for camera: DiscoveredCamera) -> CameraConnectionState? {
        guard let lastConnectableSeen = camera.lastConnectableSeen,
              Date().timeIntervalSince(lastConnectableSeen) <= availabilityFreshnessInterval else {
            return nil
        }

        return .discovered
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
                return camera
            }
            appendLog("Loaded \(cameras.count) remembered cameras.")
            sortCamerasForEditing()
        } catch {
            appendLog("Could not load remembered cameras: \(error.localizedDescription)")
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
            let lhsRank = lhs.isPaired ? 0 : 1
            let rhsRank = rhs.isPaired ? 0 : 1
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }

            let lhsName = lhs.name.localizedStandardCompare(rhs.name)
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
                    capabilities: [.record, .experimental],
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
            || environment["ACTION_CAM_REMOTE_DEMO"] == "1"
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
