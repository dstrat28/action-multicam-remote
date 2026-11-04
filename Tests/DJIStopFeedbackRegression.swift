import CoreBluetooth
import Foundation

@main
enum DJIStopFeedbackRegression {
    static func main() {
        let peripheral = CBPeripheral()
        let characteristic = CBCharacteristic(uuid: CBUUID(string: "FFF1"), properties: [.writeWithoutResponse, .notify])
        let service = CBService(uuid: CBUUID(string: "FFF0"), characteristics: [characteristic])
        var updates: [CameraStatusUpdate] = []
        let client = DJIExperimentalBLEClient(
            cameraID: UUID(), cameraName: "Osmo Nano", cameraModel: .djiOsmoNano,
            peripheral: peripheral, onStatus: { _, _, _ in },
            onCameraStatus: { _, update in updates.append(update) },
            onProtocolActivity: { _ in }, onNanoPairingStatus: { _, _ in },
            hasConfirmedAwakeNanoAdvertisement: true, onLog: { _ in }
        )
        client.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)

        func receive(_ data: Data) {
            characteristic.value = data
            client.peripheral(peripheral, didUpdateValueFor: characteristic, error: nil)
        }
        func status(recording: Bool) -> Data {
            var payload = Data(repeating: 0, count: 60)
            payload[0] = recording ? 0x40 : 0
            payload[4] = 0x01
            payload[57] = 0x01
            return DJINanoProtocol.frame(sequenceNumber: 100, source: 0x01, destination: 0x02,
                flags: 0, commandSet: 0x02, commandID: 0x80, payload: payload)
        }
        func acknowledge(_ packet: Data) {
            let sequence = UInt16(packet[6]) << 8 | UInt16(packet[7])
            receive(DJINanoProtocol.frame(sequenceNumber: sequence, source: packet[5], destination: packet[4],
                flags: 0x80, commandSet: packet[9], commandID: packet[10], payload: Data([0])))
        }

        let beforeStart = peripheral.writes.count
        precondition(client.send(.startRecording).status == .sent)
        let startPacket = peripheral.writes[beforeStart].data
        receive(status(recording: false))
        precondition(updates.last?.canClearActiveRecording == false,
            "Keep the stale-stopped guard until the user requests Stop")
        receive(status(recording: true))
        precondition(updates.last?.recordingState == .recording)
        let beforeStop = peripheral.writes.count
        precondition(client.send(.stopRecording).status == .sent)
        let stopPackets = peripheral.writes.dropFirst(beforeStop).map(\.data)
        precondition(!stopPackets.isEmpty)
        updates.removeAll()
        acknowledge(startPacket)

        // Each successful burst ACK accepts the command; the camera may still
        // be recording or finishing its file. None may publish Stopped.
        for packet in stopPackets {
            acknowledge(packet)
        }
        precondition(!updates.contains { $0.recordingState == .stopped },
            "A Nano Stop ACK must not claim the camera has finished stopping")
        receive(status(recording: true))
        precondition(updates.last?.recordingState == .recording)
        receive(status(recording: false))
        precondition(updates.last?.recordingState == .stopped)
        precondition(updates.last?.canClearActiveRecording == true,
            "An explicit Stop must release the prior Start's stale-stopped guard")
        client.didDisconnect(error: nil)
        print("DJI Nano Stop feedback checks passed: acceptance, continued recording, and confirmed Stop after a recent Start.")
    }
}
