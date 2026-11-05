import CoreBluetooth
import Foundation

@main
@MainActor
enum DJIStopFeedbackRegression {
    static func main() async {
        let peripheral = CBPeripheral()
        let characteristic = CBCharacteristic(uuid: CBUUID(string: "FFF1"), properties: [.writeWithoutResponse, .notify])
        let service = CBService(uuid: CBUUID(string: "FFF0"), characteristics: [characteristic])
        var updates: [CameraStatusUpdate] = []
        let client = DJIExperimentalBLEClient(
            cameraID: UUID(), cameraName: "Osmo Nano", cameraModel: .djiOsmoNano,
            peripheral: peripheral, onStatus: { _, _, _ in },
            onCameraStatus: { _, update in updates.append(update) },
            onProtocolActivity: { _ in }, onNanoPairingStatus: { _, _ in },
            hasConfirmedAwakeNanoAdvertisement: true, onLog: { _ in },
            onPairingRejected: { _, _ in preconditionFailure("Nano Stop must not reject pairing") }
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
        var capacity = Data(repeating: 0, count: 60)
        capacity[4] = 1; capacity[6] = 0x10; capacity[10] = 0x08; capacity[57] = 1
        func pollReply(_ payload: Data, source: UInt8 = 1, result: UInt8 = 0) -> Data {
            DJINanoProtocol.frame(sequenceNumber: 101, source: source, destination: 2,
                flags: 0x80, commandSet: 2, commandID: 0x70, payload: Data([result]) + payload)
        }
        updates.removeAll()
        receive(pollReply(capacity))
        precondition(updates.last?.recordingState == nil,
            "Nano poll replies may refresh metadata but must not confirm capture")
        precondition(updates.last?.currentMode == nil)
        precondition(updates.last?.telemetry?.storageVolumes?.first?.location == .internalStorage)
        precondition(updates.last?.telemetry?.storageFreeMB == 2048)
        let countBeforeUnrelated = updates.count
        receive(pollReply(capacity, source: 2))
        receive(pollReply(capacity, result: 1))
        precondition(updates.count == countBeforeUnrelated)
        for total in [UInt32.max, 1000] {
            var invalid = capacity
            for offset in 0..<4 { invalid[5 + offset] = UInt8(truncatingIfNeeded: total >> (offset * 8)) }
            receive(pollReply(invalid))
            precondition(updates.last?.telemetry?.storageFreeMB == nil)
            precondition(updates.last?.telemetry?.storageVolumes == [])
        }
        capacity[9] = 0; capacity[10] = 0; capacity[11] = 0; capacity[12] = 0
        receive(pollReply(capacity))
        precondition(updates.last?.telemetry?.storageFreeMB == 0)
        var compact = Data(repeating: 0, count: 34)
        compact[20] = 87
        receive(pollReply(compact))
        precondition(updates.last?.telemetry?.batteryPercent == 87)
        precondition(updates.last?.telemetry?.storageVolumes == nil,
            "Compact battery replies must preserve the independently reported internal volume")
        precondition(updates.last?.recordingState == nil && updates.last?.currentMode == nil)
        compact[20] = 255
        receive(pollReply(compact))
        precondition(updates.last?.telemetry?.batteryPercent == nil)
        client.didDisconnect(error: nil)
        await checkNanoPolling()
        await checkPairingRejection()
        print("DJI checks passed: Nano Stop acceptance/confirmation and connection-scoped pairing rejection.")
    }

    private static func checkNanoPolling() async {
        let peripheral = CBPeripheral()
        let notify = CBCharacteristic(uuid: CBUUID(string: "FFF4"), properties: [.notify])
        let writer = CBCharacteristic(uuid: CBUUID(string: "FFF5"), properties: [.writeWithoutResponse])
        let service = CBService(uuid: CBUUID(string: "FFF0"), characteristics: [notify, writer])
        var clock: TimeInterval = 100
        var activityCount = 0
        var updates: [CameraStatusUpdate] = []
        let client = DJIExperimentalBLEClient(cameraID: UUID(), cameraName: "Osmo Nano",
            cameraModel: .djiOsmoNano, peripheral: peripheral, onStatus: { _, _, _ in },
            onCameraStatus: { _, update in updates.append(update) }, onProtocolActivity: { _ in activityCount += 1 },
            onNanoPairingStatus: { _, _ in }, hasConfirmedAwakeNanoAdvertisement: true, onLog: { _ in },
            onPairingRejected: { _, _ in preconditionFailure("Unexpected rejection") }, metadataTime: { clock })
        client.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)
        var payload = Data(repeating: 0, count: 60)
        payload[0] = 0x40; payload[4] = 1; payload[57] = 1
        func receiveState() {
            notify.value = DJINanoProtocol.frame(sequenceNumber: 100, source: 1, destination: 2,
                flags: 0, commandSet: 2, commandID: 0x80, payload: payload)
            client.peripheral(peripheral, didUpdateValueFor: notify, error: nil)
        }
        func polls() -> Int { peripheral.writes.filter { $0.data[9] == 2 && $0.data[10] == 0x70 }.count }
        func heartbeats() -> Int {
            let keepAlive = DJINanoProtocol.keepAliveCommand
            return peripheral.writes.filter { $0.data[9] == keepAlive.commandSet && $0.data[10] == keepAlive.commandID }.count
        }
        receiveState()
        try? await Task.sleep(for: .seconds(3.5))
        let firstPolls = polls()
        let firstHeartbeats = heartbeats()
        precondition(firstPolls >= 1 && firstHeartbeats >= 2)
        try? await Task.sleep(for: .seconds(2.6))
        precondition(polls() == firstPolls, "Metadata must not poll on every 2.5-second tick")
        precondition(heartbeats() > firstHeartbeats, "One-second keepalives must continue independently")

        // Queue metadata behind ATT backpressure, then supersede it with Stop.
        peripheral.canSendWriteWithoutResponse = false
        clock = 130
        try? await Task.sleep(for: .seconds(2.6))
        precondition(client.send(.stopRecording).status == .sent)
        peripheral.canSendWriteWithoutResponse = true
        client.peripheralIsReady(toSendWriteWithoutResponse: peripheral)
        try? await Task.sleep(for: .seconds(1.8))
        precondition(polls() == firstPolls, "Capture must discard queued optional polls")
        clock = 144
        try? await Task.sleep(for: .seconds(2.6))
        precondition(polls() == firstPolls)
        let activityBefore = activityCount
        receiveState()
        precondition(activityCount > activityBefore && updates.last?.recordingState == .recording,
            "Live capture and health notifications must continue during the metadata pause")
        clock = 160
        try? await Task.sleep(for: .seconds(2.8))
        precondition(polls() == firstPolls + 1,
            "Metadata must resume after its bounded capture window without confirming capture")
        client.didDisconnect(error: nil)
    }

    private static func checkPairingRejection() async {
        // Standard R SDK verification request: verifyMode 2, verifyData 1
        // (declined), including the protocol's header and packet checksums.
        let packet = "aa 30 00 02 00 00 00 00 01 00 8c df 00 19 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 02 01 00 00 e0 af 0b de"
        for retired in [false, true] {
            let events = CameraClientEventSession()
            let peripheral = CBPeripheral()
            let notify = CBCharacteristic(uuid: CBUUID(string: "FFF4"), properties: [.notify])
            peripheral.services = [CBService(uuid: CBUUID(string: "FFF0"), characteristics: [notify])]
            var receivedRejections = 0
            var genericStatuses = 0
            var failureMessages: [String] = []
            var disconnects = 0
            let client = DJIExperimentalBLEClient(cameraID: UUID(), cameraName: "DJI", cameraModel: .djiRSDKCamera,
                peripheral: peripheral, onStatus: { _, _, _ in genericStatuses += 1 },
                onCameraStatus: { _, _ in }, onProtocolActivity: { _ in }, onNanoPairingStatus: { _, _ in },
                hasConfirmedAwakeNanoAdvertisement: true, onLog: { _ in },
                onPairingRejected: { _, message in
                    receivedRejections += 1
                    events.deliverStatus(.failed(message), apply: {
                        failureMessages.append(message)
                        events.invalidate() // Applying terminal status retires its own session.
                    }, onFailure: { disconnects += 1 })
                })
            notify.value = Data(packet.split(separator: " ").map { UInt8($0, radix: 16)! })
            client.peripheral(peripheral, didUpdateValueFor: notify, error: nil)
            precondition(receivedRejections == 1 && genericStatuses == 0,
                "Rejection must be one terminal event, not separately queued rejection and failure callbacks")
            if retired { events.invalidate() }

            let replacement = CameraClientEventSession()
            var replacementReady = false
            replacement.deliver { replacementReady = true }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while (!replacementReady || (!retired && disconnects == 0)), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            precondition(replacementReady)
            if retired {
                precondition(failureMessages.isEmpty && disconnects == 0,
                    "A replaced client's rejection must neither change status nor disconnect its successor")
            } else {
                precondition(failureMessages == ["Connection declined on the DJI camera. Tap Pair to try again."]
                    && disconnects == 1,
                    "Current rejection must preserve its failure reason and teardown after retiring the session")
            }
            client.didDisconnect(error: nil)
        }
    }
}
