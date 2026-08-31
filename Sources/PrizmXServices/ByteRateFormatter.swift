import Foundation

/// Formats a byte rate as a short UI string (`"1.2 MB/s"`).
public enum ByteRateFormatter: Sendable {
    public static func string(fromBytesPerSecond bytesPerSecond: Double) -> String {
        let magnitude = max(0, bytesPerSecond)
        switch magnitude {
        case ..<1_000:
            return "\(Int(magnitude.rounded())) B/s"
        case ..<1_000_000:
            return format(magnitude / 1_000, unit: "KB/s")
        case ..<1_000_000_000:
            return format(magnitude / 1_000_000, unit: "MB/s")
        default:
            return format(magnitude / 1_000_000_000, unit: "GB/s")
        }
    }

    private static func format(_ value: Double, unit: String) -> String {
        if value >= 100 {
            return String(format: "%.0f \(unit)", value)
        }
        return String(format: "%.1f \(unit)", value)
    }
}
