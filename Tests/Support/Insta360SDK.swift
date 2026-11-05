import Foundation

// Handwritten host-only test double for the public APIs used by our adapter.
// No vendor implementation, header text, or binary is included.
@objc public enum INSBluetoothManageState: UInt { case bluetoothUnknown, bluetoothDisable, bluetoothUnauthorized, ready }
public enum INSCameraCaptureState: UInt { case notCapture = 0, normalCapture = 1 }
public enum INSCameraOptionsType: UInt16 { case batteryStatus = 11, storageState = 20, photoSubMode = 40, videoSubMode = 41, storageStateList = 176 }
public enum INSCameraPowerType { case battery, adapter }
public enum INSCameraCardState { case normal, noCard, noSpace, invalidFormat, unknownError }
public enum INSStorageCardLocation: UInt { case camera = 0, reader = 1, inner = 2, SD = 3 }
public final class INSCameraCaptureStatus: NSObject {
    public var state = INSCameraCaptureState.notCapture
    public var captureTime: UInt = 0
}
public final class INSCameraBatteryStatus: NSObject {
    public var batteryScale = 100
    public var batteryLevel = 50
    public var powerType = INSCameraPowerType.battery
}
public final class INSCameraStorageStatus: NSObject {
    public var cardState = INSCameraCardState.normal
    public var cardLocation = INSStorageCardLocation.camera
    public var freeSpace: Int64 = 1_048_576 * 10
    public var totalSpace: Int64 = 1_048_576 * 20
}
public final class INSCameraOptions: NSObject {
    public var photoSubMode: UInt32 = 100
    public var videoSubMode: UInt32 = 0
    public var batteryStatus: INSCameraBatteryStatus? = INSCameraBatteryStatus()
    public var storageStatus: INSCameraStorageStatus? = INSCameraStorageStatus()
    public var cameraStorageStatus: INSCameraStorageStatus?
    public var storageStateList: NSMutableArray?
}
public final class INSCaptureOptions: NSObject {}
public final class INSTakePictureOptions: NSObject {}
public final class INSCameraManager: NSObject {
    private static let instance = INSCameraManager()
    public static func usb() -> INSCameraManager { instance }
    public private(set) var setupCount = 0
    public private(set) var shutdownCount = 0
    public private(set) var isSetup = false
    public func setup() { setupCount += 1; isSetup = true }
    public func shutdown() { shutdownCount += 1; isSetup = false }
}
public final class INSBluetoothDevice: NSObject {
    public let identifierUUIDStringSafe: String
    public init(id: UUID) { identifierUUIDStringSafe = id.uuidString }
}
public protocol INSBluetoothManagerDelegate: AnyObject {
    func device(_ device: INSBluetoothDevice, didDisconnectWithError error: Error?)
}
public protocol INSCameraBasicCommands: AnyObject {
    func sendHeartbeats(with options: Any?)
    func startCapture(with options: INSCaptureOptions?, completion: @escaping (Error?) -> Void)
    func stopCapture(with options: INSCaptureOptions?, completion: @escaping (Error?, Any?) -> Void)
    func takePicture(with options: INSTakePictureOptions?, completion: @escaping (Error?, Any?) -> Void)
    func setOptions(_ options: INSCameraOptions, forTypes: [NSNumber], completion: @escaping (Error?, [NSNumber]?) -> Void)
    func getCurrentCaptureStatus(completion: @escaping (Error?, INSCameraCaptureStatus?) -> Void)
    func getOptionsWithTypes(_ types: [NSNumber], completion: @escaping (Error?, INSCameraOptions?, [NSNumber]?) -> Void)
}
public final class SDKTestCommands: INSCameraBasicCommands {
    public var status = INSCameraCaptureStatus()
    public var options = INSCameraOptions()
    public var holdOptions = false
    public var holdStatus = false
    public var heldStatus: ((Error?, INSCameraCaptureStatus?) -> Void)?
    public var holdTelemetry = false
    public var acceptCapture = true
    public var appliesModeChanges = true
    public var includeSuccessTypes = false
    public var optionsError: Error?
    public var successTypesOverride: [NSNumber]?
    public private(set) var heldOptions: [([NSNumber], (Error?, INSCameraOptions?, [NSNumber]?) -> Void)] = []
    public private(set) var starts = 0
    public private(set) var stops = 0
    public private(set) var heartbeats = 0
    public private(set) var statusRequests = 0
    public private(set) var modeChanges = 0
    public private(set) var optionRequests: [[NSNumber]] = []
    public var startCompletion: ((Error?) -> Void)?
    public init() {}
    public func sendHeartbeats(with options: Any?) { heartbeats += 1 }
    public func startCapture(with options: INSCaptureOptions?, completion: @escaping (Error?) -> Void) {
        starts += 1
        startCompletion = completion
        if acceptCapture { completion(nil) }
    }
    public func stopCapture(with options: INSCaptureOptions?, completion: @escaping (Error?, Any?) -> Void) {
        stops += 1; completion(nil, nil)
    }
    public func takePicture(with options: INSTakePictureOptions?, completion: @escaping (Error?, Any?) -> Void) { completion(nil, nil) }
    public func setOptions(_ options: INSCameraOptions, forTypes: [NSNumber], completion: @escaping (Error?, [NSNumber]?) -> Void) {
        modeChanges += 1
        if !appliesModeChanges { completion(nil, nil); return }
        if forTypes.contains(NSNumber(value: INSCameraOptionsType.photoSubMode.rawValue)) {
            self.options.photoSubMode = options.photoSubMode; self.options.videoSubMode = 100
        } else {
            self.options.videoSubMode = options.videoSubMode; self.options.photoSubMode = 100
        }
        completion(nil, includeSuccessTypes ? forTypes : nil)
    }
    public func getCurrentCaptureStatus(completion: @escaping (Error?, INSCameraCaptureStatus?) -> Void) {
        statusRequests += 1
        if holdStatus { heldStatus = completion; return }
        let snapshot = INSCameraCaptureStatus()
        snapshot.state = status.state; snapshot.captureTime = status.captureTime
        completion(nil, snapshot)
    }
    public func getOptionsWithTypes(_ types: [NSNumber], completion: @escaping (Error?, INSCameraOptions?, [NSNumber]?) -> Void) {
        optionRequests.append(types)
        if holdOptions || (holdTelemetry && types.contains(NSNumber(value: INSCameraOptionsType.batteryStatus.rawValue))) {
            heldOptions.append((types, completion))
        }
        else { completion(optionsError, options, successTypesOverride ?? (includeSuccessTypes ? types : nil)) }
    }
    public func releaseOptions() {
        let held = heldOptions; heldOptions = []
        for (types, completion) in held {
            completion(optionsError, options, successTypesOverride ?? (includeSuccessTypes ? types : nil))
        }
    }
}
public final class INSBluetoothManager: NSObject {
    public static var instances: [INSBluetoothManager] = []
    public static var autoConnect = true
    public weak var delegate: INSBluetoothManagerDelegate?
    @objc dynamic public var state = INSBluetoothManageState.ready
    public let commands = SDKTestCommands()
    public private(set) var cancellations = 0
    public private(set) var disconnections = 0
    public var connectionCompletion: ((Error?, INSBluetoothDevice?) -> Void)?
    public private(set) var connectedID: UUID?
    public override init() {
        precondition(INSCameraManager.usb().isSetup, "SDK initialization must precede Bluetooth managers")
        super.init(); Self.instances.append(self)
    }
    public func connect(with id: UUID, completion: @escaping (Error?, INSBluetoothDevice?) -> Void) -> Any {
        connectedID = id; connectionCompletion = completion
        if Self.autoConnect { completion(nil, INSBluetoothDevice(id: id)) }
        return UUID()
    }
    public func getCommandBy(_ device: INSBluetoothDevice) -> Any { commands }
    public func cancelConnect(_ task: Any) { cancellations += 1 }
    public func disconnectDevice(_ device: INSBluetoothDevice) { disconnections += 1 }
    public func stopScan() {}
}
