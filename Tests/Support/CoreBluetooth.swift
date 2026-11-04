import Foundation

// Host-only CoreBluetooth double. Never included in an app target.
public final class CBUUID: NSObject {
    public let uuidString: String
    public init(string: String) { uuidString = string.uppercased() }
    public override func isEqual(_ object: Any?) -> Bool { (object as? CBUUID)?.uuidString == uuidString }
    public override var hash: Int { uuidString.hashValue }
}

public struct CBCharacteristicProperties: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let write = Self(rawValue: 1)
    public static let notify = Self(rawValue: 2)
    public static let indicate = Self(rawValue: 4)
    public static let writeWithoutResponse = Self(rawValue: 8)
    public static let read = Self(rawValue: 16)
    public static let broadcast = Self(rawValue: 32)
    public static let authenticatedSignedWrites = Self(rawValue: 64)
    public static let extendedProperties = Self(rawValue: 128)
    public static let notifyEncryptionRequired = Self(rawValue: 256)
    public static let indicateEncryptionRequired = Self(rawValue: 512)
}

public enum CBCharacteristicWriteType { case withResponse, withoutResponse }
public enum CBPeripheralState { case disconnected, connecting, connected, disconnecting }
public protocol CBPeripheralDelegate: AnyObject {}

public class CBCharacteristic {
    public let uuid: CBUUID
    public let properties: CBCharacteristicProperties
    public var isNotifying = false
    public var value: Data?
    public weak var service: CBService?
    public init(uuid: CBUUID, properties: CBCharacteristicProperties) { self.uuid = uuid; self.properties = properties }
}

public class CBService {
    public let uuid: CBUUID
    public var characteristics: [CBCharacteristic]? { didSet { characteristics?.forEach { $0.service = self } } }
    public init(uuid: CBUUID, characteristics: [CBCharacteristic]) {
        self.uuid = uuid; self.characteristics = characteristics
        characteristics.forEach { $0.service = self }
    }
}

public enum CBManagerState { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
public struct CBAttributePermissions: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let readable = Self(rawValue: 1)
    public static let writeable = Self(rawValue: 2)
}
public final class CBCentral {
    public let identifier: UUID
    public var maximumUpdateValueLength = 20
    public init(identifier: UUID = UUID()) { self.identifier = identifier }
}
public final class CBMutableCharacteristic: CBCharacteristic {
    public var subscribedCentrals: [CBCentral]?
    public let permissions: CBAttributePermissions
    public init(type: CBUUID, properties: CBCharacteristicProperties, value: Data?, permissions: CBAttributePermissions) {
        self.permissions = permissions
        super.init(uuid: type, properties: properties)
        self.value = value
    }
}
public final class CBMutableService: CBService {
    public let isPrimary: Bool
    public init(type: CBUUID, primary: Bool) {
        isPrimary = primary
        super.init(uuid: type, characteristics: [])
    }
}
public final class CBATTRequest {
    public let central: CBCentral
    public let characteristic: CBCharacteristic
    public var offset: Int
    public var value: Data?
    public init(central: CBCentral, characteristic: CBCharacteristic, offset: Int = 0, value: Data?) {
        self.central = central; self.characteristic = characteristic; self.offset = offset; self.value = value
    }
}
public enum CBATTError {
    public enum Code { case success, requestNotSupported, invalidOffset }
}
public protocol CBPeripheralManagerDelegate: AnyObject {}
public let CBPeripheralManagerOptionRestoreIdentifierKey = "restoreIdentifier"
public let CBPeripheralManagerRestoredStateServicesKey = "restoredServices"
public let CBPeripheralManagerRestoredStateAdvertisementDataKey = "restoredAdvertisement"
public let CBAdvertisementDataManufacturerDataKey = "manufacturerData"
public let CBAdvertisementDataLocalNameKey = "localName"
public let CBAdvertisementDataServiceUUIDsKey = "serviceUUIDs"
public final class CBPeripheralManager {
    public struct Response { public let request: CBATTRequest; public let result: CBATTError.Code }
    public struct Update { public let data: Data; public let centrals: [CBCentral]? }
    public static var instances: [CBPeripheralManager] = []
    public var state = CBManagerState.poweredOn
    public var isAdvertising = false
    public var acceptsUpdates = true
    public private(set) var services: [CBMutableService] = []
    public private(set) var responses: [Response] = []
    public private(set) var updates: [Update] = []
    public private(set) var advertisements: [[String: Any]] = []
    public init(delegate: CBPeripheralManagerDelegate?, queue: DispatchQueue?, options: [String: Any]?) { Self.instances.append(self) }
    public func add(_ service: CBMutableService) { services.append(service) }
    public func removeAllServices() { services.removeAll() }
    public func startAdvertising(_ data: [String: Any]?) { isAdvertising = true; advertisements.append(data ?? [:]) }
    public func stopAdvertising() { isAdvertising = false }
    public func respond(to request: CBATTRequest, withResult result: CBATTError.Code) { responses.append(Response(request: request, result: result)) }
    public func updateValue(_ data: Data, for characteristic: CBMutableCharacteristic, onSubscribedCentrals centrals: [CBCentral]?) -> Bool {
        guard acceptsUpdates else { return false }
        updates.append(Update(data: data, centrals: centrals)); return true
    }
}

public final class CBPeripheral {
    public struct Write { public let data: Data; public let characteristic: CBCharacteristic }
    public weak var delegate: (any CBPeripheralDelegate)?
    public var state = CBPeripheralState.connected
    public var services: [CBService]?
    public var maximumLength = 20
    public var canSendWriteWithoutResponse = true
    public private(set) var writes: [Write] = []
    public init() {}
    public func discoverServices(_ services: [CBUUID]?) {}
    public func discoverCharacteristics(_ characteristics: [CBUUID]?, for service: CBService) {}
    public func readValue(for characteristic: CBCharacteristic) {}
    public func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) { characteristic.isNotifying = enabled }
    public func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { maximumLength }
    public func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        writes.append(Write(data: data, characteristic: characteristic))
    }
}
