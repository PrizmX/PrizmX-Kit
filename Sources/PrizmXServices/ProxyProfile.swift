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
    /// `upload + download` from Clash `subscription-userinfo`.
    public var usedBytes: UInt64?
    /// Traffic quota from `subscription-userinfo` `total`.
    public var totalBytes: UInt64?
    /// Unix `expire` from `subscription-userinfo`.
    public var expiresAt: Date?
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
        usedBytes: UInt64? = nil,
        totalBytes: UInt64? = nil,
        expiresAt: Date? = nil,
        rawConfig: String
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.subscriptionURL = subscriptionURL
        self.selectedNodeID = selectedNodeID
        self.selectedGroupName = selectedGroupName
        self.lastUpdated = lastUpdated
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.expiresAt = expiresAt
        self.rawConfig = rawConfig
    }

    public var isSubscription: Bool { subscriptionURL != nil }

    /// Clash / Clash Meta `subscription-userinfo` header.
    public mutating func applySubscriptionUserInfo(from response: URLResponse) {
        guard let http = response as? HTTPURLResponse,
              let header = http.value(forHTTPHeaderField: "subscription-userinfo"),
              let quota = SubscriptionQuota.parse(header) else { return }
        usedBytes = quota.usedBytes
        totalBytes = quota.totalBytes
        expiresAt = quota.expiresAt
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
    var usedBytes: UInt64?
    var totalBytes: UInt64?
    var expiresAt: Date?
    var isActive: Bool
}

/// Clash `subscription-userinfo: upload=; download=; total=; expire=`.
public struct SubscriptionQuota: Sendable, Equatable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64?
    public var expiresAt: Date?

    public static func parse(_ header: String) -> SubscriptionQuota? {
        var upload: UInt64 = 0
        var download: UInt64 = 0
        var total: UInt64?
        var expiresAt: Date?
        var sawValue = false
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "upload":
                upload = UInt64(value) ?? 0
                sawValue = true
            case "download":
                download = UInt64(value) ?? 0
                sawValue = true
            case "total":
                if let parsed = UInt64(value), parsed > 0 { total = parsed }
                sawValue = true
            case "expire", "expires":
                if let timestamp = TimeInterval(value), timestamp > 0 {
                    expiresAt = Date(timeIntervalSince1970: timestamp)
                }
                sawValue = true
            default:
                break
            }
        }
        guard sawValue else { return nil }
        return SubscriptionQuota(
            usedBytes: upload &+ download,
            totalBytes: total,
            expiresAt: expiresAt
        )
    }
}

struct ProfileIndexFile: Sendable, Codable, Equatable {
    var activeProfileID: UUID?
    var profiles: [ProfileIndexRecord]
}
