import Foundation

/// Snapshot of tunnel throughput, exchanged over PacketTunnel IPC.
public struct VPNMetrics: Sendable, Hashable, Codable, Equatable {
    /// Instantaneous uplink rate in bytes / second.
    public var uploadBytesPerSecond: Double
    /// Instantaneous downlink rate in bytes / second.
    public var downloadBytesPerSecond: Double
    /// Cumulative bytes sent since the tunnel started.
    public var uplinkBytes: UInt64
    /// Cumulative bytes received since the tunnel started.
    public var downlinkBytes: UInt64
    /// Live TCP/UDP flows currently tracked by the provider.
    public var activeConnections: Int

    public init(
        uploadBytesPerSecond: Double = 0,
        downloadBytesPerSecond: Double = 0,
        uplinkBytes: UInt64 = 0,
        downlinkBytes: UInt64 = 0,
        activeConnections: Int = 0
    ) {
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uplinkBytes = uplinkBytes
        self.downlinkBytes = downlinkBytes
        self.activeConnections = activeConnections
    }

    public static let zero = VPNMetrics()

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uploadBytesPerSecond = try container.decodeIfPresent(Double.self, forKey: .uploadBytesPerSecond) ?? 0
        downloadBytesPerSecond = try container.decodeIfPresent(Double.self, forKey: .downloadBytesPerSecond) ?? 0
        uplinkBytes = try container.decodeIfPresent(UInt64.self, forKey: .uplinkBytes) ?? 0
        downlinkBytes = try container.decodeIfPresent(UInt64.self, forKey: .downlinkBytes) ?? 0
        activeConnections = try container.decodeIfPresent(Int.self, forKey: .activeConnections) ?? 0
    }
}

/// Failures raised by `VPNManager` when talking to NetworkExtension.
public enum VPNError: Error, Sendable, Equatable {
    case notConfigured
    case startFailed(String)
    case ipcUnavailable
    case ipcFailed(String)
}
