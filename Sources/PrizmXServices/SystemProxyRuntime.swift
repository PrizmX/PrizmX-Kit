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
///
/// Every `apply` / `shutdown` bumps a generation. An apply only touches
/// listeners or System Configuration while it is still the latest request,
/// so a slow apply can never undo a later shutdown. A failed apply restores
/// the system proxy (fail closed) instead of leaving macOS pointed at a
/// port nobody listens on.
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

    /// System Configuration side effects; injectable so tests never touch
    /// the real network preferences.
    struct SystemProxyControl: Sendable {
        var apply: @Sendable (_ host: String, _ httpPort: Int, _ socksPort: Int) -> Void
        var restore: @Sendable () -> Void
        /// Test seam standing in for a slow `GeoAssetStore.prepare`.
        var afterPrepare: @Sendable () async -> Void = {}

        static let live = SystemProxyControl(
            apply: { SystemProxyConfigurator.apply(host: $0, httpPort: $1, socksPort: $2) },
            restore: { SystemProxyConfigurator.restore() }
        )
    }

    private struct State {
        var engine: Engine?
        var servers: [MixedPortServer] = []
        var signature: Signature?
        /// Serializes `apply`: concurrent calls (e.g. rapid config switching)
        /// would otherwise each start a server, and last-writer-wins state
        /// would leak the loser's listener. Survives `stopServer`.
        var applyChain: Task<Void, Error>?
        /// Latest apply/shutdown request. Older applies become no-ops.
        var generation: UInt64 = 0
        /// Bumped by `invalidate` so an in-flight apply does not record a
        /// signature the caller asked to rebuild.
        var invalidation: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Orders generation checks against System Configuration writes, so a
    /// stale apply cannot re-enable the proxy after `shutdown` restored it.
    /// Not the unfair lock: the configurator may block on authorization.
    private let proxyGate = NSLock()
    private let systemProxy: SystemProxyControl
    #if canImport(PrizmXAttribution)
    /// The app is a client of its own listener too (External IP lookup and
    /// other URLSession requests follow the system proxy). Root / system
    /// account clients come from the Packet Tunnel's view, while it runs.
    private let flowAttributor: (any FlowAttributing)? = TunnelAssistedAttributor(
        local: ProcessFlowAttributor(includesOwnProcess: true)
    )
    #else
    private let flowAttributor: (any FlowAttributing)? = nil
    #endif

    public convenience init() {
        self.init(systemProxy: .live)
    }

    init(systemProxy: SystemProxyControl) {
        self.systemProxy = systemProxy
    }

    /// True while mixed-port listeners are up.
    public var isRunning: Bool {
        state.withLock { !$0.servers.isEmpty }
    }

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
            current.generation &+= 1
            let generation = current.generation
            let previous = current.applyChain
            let task = Task { [weak self] in
                // Wait out the in-flight apply; its failure must not block us.
                _ = try? await previous?.value
                try await self?.performApply(
                    configText: configText,
                    overlay: overlay,
                    allowLAN: allowLAN,
                    setSystemProxy: setSystemProxy,
                    signature: signature,
                    generation: generation
                )
            }
            current.applyChain = task
            return task
        }
        try await task.value
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { $0.generation == generation }
    }

    private func performApply(
        configText: String,
        overlay: ProfileOverlay,
        allowLAN: Bool,
        setSystemProxy: Bool,
        signature: Signature,
        generation: UInt64
    ) async throws {
        // Superseded while queued: the newer request owns servers and proxy.
        guard isCurrent(generation) else { return }
        let alreadyRunning = state.withLock {
            $0.signature == signature && !$0.servers.isEmpty
        }
        if alreadyRunning {
            applySystemProxy(setSystemProxy, listen: signature.listen, generation: generation)
            return
        }
        do {
            let installed = try await startServer(
                configText: configText,
                overlay: overlay,
                allowLAN: allowLAN,
                signature: signature,
                generation: generation
            )
            guard installed else { return }
        } catch {
            // A superseded request's failure is moot; the newer one decides.
            guard isCurrent(generation) else { return }
            // Fail closed: the old listener is gone, so a system proxy still
            // pointing at it would take the whole machine offline.
            restoreSystemProxy(ifCurrent: generation)
            throw error
        }
        applySystemProxy(setSystemProxy, listen: signature.listen, generation: generation)
    }

    /// System proxy always targets loopback, even when inbound binds 0.0.0.0.
    private func applySystemProxy(_ on: Bool, listen: InboundListenConfig, generation: UInt64) {
        proxyGate.lock()
        defer { proxyGate.unlock() }
        guard isCurrent(generation) else { return }
        if on {
            systemProxy.apply(
                "127.0.0.1",
                Int(listen.systemProxyHTTPPort),
                Int(listen.systemProxySOCKSPort)
            )
        } else {
            systemProxy.restore()
        }
    }

    private func restoreSystemProxy(ifCurrent generation: UInt64?) {
        proxyGate.lock()
        defer { proxyGate.unlock() }
        if let generation, !isCurrent(generation) { return }
        systemProxy.restore()
    }

    /// Restores System Configuration and stops listeners. Supersedes any
    /// in-flight apply, which tears down whatever it started.
    public func shutdown() {
        state.withLock { $0.generation &+= 1 }
        restoreSystemProxy(ifCurrent: nil)
        stopServer()
    }

    /// Forces the next `apply` to rebuild the engine (config reload). The
    /// current listener keeps serving until then, so the system proxy never
    /// points at a dead port in between; a failed rebuild restores it.
    public func invalidate() {
        state.withLock {
            $0.signature = nil
            $0.invalidation &+= 1
        }
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

    /// Returns false when a newer request superseded this one; anything it
    /// started has been torn down again.
    private func startServer(
        configText: String,
        overlay: ProfileOverlay,
        allowLAN: Bool,
        signature: Signature,
        generation: UInt64
    ) async throws -> Bool {
        let invalidation = state.withLock { $0.invalidation }
        stopServer()
        let (router, _) = try ConfigAdapter.parse(rawString: configText, overlay: overlay)
        let needsGeoIP = router.rules.contains { if case .geoIP = $0.matcher { return true }; return false }
        let needsGeosite = router.rules.contains { if case .geosite = $0.matcher { return true }; return false }
        let assets = await GeoAssetStore.prepare(geoIP: needsGeoIP, geosite: needsGeosite)
        await systemProxy.afterPrepare()
        guard isCurrent(generation) else { return false }
        let capturedDNS = PhysicalDNSSnapshot.capture()
        Task {
            _ = await NodeAddressStore.refresh(configText: configText, nameservers: capturedDNS)
        }
        // Pins refresh in the background, so the file still holds the last
        // session's answers. Following the profile's DNS, the engine asks the
        // profile itself instead of dialing those first.
        let pins = NodeAddressStore.followsProfileDNS(configText: configText) ? [:] : NodeAddressStore.load()
        let engine = try EngineFactory.make(
            configText: configText,
            geoIPURL: GeoAssetStore.resolve(assets.geoIPPath),
            geositeURL: GeoAssetStore.resolve(assets.geositePath),
            systemDNS: capturedDNS,
            pinnedNodeAddresses: pins,
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
                    accept: socket.accept,
                    authentication: signature.listen.authentication.map { "\($0.username):\($0.password)" },
                    skipAuthPrefixes: signature.listen.skipAuthPrefixes
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
        // Install atomically with the generation check: a shutdown either
        // happened before (we tear down) or will stop what we install.
        let installed = state.withLock { current -> Bool in
            guard current.generation == generation else { return false }
            current.engine = engine
            current.servers = servers
            current.signature = current.invalidation == invalidation ? signature : nil
            return true
        }
        guard installed else {
            servers.forEach { $0.stop() }
            engine.stopURLTest()
            return false
        }
        TunnelLog.write(.info, "inbound ready lan=\(allowLAN)")
        return true
    }

    /// Stops listeners and drops the engine. Keeps `applyChain` and the
    /// generation so serialization survives restarts.
    private func stopServer() {
        let snapshot = state.withLock { current -> ([MixedPortServer], Engine?) in
            let pair = (current.servers, current.engine)
            current.servers = []
            current.engine = nil
            current.signature = nil
            return pair
        }
        snapshot.0.forEach { $0.stop() }
        snapshot.1?.stopURLTest()
    }
}

#else

public final class SystemProxyRuntime: @unchecked Sendable {
    public init() {}

    public var isRunning: Bool { false }

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
