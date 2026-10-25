import Foundation
import os
import PrizmXConfig
import PrizmXCore

/// Mixed-port attribution for the app. `local` reads the app's own view of
/// the socket table, which cannot see root / system-account processes
/// (cloudd, apsd, trustd …). While TUN is on, the root Packet Tunnel can: the
/// app asks it over XPC (`TunnelXPCService`) and `attributeLate` answers the
/// flows `local` missed from its reply.
public final class TunnelAssistedAttributor: FlowAttributing, @unchecked Sendable {
    private let local: any FlowAttributing
    private let fetch: @Sendable () async -> [LoopbackClient]?
    /// The latest request and when it began. The tunnel reads its socket
    /// table after the request arrives, so its reply lists every socket
    /// opened before that time; a lookup that began earlier can share it.
    private let latest = OSAllocatedUnfairLock<(began: Date, reply: Task<[LoopbackClient]?, Never>)?>(
        initialState: nil
    )

    public convenience init(local: any FlowAttributing) {
        #if os(macOS)
        self.init(local: local, fetch: { await TunnelXPCClient.shared.fetchProxyClients() })
        #else
        self.init(local: local, fetch: { nil })
        #endif
    }

    init(local: any FlowAttributing, fetch: @escaping @Sendable () async -> [LoopbackClient]?) {
        self.local = local
        self.fetch = fetch
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

    /// Asks the tunnel who owns the socket. `since` is when the first lookup
    /// ran; the reply used began no earlier, so it surely holds the socket if
    /// it is still open. nil: the tunnel is not running, or has no such client.
    public func attributeLate(
        transport: FlowTransport,
        localPort: UInt16,
        remotePort: UInt16,
        since: Date
    ) async -> FlowAttribution? {
        guard transport == .tcp else { return nil }
        let clients = await reply(since: since).value
        return clients?.first { $0.clientPort == localPort && $0.listenPort == remotePort }?.attribution
    }

    private func reply(since: Date) -> Task<[LoopbackClient]?, Never> {
        latest.withLock { current in
            if let current, current.began >= since { return current.reply }
            let fetch = self.fetch
            let reply = Task { await fetch() }
            current = (Date(), reply)
            return reply
        }
    }
}
