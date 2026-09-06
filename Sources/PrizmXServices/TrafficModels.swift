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
        case .app: "A packet tunnel cannot see which process sent a flow."
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

    public init(
        id: String,
        name: String,
        bytes: UInt64,
        fraction: Double,
        systemImage: String = "app.fill",
        bundleID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.bytes = bytes
        self.fraction = fraction
        self.systemImage = systemImage
        self.bundleID = bundleID
    }
}

public struct RankingHourSample: Identifiable, Hashable, Sendable, Codable {
    public var hour: Int
    public var bytes: Double
    public var id: Int { hour }

    public init(hour: Int, bytes: Double) {
        self.hour = hour
        self.bytes = bytes
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

    public mutating func addProxy(upload: UInt64, download: UInt64) {
        uploadProxy &+= upload
        downloadProxy &+= download
    }
}
