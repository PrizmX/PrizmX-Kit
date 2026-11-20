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

    private func syncHistory(from metrics: VPNMetrics) {
        if !metrics.rateHistory.isEmpty {
            let points = metrics.rateHistory.enumerated().map { idx, sample in
                SpeedPoint(
                    id: idx,
                    timestamp: sample.timestamp,
                    uploadBytesPerSecond: sample.uploadBytesPerSecond,
                    downloadBytesPerSecond: sample.downloadBytesPerSecond
                )
            }
            history = SpeedHistoryBuffer(capacity: history.capacity, points: points)
        } else {
            history.append(
                uploadBytesPerSecond: vpn.uploadBytesPerSecond,
                downloadBytesPerSecond: vpn.downloadBytesPerSecond
            )
        }
        if publishesSpeedHistory {
            speedHistory = paddedHistory
        }
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
        if !vpn.lastMetrics.rateHistory.isEmpty {
            syncHistory(from: vpn.lastMetrics)
        }
        historyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: VPNManager.metricsPollInterval)
                guard let self, !Task.isCancelled else { return }
                self.syncHistory(from: self.vpn.lastMetrics)
            }
        }
    }

    private func resolvedGroupName(for node: OutboundNode) -> String? {
        guard let manager = profiles.nodeManager else { return node.id }
        return Self.groupName(for: node.id, current: profiles.activeProfile?.selectedGroupName, in: manager)
    }

    /// The group a picked node goes to: the first select group holding it,
    /// trying the current group before the others in profile order, so
    /// every launch picks the same one. A url-test, fallback or
    /// load-balance group does not keep a manual pick, so it is used only
    /// when no select group holds the node.
    static func groupName(for nodeID: String, current: String?, in manager: NodeManager) -> String? {
        let candidates = [current.flatMap { manager.group(named: $0) }].compactMap { $0 } + manager.groups
        let holders = candidates.filter { $0.nodeIDs.contains(nodeID) && $0.name != nodeID }
        if let group = holders.first(where: { $0.mode == .select }) ?? holders.first {
            return group.name
        }
        if manager.group(named: nodeID) != nil {
            return nodeID
        }
        return manager.groups.first { $0.nodeIDs.contains(nodeID) }?.name
    }
}
