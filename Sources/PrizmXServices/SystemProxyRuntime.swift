import Foundation
import os
import PrizmXConfig
import PrizmXCore
import PrizmXProtocols
#if canImport(PrizmXAttribution)
import PrizmXAttribution
#endif

#if os(macOS)

/// Mixed-port + system proxy, owned by the **main app**.
///
/// Clash/Surge keep HTTP/SOCKS on the core process, not inside a Packet
/// Tunnel. A dummy VPN just to host mixed-port steals the default route
/// when TUN is off, so Safari cannot reach the internet.
public final class SystemProxyRuntime: @unchecked Sendable {
    /// Full-value signature for "already running this config" equality.
    /// (Previously `hashValue`, which is not collision-free and can skip a
    /// required restart.)
    private struct Signature: Equatable {
        var configText: String
        var overlayBlob: Data
        var allowLAN: Bool
        var listen: InboundListenConfig
    }

    private struct State {
        var engine: Engine?
        var servers: [MixedPortServer] = []
        var signature: Signature?
        /// Serializes `apply`: concurrent calls (e.g. rapid config switching)
        /// would otherwise each start a server, and last-writer-wins state
        /// would leak the loser's listener.
        var applyChain: Task<Void, Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    #if canImport(PrizmXAttribution)
    private let flowAttributor: (any FlowAttributing)? = ProcessFlowAttributor()
    #else
    private let flowAttributor: (any FlowAttributing)? = nil
    #endif

    public init() {}

    public func apply(
        configText: String,
        overlay: ProfileOverlay,
        allowLAN: Bool,
        setSystemProxy: Bool
    ) async throws {
        let signature = Signature(
            configText: configText,
            overlayBlob: (try? JSONEncoder().encode(overlay)) ?? Data(),
            allowLAN: allowLAN,
            listen: InboundListenConfig.parse(from: configText)
        )
        let task: Task<Void, Error> = state.withLock { current in
            let previous = current.applyChain
            let task = Task { [weak self] in
                // Wait out the in-flight apply; its failure must not block us.
                _ = try? await previous?.value
                try await self?.performApply(
                    configText: configText,
                    overlay: overlay,
                    allowLAN: allowLAN,
                    setSystemProxy: setSystemProxy,
                    signature: signature
                )
            }
            current.applyChain = task
            return task
        }
        try await task.value
    }

    private func performApply(
        configText: String,
        overlay: ProfileOverlay,
        allowLAN: Bool,
        setSystemProxy: Bool,
        signature: Signature
    ) async throws {
        let alreadyRunning = state.withLock {
            $0.signature == signature && !$0.servers.isEmpty
        }
        if alreadyRunning {
            Self.applySystemProxy(setSystemProxy, listen: signature.listen)
            return
        }
        try await startServer(
            configText: configText,
            overlay: overlay,
            allowLAN: allowLAN,
            signature: signature
        )
        Self.applySystemProxy(setSystemProxy, listen: signature.listen)
    }

    /// System proxy always targets loopback, even when inbound binds 0.0.0.0.
    private static func applySystemProxy(_ on: Bool, listen: InboundListenConfig) {
        if on {
            SystemProxyConfigurator.apply(
                host: "127.0.0.1",
                httpPort: Int(listen.systemProxyHTTPPort),
                socksPort: Int(listen.systemProxySOCKSPort)
            )
        } else {
            SystemProxyConfigurator.restore()
        }
    }

    public func shutdown() {
        SystemProxyConfigurator.restore()
        stopServer()
    }

    /// Drop the listener without touching System Configuration (config reload).
    public func invalidate() {
        stopServer()
    }

    /// Re-apply persisted node selections and outbound mode to the live
    /// mixed-port engine. `notifySelectedNode` only IPCs the Packet Tunnel —
    /// without this, System-Proxy-only traffic keeps the old node forever.
    public func reloadSelections() {
        let selections = PolicySelectionStore.load()
        let stored = OutboundModeStore.load()
        state.withLock {
            $0.engine?.nodeManager.applySelections(selections)
            $0.engine?.setOutboundMode(stored.mode, globalGroup: stored.globalGroup)
        }
    }

    /// Live mixed-port counters. Mutates the engine sample window — call from
    /// the single 1s UI poller only.
    public func metrics() -> TrafficSnapshot {
        state.withLock { $0.engine?.traffic.snapshot() } ?? .zero
    }

    public func clearFlows() {
        state.withLock { $0.engine?.traffic.clearRecent() }
    }

    private func startServer(
        configText: String,
        overlay: ProfileOverlay,
        allowLAN: Bool,
        signature: Signature
    ) async throws {
        stopServer()
        let (router, _) = try ConfigAdapter.parse(rawString: configText, overlay: overlay)
        let needsGeoIP = router.rules.contains { if case .geoIP = $0.matcher { return true }; return false }
        let needsGeosite = router.rules.contains { if case .geosite = $0.matcher { return true }; return false }
        let assets = await GeoAssetStore.prepare(geoIP: needsGeoIP, geosite: needsGeosite)
        let capturedDNS = PhysicalDNSSnapshot.capture()
        Task {
            _ = await NodeAddressStore.refresh(configText: configText, nameservers: capturedDNS)
        }
        let engine = try EngineFactory.make(
            configText: configText,
            geoIPURL: GeoAssetStore.resolve(assets.geoIPPath),
            geositeURL: GeoAssetStore.resolve(assets.geositePath),
            systemDNS: capturedDNS,
            pinnedNodeAddresses: NodeAddressStore.load(),
            overlay: overlay,
            flowAttributor: flowAttributor,
            dnsPersistenceURL: nil
        )
        engine.startURLTest()
        var started: [MixedPortServer] = []
        do {
            for socket in signature.listen.sockets {
                let server = MixedPortServer(
                    engine: engine,
                    port: socket.port,
                    allowLAN: allowLAN,
                    accept: socket.accept
                )
                try await server.start()
                started.append(server)
            }
        } catch {
            started.forEach { $0.stop() }
            engine.stopURLTest()
            throw error
        }
        let servers = started
        state.withLock {
            $0.engine = engine
            $0.servers = servers
            $0.signature = signature
        }
        TunnelLog.write(.info, "inbound ready lan=\(allowLAN)")
    }

    private func stopServer() {
        let snapshot = state.withLock { current -> ([MixedPortServer], Engine?) in
            let pair = (current.servers, current.engine)
            current = State()
            return pair
        }
        snapshot.0.forEach { $0.stop() }
        snapshot.1?.stopURLTest()
    }
}

#else

public final class SystemProxyRuntime: @unchecked Sendable {
    public init() {}

    public func apply(
        configText: String,
        overlay: ProfileOverlay,
        allowLAN: Bool,
        setSystemProxy: Bool
    ) async throws {
        _ = configText
        _ = overlay
        _ = allowLAN
        _ = setSystemProxy
    }

    public func shutdown() {}
    public func invalidate() {}
    public func metrics() -> TrafficSnapshot { .zero }
    public func clearFlows() {}
}

#endif
