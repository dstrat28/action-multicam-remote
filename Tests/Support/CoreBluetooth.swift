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
}

public enum CBCharacteristicWriteType { case withResponse, withoutResponse }
public enum CBPeripheralState { case disconnected, connecting, connected, disconnecting }
public protocol CBPeripheralDelegate: AnyObject {}

public final class CBCharacteristic {
    public let uuid: CBUUID
    public let properties: CBCharacteristicProperties
    public var isNotifying = false
    public var value: Data?
    public init(uuid: CBUUID, properties: CBCharacteristicProperties) { self.uuid = uuid; self.properties = properties }
}

public final class CBService {
    public let uuid: CBUUID
    public var characteristics: [CBCharacteristic]?
    public init(uuid: CBUUID, characteristics: [CBCharacteristic]) { self.uuid = uuid; self.characteristics = characteristics }
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
    public func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) { characteristic.isNotifying = enabled }
    public func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { maximumLength }
    public func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        writes.append(Write(data: data, characteristic: characteristic))
    }
}
