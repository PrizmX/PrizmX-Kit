import Foundation

/// High-level tunnel lifecycle shown by host UIs.
///
/// Mapped from `NEVPNStatus` inside `VPNManager`; kept as a Kit type so
/// ViewModels and SwiftUI controls do not import NetworkExtension.
public enum VPNStatus: String, Sendable, Hashable, CaseIterable, Codable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reconnecting
    case disconnecting
    case error

    /// Traffic is flowing (or about to).
    public var isSessionActive: Bool {
        switch self {
        case .connecting, .connected, .reconnecting:
            return true
        case .invalid, .disconnected, .disconnecting, .error:
            return false
        }
    }

    /// A toggle should currently mean "disconnect".
    public var isConnectedOrTransitioningOn: Bool {
        switch self {
        case .connecting, .connected, .reconnecting, .disconnecting:
            return true
        case .invalid, .disconnected, .error:
            return false
        }
    }

    /// Semantic color bucket for status dots (green / yellow / red).
    public var signal: VPNStatusSignal {
        switch self {
        case .connected:
            return .good
        case .connecting, .reconnecting, .disconnecting:
            return .pending
        case .invalid, .disconnected, .error:
            return .bad
        }
    }
}

/// Traffic-light grouping used by `StatusDotView`.
public enum VPNStatusSignal: Sendable, Hashable {
    case good
    case pending
    case bad
}
