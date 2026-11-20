import Foundation

/// Status of cross-device profile synchronization (macOS <-> iOS).
public enum ProfileSyncStatus: Sendable, Equatable {
    case notConfigured
    case idle(lastSyncedAt: Date?)
    case syncing
    case failed(String)

    public var summary: String {
        switch self {
        case .notConfigured:
            "Not configured (reserved for iCloud)"
        case .idle(let date):
            if let date {
                "Synced \(date.formatted(.relative(presentation: .named)))"
            } else {
                "Ready"
            }
        case .syncing:
            "Syncing…"
        case .failed(let message):
            message
        }
    }
}

/// Extension point for future iCloud Documents / CloudKit synchronization
/// shared across macOS and iOS hosts.
@MainActor
public protocol ProfileSyncProvider: AnyObject {
    var status: ProfileSyncStatus { get }
    var isAvailable: Bool { get }
    func syncNow(store: ProfileStore) async
}

/// Default placeholder used until iCloud entitlements are enabled.
@MainActor
public final class UnconfiguredProfileSyncProvider: ProfileSyncProvider {
    public static let shared = UnconfiguredProfileSyncProvider()

    public let status: ProfileSyncStatus = .notConfigured
    public let isAvailable: Bool = false

    private init() {}

    public func syncNow(store: ProfileStore) async {}
}
