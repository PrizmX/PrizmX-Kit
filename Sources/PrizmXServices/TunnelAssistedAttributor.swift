import Foundation
import os
import PrizmXConfig
import PrizmXCore

/// Mixed-port attribution for the sandboxed app. `local` reads the app's own
/// view of the socket table, which cannot see root / system-account
/// processes (cloudd, apsd, trustd …). While TUN is on, the root Packet
/// Tunnel publishes the listeners' clients each second (`ProxyClientStore`),
/// and `attributeLate` answers those flows from it a moment later.
public final class TunnelAssistedAttributor: FlowAttributing, @unchecked Sendable {
    public static let pollInterval: Duration = .milliseconds(250)
    /// One missed write on top of the 1s cadence.
    public static let maxWait: Duration = .milliseconds(2_500)

    private let local: any FlowAttributing
    private let load: @Sendable () -> ProxyClientStore.Snapshot?
    /// Pending lookups share one file read per poll interval.
    private let cache = OSAllocatedUnfairLock<(at: ContinuousClock.Instant, snapshot: ProxyClientStore.Snapshot?)?>(
        initialState: nil
    )

    public convenience init(local: any FlowAttributing) {
        self.init(local: local, load: { ProxyClientStore.load() })
    }

    init(local: any FlowAttributing, load: @escaping @Sendable () -> ProxyClientStore.Snapshot?) {
        self.local = local
        self.load = load
    }

    public func attribute(
        transport: FlowTransport,
        localAddress: String,
        localPort: UInt16,
        remoteAddress: String,
        remotePort: UInt16
    ) -> FlowAttribution? {
        local.attribute(
            transport: transport,
            localAddress: localAddress,
            localPort: localPort,
            remoteAddress: remoteAddress,
            remotePort: remotePort
        )
    }

    /// Waits for a snapshot written after `since` (one that surely lists the
    /// socket if it is still open). No fresh file: the tunnel is not running.
    public func attributeLate(
        transport: FlowTransport,
        localPort: UInt16,
        remotePort: UInt16,
        since: Date
    ) async -> FlowAttribution? {
        guard transport == .tcp else { return nil }
        let deadline = ContinuousClock.now + Self.maxWait
        while true {
            guard let snapshot = currentSnapshot() else { return nil }
            if snapshot.writtenAt >= since.timeIntervalSince1970 {
                return snapshot.client(port: localPort, listenPort: remotePort)?.attribution
            }
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func currentSnapshot() -> ProxyClientStore.Snapshot? {
        let now = ContinuousClock.now
        if let hit = cache.withLock({ $0 }), hit.at.duration(to: now) < Self.pollInterval {
            return hit.snapshot
        }
        let snapshot = load()
        cache.withLock { $0 = (now, snapshot) }
        return snapshot
    }
}
