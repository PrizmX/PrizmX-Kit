import Foundation
import PrizmXCore

/// Throughput snapshot exchanged over tunnel IPC.
///
/// The canonical definition lives in Foundation (`PrizmXCore.TrafficSnapshot`)
/// so the host app and the network extensions encode/decode the same type.
public typealias VPNMetrics = TrafficSnapshot

/// Per-label byte counts — alias of `PrizmXCore.TrafficByteCount`.
public typealias TrafficByteCount = PrizmXCore.TrafficByteCount

/// Failures raised by `VPNManager` when talking to NetworkExtension.
public enum VPNError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured
    case startFailed(String)
    case ipcFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "VPN is not configured"
        case .startFailed(let message): message
        case .ipcFailed(let message): message
        }
    }
}
