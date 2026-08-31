import Foundation
import Testing
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
func dashboardPreviewExposesFormattedRatesAndHistory() {
    let viewModel = DashboardViewModel.preview
    #expect(viewModel.speedHistory.count == 60)
    #expect(viewModel.uploadSpeedString.contains("/s"))
    #expect(viewModel.downloadSpeedString.contains("MB/s") || viewModel.downloadSpeedString.contains("KB/s"))
    #expect(viewModel.status == .connected)
    viewModel.vpn.stopVPN()
}
