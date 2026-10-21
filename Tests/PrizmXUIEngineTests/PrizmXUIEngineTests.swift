import Foundation
import Testing
import PrizmXNodes
import PrizmXServices
@testable import PrizmXUIEngine

@Test
func regionClassifierReadsISOTokens() {
    #expect(NodeRegionClassifier.classify("HK-01") == NodeRegion.hongKong)
    #expect(NodeRegionClassifier.classify("US-West") == NodeRegion.unitedStates)
    #expect(NodeRegionClassifier.classify("JP-Tokyo") == NodeRegion.japan)
    #expect(NodeRegionClassifier.classify("CN-01") == NodeRegion.china)
    #expect(NodeRegionClassifier.classify("Singapore-01") == nil)
}

@MainActor
@Test
func nodeListPreviewGroupsByRegionAndPolicy() {
    let viewModel = NodeListViewModel.preview
    let regions = viewModel.groupNodesByRegion()
    #expect(regions.map(\.id) == ["CN", "HK", "JP", "US"])
    #expect(viewModel.latency(for: regions.first { $0.id == "HK" }!.nodes[0]) == 38)

    let policies = viewModel.groupNodesByPolicy()
    let titles = Set(policies.map(\.title))
    #expect(titles.isSuperset(of: ["Auto", "Proxy", "Direct"]))
}

@MainActor
@Test
func pickedNodeGoesToTheFirstSelectGroupInProfileOrder() {
    let manager = NodeManager(nodes: [], groups: [
        PolicyGroup(name: "HK01", mode: .select, nodeIDs: ["HK01"]),
        PolicyGroup(name: "Auto", mode: .urlTest, nodeIDs: ["HK01", "US01", "JP01"]),
        PolicyGroup(name: "Proxy", mode: .select, nodeIDs: ["Auto", "HK01", "US01"]),
        PolicyGroup(name: "Netflix", mode: .select, nodeIDs: ["US01", "DIRECT"]),
        PolicyGroup(name: "Backup", mode: .fallback, nodeIDs: ["JP01", "DIRECT"]),
    ])
    // Not the node's own group, nor the url-test group listed first.
    #expect(DashboardViewModel.groupName(for: "HK01", current: nil, in: manager) == "Proxy")
    #expect(DashboardViewModel.groupName(for: "HK01", current: "Netflix", in: manager) == "Proxy")
    #expect(DashboardViewModel.groupName(for: "US01", current: nil, in: manager) == "Proxy")
    // The current group keeps the pick when it holds the node.
    #expect(DashboardViewModel.groupName(for: "US01", current: "Netflix", in: manager) == "Netflix")
    // Unless it would drop the pick: a url-test group set from Policies.
    #expect(DashboardViewModel.groupName(for: "US01", current: "Auto", in: manager) == "Proxy")
    // With no select group holding the node, the current one still comes first.
    #expect(DashboardViewModel.groupName(for: "JP01", current: "Backup", in: manager) == "Backup")
    #expect(DashboardViewModel.groupName(for: "JP01", current: nil, in: manager) == "Auto")
}

@MainActor
@Test
func dashboardPreviewExposesFormattedRatesAndHistory() {
    let viewModel = DashboardViewModel.preview
    #expect(viewModel.speedHistory.count == 60)
    #expect(viewModel.uploadSpeedString.contains("/s"))
    #expect(viewModel.downloadSpeedString.contains("MB/s") || viewModel.downloadSpeedString.contains("KB/s"))
    #expect(viewModel.status == .connected)
    viewModel.vpn.stopVPN()
}
