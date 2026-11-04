import CoreBluetooth
import CoreFoundation
import Foundation

// The scanner owns this service UUID in the app. This host shim avoids importing
// the central manager; the transport and session below are production sources.
enum Insta360BLEUUID {
    static let directControl = CBUUID(string: "BE80")
}

@main
enum Insta360TransportRegression {
    static func verifyUnknownInitialStatus(_ body: [UInt8]) {
        let peripheral = CBPeripheral()
        var states: [CameraConnectionState] = []
        var statuses: [CameraStatusUpdate] = []
        let writer = CBCharacteristic(uuid: CBUUID(string: "BE81"), properties: [.writeWithoutResponse])
        let notifier = CBCharacteristic(uuid: CBUUID(string: "BE82"), properties: [.notify])
        let service = CBService(uuid: Insta360BLEUUID.directControl, characteristics: [writer, notifier])
        peripheral.services = [service]
        let client = Insta360DirectBLEClient(cameraID: UUID(), cameraName: "X5 Unknown", cameraModel: .insta360X5,
            peripheral: peripheral, onStatus: { _, state, _ in states.append(state) },
            onCameraStatus: { _, status in statuses.append(status) }, onProtocolActivity: { _ in }, onLog: { _ in },
            onCommandCompleted: { _ in }, onDisconnectRequested: { _ in })
        client.didConnect()
        client.peripheral(peripheral, didDiscoverServices: nil)
        client.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)
        client.peripheral(peripheral, didUpdateNotificationStateFor: notifier, error: nil)
        precondition(!states.contains(.connected))
        func reply() {
            let request = Array(peripheral.writes.last!.data)
            notifier.value = Data([UInt8(16 + body.count), 0, 0, 0, 4, 0, 0, 200, 0, 2]
                + Array(request[10...12]) + [0x80, 0, 0] + body)
            client.peripheral(peripheral, didUpdateValueFor: notifier, error: nil)
        }
        reply()
        precondition(states.filter { $0 == .connected }.count == 1,
                     "A valid first X5 unknown capture status must establish protocol readiness")
        precondition(statuses.last?.recordingState == .unknown && !client.mayUseGPSRemoteFallback)
        precondition(client.send(.startRecording).status == .skipped, "Protocol readiness does not authorize Start without a known stopped state")
        reply() // Respond to the new read-only status request made by the skipped Start.
        precondition(states.filter { $0 == .connected }.count == 1, "Unchanged later status must not repeat Connected")
        client.didDisconnect(error: nil)
    }

    static func main() {
        verifyUnknownInitialStatus([0x0A, 0])
        verifyUnknownInitialStatus([0x0A, 2, 8, 2])
        let peripheral = CBPeripheral()
        var states: [CameraConnectionState] = []
        let writer = CBCharacteristic(uuid: CBUUID(string: "BE81"), properties: [.writeWithoutResponse])
        let notifier = CBCharacteristic(uuid: CBUUID(string: "BE82"), properties: [.notify])
        let service = CBService(uuid: Insta360BLEUUID.directControl, characteristics: [writer, notifier])
        peripheral.services = [service]
        let client = Insta360DirectBLEClient(
            cameraID: UUID(), cameraName: "Test X5", cameraModel: .insta360X5, peripheral: peripheral,
            onStatus: { _, state, _ in states.append(state) }, onCameraStatus: { _, _ in }, onProtocolActivity: { _ in },
            onLog: { _ in }, onCommandCompleted: { _ in }, onDisconnectRequested: { _ in })
        client.didConnect()
        client.peripheral(peripheral, didDiscoverServices: nil)
        client.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)
        client.peripheral(peripheral, didUpdateNotificationStateFor: notifier, error: nil)
        precondition(!states.contains(.connected), "GATT notification setup alone is not protocol readiness")
        precondition(peripheral.writes.contains { $0.data == Data(Insta360X5Protocol.sync) })
        precondition(!peripheral.writes.contains { $0.data == Data(Insta360X5Protocol.heartbeat) })
        let statusRequest = Array(peripheral.writes.last!.data)
        let body: [UInt8] = [0x0A, 6, 8, 0, 0x10, 0, 0x50, 0]
        notifier.value = Data([UInt8(16 + body.count), 0, 0, 0, 4, 0, 0, 200, 0, 2]
            + Array(statusRequest[10...12]) + [0x80, 0, 0] + body)
        client.peripheral(peripheral, didUpdateValueFor: notifier, error: nil)
        precondition(states.filter { $0 == .connected }.count == 1)

        // UIKit adds tracking mode to the common modes. Run only that mode so a
        // default-mode timer cannot pass while simulating a sustained scroll.
        let trackingMode = CFRunLoopMode(rawValue: "MulticamUITrackingRegression" as CFString)
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), trackingMode)
        CFRunLoopRunInMode(trackingMode, 3.2, false)
        let heartbeatSent = peripheral.writes.contains { $0.data == Data(Insta360X5Protocol.heartbeat) }
        client.didDisconnect(error: nil)
        guard heartbeatSent else {
            fputs("X5 heartbeat stopped while the run loop was tracking UI input.\n", stderr)
            exit(1)
        }
        print("Insta360 transport check passed: X5 heartbeat continues during UI tracking.")
    }
}
