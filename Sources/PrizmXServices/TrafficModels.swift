import Foundation

/// Day / Month bucket selector for traffic totals.
public enum TrafficPeriod: String, CaseIterable, Identifiable, Sendable, Codable {
    case day
    case month

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day: "Day"
        case .month: "Month"
        }
    }
}

/// Ranking breakdown selector.
public enum TrafficRankScope: String, CaseIterable, Identifiable, Sendable, Codable {
    case app
    case domain
    case policy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .app: "App"
        case .domain: "Domain"
        case .policy: "Policy"
        }
    }

    public var emptyDescription: String {
        switch self {
        case .app: "App totals appear after the packet tunnel attributes flows."
        case .domain: "Domain totals appear when requests are classified."
        case .policy: "Policy totals appear when rules match traffic."
        }
    }
}

public struct TrafficRankRow: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var bytes: UInt64
    public var fraction: Double
    public var systemImage: String
    public var bundleID: String?
    public var tcpBytes: UInt64
    public var udpBytes: UInt64

    public init(
        id: String,
        name: String,
        bytes: UInt64,
        fraction: Double,
        systemImage: String = "app.fill",
        bundleID: String? = nil,
        tcpBytes: UInt64 = 0,
        udpBytes: UInt64 = 0
    ) {
        self.id = id
        self.name = name
        self.bytes = bytes
        self.fraction = fraction
        self.systemImage = systemImage
        self.bundleID = bundleID
        self.tcpBytes = tcpBytes
        self.udpBytes = udpBytes
    }
}

public struct RankingHourSample: Identifiable, Hashable, Sendable, Codable {
    /// Position in the rolling 24-hour window (0 = oldest, 23 = current hour).
    public var index: Int
    /// Clock hour 0...23 for axis labels.
    public var hour: Int
    /// Start of this hour (local).
    public var startedAt: Date
    public var bytes: Double
    public var proxyBytes: UInt64
    public var directBytes: UInt64
    public var id: Int { index }

    public init(
        hour: Int,
        bytes: Double,
        index: Int? = nil,
        startedAt: Date = .now,
        proxyBytes: UInt64 = 0,
        directBytes: UInt64 = 0
    ) {
        self.hour = hour
        self.bytes = bytes
        self.index = index ?? hour
        self.startedAt = startedAt
        self.proxyBytes = proxyBytes
        self.directBytes = directBytes
    }
}

public struct TrafficTotals: Sendable, Hashable, Codable {
    public var uploadProxy: UInt64 = 0
    public var uploadDirect: UInt64 = 0
    public var downloadProxy: UInt64 = 0
    public var downloadDirect: UInt64 = 0

    public init(
        uploadProxy: UInt64 = 0,
        uploadDirect: UInt64 = 0,
        downloadProxy: UInt64 = 0,
        downloadDirect: UInt64 = 0
    ) {
        self.uploadProxy = uploadProxy
        self.uploadDirect = uploadDirect
        self.downloadProxy = downloadProxy
        self.downloadDirect = downloadDirect
    }

    public var upload: UInt64 { uploadProxy &+ uploadDirect }
    public var download: UInt64 { downloadProxy &+ downloadDirect }
    public var combined: UInt64 { upload &+ download }
}
