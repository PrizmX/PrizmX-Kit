import Foundation
import NetworkExtension
import Observation
import PrizmXConfig
import PrizmXCore
import PrizmXProtocols

/// Observable bridge to `NEPacketTunnelProvider`.
///
/// Host apps should use `VPNManager.shared` for the live Packet Tunnel
/// session. SwiftUI Previews and tests pass `isMock: true` so the same
/// ViewModels can run without a network-extension process.
@MainActor
@Observable
public final class VPNManager {
    /// How the host reads Packet Tunnel counters. The app chooses this from
    /// its packaging; Kit does not infer Developer ID vs Debug vs MAS.
    public enum MetricsChannel: Sendable, Equatable {
        /// `NETunnelProviderSession.sendProviderMessage`.
        case providerMessage
        /// Packet Tunnel writes `tunnel/metrics.json` under the kit root.
        case kitFile
        /// XPC to the system extension (`TunnelXPC`), falling back to the
        /// kit file while the extension cannot be reached. macOS only.
        case xpc
    }

    public struct Configuration: Sendable, Equatable {
        /// Packet tunnel network-extension bundle identifier.
        public var providerBundleIdentifier: String
        public var localizedDescription: String
        public var serverAddress: String
        public var metricsChannel: MetricsChannel

        public init(
            providerBundleIdentifier: String,
            localizedDescription: String = "PrizmX",
            serverAddress: String = "PrizmX",
            metricsChannel: MetricsChannel = .providerMessage
        ) {
            self.providerBundleIdentifier = providerBundleIdentifier
            self.localizedDescription = localizedDescription
            self.serverAddress = serverAddress
            self.metricsChannel = metricsChannel
        }

        public static var `default`: Configuration {
            let host = Bundle.main.bundleIdentifier ?? "app.prizmx.macos"
            return Configuration(providerBundleIdentifier: "\(host).packet-tunnel")
        }
    }

    /// Host apps assign this before the first `VPNManager.shared` access.
    public static var metricsChannel: MetricsChannel = .providerMessage

    public static let shared = VPNManager()
    public static let metricsPollInterval: Duration = .seconds(1)

    public let configuration: Configuration
    public let isMock: Bool

    public private(set) var status: VPNStatus = .invalid
    public private(set) var uploadBytesPerSecond: Double = 0
    public private(set) var downloadBytesPerSecond: Double = 0
    public private(set) var activeConnections: Int = 0
    public private(set) var lastMetrics: VPNMetrics = .zero
    public private(set) var lastError: String?

    /// Host-side failures (system-extension activation, etc.) that happen
    /// before `startVPN` runs.
    public func reportHostError(_ error: Error) {
        lastError = error.localizedDescription
    }

    @ObservationIgnored
    private var tunnelManager: NETunnelProviderManager?
    #if os(macOS)
    @ObservationIgnored
    private let xpcClient = TunnelXPCClient()
    #endif
    @ObservationIgnored
    nonisolated(unsafe) private var statusObserver: NSObjectProtocol?
    @ObservationIgnored
    nonisolated(unsafe) private var metricsTask: Task<Void, Never>?
    /// Follows external state changes (System Settings VPN toggle): true when
    /// the tunnel came up outside the app, false when the user turned it off.
    /// Lets the UI sync its TUN intent instead of fighting the system.
    public var onExternalStateChange: (@MainActor (Bool) -> Void)?

    /// Mixed-port engine lives in the host app (not the system extension).
    /// Polled alongside tunnel IPC so System Proxy traffic still shows in the UI.
    public var localMetricsProvider: (@Sendable () -> TrafficSnapshot)?

    /// Host sets this while its mixed-port listener is up. The metrics poll
    /// only runs while the tunnel or local egress is active.
    @ObservationIgnored
    public var localEgressActive = false {
        didSet {
            guard localEgressActive != oldValue else { return }
            updateMetricsPolling()
        }
    }

    /// True while the 1 Hz metrics poll runs. Consumers (speed history,
    /// traffic ledger) follow it instead of ticking forever.
    public private(set) var isPollingMetrics = false

    /// User intent: startVPN sets it, stopVPN clears it. A disconnect without
    /// stopVPN means the system killed the plugin (rebuild, update, reclaim)
    /// or the user turned the VPN off from System Settings.
    @ObservationIgnored
    private var wantsConnection = false
    @ObservationIgnored
    private var reconnectAttempts = 0
    @ObservationIgnored
    private var reconnectTask: Task<Void, Never>?
    /// Set by `stopVPN`. A trailing stale `.connected` notification right
    /// after an explicit stop must not be "adopted" as an external start.
    @ObservationIgnored
    private var lastStopRequestAt: Date?
    /// True while `startVPN` is waiting for NEVPN `.connected` — blocks reconnect.
    @ObservationIgnored
    private var startingTunnel = false
    /// Config the session runs with, so an auto-reconnect after a live
    /// reload starts with that config instead of the one in the saved
    /// VPN preferences.
    private struct StartArguments {
        var configText: String
        var fakeIP: Bool
        var systemProxy: Bool
        var allowLAN: Bool
        var overlay: ProfileOverlay
    }

    @ObservationIgnored
    private var lastStart: StartArguments?
    @ObservationIgnored
    private var mockUplinkBytes: UInt64 = 0
    @ObservationIgnored
    private var mockDownlinkBytes: UInt64 = 0

    public init(configuration: Configuration = .default, isMock: Bool = false) {
        var configuration = configuration
        if !isMock {
            configuration.metricsChannel = Self.metricsChannel
        }
        self.configuration = configuration
        self.isMock = isMock
        if isMock {
            status = .connected
            apply(metrics: nextMockMetrics())
            startMetricsLoop()
            return
        }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let connection = self.tunnelManager?.connection else { return }
                self.applyVPNStatus(connection.status)
            }
        }
        Task { await loadManager() }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        metricsTask?.cancel()
        reconnectTask?.cancel()
    }

    // MARK: - Preferences

    /// Loads an existing Packet Tunnel preference or creates an unsaved one.
    public func loadManager() async {
        guard !isMock else { return }
        do {
            let existing = try await NETunnelProviderManager.loadAllFromPreferences()
            let bundleID = configuration.providerBundleIdentifier
            if let found = existing.first(where: { manager in
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == bundleID
            }) {
                tunnelManager = found
            } else {
                tunnelManager = NETunnelProviderManager()
            }
            refreshStatus()
        } catch {
            lastError = error.localizedDescription
            status = .error
        }
    }

    /// Writes Clash / sing-box text into `NETunnelProviderProtocol.providerConfiguration`.
    public func configure(
        configText: String,
        fakeIP: Bool = true,
        systemProxy: Bool = false,
        allowLAN: Bool = false,
        mixedPort: Int = TunnelProviderKeys.defaultMixedPort,
        geoIPPath: String? = nil,
        geositePath: String? = nil,
        dnsServers: [String]? = nil,
        overlay: ProfileOverlay = .empty
    ) async throws {
        guard !isMock else { return }
        if tunnelManager == nil { await loadManager() }
        guard let manager = tunnelManager else { throw VPNError.notConfigured }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = configuration.providerBundleIdentifier
        proto.serverAddress = configuration.serverAddress
        proto.providerConfiguration = try await makeProviderPayload(
            configText: configText,
            fakeIP: fakeIP,
            systemProxy: systemProxy,
            allowLAN: allowLAN,
            mixedPort: mixedPort,
            geoIPPath: geoIPPath,
            geositePath: geositePath,
            dnsServers: dnsServers,
            overlay: overlay
        )

        manager.localizedDescription = configuration.localizedDescription
        manager.protocolConfiguration = proto
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        tunnelManager = manager
        refreshStatus()
    }

    /// Stages the config, overlay, geo assets and node pins the extension
    /// reads, and returns the `providerConfiguration` that points at them.
    private func makeProviderPayload(
        configText: String,
        fakeIP: Bool,
        systemProxy: Bool,
        allowLAN: Bool,
        mixedPort: Int,
        geoIPPath: String?,
        geositePath: String?,
        dnsServers: [String]?,
        overlay: ProfileOverlay
    ) async throws -> [String: Any] {
        // Rule / proxy providers the profile names, downloaded here: the
        // extension only reads them from the kit.
        await ProviderStore.prepare(configText: configText)
        // Config lives in the App Group; the NE profile only stores its path
        // (profiles are limited to 512 KB). Validate first so a bad config
        // (e.g. a subscription error page) never reaches the tunnel.
        let (router, _) = try ConfigAdapter.parse(rawString: configText, overlay: overlay)
        let matchers = router.rules.flatMap(\.matcher.flattened)
        // The DNS section can need them too (fallback-filter, geosite: keys).
        let dnsSection = ClashDNSSection.parse(from: configText)
        let needsGeoIP = matchers.contains { switch $0 { case .geoIP, .srcGeoIP: true; default: false } }
            || dnsSection?.usesGeoIP == true
        let needsGeosite = matchers.contains { if case .geosite = $0 { return true }; return false }
            || dnsSection?.geositeTags.isEmpty == false
        let needsASN = matchers.contains { switch $0 { case .ipASN, .srcIPASN: true; default: false } }
        let assets = await GeoAssetStore.prepare(geoIP: needsGeoIP, geosite: needsGeosite, asn: needsASN)
        let configPath = try TunnelConfigStorage.write(configText: configText)
        let overlayPath = overlay.isEmpty
            ? nil
            : try ProfileOverlayStore.write(overlay)
        // Resolve node hostnames in the app (system DNS / 114). The extension
        // cannot: FakeDNS owns getaddrinfo there. Like Clash/Surge this must
        // NOT block startup — pins refresh in the background and land well
        // before the extension's cold-spawn bootstrap reads them; a stale pin
        // is healed by the extension's last-resort re-resolution at dial time.
        let capturedDNS = dnsServers ?? PhysicalDNSSnapshot.capture()
        // Resolve before the tunnel hijacks system DNS, or node pins become
        // FakeIP (198.18.0.0/16) and outbound dials connection-refused.
        _ = await NodeAddressStore.refresh(
            configText: configText,
            nameservers: capturedDNS
        )
        guard let kit = TunnelConfigStorage.containerURL() else {
            throw TunnelConfigStorageError.appGroupUnavailable
        }
        TunnelLog.write(
            .info,
            "configure wrote \(configPath) bytes=\(configText.utf8.count) appDNS=\(capturedDNS) kit=\(kit.path)"
        )
        var payload: [String: Any] = [
            TunnelProviderKeys.configPath: configPath,
            TunnelProviderKeys.containerPath: kit.path,
            TunnelProviderKeys.fakeIP: fakeIP,
            TunnelProviderKeys.systemProxy: systemProxy,
            TunnelProviderKeys.allowLAN: allowLAN,
            TunnelProviderKeys.mixedPort: mixedPort,
            TunnelProviderKeys.dnsServers: capturedDNS
        ]
        if let path = geoIPPath ?? assets.geoIPPath {
            payload[TunnelProviderKeys.geoIPPath] = path
        }
        if let path = geositePath ?? assets.geositePath {
            payload[TunnelProviderKeys.geositePath] = path
        }
        if let path = assets.asnPath {
            payload[TunnelProviderKeys.asnPath] = path
        }
        if let overlayPath {
            payload[TunnelProviderKeys.overlayPath] = overlayPath
        }
        return payload
    }

    /// Applies a new config to the connected tunnel without restarting it:
    /// open flows and FakeIP mappings survive, new flows use the new rules.
    /// Throws when the tunnel is not connected, refuses (e.g. FakeIP / IPv6
    /// changed) or does not answer in time; the caller then restarts it.
    public func reloadConfiguration(
        configText: String,
        fakeIP: Bool = true,
        systemProxy: Bool = false,
        allowLAN: Bool = false,
        overlay: ProfileOverlay = .empty
    ) async throws {
        guard !isMock else { return }
        guard status == .connected,
              let session = tunnelManager?.connection as? NETunnelProviderSession
        else {
            throw VPNError.reloadFailed("tunnel is not connected")
        }
        let payload = try await makeProviderPayload(
            configText: configText,
            fakeIP: fakeIP,
            systemProxy: systemProxy,
            allowLAN: allowLAN,
            mixedPort: TunnelProviderKeys.defaultMixedPort,
            geoIPPath: nil,
            geositePath: nil,
            dnsServers: nil,
            overlay: overlay
        )
        // Staging takes a while (providers, node addresses); a newer request
        // may have superseded this one meanwhile.
        try Task.checkCancellation()
        let plist = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        let request = try TunnelIPC.encode(.init(method: .reloadConfig, providerConfiguration: plist))
        let response = try await Self.sendRequest(request, over: session, timeout: .seconds(5))
        guard response.ok else {
            throw VPNError.reloadFailed(response.error ?? "tunnel refused the reload")
        }
        lastStart = StartArguments(
            configText: configText,
            fakeIP: fakeIP,
            systemProxy: systemProxy,
            allowLAN: allowLAN,
            overlay: overlay
        )
        TunnelLog.write(.info, "vpn config reloaded in place")
    }

    /// `sendProviderMessage` with a deadline: a provider that never answers
    /// (old build, IPC hiccup) must not hang the caller.
    private static func sendRequest(
        _ data: Data,
        over session: NETunnelProviderSession,
        timeout: Duration
    ) async throws -> TunnelIPC.Response {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TunnelIPC.Response, Error>) in
            let once = ReplyOnce(continuation)
            do {
                // NE calls back on its own queue: not main-actor isolated.
                try session.sendProviderMessage(data) { @Sendable reply in
                    once.resume { try TunnelIPC.decodeResponse(from: reply) }
                }
            } catch {
                once.resume { throw error }
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume { throw VPNError.reloadFailed("the tunnel did not answer") }
            }
        }
    }

    // MARK: - Lifecycle

    /// Starts the Packet Tunnel. Pass `configText` to (re)install the profile first.
    public func startVPN(
        configText: String? = nil,
        fakeIP: Bool = true,
        systemProxy: Bool = false,
        allowLAN: Bool = false,
        overlay: ProfileOverlay = .empty
    ) async throws {
        lastError = nil
        if isMock {
            status = .connecting
            try await Task.sleep(for: .milliseconds(250))
            // stopVPN during the simulated handshake must win: don't flip
            // back to .connected after the user asked to disconnect.
            guard !Task.isCancelled, wantsConnection else { return }
            status = .connected
            apply(metrics: nextMockMetrics())
            startMetricsLoop()
            return
        }

        if let configText {
            try await configure(
                configText: configText,
                fakeIP: fakeIP,
                systemProxy: systemProxy,
                allowLAN: allowLAN,
                overlay: overlay
            )
        }
        if tunnelManager == nil { await loadManager() }
        guard let manager = tunnelManager else { throw VPNError.notConfigured }

        var didConfigure = configText != nil
        if manager.protocolConfiguration == nil {
            try await configure(
                configText: Self.defaultDirectConfig,
                fakeIP: fakeIP,
                systemProxy: systemProxy,
                allowLAN: allowLAN,
                overlay: overlay
            )
            didConfigure = true
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        TunnelLifecycleStore.clearStop()
        wantsConnection = true

        if status == .connected {
            await notifyCaptureMode(fakeIP: fakeIP, systemProxy: systemProxy, allowLAN: allowLAN)
            return
        }

        startingTunnel = true
        defer { startingTunnel = false }
        do {
            if !didConfigure {
                try await manager.loadFromPreferences()
            }
            manager.isEnabled = true
            try await manager.saveToPreferences()
            let session = try await Self.reloadSession(
                matching: configuration.providerBundleIdentifier
            )
            tunnelManager = session.manager
            guard session.manager.isEnabled else {
                throw VPNError.startFailed("VPN profile is disabled in System Settings")
            }
            TunnelLog.write(
                .info,
                "vpn start requested enabled=\(session.manager.isEnabled) status=\(session.connection.status.rawValue)"
            )
            var options: [String: NSObject] = [:]
            if let proto = session.manager.protocolConfiguration as? NETunnelProviderProtocol,
               let root = proto.providerConfiguration?[TunnelProviderKeys.containerPath] as? String {
                options[TunnelProviderKeys.containerPath] = root as NSString
            }
            try session.connection.startVPNTunnel(options: options.isEmpty ? nil : options)
            try await waitUntilConnected(timeout: .seconds(15))
            if let configText {
                lastStart = StartArguments(
                    configText: configText,
                    fakeIP: fakeIP,
                    systemProxy: systemProxy,
                    allowLAN: allowLAN,
                    overlay: overlay
                )
            }
            refreshStatus()
            startMetricsLoop()
        } catch is CancellationError {
            wantsConnection = false
            startingTunnel = false
            throw CancellationError()
        } catch let error as VPNError {
            wantsConnection = false
            reconnectTask?.cancel()
            reconnectTask = nil
            lastError = error.localizedDescription
            status = .error
            TunnelLog.write(.error, "vpn start failed: \(error.localizedDescription)")
            throw error
        } catch {
            wantsConnection = false
            reconnectTask?.cancel()
            reconnectTask = nil
            lastError = error.localizedDescription
            status = .error
            TunnelLog.write(.error, "vpn start failed: \(error.localizedDescription)")
            throw VPNError.startFailed(error.localizedDescription)
        }
    }

    public func stopVPN() {
        wantsConnection = false
        // A later external start must not be "reconnected" with this config.
        lastStart = nil
        lastStopRequestAt = Date()
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        if !isMock {
            tunnelManager?.connection.stopVPNTunnel()
            TunnelLog.write(.info, "vpn stop requested")
        }
        if isMock {
            status = .disconnected
            stopMetricsLoop()
            apply(metrics: .zero)
        } else {
            refreshStatus()
        }
    }

    public func refreshStatus() {
        guard !isMock else { return }
        applyVPNStatus(tunnelManager?.connection.status ?? .invalid)
    }

    /// `startVPNTunnel()` returning is not connected — wait for NEVPNStatus.
    /// Do not publish intermediate status here; that would trigger reconnect.
    private func waitUntilConnected(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let vpnStatus = tunnelManager?.connection.status ?? .invalid
            if vpnStatus == .connected {
                applyVPNStatus(vpnStatus)
                return
            }
            if vpnStatus == .invalid {
                throw VPNError.startFailed("VPN profile invalid")
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        let vpnStatus = tunnelManager?.connection.status ?? .invalid
        if vpnStatus == .connected {
            applyVPNStatus(vpnStatus)
            return
        }
        var detail = "Packet Tunnel did not connect (\(Self.statusName(vpnStatus)))"
        if let extra = await lastDisconnectReason() {
            detail += ": \(extra)"
        }
        TunnelLog.write(.error, detail)
        throw VPNError.startFailed(detail)
    }

    private func lastDisconnectReason() async -> String? {
        guard let connection = tunnelManager?.connection else { return nil }
        do {
            try await connection.fetchLastDisconnectError()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func statusName(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: "invalid"
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .reasserting: "reasserting"
        case .disconnecting: "disconnecting"
        @unknown default: "status=\(status.rawValue)"
        }
    }

    private struct ReloadedSession {
        var manager: NETunnelProviderManager
        var connection: NEVPNConnection { manager.connection }
    }

    private static func reloadSession(matching bundleID: String) async throws -> ReloadedSession {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let found = all.first(where: { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == bundleID
        }) else {
            throw VPNError.startFailed("VPN profile missing after save")
        }
        return ReloadedSession(manager: found)
    }

    // MARK: - IPC

    /// Live throughput: Packet Tunnel counters plus in-app mixed-port.
    /// Mixed-port is polled even when the tunnel is down (System Proxy only).
    /// Channel is chosen by the host app (`Configuration.metricsChannel`).
    /// Runs every second, so the file read, JSON decode, mixed-port snapshot
    /// and merge run off the main actor; each call snapshots local once.
    public func fetchMetrics() async -> VPNMetrics {
        if isMock {
            return status == .connected ? nextMockMetrics() : .zero
        }
        let provider = localMetricsProvider
        guard status == .connected else {
            return await Self.offMain { provider?() ?? .zero }
        }
        if configuration.metricsChannel != .providerMessage {
            let local = await Self.offMain { provider?() ?? .zero }
            #if os(macOS)
            if configuration.metricsChannel == .xpc, let remote = await xpcClient.fetchMetrics() {
                return remote.merging(local)
            }
            #endif
            return await Self.offMain { TunnelMetricsStore.load()?.merging(local) ?? local }
        }
        let local = await Self.offMain { provider?() ?? .zero }
        guard let session = tunnelManager?.connection as? NETunnelProviderSession else {
            return local
        }

        let payload: Data
        do {
            payload = try TunnelIPC.encode(.init(method: .fetchMetrics))
        } catch {
            lastError = error.localizedDescription
            return local
        }

        do {
            let responseData: Data? = try await withCheckedThrowingContinuation { continuation in
                do {
                    try session.sendProviderMessage(payload) { data in
                        continuation.resume(returning: data)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            return try await Self.offMain { try TunnelIPC.metrics(from: responseData).merging(local) }
        } catch {
            // Provider may not have registered IPC yet; keep mixed-port alive.
            return local
        }
    }

    @concurrent
    nonisolated private static func offMain<T: Sendable>(
        _ work: @Sendable () throws -> T
    ) async rethrows -> T {
        try work()
    }

    /// Notifies a running tunnel that the selected outbound changed.
    public func notifySelectedNode(id nodeID: String, groupName: String?) async {
        if !isMock, let groupName {
            let mode = OutboundModeStore.load().mode
            OutboundModeStore.save(mode: mode, globalGroup: groupName)
        }
        guard !isMock, status == .connected else { return }
        guard let session = tunnelManager?.connection as? NETunnelProviderSession else { return }
        guard let payload = try? TunnelIPC.encode(
            .init(method: .selectNode, nodeID: nodeID, groupName: groupName)
        ) else { return }
        try? session.sendProviderMessage(payload) { _ in }
    }

    /// Rule / Global / Direct. No-op when the session is down; the next start
    /// reads `OutboundModeStore`.
    public func notifyOutboundMode(_ modeRawValue: String, globalGroup: String?) async {
        guard let mode = OutboundMode(rawValue: modeRawValue) else { return }
        guard !isMock else { return }
        OutboundModeStore.save(mode: mode, globalGroup: globalGroup)
        guard status == .connected else { return }
        guard let session = tunnelManager?.connection as? NETunnelProviderSession else { return }
        guard let payload = try? TunnelIPC.encode(
            .init(method: .setOutboundMode, groupName: globalGroup, outboundMode: mode.rawValue)
        ) else { return }
        try? session.sendProviderMessage(payload) { _ in }
    }

    public func clearFlows() async {
        if isMock {
            var snapshot = lastMetrics
            snapshot.recentFlows = []
            lastMetrics = snapshot
            return
        }
        guard status == .connected else { return }
        guard let session = tunnelManager?.connection as? NETunnelProviderSession else { return }
        guard let payload = try? TunnelIPC.encode(TunnelIPC.Request(method: .clearFlows)) else { return }
        try? session.sendProviderMessage(payload) { _ in }
    }

    public func notifyCaptureMode(fakeIP: Bool, systemProxy: Bool, allowLAN: Bool = false) async {
        guard !isMock, status == .connected else { return }
        guard let session = tunnelManager?.connection as? NETunnelProviderSession else { return }
        guard let payload = try? TunnelIPC.encode(
            TunnelIPC.Request(
                method: .setCaptureMode,
                fakeIP: fakeIP,
                systemProxy: systemProxy,
                allowLAN: allowLAN
            )
        ) else { return }
        try? session.sendProviderMessage(payload) { _ in }
    }

    /// Clash YAML that sends everything DIRECT — used when no profile is active.
    public static let defaultDirectConfig = """
    proxies: []
    proxy-groups: []
    rules:
      - MATCH,DIRECT
    """
}

extension VPNManager {
    /// Reconnects the 1s metrics poll when NEVPN comes back to `.connected`,
    /// and tears it down as soon as the session drops. When the session dies
    /// without `stopVPN`, fetch the stop reason first: `.userInitiated` (the
    /// Settings toggle) must win over auto-reconnect; a killed plugin restarts.
    /// Internal (not fileprivate) so the mock path can drive it in tests.
    func applyVPNStatus(_ vpnStatus: NEVPNStatus) {
        let next = VPNStatus(vpnStatus)
        let previous = status
        status = next
        if next == .connected {
            reconnectAttempts = 0
            if !wantsConnection {
                // A stale `.connected` trailing our own stopVPN is not an
                // external start — suppress it or the UI toggle flashes on.
                if let lastStopRequestAt, Date().timeIntervalSince(lastStopRequestAt) < 2 {
                    return
                }
                // Started from System Settings or another client — adopt it.
                wantsConnection = true
                onExternalStateChange?(true)
            }
            startMetricsLoop()
        } else if next == .disconnected || next == .invalid || next == .error {
            // Keep polling only while mixed-port in the app still has counters.
            updateMetricsPolling()
            // Only a drop *from* an active session is unexpected. A start
            // while already disconnected must not read a stale user-stop.
            let droppedWhileUp = previous == .connected
                || previous == .connecting
                || previous == .reconnecting
                || previous == .disconnecting
            if wantsConnection, droppedWhileUp, !startingTunnel {
                handleExternalDisconnect()
            }
        }
    }

    private func handleExternalDisconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            // Give the dying extension a beat to record its stop reason.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let userStopped = TunnelLifecycleStore.stopWasUserInitiated()
            self.reconnectTask = nil
            guard self.wantsConnection else { return }
            if userStopped {
                TunnelLog.write(.info, "vpn stopped by user; not reconnecting")
                self.wantsConnection = false
                self.reconnectAttempts = 0
                self.onExternalStateChange?(false)
            } else {
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        let delays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]
        guard reconnectAttempts < delays.count else {
            if lastError == nil {
                lastError = "Tunnel plugin stopped unexpectedly; toggle TUN to retry"
            }
            return
        }
        let delay = delays[reconnectAttempts]
        reconnectAttempts += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard self.wantsConnection else { return }
            TunnelLog.write(.info, "vpn auto-reconnect attempt \(self.reconnectAttempts)")
            do {
                if let last = self.lastStart {
                    try await self.startVPN(
                        configText: last.configText,
                        fakeIP: last.fakeIP,
                        systemProxy: last.systemProxy,
                        allowLAN: last.allowLAN,
                        overlay: last.overlay
                    )
                } else {
                    try await self.startVPN()
                }
            } catch {
                self.refreshStatus()
            }
        }
    }

    fileprivate func apply(metrics: VPNMetrics) {
        if lastMetrics != metrics {
            lastMetrics = metrics
        }
        if uploadBytesPerSecond != metrics.uploadBytesPerSecond {
            uploadBytesPerSecond = metrics.uploadBytesPerSecond
        }
        if downloadBytesPerSecond != metrics.downloadBytesPerSecond {
            downloadBytesPerSecond = metrics.downloadBytesPerSecond
        }
        if activeConnections != metrics.activeConnections {
            activeConnections = metrics.activeConnections
        }
    }

    fileprivate func resetThroughput() {
        uploadBytesPerSecond = 0
        downloadBytesPerSecond = 0
        activeConnections = 0
        lastMetrics = .zero
    }

    /// Starts or pauses the poll for the current tunnel / local-egress state.
    private func updateMetricsPolling() {
        guard !isMock else { return }
        if status.isConnectedOrTransitioningOn || localEgressActive {
            startMetricsLoop()
        } else if metricsTask != nil {
            stopMetricsLoop()
            apply(metrics: .zero)
        }
    }

    fileprivate func startMetricsLoop() {
        guard metricsTask == nil else { return }
        isPollingMetrics = true
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let metrics = await self.fetchMetrics()
                self.apply(metrics: metrics)
                try? await Task.sleep(for: Self.metricsPollInterval)
            }
        }
    }

    fileprivate func stopMetricsLoop() {
        metricsTask?.cancel()
        metricsTask = nil
        isPollingMetrics = false
    }

    fileprivate func nextMockMetrics() -> VPNMetrics {
        var snapshot = MockTrafficGenerator.metrics()
        mockUplinkBytes &+= UInt64(max(0, snapshot.uploadBytesPerSecond.rounded()))
        mockDownlinkBytes &+= UInt64(max(0, snapshot.downloadBytesPerSecond.rounded()))
        snapshot.uplinkBytes = mockUplinkBytes
        snapshot.downlinkBytes = mockDownlinkBytes
        return snapshot
    }
}

/// Resumes a continuation exactly once: the provider's reply or the
/// deadline, whichever comes first.
private final class ReplyOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: () throws -> Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        do {
            pending.resume(returning: try result())
        } catch {
            pending.resume(throwing: error)
        }
    }
}

extension VPNStatus {
    init(_ status: NEVPNStatus) {
        switch status {
        case .invalid:
            self = .invalid
        case .disconnected:
            self = .disconnected
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .reasserting:
            self = .reconnecting
        case .disconnecting:
            self = .disconnecting
        @unknown default:
            self = .invalid
        }
    }
}
