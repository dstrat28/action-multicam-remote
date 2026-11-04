import Foundation

// Host-only wake-advertisement double. Never included in an app target.
public final class CLBeaconRegion {
    public init(uuid: UUID, major: UInt16, minor: UInt16, identifier: String) {}
    public func peripheralData(withMeasuredPower: NSNumber?) -> NSMutableDictionary { NSMutableDictionary() }
}
