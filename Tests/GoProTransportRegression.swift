import CoreBluetooth
import Foundation

private final class Harness {
    let peripheral = CBPeripheral()
    var client: GoProBLEClient!
    var completions: [CameraCommandResult] = []
    var states: [CameraConnectionState] = []
    var disconnects = 0
    var nextWrite = 0
    var commandPayloads: [Data] = []
    let commandResponse = CBCharacteristic(uuid: GoProBLEUUID.commandResponse, properties: [.notify])
    let settingsResponse = CBCharacteristic(uuid: GoProBLEUUID.settingsResponse, properties: [.notify])
    let queryResponse = CBCharacteristic(uuid: GoProBLEUUID.queryResponse, properties: [.notify])
    let managementResponse = CBCharacteristic(uuid: GoProBLEUUID.cameraManagementResponse, properties: [.notify])

    init(maximumLength: Int = 20, initialPairing: Bool = false) {
        peripheral.maximumLength = maximumLength
        let service = CBService(uuid: GoProBLEUUID.serviceControlAndQuery, characteristics: [
            CBCharacteristic(uuid: GoProBLEUUID.command, properties: [.write]), commandResponse,
            CBCharacteristic(uuid: GoProBLEUUID.settings, properties: [.write]), settingsResponse,
            CBCharacteristic(uuid: GoProBLEUUID.query, properties: [.write]), queryResponse,
            CBCharacteristic(uuid: GoProBLEUUID.cameraManagement, properties: [.write]), managementResponse
        ])
        peripheral.services = [service]
        client = GoProBLEClient(cameraID: UUID(), cameraName: "Test GoPro", peripheral: peripheral,
            isInitialPairing: initialPairing,
            onStatus: { [weak self] _, state, _ in self?.states.append(state) },
            onCameraStatus: { _, _ in }, onLog: { _ in },
            onCommandCompleted: { [weak self] in self?.completions.append($0) },
            onDisconnectRequested: { [weak self] _ in self?.disconnects += 1 })
        client.didConnect()
        client.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)
    }

    func notify(_ payload: Data, on characteristic: CBCharacteristic) {
        characteristic.value = GoProPacket.packetize(payload)
        client.peripheral(peripheral, didUpdateValueFor: characteristic, error: nil)
    }

    @discardableResult func respondNext(hardwareStatus: UInt8 = 0) -> Data {
        var parser = GoProPacketReassembler()
        var payload: Data?
        var characteristic: CBCharacteristic!
        while payload == nil {
            precondition(nextWrite < peripheral.writes.count, "Expected a queued Bluetooth write")
            let write = peripheral.writes[nextWrite]
            characteristic = write.characteristic
            payload = parser.append(write.data).first
            nextWrite += 1
            client.peripheral(peripheral, didWriteValueFor: characteristic, error: nil)
        }
        let request = payload!
        commandPayloads.append(request)
        let response: CBCharacteristic
        let body: Data
        if characteristic.uuid == GoProBLEUUID.query {
            response = queryResponse
            if request[0] == 0xF5 { body = Data([0xF5, request[1] | 0x80]) }
            else if request[0] == 0x13 || request[0] == 0x53 {
                body = Data([request[0], 0, 8, 1, 0, 10, 1, 0, 89, 1, 12])
            } else { body = Data([request[0], 0]) }
        } else if characteristic.uuid == GoProBLEUUID.cameraManagement {
            response = managementResponse; body = Data([request[0], request[1] | 0x80, 8, 0])
        } else if characteristic.uuid == GoProBLEUUID.settings {
            response = settingsResponse; body = Data([request[0], 0])
        } else {
            response = commandResponse
            body = request[0] >= 0xF0 ? Data([request[0], request[1] | 0x80, 8, 0])
                : Data([request[0], request[0] == 0x3C ? hardwareStatus : 0])
        }
        notify(body, on: response)
        return request
    }

    func drain() {
        var count = 0
        while nextWrite < peripheral.writes.count {
            respondNext(); count += 1; precondition(count < 50)
        }
    }
    func close() { client.didDisconnect(error: nil) }
}

@main
enum GoProTransportRegression {
    static func main() {
        do {
            let h = Harness(maximumLength: 8)
            precondition(h.peripheral.writes.count == 1)
            h.client.peripheral(h.peripheral, didWriteValueFor: h.peripheral.writes[0].characteristic, error: nil)
            precondition(h.peripheral.writes.count == 1, "ATT completion must not advance the command queue")
            h.notify(Data([0x93, 0, 8, 1, 0, 10, 1, 0]), on: h.queryResponse)
            precondition(h.peripheral.writes.count == 1, "Status notifications are not request replies")
            h.notify(Data([0x3C, 0]), on: h.commandResponse)
            h.nextWrite = 1
            h.drain()
            precondition(h.states.contains(.connected))
            let start = h.client.send(.startRecording)
            let count = h.peripheral.writes.count
            h.notify(Data([1, 0]), on: h.commandResponse) // Response arrives before ATT callback.
            precondition(h.peripheral.writes.count == count)
            h.respondNext()
            precondition(h.completions.contains { $0.id == start.id && $0.status == .sent })
            h.close()
        }
        do {
            let h = Harness()
            h.respondNext(hardwareStatus: 1)
            h.drain()
            precondition(!h.states.contains(.connected), "Hardware-info failure cannot establish readiness")
            RunLoop.current.run(until: Date().addingTimeInterval(1.1))
            precondition(h.peripheral.writes.count > h.nextWrite, "Read-only startup requests should retry")
            h.drain()
            precondition(h.states.contains(.connected))
            h.close()
        }
        do {
            let h = Harness()
            h.drain()
            let start = h.client.send(.startRecording)
            let write = h.peripheral.writes[h.nextWrite]
            h.nextWrite += 1
            h.client.peripheral(h.peripheral, didWriteValueFor: write.characteristic, error: nil)
            RunLoop.current.run(until: Date().addingTimeInterval(3.2))
            precondition(h.disconnects == 1)
            precondition(h.completions.contains { $0.id == start.id && $0.status == .failed })
            let shutters = h.peripheral.writes.filter { $0.data == Data([0x20, 3, 1, 1, 1]) }
            precondition(shutters.count == 1, "A timed-out Start must not be retransmitted")
            h.close()
        }
        do {
            let h = Harness()
            h.drain()
            _ = h.client.send(.addHighlight)
            let photo = h.client.send(.capturePhoto)
            _ = h.client.send(.stopRecording)
            precondition(h.completions.contains { $0.id == photo.id && $0.status == .skipped })
            h.drain()
            precondition(!h.peripheral.writes.contains { $0.data == Data([0x20, 3, 1, 1, 1]) })
            precondition(h.peripheral.writes.contains { $0.data == Data([0x20, 3, 1, 1, 0]) })
            h.close()
        }
        do {
            let h = Harness(initialPairing: true)
            RunLoop.current.run(until: Date().addingTimeInterval(5.2))
            precondition(h.disconnects == 0, "The normal write watchdog must allow time for first-pairing approval")
            h.close()
        }
        print("GoPro transport checks passed: reply ordering, fragmentation, early notifications, startup recovery, capture timeout, Stop cancellation, and pairing approval time.")
    }
}
