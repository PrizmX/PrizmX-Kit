import Foundation
import Observation
import PrizmXNodes
import PrizmXServices

/// Home-screen ViewModel: connection toggle, live rates, active profile / node.
@MainActor
@Observable
public final class DashboardViewModel {
    public let vpn: VPNManager
    public let profiles: ProfileStore

    /// Rolling 60s samples bound directly to Swift Charts. Zero-padded on the
    /// left until the window fills, so new samples always enter on the right.
    public private(set) var speedHistory: [SpeedPoint]

    @ObservationIgnored
    private var history: SpeedHistoryBuffer
    private static let sampleInterval = VPNManager.metricsPollInterval / .seconds(1)
    @ObservationIgnored
    nonisolated(unsafe) private var historyTask: Task<Void, Never>?
    /// When false, sampling still fills the ring buffer but the observable
    /// `speedHistory` array stays untouched, so hidden windows don't churn
    /// SwiftUI layout. The host app toggles this with UI visibility.
    @ObservationIgnored
    private var publishesSpeedHistory = true

    public init(
        vpn: VPNManager,
        profiles: ProfileStore,
        speedHistory history: SpeedHistoryBuffer = SpeedHistoryBuffer()
    ) {
        self.vpn = vpn
        self.profiles = profiles
        self.history = history
        self.speedHistory = history.paddedPoints(interval: Self.sampleInterval)
        followMetricsPolling()
    }

    deinit {
        historyTask?.cancel()
    }

    public var status: VPNStatus { vpn.status }

    public var uploadSpeedString: String {
        ByteRateFormatter.string(fromBytesPerSecond: vpn.uploadBytesPerSecond)
    }

    public var downloadSpeedString: String {
        ByteRateFormatter.string(fromBytesPerSecond: vpn.downloadBytesPerSecond)
    }

    public var activeProfileName: String {
        profiles.activeProfileName ?? "No Profile"
    }

    public var activeNodeName: String {
        profiles.activeNodeName ?? "Auto"
    }

    public var lastError: String? {
        vpn.lastError ?? profiles.lastError
    }

    /// Mock VPN + in-memory catalog + a full 60s chart window for Previews.
    public static var preview: DashboardViewModel {
        DashboardViewModel(
            vpn: VPNManager(isMock: true),
            profiles: .preview,
            speedHistory: .preview()
        )
    }

    /// Connects with the active profile, or disconnects an existing session.
    public func toggleConnection() async {
        if vpn.status.isConnectedOrTransitioningOn {
            vpn.stopVPN()
            return
        }
        let config = profiles.activeProfile?.rawConfig ?? VPNManager.defaultDirectConfig
        try? await vpn.startVPN(configText: config, overlay: profiles.overlay)
    }

    /// Persists the selected outbound and notifies a running Packet Tunnel.
    public func selectNode(_ node: OutboundNode) {
        applySelection(node.id, inGroup: resolvedGroupName(for: node))
    }

    /// Policies: persist `group → member` (node, nested group, or DIRECT).
    public func selectPolicyMember(_ memberID: String, inGroup groupName: String) {
        applySelection(memberID, inGroup: groupName)
    }

    private func applySelection(_ memberID: String, inGroup groupName: String?) {
        try? profiles.setSelectedNode(id: memberID, groupName: groupName)
        if let groupName {
            try? profiles.nodeManager?.select(nodeID: memberID, inGroup: groupName)
            profiles.setPolicySelection(memberID, inGroup: groupName)
        }
        Task {
            await vpn.notifySelectedNode(id: memberID, groupName: groupName)
        }
    }

    /// Pauses observable chart updates while every surface is hidden; the
    /// buffer keeps recording and is republished wholesale on resume.
    public func setSpeedHistoryPublishing(_ active: Bool) {
        guard active != publishesSpeedHistory else { return }
        publishesSpeedHistory = active
        if active {
            speedHistory = paddedHistory
        }
    }

    /// What `speedHistory` publishes: the buffer padded to a full window.
    private var paddedHistory: [SpeedPoint] {
        history.paddedPoints(interval: Self.sampleInterval)
    }

    /// Samples only while `VPNManager` polls; idle (no tunnel, no mixed-port)
    /// means no 1 Hz wakeups here either.
    private func followMetricsPolling() {
        let polling = withObservationTracking {
            vpn.isPollingMetrics
        } onChange: { [weak self] in
            Task { @MainActor in self?.followMetricsPolling() }
        }
        if polling {
            startHistorySampling()
        } else {
            stopHistorySampling()
        }
    }

    private func stopHistorySampling() {
        guard let historyTask else { return }
        historyTask.cancel()
        self.historyTask = nil
        // Close the chart on zero instead of freezing at the last rate.
        history.append(uploadBytesPerSecond: 0, downloadBytesPerSecond: 0)
        if publishesSpeedHistory {
            speedHistory = paddedHistory
        }
    }

    private func startHistorySampling() {
        guard historyTask == nil else { return }
        historyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: VPNManager.metricsPollInterval)
                guard let self, !Task.isCancelled else { return }
                self.history.append(
                    uploadBytesPerSecond: self.vpn.uploadBytesPerSecond,
                    downloadBytesPerSecond: self.vpn.downloadBytesPerSecond
                )
                if self.publishesSpeedHistory {
                    self.speedHistory = self.paddedHistory
                }
            }
        }
    }

    private func resolvedGroupName(for node: OutboundNode) -> String? {
        if let stored = profiles.activeProfile?.selectedGroupName,
           let group = profiles.nodeManager?.group(named: stored),
           group.nodeIDs.contains(node.id) {
            return stored
        }
        guard let manager = profiles.nodeManager else { return node.id }
        if let named = manager.groupsByName.values.first(where: { group in
            group.nodeIDs.contains(node.id) && group.name != node.id
        }) {
            return named.name
        }
        if manager.group(named: node.id) != nil {
            return node.id
        }
        return manager.groupsByName.values.first { $0.nodeIDs.contains(node.id) }?.name
    }
}
