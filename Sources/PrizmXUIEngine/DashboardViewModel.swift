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

    /// Rolling 60s samples bound directly to Swift Charts.
    public private(set) var speedHistory: [SpeedPoint]

    @ObservationIgnored
    private var history: SpeedHistoryBuffer
    @ObservationIgnored
    nonisolated(unsafe) private var historyTask: Task<Void, Never>?

    public init(
        vpn: VPNManager,
        profiles: ProfileStore,
        speedHistory history: SpeedHistoryBuffer = SpeedHistoryBuffer()
    ) {
        self.vpn = vpn
        self.profiles = profiles
        self.history = history
        self.speedHistory = history.points
        startHistorySampling()
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

    private func startHistorySampling() {
        historyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: VPNManager.metricsPollInterval)
                guard let self, !Task.isCancelled else { return }
                self.history.append(
                    uploadBytesPerSecond: self.vpn.uploadBytesPerSecond,
                    downloadBytesPerSecond: self.vpn.downloadBytesPerSecond
                )
                self.speedHistory = self.history.points
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
