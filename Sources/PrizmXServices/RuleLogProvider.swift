import Foundation
import Observation

/// One split-routing decision captured for the log pane.
public struct RuleLogItem: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var timestamp: Date
    /// Domain or IP that triggered the rule.
    public var host: String
    /// Hit policy (`DIRECT`, `PROXY`, `REJECT`, or a named group).
    public var policy: String
    /// Outbound node that handled the flow.
    public var outboundNode: String
    /// ISO 3166-1 alpha-2 country code of the destination, when known.
    public var countryCode: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        host: String,
        policy: String,
        outboundNode: String,
        countryCode: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.host = host
        self.policy = policy
        self.outboundNode = outboundNode
        self.countryCode = countryCode
    }
}

/// Main-actor ring buffer of the most recent split-routing events.
///
/// ViewModels read `logs` through Observation.
@MainActor
@Observable
public final class RuleLogProvider {
    public static let capacity = 200

    public private(set) var logs: [RuleLogItem] = []

    @ObservationIgnored
    private var buffer = RingBuffer<RuleLogItem>(capacity: RuleLogProvider.capacity)

    public init() {}

    public func addLog(_ item: RuleLogItem) {
        buffer.append(item)
        logs = buffer.elements
    }

    public func removeAll() {
        buffer.removeAll()
        logs = []
    }

    /// Sample rows so a log pane can render in Xcode Previews.
    public static var preview: RuleLogProvider {
        let provider = RuleLogProvider()
        let samples: [RuleLogItem] = [
            RuleLogItem(host: "www.google.com", policy: "Proxy", outboundNode: "US-West", countryCode: "US"),
            RuleLogItem(host: "github.com", policy: "Proxy", outboundNode: "HK-01", countryCode: "HK"),
            RuleLogItem(host: "www.apple.com", policy: "Proxy", outboundNode: "JP-Tokyo", countryCode: "JP"),
            RuleLogItem(host: "www.baidu.com", policy: "Direct", outboundNode: "CN-01", countryCode: "CN"),
            RuleLogItem(host: "1.1.1.1", policy: "Proxy", outboundNode: "HK-01", countryCode: "US")
        ]
        for item in samples {
            provider.addLog(item)
        }
        return provider
    }
}
