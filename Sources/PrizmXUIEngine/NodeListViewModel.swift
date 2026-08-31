import Foundation
import Observation
import PrizmXNodes
import PrizmXServices

/// One named bucket in the node list (policy group, region, or a fallback "All" section).
public struct NodeSection: Identifiable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var nodes: [OutboundNode]

    public init(id: String, title: String, nodes: [OutboundNode]) {
        self.id = id
        self.title = title
        self.nodes = nodes
    }
}

/// Node tree / group list with search filtering and concurrent delay tests.
@MainActor
@Observable
public final class NodeListViewModel {
    public let profiles: ProfileStore
    public var pinger: NodePinger
    public var searchText: String = ""
    public var grouping: NodeListGrouping = .policy
    public var isPinging: Bool = false
    /// Present after a probe. `nil` value means the node timed out.
    public var latencyByNodeID: [String: Double?] = [:]

    @ObservationIgnored
    nonisolated(unsafe) private var pingTask: Task<Void, Never>?
    @ObservationIgnored
    private var pingGeneration = 0

    public init(profiles: ProfileStore, pinger: NodePinger = NodePinger()) {
        self.profiles = profiles
        self.pinger = pinger
    }

    deinit {
        pingTask?.cancel()
    }

    public var selectedNodeID: String? {
        profiles.activeProfile?.selectedNodeID
    }

    /// Grouped nodes after search filtering.
    public var sections: [NodeSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rawSections.compactMap { section in
            let nodes: [OutboundNode]
            if query.isEmpty {
                nodes = section.nodes
            } else {
                nodes = section.nodes.filter { node in
                    node.name.localizedCaseInsensitiveContains(query)
                        || node.id.localizedCaseInsensitiveContains(query)
                }
            }
            guard !nodes.isEmpty else { return nil }
            return NodeSection(id: section.id, title: section.title, nodes: nodes)
        }
    }

    /// Flattened view of the current filter.
    public var filteredNodes: [OutboundNode] {
        sections.flatMap(\.nodes)
    }

    public func latency(for node: OutboundNode) -> Double? {
        guard let boxed = latencyByNodeID[node.id] else { return nil }
        return boxed
    }

    public func hasPingResult(for node: OutboundNode) -> Bool {
        latencyByNodeID[node.id] != nil
    }

    /// HK / US / JP sample catalog with pre-filled delay badges for Previews.
    public static var preview: NodeListViewModel {
        let viewModel = NodeListViewModel(profiles: .preview)
        viewModel.latencyByNodeID = PreviewFixtures.previewLatencies
        return viewModel
    }

    /// Runs a bounded concurrent TCP / HTTP probe and updates `latencyByNodeID`
    /// as replies arrive. Cooperative cancellation stops remaining workers.
    public func pingAllNodes(method: NodePingMethod = .tcp) async {
        pingGeneration += 1
        pingTask?.cancel()
        let generation = pingGeneration
        let task = Task<Void, Never>(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runPingAll(method: method, generation: generation)
        }
        pingTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func cancelPing() {
        pingGeneration += 1
        pingTask?.cancel()
        pingTask = nil
        isPinging = false
    }

    public func ping(_ node: OutboundNode, method: NodePingMethod = .tcp) async {
        let rtt = await pinger.ping(node, method: method)
        latencyByNodeID[node.id] = rtt
    }

    /// Buckets nodes by inferred country / region (`CN`, `US`, `HK`, `JP`).
    public func groupNodesByRegion() -> [NodeSection] {
        var buckets: [NodeRegion: [OutboundNode]] = [:]
        for node in uniqueNodes {
            buckets[NodeRegionClassifier.region(for: node), default: []].append(node)
        }
        return NodeRegion.displayOrder.compactMap { region in
            guard var grouped = buckets[region], !grouped.isEmpty else { return nil }
            grouped.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return NodeSection(id: region.id, title: region.title, nodes: grouped)
        }
    }

    /// Buckets nodes by profile policy groups (`Auto`, `Proxy`, `Direct`, …).
    public func groupNodesByPolicy() -> [NodeSection] {
        policySections
    }

    // MARK: - Catalog

    private var rawSections: [NodeSection] {
        switch grouping {
        case .policy:
            return groupNodesByPolicy()
        case .region:
            return groupNodesByRegion()
        }
    }

    private var uniqueNodes: [OutboundNode] {
        guard let manager = profiles.nodeManager else { return [] }
        return manager.nodesByID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var policySections: [NodeSection] {
        guard let manager = profiles.nodeManager else { return [] }

        let nodesByID = manager.nodesByID
        let groups = manager.groupsByName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // Implicit 1:1 groups (`name == node.id`) duplicate the proxy list.
        let namedGroups = groups.filter { group in
            !(group.nodeIDs.count == 1 && group.name == group.nodeIDs[0])
        }

        if namedGroups.isEmpty {
            return [
                NodeSection(id: "all", title: "Proxies", nodes: uniqueNodes)
            ]
        }

        var consumed: Set<String> = []
        var sections: [NodeSection] = namedGroups.map { group in
            let nodes = group.nodeIDs.compactMap { nodesByID[$0] }
            consumed.formUnion(nodes.map(\.id))
            return NodeSection(id: group.name, title: group.name, nodes: nodes)
        }

        let leftovers = uniqueNodes.filter { !consumed.contains($0.id) }
        if !leftovers.isEmpty {
            sections.append(NodeSection(id: "ungrouped", title: "Other", nodes: leftovers))
        }
        return sections
    }

    private func runPingAll(method: NodePingMethod, generation: Int) async {
        let nodes = uniqueNodes
        guard !nodes.isEmpty else { return }

        isPinging = true
        defer {
            if pingGeneration == generation {
                isPinging = false
            }
        }

        for node in nodes {
            latencyByNodeID.removeValue(forKey: node.id)
        }

        let pinger = self.pinger
        let maxConcurrent = pinger.maxConcurrent
        await withTaskGroup(of: (String, Double?).self) { group in
            var iterator = nodes.makeIterator()
            var inFlight = 0

            func enqueue() {
                while inFlight < maxConcurrent, !Task.isCancelled, let node = iterator.next() {
                    inFlight += 1
                    group.addTask(priority: .utility) {
                        let rtt = await pinger.ping(node, method: method)
                        return (node.id, rtt)
                    }
                }
            }

            enqueue()
            for await item in group {
                inFlight -= 1
                await MainActor.run {
                    self.latencyByNodeID[item.0] = item.1
                }
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                enqueue()
            }
        }
    }
}
