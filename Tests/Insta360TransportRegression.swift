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
    static func main() {
        let peripheral = CBPeripheral()
        let writer = CBCharacteristic(uuid: CBUUID(string: "BE81"), properties: [.writeWithoutResponse])
        let notifier = CBCharacteristic(uuid: CBUUID(string: "BE82"), properties: [.notify])
        let service = CBService(uuid: Insta360BLEUUID.directControl, characteristics: [writer, notifier])
        peripheral.services = [service]
        let client = Insta360DirectBLEClient(
            cameraID: UUID(), cameraName: "Test X5", cameraModel: .insta360X5, peripheral: peripheral,
            onStatus: { _, _, _ in }, onCameraStatus: { _, _ in }, onProtocolActivity: { _ in },
            onLog: { _ in }, onCommandCompleted: { _ in }, onDisconnectRequested: { _ in })
        client.didConnect()
        client.peripheral(peripheral, didDiscoverServices: nil)
        client.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)
        client.peripheral(peripheral, didUpdateNotificationStateFor: notifier, error: nil)
        precondition(peripheral.writes.contains { $0.data == Data(Insta360X5Protocol.sync) })
        precondition(!peripheral.writes.contains { $0.data == Data(Insta360X5Protocol.heartbeat) })

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
