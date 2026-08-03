import CoreBluetooth
import Foundation

struct DiscoveredCameraCandidate {
    var id: UUID
    var name: String
    var brand: CameraBrand
    var model: CameraModel
    var rssi: Int
    var capabilities: Set<CameraCapability>
    var isAwake: Bool? = nil
    var isPairing: Bool? = nil
    var isConnectable: Bool? = nil
}

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

enum BLEPeripheralLookupState {
    case cached
    case restored
    case missing

    var label: String {
        switch self {
        case .cached:
            "cached"
        case .restored:
            "restored"
        case .missing:
            "missing"
        }
    }
}

enum BLEScannerEvent {
    case bluetoothStateChanged(CBManagerState)
    case discovered(DiscoveredCameraCandidate)
    case connectionChanged(UUID, CameraConnectionState)
    case log(String)
}

private struct KnownCameraProfile {
    var name: String
    var brand: CameraBrand
    var model: CameraModel
    var capabilities: Set<CameraCapability>
}

final class BLECameraScanner: NSObject {
    private lazy var centralManager = CBCentralManager(delegate: self, queue: nil)
    private var wantsScanning = false
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var clientsByID: [UUID: any BLECameraDeviceClient] = [:]
    private var forcedReconnectOptionsByID: [UUID: [String: Any]] = [:]
    private var knownCamerasByID: [UUID: KnownCameraProfile] = [:]
    private var lastAdvertisementLogByID: [UUID: Date] = [:]

    var onEvent: ((BLEScannerEvent) -> Void)?

    var bluetoothState: CBManagerState {
        centralManager.state
    }

    func start() {
        wantsScanning = true
        guard centralManager.state == .poweredOn else {
            onEvent?(.bluetoothStateChanged(centralManager.state))
            return
        }

        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        onEvent?(.log("Scanning for GoPro and DJI Bluetooth advertisements."))
    }

    func stop() {
        wantsScanning = false
        centralManager.stopScan()
        onEvent?(.log("Stopped scanning."))
    }

    func peripheralLookup(for id: UUID) -> (peripheral: CBPeripheral?, state: BLEPeripheralLookupState) {
        if let peripheral = peripheralsByID[id] {
            return (peripheral, .cached)
        }

        guard let restoredPeripheral = centralManager.retrievePeripherals(withIdentifiers: [id]).first else {
            return (nil, .missing)
        }

        peripheralsByID[id] = restoredPeripheral
        return (restoredPeripheral, .restored)
    }

    func peripheral(for id: UUID) -> CBPeripheral? {
        peripheralLookup(for: id).peripheral
    }

    func rememberKnownCameras(_ cameras: [DiscoveredCamera]) {
        knownCamerasByID = Dictionary(
            uniqueKeysWithValues: cameras
                .filter(\.isPaired)
                .map { camera in
                    (
                        camera.id,
                        KnownCameraProfile(
                            name: camera.name,
                            brand: camera.brand,
                            model: camera.model,
                            capabilities: camera.capabilities
                        )
                    )
                }
        )
    }

    func connect(
        to id: UUID,
        client: any BLECameraDeviceClient,
        enableAutoReconnect: Bool = false,
        forceReconnect: Bool = false
    ) throws {
        guard let peripheral = peripheralsByID[id] else {
            throw BLEScannerError.peripheralNotFound
        }

        clientsByID[id] = client
        peripheral.delegate = client
        onEvent?(.connectionChanged(id, .connecting))

        if forceReconnect, peripheral.state != .disconnected {
            forcedReconnectOptionsByID[id] = connectOptions(enableAutoReconnect: enableAutoReconnect)
            onEvent?(.log("\(peripheral.name ?? "Camera"): closing the stale BLE link before an explicit wake connection."))
            if peripheral.state != .disconnecting {
                centralManager.cancelPeripheralConnection(peripheral)
            }
            return
        }

        if peripheral.state == .connected {
            onEvent?(.log("\(peripheral.name ?? "Camera"): reusing existing BLE connection."))
            client.didConnect()
            return
        }

        centralManager.connect(
            peripheral,
            options: connectOptions(enableAutoReconnect: enableAutoReconnect)
        )
    }

    func disconnect(from id: UUID) {
        guard let peripheral = peripheralsByID[id] else {
            clientsByID[id]?.didDisconnect(error: nil)
            clientsByID[id] = nil
            onEvent?(.connectionChanged(id, .disconnected))
            return
        }

        if peripheral.state == .disconnected {
            clientsByID[id]?.didDisconnect(error: nil)
            clientsByID[id] = nil
            onEvent?(.connectionChanged(id, .disconnected))
            return
        }

        centralManager.cancelPeripheralConnection(peripheral)
    }
}

extension BLECameraScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onEvent?(.bluetoothStateChanged(central.state))

        if central.state == .poweredOn, wantsScanning {
            start()
        } else if central.state != .poweredOn {
            let activeClients = clientsByID
            clientsByID.removeAll()
            activeClients.forEach { id, client in
                client.didDisconnect(error: nil)
                onEvent?(.connectionChanged(id, .disconnected))
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let candidate = identifyRememberedCamera(
            peripheral: peripheral,
            advertisementData: advertisementData,
            rssi: RSSI.intValue
        ) ?? identifyCamera(
            peripheral: peripheral,
            advertisementData: advertisementData,
            rssi: RSSI.intValue
        ) else {
            return
        }

        peripheralsByID[peripheral.identifier] = peripheral
        logAdvertisementIfNeeded(
            candidate: candidate,
            peripheral: peripheral,
            advertisementData: advertisementData
        )
        onEvent?(.discovered(candidate))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        onEvent?(.log("\(peripheral.name ?? "Camera"): BLE connection established."))
        clientsByID[id]?.didConnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let message = error?.localizedDescription ?? "Connection failed."
        clientsByID[peripheral.identifier]?.didDisconnect(error: error)
        if beginForcedReconnectIfPending(for: peripheral) {
            return
        }
        clientsByID[peripheral.identifier] = nil
        onEvent?(.log("\(peripheral.name ?? "Camera"): BLE connection failed: \(message)"))
        onEvent?(.connectionChanged(peripheral.identifier, .failed(message)))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        handleDisconnect(peripheral: peripheral, error: error, isReconnecting: false)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        handleDisconnect(peripheral: peripheral, error: error, isReconnecting: isReconnecting)
    }
}

private extension BLECameraScanner {
    enum BLEScannerError: LocalizedError {
        case peripheralNotFound

        var errorDescription: String? {
            "The selected Bluetooth peripheral is no longer available."
        }
    }

    func identifyCamera(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: Int
    ) -> DiscoveredCameraCandidate? {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = advertisedServiceUUIDs(from: advertisementData)
        let name = advertisedName ?? peripheral.name ?? "Unnamed Camera"
        let lowercasedName = name.lowercased()

        if services.contains(GoProBLEUUID.serviceControlAndQuery) || lowercasedName.contains("gopro") {
            return DiscoveredCameraCandidate(
                id: peripheral.identifier,
                name: name,
                brand: .gopro,
                model: inferGoProModel(from: name, advertisementData: advertisementData),
                rssi: rssi,
                capabilities: [.record, .mode, .settings, .status, .keepAlive],
                isAwake: inferGoProAwakeState(from: advertisementData, advertisedServices: services),
                isPairing: inferGoProPairingState(from: advertisementData),
                isConnectable: inferConnectableState(from: advertisementData)
            )
        }

        if DJICameraNameClassifier.isCredibleCameraName(name) {
            let model = inferDJIModel(from: name)
            return DiscoveredCameraCandidate(
                id: peripheral.identifier,
                name: name,
                brand: .dji,
                model: model,
                rssi: rssi,
                capabilities: [.experimental],
                isAwake: inferDJIAwakeState(for: model, from: advertisementData),
                isConnectable: inferConnectableState(from: advertisementData)
            )
        }

        return nil
    }

    func logAdvertisementIfNeeded(
        candidate: DiscoveredCameraCandidate,
        peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) {
        guard candidate.brand == .dji || candidate.brand == .gopro else { return }

        let now = Date()
        if let lastLog = lastAdvertisementLogByID[candidate.id],
           now.timeIntervalSince(lastLog) < 3 {
            return
        }

        lastAdvertisementLogByID[candidate.id] = now
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map(\.uuidString)
            .joined(separator: ",")
        let overflowServices = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
            .map(\.uuidString)
            .joined(separator: ",")
        let manufacturerData = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexString ?? "-"
        let serviceData = formatServiceData(advertisementData[CBAdvertisementDataServiceDataKey])
        let txPower = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.stringValue ?? "-"
        let isConnectable = inferConnectableState(from: advertisementData)
            .map { $0 ? "yes" : "no" } ?? "unknown"

        let awake = candidate.isAwake.map { $0 ? "yes" : "no" } ?? "unknown"
        let pairing = candidate.isPairing.map { $0 ? "yes" : "no" } ?? "unknown"
        onEvent?(.log(
            "\(candidate.name): \(candidate.brand.rawValue) ad fingerprint rssi \(candidate.rssi), awake \(awake), pairing \(pairing), connectable \(isConnectable), localName \(localName ?? "-"), peripheralName \(peripheral.name ?? "-"), services [\(services.isEmpty ? "-" : services)], overflow [\(overflowServices.isEmpty ? "-" : overflowServices)], tx \(txPower), mfg \(manufacturerData), serviceData \(serviceData)"
        ))
    }

    func formatServiceData(_ value: Any?) -> String {
        guard let serviceData = value as? [CBUUID: Data], !serviceData.isEmpty else {
            return "-"
        }

        return serviceData
            .map { "\($0.key.uuidString)=\($0.value.hexString)" }
            .sorted()
            .joined(separator: ",")
    }

    func identifyRememberedCamera(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: Int
    ) -> DiscoveredCameraCandidate? {
        guard let known = knownCamerasByID[peripheral.identifier] else { return nil }

        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = advertisedServiceUUIDs(from: advertisementData)
        let name = preferredCameraName(
            advertisedName: advertisedName,
            peripheralName: peripheral.name,
            fallback: known.name
        )
        let inferredModel: CameraModel
        switch known.brand {
        case .gopro:
            inferredModel = inferGoProModel(from: name, advertisementData: advertisementData)
        case .dji:
            inferredModel = inferDJIModel(from: name)
        case .unknown:
            inferredModel = .unknown
        }

        return DiscoveredCameraCandidate(
            id: peripheral.identifier,
            name: name,
            brand: known.brand,
            model: inferredModel == .unknown ? known.model : inferredModel,
            rssi: rssi,
            capabilities: known.capabilities,
            isAwake: inferAwakeState(
                for: known.brand,
                cameraModel: inferredModel == .unknown ? known.model : inferredModel,
                from: advertisementData,
                advertisedServices: services
            ),
            isPairing: known.brand == .gopro ? inferGoProPairingState(from: advertisementData) : nil,
            isConnectable: inferConnectableState(from: advertisementData)
        )
    }

    func preferredCameraName(
        advertisedName: String?,
        peripheralName: String?,
        fallback: String
    ) -> String {
        if let advertisedName, !advertisedName.isEmpty {
            return advertisedName
        }

        if let peripheralName, !peripheralName.isEmpty {
            return peripheralName
        }

        return fallback
    }

    func connectOptions(enableAutoReconnect: Bool) -> [String: Any] {
        var options: [String: Any] = [:]

        if enableAutoReconnect {
            options[CBConnectPeripheralOptionEnableAutoReconnect] = true
        }

        return options
    }

    func handleDisconnect(
        peripheral: CBPeripheral,
        error: Error?,
        isReconnecting: Bool
    ) {
        let id = peripheral.identifier
        clientsByID[id]?.didDisconnect(error: error)

        if beginForcedReconnectIfPending(for: peripheral) {
            return
        }

        if isReconnecting {
            onEvent?(.log("\(peripheral.name ?? "Camera"): BLE disconnected; iOS is reconnecting."))
            onEvent?(.connectionChanged(id, .reconnecting))
            return
        }

        clientsByID[id] = nil

        if let error {
            onEvent?(.log("\(peripheral.name ?? "Camera"): BLE disconnected: \(error.localizedDescription)"))
            onEvent?(.connectionChanged(id, .failed(error.localizedDescription)))
        } else {
            onEvent?(.log("\(peripheral.name ?? "Camera"): BLE disconnected."))
            onEvent?(.connectionChanged(id, .disconnected))
        }
    }

    func beginForcedReconnectIfPending(for peripheral: CBPeripheral) -> Bool {
        let id = peripheral.identifier
        guard let reconnectOptions = forcedReconnectOptionsByID.removeValue(forKey: id),
              let client = clientsByID[id] else {
            return false
        }

        peripheral.delegate = client
        onEvent?(.log("\(peripheral.name ?? "Camera"): starting a fresh BLE wake connection."))
        onEvent?(.connectionChanged(id, .connecting))
        centralManager.connect(peripheral, options: reconnectOptions)
        return true
    }

    func inferGoProModel(from name: String, advertisementData: [String: Any]? = nil) -> CameraModel {
        if let manufacturerData = advertisementData.flatMap(goProManufacturerData),
           manufacturerData.count >= 5 {
            let modelID = manufacturerData[manufacturerData.index(manufacturerData.startIndex, offsetBy: 4)]
            if let model = Self.goProModelByID[modelID] {
                return model
            }
        }

        let lowercasedName = name.lowercased()
        let normalizedName = lowercasedName.filter { $0.isLetter || $0.isNumber }
        for signature in Self.goProModelNameSignatures {
            if normalizedName.contains(signature.normalizedName) {
                return signature.model
            }
        }
        if normalizedName == "hero" || normalizedName == "goprohero" {
            return .goproHero
        }
        return .unknown
    }

    static let goProModelByID: [UInt8: CameraModel] = [
        70: .goproLitHero,
        64: .goproMax2,
        65: .goproHero13Black,
        62: .goproHero12Black,
        60: .goproHero11BlackMini,
        58: .goproHero11Black,
        57: .goproHero10Black,
        55: .goproHero9Black
    ]

    static let goProModelNameSignatures: [(normalizedName: String, model: CameraModel)] = [
        ("h2503", .goproLitHero),
        ("lithero", .goproLitHero),
        ("h2402", .goproMax2),
        ("max2", .goproMax2),
        ("h2401", .goproHero13Black),
        ("hero13", .goproHero13Black),
        ("13black", .goproHero13Black),
        ("h2301", .goproHero12Black),
        ("hero12", .goproHero12Black),
        ("12black", .goproHero12Black),
        ("h2203", .goproHero11BlackMini),
        ("hero11blackmini", .goproHero11BlackMini),
        ("11blackmini", .goproHero11BlackMini),
        ("h2201", .goproHero11Black),
        ("hero11", .goproHero11Black),
        ("11black", .goproHero11Black),
        ("h2101", .goproHero10Black),
        ("hero10", .goproHero10Black),
        ("10black", .goproHero10Black),
        ("hd901", .goproHero9Black),
        ("hero9", .goproHero9Black),
        ("9black", .goproHero9Black),
        ("hero2024", .goproHero),
        ("hero8", .goproHero8Black),
        ("8black", .goproHero8Black),
        ("gopromax", .goproMax),
        ("max", .goproMax)
    ]

    func advertisedServiceUUIDs(from advertisementData: [String: Any]) -> [CBUUID] {
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflowServices = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        return services + overflowServices
    }

    func inferGoProAwakeState(
        from advertisementData: [String: Any],
        advertisedServices: [CBUUID]
    ) -> Bool? {
        guard let manufacturerData = goProManufacturerData(from: advertisementData),
              manufacturerData.count >= 4 else {
            return nil
        }

        let statusByte = manufacturerData[manufacturerData.index(manufacturerData.startIndex, offsetBy: 3)]
        return GoProAdvertisementStatus.isProcessorAwake(statusByte)
    }

    func inferGoProPairingState(from advertisementData: [String: Any]) -> Bool? {
        guard let manufacturerData = goProManufacturerData(from: advertisementData),
              manufacturerData.count >= 4 else {
            return nil
        }

        let statusByte = manufacturerData[manufacturerData.index(manufacturerData.startIndex, offsetBy: 3)]
        return GoProAdvertisementStatus.isPeripheralPairingEnabled(statusByte)
    }

    func goProManufacturerData(from advertisementData: [String: Any]) -> Data? {
        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manufacturerData.count >= 2 else {
            return nil
        }

        let firstByte = UInt16(manufacturerData[manufacturerData.startIndex])
        let secondByte = UInt16(manufacturerData[manufacturerData.index(manufacturerData.startIndex, offsetBy: 1)])
        let littleEndianCompanyID = firstByte | (secondByte << 8)
        let bigEndianCompanyID = (firstByte << 8) | secondByte

        guard littleEndianCompanyID == 0xF202 || bigEndianCompanyID == 0xF202 else {
            return nil
        }

        return manufacturerData
    }

    func inferAwakeState(
        for brand: CameraBrand,
        cameraModel: CameraModel,
        from advertisementData: [String: Any],
        advertisedServices: [CBUUID]
    ) -> Bool? {
        switch brand {
        case .gopro:
            inferGoProAwakeState(from: advertisementData, advertisedServices: advertisedServices)
        case .dji:
            inferDJIAwakeState(for: cameraModel, from: advertisementData)
        case .unknown:
            nil
        }
    }

    func inferDJIAwakeState(
        for model: CameraModel,
        from advertisementData: [String: Any]
    ) -> Bool? {
        guard model == .djiOsmoNano,
              let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manufacturerData.count >= 12,
              manufacturerData[manufacturerData.startIndex] == 0xAA,
              manufacturerData[manufacturerData.index(manufacturerData.startIndex, offsetBy: 1)] == 0x08,
              manufacturerData[manufacturerData.index(manufacturerData.startIndex, offsetBy: 2)] == 0x19 else {
            return nil
        }

        switch manufacturerData[manufacturerData.index(manufacturerData.startIndex, offsetBy: 11)] {
        case 0x02:
            return true
        case 0x03:
            return false
        default:
            return nil
        }
    }

    func inferConnectableState(from advertisementData: [String: Any]) -> Bool? {
        if let isConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool {
            return isConnectable
        }

        if let isConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber {
            return isConnectable.boolValue
        }

        return nil
    }

    func inferDJIModel(from name: String) -> CameraModel {
        DJICameraNameClassifier.model(for: name)
    }
}
