import Foundation

/// On-disk Clash YAML or sing-box JSON profile owned by the host app.
public struct ProxyProfile: Identifiable, Sendable, Hashable, Codable {
    public enum Format: String, Sendable, Codable, Hashable {
        case clash
        case singbox
        case unknown
    }

    public var id: UUID
    public var name: String
    public var format: Format
    public var subscriptionURL: URL?
    public var selectedNodeID: String?
    public var selectedGroupName: String?
    public var lastUpdated: Date?
    /// Raw Clash YAML / sing-box JSON. Stored beside the index in App Group.
    public var rawConfig: String

    public init(
        id: UUID = UUID(),
        name: String,
        format: Format = .unknown,
        subscriptionURL: URL? = nil,
        selectedNodeID: String? = nil,
        selectedGroupName: String? = nil,
        lastUpdated: Date? = nil,
        rawConfig: String
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.subscriptionURL = subscriptionURL
        self.selectedNodeID = selectedNodeID
        self.selectedGroupName = selectedGroupName
        self.lastUpdated = lastUpdated
        self.rawConfig = rawConfig
    }

    /// Infers Clash vs sing-box from the first non-space character.
    public static func inferredFormat(for rawConfig: String) -> Format {
        let trimmed = rawConfig.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "{" || trimmed.first == "[" { return .singbox }
        if trimmed.isEmpty { return .unknown }
        return .clash
    }
}

/// Index record persisted without the bulky `rawConfig` blob.
struct ProfileIndexRecord: Sendable, Codable, Equatable {
    var id: UUID
    var name: String
    var format: ProxyProfile.Format
    var subscriptionURL: URL?
    var selectedNodeID: String?
    var selectedGroupName: String?
    var lastUpdated: Date?
    var isActive: Bool
}

struct ProfileIndexFile: Sendable, Codable, Equatable {
    var activeProfileID: UUID?
    var profiles: [ProfileIndexRecord]
}
