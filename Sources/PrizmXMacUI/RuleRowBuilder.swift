import Foundation
import PrizmXServices

/// One row of the Rules table: a compiled rule with its labels precomputed.
struct RuleRow: Identifiable, Equatable {
    /// Local rules by overlay ID; module rules by position; profile rules by
    /// position among the profile rules.
    enum ID: Hashable {
        case local(UUID)
        case module(Int)
        case profile(Int)
    }

    var id: ID
    var number: Int
    var type: String
    var payload: String
    var policy: String
    var sourceLabel: String
    /// Lowercased type, payload, policy and source, matched by the search field.
    var searchText: String

    var overlayID: UUID? {
        if case .local(let id) = id { id } else { nil }
    }

    var isLocal: Bool { overlayID != nil }
}

/// What the Rules table shows: the active profile's compiled rules (local
/// overlay rules first, then enabled module rules, then profile body rules).
final class RuleRowBuilder {
    private var rules: [RouteRule] = []
    private var localIDs: [UUID] = []
    private var moduleSources: [String] = []
    private var all: [RuleRow] = []
    private var query = ""
    private var filtered: [RuleRow] = []

    func rows(
        rules: [RouteRule],
        localIDs: [UUID],
        moduleSources: [String] = [],
        search: String
    ) -> [RuleRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rules != self.rules || localIDs != self.localIDs || moduleSources != self.moduleSources {
            self.rules = rules
            self.localIDs = localIDs
            self.moduleSources = moduleSources
            all = Self.build(rules, localIDs: localIDs, moduleSources: moduleSources)
            filtered = Self.filter(all, query)
        } else if query != self.query {
            filtered = Self.filter(all, query)
        }
        self.query = query
        return filtered
    }

    private static func build(
        _ rules: [RouteRule],
        localIDs: [UUID],
        moduleSources: [String]
    ) -> [RuleRow] {
        let localCount = localIDs.count
        let moduleEnd = localCount + moduleSources.count
        return rules.enumerated().map { index, rule in
            let type = rule.displayType
            let payload = rule.displayPayload
            let policy = rule.displayPolicy
            let id: RuleRow.ID
            let sourceLabel: String
            if index < localCount {
                id = .local(localIDs[index])
                sourceLabel = "Local"
            } else if index < moduleEnd {
                let moduleIndex = index - localCount
                id = .module(moduleIndex)
                sourceLabel = "Module: \(moduleSources[moduleIndex])"
            } else {
                id = .profile(index - moduleEnd)
                sourceLabel = "Profile"
            }
            return RuleRow(
                id: id,
                number: index + 1,
                type: type,
                payload: payload,
                policy: policy,
                sourceLabel: sourceLabel,
                searchText: "\(type)\n\(payload)\n\(policy)\n\(sourceLabel)".lowercased()
            )
        }
    }

    private static func filter(_ rows: [RuleRow], _ query: String) -> [RuleRow] {
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.searchText.range(of: query, options: .literal) != nil }
    }
}
