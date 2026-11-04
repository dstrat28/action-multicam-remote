import CoreBluetooth
import Foundation

protocol BLECameraDeviceClient: AnyObject, CBPeripheralDelegate {
    var cameraID: UUID { get }
    var cameraName: String { get }
    var managesOwnConnection: Bool { get }

    func disconnectManagedConnection()
    func didConnect()
    func didDisconnect(error: Error?)
    func send(_ command: CameraCommand) -> CameraCommandResult
}

extension BLECameraDeviceClient {
    var managesOwnConnection: Bool { false }
    func disconnectManagedConnection() {}

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
