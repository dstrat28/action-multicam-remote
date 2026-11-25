import CoreBluetooth
import Foundation

enum DJIRSDKBLEUUID {
    static let service = CBUUID(string: "FFF0")
    static let notifyCharacteristic = CBUUID(string: "FFF4")
    static let writeCharacteristic = CBUUID(string: "FFF5")
}

protocol BLECameraDeviceClient: AnyObject, CBPeripheralDelegate {
    var cameraID: UUID { get }
    var cameraName: String { get }
    var managesOwnConnection: Bool { get }

    func disconnectManagedConnection()
    func didConnect()
    func didDisconnect(error: Error?)
    func send(_ command: CameraCommand) -> CameraCommandResult
    func setRecordingElapsedVisible(_ visible: Bool)
}

extension BLECameraDeviceClient {
    var managesOwnConnection: Bool { false }
    func disconnectManagedConnection() {}
    func setRecordingElapsedVisible(_ visible: Bool) {}

    func result(
        for command: CameraCommand,
        status: CameraCommandStatus,
        message: String
    ) -> CameraCommandResult {
        CameraCommandResult(
            cameraID: cameraID,
            cameraName: cameraName,
            command: command,
            status: status,
            message: message,
            timestamp: Date()
        )
    }
}
