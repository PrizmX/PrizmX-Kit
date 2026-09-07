import Foundation
import os
import PrizmXConfig
import PrizmXCore
import PrizmXProtocols

#if os(macOS)

/// Mixed-port + system proxy, owned by the **main app**.
///
/// Clash/Surge keep HTTP/SOCKS on the core process, not inside a Packet
/// Tunnel. A dummy VPN just to host mixed-port steals the default route
/// when TUN is off, so Safari cannot reach the internet.
public final class SystemProxyRuntime: @unchecked Sendable {
    private struct State {
        var engine: Engine?
        var server: MixedPortServer?
        var signature: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func apply(
        configText: String,
        overlay: ProfileOverlay,
        allowLAN: Bool
    ) async throws {
        let signature = Self.signature(configText: configText, overlay: overlay, allowLAN: allowLAN)
        let alreadyRunning = state.withLock {
            $0.signature == signature && $0.server != nil
        }
        if alreadyRunning {
            SystemProxyConfigurator.apply()
            return
        }
        try await startServer(
            configText: configText,
            overlay: overlay,
            allowLAN: allowLAN,
            signature: signature
        )
        SystemProxyConfigurator.apply()
    }

    public func shutdown() {
        SystemProxyConfigurator.restore()
        stopServer()
    }

    /// Drop the listener without touching System Configuration (config reload).
    public func invalidate() {
        stopServer()
    }

    private func startServer(
        configText: String,
        overlay: ProfileOverlay,
        allowLAN: Bool,
        signature: String
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
            dnsPersistenceURL: nil
        )
        engine.startURLTest()
        let server = MixedPortServer(
            engine: engine,
            port: UInt16(clamping: TunnelProviderKeys.defaultMixedPort),
            allowLAN: allowLAN
        )
        try await server.start()
        state.withLock {
            $0.engine = engine
            $0.server = server
            $0.signature = signature
        }
        TunnelLog.write(.info, "system proxy mixed-port ready")
    }

    private func stopServer() {
        let snapshot = state.withLock { current -> (MixedPortServer?, Engine?) in
            let pair = (current.server, current.engine)
            current = State()
            return pair
        }
        snapshot.0?.stop()
        snapshot.1?.stopURLTest()
    }

    private static func signature(
        configText: String,
        overlay: ProfileOverlay,
        allowLAN: Bool
    ) -> String {
        let overlayBlob = (try? JSONEncoder().encode(overlay)) ?? Data()
        return "\(allowLAN)|\(configText.utf8.count)|\(configText.hashValue)|\(overlayBlob.hashValue)"
    }
}

#else

public final class SystemProxyRuntime: @unchecked Sendable {
    public init() {}

    public func apply(
        configText: String,
        overlay: ProfileOverlay,
        allowLAN: Bool
    ) async throws {
        _ = configText
        _ = overlay
        _ = allowLAN
    }

    public func shutdown() {}
    public func invalidate() {}
}

#endif
