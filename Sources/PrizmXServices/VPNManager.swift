import Foundation
import NetworkExtension
import Observation
import PrizmXConfig

/// Observable bridge to `NEPacketTunnelProvider`.
///
/// Host apps should use `VPNManager.shared` for the live Packet Tunnel
/// session. SwiftUI Previews and tests pass `isMock: true` so the same
/// ViewModels can run without a network-extension process.
@MainActor
@Observable
public final class VPNManager {
    public struct Configuration: Sendable, Equatable {
        /// Packet tunnel network-extension bundle identifier.
        public var providerBundleIdentifier: String
        public var localizedDescription: String
        public var serverAddress: String

        public init(
            providerBundleIdentifier: String,
            localizedDescription: String = "PrizmX",
            serverAddress: String = "PrizmX"
        ) {
            self.providerBundleIdentifier = providerBundleIdentifier
            self.localizedDescription = localizedDescription
            self.serverAddress = serverAddress
        }

        public static var `default`: Configuration {
            #if os(macOS)
            Configuration(providerBundleIdentifier: "app.prizmx.macos.packet-tunnel")
            #else
            Configuration(providerBundleIdentifier: "app.prizmx.packet-tunnel")
            #endif
        }
    }

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

    @ObservationIgnored
    private var tunnelManager: NETunnelProviderManager?
    @ObservationIgnored
    nonisolated(unsafe) private var statusObserver: NSObjectProtocol?
    @ObservationIgnored
    nonisolated(unsafe) private var metricsTask: Task<Void, Never>?
    @ObservationIgnored
    private var mockUplinkBytes: UInt64 = 0
    @ObservationIgnored
    private var mockDownlinkBytes: UInt64 = 0

    public init(configuration: Configuration = .default, isMock: Bool = false) {
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
        ) { [weak self] notification in
            let vpnStatus = (notification.object as? NEVPNConnection)?.status ?? .invalid
            Task { @MainActor in
                self?.applyVPNStatus(vpnStatus)
            }
        }
        Task { await loadManager() }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        metricsTask?.cancel()
    }

    // MARK: - Preferences

    /// Loads an existing Packet Tunnel preference or creates an unsaved one.
    public func loadManager() async {
        guard !isMock else { return }
        do {
            let existing = try await NETunnelProviderManager.loadAllFromPreferences()
            if let found = existing.first(where: { manager in
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == configuration.providerBundleIdentifier
            }) ?? existing.first {
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
        geoIPPath: String? = nil,
        geositeJSON: String? = nil,
        dnsServers: [String]? = nil
    ) async throws {
        guard !isMock else { return }
        if tunnelManager == nil { await loadManager() }
        guard let manager = tunnelManager else { throw VPNError.notConfigured }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = configuration.providerBundleIdentifier
        proto.serverAddress = configuration.serverAddress

        var payload: [String: Any] = [
            TunnelProviderKeys.configText: configText,
            TunnelProviderKeys.fakeIP: fakeIP
        ]
        if let geoIPPath { payload[TunnelProviderKeys.geoIPPath] = geoIPPath }
        if let geositeJSON { payload[TunnelProviderKeys.geositeJSON] = geositeJSON }
        if let dnsServers { payload[TunnelProviderKeys.dnsServers] = dnsServers }
        proto.providerConfiguration = payload

        manager.localizedDescription = configuration.localizedDescription
        manager.protocolConfiguration = proto
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        tunnelManager = manager
        refreshStatus()
    }

    // MARK: - Lifecycle

    /// Starts the Packet Tunnel. Pass `configText` to (re)install the profile first.
    public func startVPN(configText: String? = nil) async throws {
        lastError = nil
        if isMock {
            status = .connecting
            try await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            status = .connected
            apply(metrics: nextMockMetrics())
            startMetricsLoop()
            return
        }

        if let configText {
            try await configure(configText: configText)
        }
        if tunnelManager == nil { await loadManager() }
        guard let manager = tunnelManager else { throw VPNError.notConfigured }

        if manager.protocolConfiguration == nil {
            try await configure(configText: Self.defaultDirectConfig)
        }

        do {
            try await manager.loadFromPreferences()
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            try manager.connection.startVPNTunnel()
            refreshStatus()
            startMetricsLoop()
        } catch {
            lastError = error.localizedDescription
            status = .error
            throw VPNError.startFailed(error.localizedDescription)
        }
    }

    public func stopVPN() {
        if !isMock {
            tunnelManager?.connection.stopVPNTunnel()
        }
        stopMetricsLoop()
        resetThroughput()
        if isMock {
            status = .disconnected
        } else {
            refreshStatus()
        }
    }

    public func refreshStatus() {
        guard !isMock else { return }
        applyVPNStatus(tunnelManager?.connection.status ?? .invalid)
    }

    // MARK: - IPC

    /// Asks the Packet Tunnel for a live throughput snapshot.
    /// Returns `.zero` when the session is down or the provider has not
    /// implemented `handleAppMessage` yet.
    public func fetchMetrics() async -> VPNMetrics {
        if isMock {
            return status == .connected ? nextMockMetrics() : .zero
        }
        guard status == .connected else { return .zero }
        guard let session = tunnelManager?.connection as? NETunnelProviderSession else {
            return .zero
        }

        let payload: Data
        do {
            payload = try TunnelIPC.encode(.init(method: .fetchMetrics))
        } catch {
            lastError = error.localizedDescription
            return .zero
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
            return try TunnelIPC.metrics(from: responseData)
        } catch {
            // Provider may not have registered IPC yet; keep the UI alive.
            return .zero
        }
    }

    /// Notifies a running tunnel that the selected outbound changed.
    public func notifySelectedNode(id nodeID: String, groupName: String?) async {
        guard !isMock, status == .connected else { return }
        guard let session = tunnelManager?.connection as? NETunnelProviderSession else { return }
        guard let payload = try? TunnelIPC.encode(
            .init(method: .selectNode, nodeID: nodeID, groupName: groupName)
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
    /// and tears it down as soon as the session drops.
    fileprivate func applyVPNStatus(_ vpnStatus: NEVPNStatus) {
        let next = VPNStatus(vpnStatus)
        status = next
        if next == .connected {
            startMetricsLoop()
        } else if next == .disconnected || next == .invalid || next == .error {
            stopMetricsLoop()
            resetThroughput()
        }
    }

    fileprivate func apply(metrics: VPNMetrics) {
        lastMetrics = metrics
        uploadBytesPerSecond = metrics.uploadBytesPerSecond
        downloadBytesPerSecond = metrics.downloadBytesPerSecond
        activeConnections = metrics.activeConnections
    }

    fileprivate func resetThroughput() {
        uploadBytesPerSecond = 0
        downloadBytesPerSecond = 0
        activeConnections = 0
        lastMetrics = .zero
    }

    fileprivate func startMetricsLoop() {
        guard metricsTask == nil else { return }
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.status == .connected {
                    let metrics = await self.fetchMetrics()
                    self.apply(metrics: metrics)
                }
                try? await Task.sleep(for: Self.metricsPollInterval)
            }
        }
    }

    fileprivate func stopMetricsLoop() {
        metricsTask?.cancel()
        metricsTask = nil
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
