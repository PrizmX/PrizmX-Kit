import Foundation

/// Formats a byte rate as a short UI string (`"1.2 MB/s"`).
public enum ByteRateFormatter: Sendable {
    public static func string(fromBytesPerSecond bytesPerSecond: Double) -> String {
        let parts = Self.parts(fromBytesPerSecond: bytesPerSecond)
        return "\(parts.value) \(parts.unit)"
    }

    public static func parts(fromBytesPerSecond bytesPerSecond: Double) -> (value: String, unit: String) {
        let magnitude = max(0, bytesPerSecond)
        switch magnitude {
        case ..<1_000:
            return ("\(Int(magnitude.rounded()))", "B/s")
        case ..<1_000_000:
            return (format(magnitude / 1_000), "KB/s")
        case ..<1_000_000_000:
            return (format(magnitude / 1_000_000), "MB/s")
        default:
            return (format(magnitude / 1_000_000_000), "GB/s")
        }
    }

    private static func format(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    /// Byte-count form, e.g. `551 MB`.
    public static func byteCount(_ bytes: UInt64) -> String {
        let parts = Self.parts(bytes)
        return "\(parts.value) \(parts.unit)"
    }

    public static func parts(_ bytes: UInt64) -> (value: String, unit: String) {
        let magnitude = Double(bytes)
        switch magnitude {
        case ..<1_000:
            return ("\(bytes)", "B")
        case ..<1_000_000:
            return (format(magnitude / 1_000), "KB")
        case ..<1_000_000_000:
            return (format(magnitude / 1_000_000), "MB")
        default:
            return (format(magnitude / 1_000_000_000), "GB")
        }
    }
}
