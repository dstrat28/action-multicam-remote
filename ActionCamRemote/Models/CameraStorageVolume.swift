import Foundation

/// A reported volume, without claiming that it is the selected recording destination.
struct CameraStorageVolume: Equatable, Codable, Identifiable {
    enum Location: String, Codable {
        case internalStorage, sdCard
        var label: String { self == .internalStorage ? "Internal Storage" : "SD Card" }
    }
    enum State: String, Codable { case available, notInserted, unavailable }
    var location: Location
    var state: State = .available
    var freeMB: UInt32? = nil
    var totalMB: UInt32? = nil
    var id: Location { location }

    var valueDescription: String {
        switch state {
        case .notInserted: return "Not inserted"
        case .unavailable: return "Unavailable"
        case .available:
            guard let freeMB, freeMB != .max else { return "Unavailable" }
            if let totalMB {
                guard totalMB > 0, totalMB != .max, freeMB <= totalMB else { return "Unavailable" }
            }
            return "\(Self.capacityText(mb: freeMB)) free"
        }
    }

    static func capacityText(mb: UInt32) -> String {
        guard mb >= 1024 else { return "\(mb)MB" }
        let gb = Double(mb) / 1024
        return gb >= 100 || gb.rounded() == gb ? "\(Int(gb.rounded()))GB" : String(format: "%.1fGB", gb)
    }
}
