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

/// One `select` group member: a node, nested group, or built-in DIRECT/REJECT.
public struct PolicyMember: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var kindLabel: String
    public var node: OutboundNode?
    public var isUnsupported: Bool

    public init(
        id: String,
        name: String,
        kindLabel: String,
        node: OutboundNode? = nil,
        isUnsupported: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kindLabel = kindLabel
        self.node = node
        self.isUnsupported = isUnsupported
    }
}

public struct PolicyGroupSection: Identifiable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var members: [PolicyMember]

    public init(id: String, title: String, members: [PolicyMember]) {
        self.id = id
        self.title = title
        self.members = members
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

    /// Currently chosen member (node, nested group, or DIRECT) in `groupName`.
    /// Reads the persisted Policies selection, then the catalog default.
    public func selectedMemberID(inGroup groupName: String) -> String? {
        if let persisted = profiles.policySelections()[groupName] { return persisted }
        return profiles.nodeManager?.selectedMemberID(inGroup: groupName)
    }

    /// Policy groups with every member (nodes, nested groups, DIRECT).
    public var policyGroupSections: [PolicyGroupSection] {
        guard let manager = profiles.nodeManager else { return [] }
        let groups = manager.groupsByName.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let namedGroups = groups.filter { group in
            !(group.nodeIDs.count == 1 && group.name == group.nodeIDs[0])
        }
        return namedGroups.map { group in
            PolicyGroupSection(
                id: group.name,
                title: group.name,
                members: group.nodeIDs.map { Self.policyMember($0, manager: manager) }
            )
        }
    }

    private static func policyMember(_ id: String, manager: NodeManager) -> PolicyMember {
        if let node = manager.nodesByID[id] {
            return PolicyMember(
                id: id,
                name: node.name,
                kindLabel: "Node (\(Self.protocolLabel(node.protocolConfig)))",
                node: node
            )
        }
        if manager.groupsByName[id] != nil {
            return PolicyMember(id: id, name: id, kindLabel: "Group")
        }
        switch id.uppercased() {
        case "DIRECT":
            return PolicyMember(id: id, name: id, kindLabel: "DIRECT")
        case "REJECT", "REJECT-DROP":
            return PolicyMember(id: id, name: id, kindLabel: "REJECT")
        default:
            return PolicyMember(id: id, name: id, kindLabel: "Unsupported", isUnsupported: true)
        }
    }

    private static func protocolLabel(_ config: ProtocolConfig) -> String {
        switch config {
        case .shadowsocks: "SS"
        case .vless: "VLESS"
        case .trojan: "Trojan"
        case .anytls: "AnyTLS"
        case .direct: "Direct"
        }
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

    /// Runs a bounded concurrent TCP probe and updates `latencyByNodeID`
    /// as replies arrive. Cooperative cancellation stops remaining workers.
    public func pingAllNodes() async {
        pingGeneration += 1
        pingTask?.cancel()
        let generation = pingGeneration
        let task = Task<Void, Never>(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runPingAll(generation: generation)
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

    public func ping(_ node: OutboundNode) async {
        let rtt = await pinger.ping(node)
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

    private func runPingAll(generation: Int) async {
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

        // Bounded worker pool lives in NodePinger; results stream back on the
        // main actor as each probe lands. Results from a superseded generation
        // (cancelled but already in flight) are discarded.
        await pinger.pingAll(nodes) { nodeID, rtt in
            guard self.pingGeneration == generation else { return }
            self.latencyByNodeID[nodeID] = rtt
        }
    }
}
