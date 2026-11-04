import CoreBluetooth
import Foundation

/// Direct central-to-camera control for X5/X6, using their distinct wire formats.
/// Older X5 firmware can return to the CE80 GPS Remote service during setup.
final class Insta360DirectBLEClient: NSObject, BLECameraDeviceClient {
    private static let writeUUID = CBUUID(string: "BE81")
    private static let notifyUUID = CBUUID(string: "BE82")

    let cameraID: UUID
    let cameraName: String
    private weak var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var notifier: CBCharacteristic?
    private var x6Decoder = Insta360X6Decoder()
    private var x5Decoder = Insta360X5Decoder()
    private let profile: Insta360DirectProfile
    private var writeChunks: [Data] = []
    private var writingID: UInt32?
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var timer: Timer?
    private var setupBeganAt: TimeInterval?
    private var hasReportedProtocolReady = false
    private let session: Insta360DirectSession
    private let onStatus: (UUID, CameraConnectionState, String?) -> Void
    private let onCameraStatus: (UUID, CameraStatusUpdate) -> Void
    private let onProtocolActivity: (UUID) -> Void
    private let onLog: (String) -> Void
    private let onCommandCompleted: (CameraCommandResult) -> Void
    private let onDisconnectRequested: (UUID) -> Void
    private let onSetupUnavailable: (UUID, String) -> Void

    init(
        cameraID: UUID, cameraName: String, cameraModel: CameraModel, peripheral: CBPeripheral,
        onStatus: @escaping (UUID, CameraConnectionState, String?) -> Void,
        onCameraStatus: @escaping (UUID, CameraStatusUpdate) -> Void,
        onProtocolActivity: @escaping (UUID) -> Void,
        onLog: @escaping (String) -> Void,
        onCommandCompleted: @escaping (CameraCommandResult) -> Void,
        onDisconnectRequested: @escaping (UUID) -> Void,
        onSetupUnavailable: @escaping (UUID, String) -> Void = { _, _ in }
    ) {
        profile = cameraModel == .insta360X5 ? .x5 : .x6
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.peripheral = peripheral
        self.onStatus = onStatus
        self.onCameraStatus = onCameraStatus
        self.onProtocolActivity = onProtocolActivity
        self.onLog = onLog
        self.onCommandCompleted = onCommandCompleted
        self.onDisconnectRequested = onDisconnectRequested
        self.onSetupUnavailable = onSetupUnavailable
        session = Insta360DirectSession(cameraID: cameraID, cameraName: cameraName, profile: profile)
        super.init()
        session.onWrite = { [weak self] data, id in self?.write(data, id: id) }
        session.onStatus = { [weak self] update in
            guard let self else { return }
            if self.session.hasConfirmedProtocol, !self.hasReportedProtocolReady {
                self.hasReportedProtocolReady = true
                self.onStatus(cameraID, .connected, "Insta360 \(self.profile.name) direct Bluetooth ready. Use normal Video mode on the camera.")
            }
            self.onCameraStatus(cameraID, update)
        }
        session.onCompletion = { [weak self] result in self?.onCommandCompleted(result) }
        session.onLog = { [weak self] message in self?.onLog("\(cameraName): \(message)") }
        session.onTransportFailure = { [weak self] message in self?.fail(message) }
    }

    deinit { timer?.invalidate() }

    func didConnect() {
        reset()
        peripheral?.delegate = self
        peripheral?.discoverServices([Insta360BLEUUID.directControl])
    }

    func didDisconnect(error: Error?) { reset() }

    func send(_ command: CameraCommand) -> CameraCommandResult {
        session.send(command, at: ProcessInfo.processInfo.systemUptime)
    }

    var mayUseGPSRemoteFallback: Bool { session.mayUseGPSRemoteFallback }

    private func reset() {
        timer?.invalidate()
        timer = nil
        setupBeganAt = nil
        hasReportedProtocolReady = false
        session.end()
        x6Decoder.reset()
        x5Decoder.reset()
        writer = nil
        notifier = nil
        writingID = nil
        writeChunks.removeAll()
    }

    private func fail(_ message: String) {
        if session.mayUseGPSRemoteFallback {
            reset()
            onLog("\(cameraName): \(message) Trying the GPS Remote connection instead.")
            onSetupUnavailable(cameraID, message)
            return
        }
        if session.isReady {
            session.transportFailed(message)
        } else {
            reset()
            onLog("\(cameraName): \(message)")
            onStatus(cameraID, .failed(message), message)
            onDisconnectRequested(cameraID)
        }
    }

    private func write(_ data: Data, id: UInt32) {
        guard let peripheral, let writer, writingID == nil,
              peripheral.state == .connected else {
            fail("\(self.profile.name) Bluetooth command channel is unavailable.")
            return
        }
        let negotiated = peripheral.maximumWriteValueLength(for: writeType)
        let size = profile == .x5 ? min(20, negotiated) : negotiated
        guard size > 0 else { fail("\(self.profile.name) Bluetooth write size is unavailable."); return }
        writeChunks = stride(from: 0, to: data.count, by: size).map {
            data.subdata(in: $0..<min($0 + size, data.count))
        }
        writingID = id
        if writeType == .withoutResponse {
            flushWithoutResponse(peripheral)
        } else {
            peripheral.writeValue(writeChunks.removeFirst(), for: writer, type: .withResponse)
        }
    }

    private func flushWithoutResponse(_ peripheral: CBPeripheral) {
        guard let writer, let id = writingID else { return }
        while !writeChunks.isEmpty, peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(writeChunks.removeFirst(), for: writer, type: .withoutResponse)
        }
        guard writeChunks.isEmpty else { return }
        writingID = nil
        session.didWrite(id: id, at: ProcessInfo.processInfo.systemUptime)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard self.peripheral === peripheral, writeType == .withoutResponse else { return }
        flushWithoutResponse(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Insta360BLEUUID.directControl }) else {
            fail("\(self.profile.name) direct Bluetooth service was not found. Turn on the camera and enable Bluetooth.")
            return
        }
        peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, service.uuid == Insta360BLEUUID.directControl else { return }
        guard error == nil,
              let writer = service.characteristics?.first(where: { $0.uuid == Self.writeUUID }),
              let notifier = service.characteristics?.first(where: { $0.uuid == Self.notifyUUID }),
              (writer.properties.contains(.write) || (profile == .x5 && writer.properties.contains(.writeWithoutResponse))),
              notifier.properties.contains(.notify) else {
            fail("\(self.profile.name) direct Bluetooth command characteristics are unavailable.")
            return
        }
        self.writer = writer
        self.notifier = notifier
        writeType = profile == .x5 && writer.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.setNotifyValue(true, for: notifier)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic === notifier else { return }
        guard error == nil, characteristic.isNotifying else {
            fail("\(self.profile.name) Bluetooth response notifications could not be enabled.")
            return
        }
        guard !session.isReady else { return }
        onStatus(cameraID, .connecting, "Insta360 \(self.profile.name) command channel open; waiting for a valid capture status.")
        session.begin(at: ProcessInfo.processInfo.systemUptime)
        setupBeganAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.session.mayUseGPSRemoteFallback, now - (self.setupBeganAt ?? now) >= 10 {
                self.fail("X5 did not establish the documented direct-control protocol.")
                return
            }
            self.session.tick(at: now)
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic === writer, let id = writingID else { return }
        if let error { fail("\(self.profile.name) Bluetooth write failed: \(error.localizedDescription)"); return }
        if !writeChunks.isEmpty {
            peripheral.writeValue(writeChunks.removeFirst(), for: characteristic, type: .withResponse)
        } else {
            writingID = nil
            session.didWrite(id: id, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic === notifier, session.isReady else { return }
        guard error == nil, let value = characteristic.value else {
            onLog("\(cameraName): \(self.profile.name) Bluetooth notification error: \(error?.localizedDescription ?? "empty value")")
            return
        }
        do {
            let messages = try profile == .x5 ? x5Decoder.feed(Array(value)) : x6Decoder.feed(Array(value))
            for message in messages {
                onProtocolActivity(cameraID)
                session.receive(message, at: ProcessInfo.processInfo.systemUptime)
            }
        } catch {
            // Do not reuse an ambiguous command stream after a corrupt frame.
            fail("\(self.profile.name) Bluetooth response could not be decoded: \(error)")
        }
    }
}
