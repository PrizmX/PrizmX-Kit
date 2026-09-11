import Foundation
import Observation

/// Accumulates tunnel bytes into local day / month buckets.
///
/// The engine's `TrafficCounter` is the source of truth (protocol-agnostic,
/// counted at the splice layer); this only diffs cumulative snapshots and
/// persists. Direct/Proxy split comes from the engine's `direct` bucket.
@MainActor
@Observable
public final class TrafficLedger {
    private static let defaultsKey = "trafficLedger.v2"

    struct HourBucket: Codable, Equatable {
        var total: UInt64 = 0
        var proxy: UInt64 = 0
        var direct: UInt64 = 0
    }

    struct DayBucket: Codable {
        var totals = TrafficTotals()
        /// up+down per policy label (group name / "proxy").
        var policy: [String: UInt64] = [:]
        /// up+down per domain.
        var domain: [String: UInt64] = [:]
        /// up+down per app accounting key.
        var app: [String: UInt64] = [:]
        var appNames: [String: String] = [:]
        var appTCP: [String: UInt64] = [:]
        var appUDP: [String: UInt64] = [:]
        var domainTCP: [String: UInt64] = [:]
        var domainUDP: [String: UInt64] = [:]
        var policyTCP: [String: UInt64] = [:]
        var policyUDP: [String: UInt64] = [:]
        /// Hour-of-day (0...23) → proxy / direct / total.
        var hours: [Int: HourBucket] = [:]

        enum CodingKeys: String, CodingKey {
            case totals, policy, domain, app, appNames, hours
            case appTCP, appUDP, domainTCP, domainUDP, policyTCP, policyUDP
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            totals = try container.decodeIfPresent(TrafficTotals.self, forKey: .totals) ?? TrafficTotals()
            policy = try container.decodeIfPresent([String: UInt64].self, forKey: .policy) ?? [:]
            domain = try container.decodeIfPresent([String: UInt64].self, forKey: .domain) ?? [:]
            app = try container.decodeIfPresent([String: UInt64].self, forKey: .app) ?? [:]
            appNames = try container.decodeIfPresent([String: String].self, forKey: .appNames) ?? [:]
            appTCP = try container.decodeIfPresent([String: UInt64].self, forKey: .appTCP) ?? [:]
            appUDP = try container.decodeIfPresent([String: UInt64].self, forKey: .appUDP) ?? [:]
            domainTCP = try container.decodeIfPresent([String: UInt64].self, forKey: .domainTCP) ?? [:]
            domainUDP = try container.decodeIfPresent([String: UInt64].self, forKey: .domainUDP) ?? [:]
            policyTCP = try container.decodeIfPresent([String: UInt64].self, forKey: .policyTCP) ?? [:]
            policyUDP = try container.decodeIfPresent([String: UInt64].self, forKey: .policyUDP) ?? [:]
            if let typed = try? container.decode([Int: HourBucket].self, forKey: .hours) {
                hours = typed
            } else if let legacy = try? container.decode([Int: UInt64].self, forKey: .hours) {
                hours = legacy.mapValues { HourBucket(total: $0) }
            } else {
                hours = [:]
            }
        }
    }

    private var days: [String: DayBucket]
    private var months: [String: TrafficTotals]
    /// Last cumulative snapshot used as the diff baseline.
    private var last: VPNMetrics

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let file = try? JSONDecoder().decode(File.self, from: data) {
            days = file.days
            months = file.months
            last = file.last
        } else {
            days = [:]
            months = [:]
            last = .zero
        }
    }

    public func totals(for period: TrafficPeriod, now: Date = .now) -> TrafficTotals {
        switch period {
        case .day: days[Self.dayKey(now)]?.totals ?? TrafficTotals()
        case .month: months[Self.monthKey(now)] ?? TrafficTotals()
        }
    }

    /// Top rows for the Ranking card.
    public func rows(for scope: TrafficRankScope, now: Date = .now) -> [TrafficRankRow] {
        let bucket = days[Self.dayKey(now)] ?? DayBucket()
        var source: [String: UInt64]
        switch scope {
        case .app:
            source = bucket.app
        case .domain:
            source = bucket.domain
        case .policy:
            source = bucket.policy
            let directTotal = bucket.totals.uploadDirect + bucket.totals.downloadDirect
            if directTotal > 0 { source["DIRECT"] = directTotal }
        }
        let sorted = source.sorted { $0.value > $1.value }.prefix(8)
        let peak = max(sorted.first?.value ?? 1, 1)
        return sorted.enumerated().map { index, entry in
            let name: String
            var bundleID: String?
            var icon = "terminal"
            switch scope {
            case .app:
                name = bucket.appNames[entry.key] ?? entry.key
                bundleID = entry.key.contains(".") ? entry.key : nil
            case .domain:
                name = entry.key
                icon = "globe"
            case .policy:
                name = entry.key == "proxy" ? "Proxy" : entry.key
                icon = Self.policyIcon(entry.key)
            }
            let tcp: UInt64
            let udp: UInt64
            switch scope {
            case .app:
                tcp = bucket.appTCP[entry.key] ?? 0
                udp = bucket.appUDP[entry.key] ?? 0
            case .domain:
                tcp = bucket.domainTCP[entry.key] ?? 0
                udp = bucket.domainUDP[entry.key] ?? 0
            case .policy:
                tcp = bucket.policyTCP[entry.key] ?? 0
                udp = bucket.policyUDP[entry.key] ?? 0
            }
            return TrafficRankRow(
                id: "\(scope.rawValue)-\(index)",
                name: name,
                bytes: entry.value,
                fraction: Double(entry.value) / Double(peak),
                systemImage: icon,
                bundleID: bundleID,
                tcpBytes: tcp,
                udpBytes: udp
            )
        }
    }

    /// Rolling 24-hour buckets for the Ranking chart. Slot 23 is the current hour.
    public func hourly(now: Date = .now) -> [RankingHourSample] {
        let calendar = Calendar.current
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return (0..<24).map { index in
            let date = calendar.date(byAdding: .hour, value: index - 23, to: currentHour) ?? now
            let hour = calendar.component(.hour, from: date)
            let bucket = days[Self.dayKey(date)]?.hours[hour] ?? HourBucket()
            return RankingHourSample(
                hour: hour,
                bytes: Double(bucket.total),
                index: index,
                startedAt: date,
                proxyBytes: bucket.proxy,
                directBytes: bucket.direct
            )
        }
    }

    public func ingest(_ metrics: VPNMetrics) {
        // Tunnel restart resets every cumulative counter — rebase instead of
        // recording a negative delta.
        guard metrics.uplinkBytes >= last.uplinkBytes,
              metrics.downlinkBytes >= last.downlinkBytes,
              metrics.directUplinkBytes >= last.directUplinkBytes,
              metrics.directDownlinkBytes >= last.directDownlinkBytes else {
            last = metrics
            persist()
            return
        }
        let uploadDelta = metrics.uplinkBytes - last.uplinkBytes
        let downloadDelta = metrics.downlinkBytes - last.downlinkBytes
        let directUpDelta = metrics.directUplinkBytes - last.directUplinkBytes
        let directDownDelta = metrics.directDownlinkBytes - last.directDownlinkBytes
        let policyDeltas = Self.diff(metrics.policyBytes, minus: last.policyBytes)
        let domainDeltas = Self.diff(metrics.domainBytes, minus: last.domainBytes)
        let appDeltas = Self.diff(metrics.appBytes, minus: last.appBytes)
        let appTCPDeltas = Self.diffCount(metrics.appTCPBytes, minus: last.appTCPBytes)
        let appUDPDeltas = Self.diffCount(metrics.appUDPBytes, minus: last.appUDPBytes)
        let domainTCPDeltas = Self.diffCount(metrics.domainTCPBytes, minus: last.domainTCPBytes)
        let domainUDPDeltas = Self.diffCount(metrics.domainUDPBytes, minus: last.domainUDPBytes)
        let policyTCPDeltas = Self.diffCount(metrics.policyTCPBytes, minus: last.policyTCPBytes)
        let policyUDPDeltas = Self.diffCount(metrics.policyUDPBytes, minus: last.policyUDPBytes)
        last = metrics
        guard uploadDelta > 0 || downloadDelta > 0 else { return }

        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let dayKey = Self.dayKey(now)
        let monthKey = Self.monthKey(now)
        var day = days[dayKey] ?? DayBucket()
        var month = months[monthKey] ?? TrafficTotals()

        day.totals.uploadDirect &+= directUpDelta
        day.totals.downloadDirect &+= directDownDelta
        // Engine counters are not an atomic snapshot: a torn read can make
        // direct > total, which must not trap on UInt64 underflow.
        day.totals.uploadProxy &+= uploadDelta &- min(uploadDelta, directUpDelta)
        day.totals.downloadProxy &+= downloadDelta &- min(downloadDelta, directDownDelta)
        month.uploadDirect &+= directUpDelta
        month.downloadDirect &+= directDownDelta
        month.uploadProxy &+= uploadDelta &- min(uploadDelta, directUpDelta)
        month.downloadProxy &+= downloadDelta &- min(downloadDelta, directDownDelta)

        for (policy, bytes) in policyDeltas {
            day.policy[policy, default: 0] &+= bytes
        }
        for (domain, bytes) in domainDeltas {
            day.domain[domain, default: 0] &+= bytes
        }
        for (app, bytes) in appDeltas {
            day.app[app, default: 0] &+= bytes
        }
        for (key, name) in metrics.appNames where day.appNames[key] == nil {
            day.appNames[key] = name
        }
        Self.addCounts(&day.appTCP, appTCPDeltas)
        Self.addCounts(&day.appUDP, appUDPDeltas)
        Self.addCounts(&day.domainTCP, domainTCPDeltas)
        Self.addCounts(&day.domainUDP, domainUDPDeltas)
        Self.addCounts(&day.policyTCP, policyTCPDeltas)
        Self.addCounts(&day.policyUDP, policyUDPDeltas)
        let directDelta = directUpDelta &+ directDownDelta
        let proxyDelta =
            (uploadDelta &- min(uploadDelta, directUpDelta))
            &+ (downloadDelta &- min(downloadDelta, directDownDelta))
        var hourBucket = day.hours[hour] ?? HourBucket()
        hourBucket.total &+= uploadDelta &+ downloadDelta
        hourBucket.proxy &+= proxyDelta
        hourBucket.direct &+= directDelta
        day.hours[hour] = hourBucket

        days[dayKey] = day
        months[monthKey] = month
        persist()
    }

    private static func diffCount(
        _ current: [String: UInt64],
        minus previous: [String: UInt64]
    ) -> [String: UInt64] {
        var deltas: [String: UInt64] = [:]
        for (key, count) in current {
            let before = previous[key] ?? 0
            guard count >= before else { continue }
            let delta = count - before
            if delta > 0 { deltas[key] = delta }
        }
        return deltas
    }

    private static func addCounts(_ target: inout [String: UInt64], _ deltas: [String: UInt64]) {
        for (key, bytes) in deltas {
            target[key, default: 0] &+= bytes
        }
    }

    private static func diff(
        _ current: [String: TrafficByteCount],
        minus previous: [String: TrafficByteCount]
    ) -> [String: UInt64] {
        var deltas: [String: UInt64] = [:]
        for (key, count) in current {
            let before = previous[key] ?? TrafficByteCount()
            guard count.up >= before.up, count.down >= before.down else { continue }
            let delta = (count.up - before.up) + (count.down - before.down)
            if delta > 0 { deltas[key] = delta }
        }
        return deltas
    }

    private static func policyIcon(_ label: String) -> String {
        if label == "DIRECT" { return "arrow.right" }
        return "arrow.triangle.branch"
    }

    private var lastPersist = Date.distantPast

    /// Writes are throttled: ingest runs on a 1s metrics loop and the payload
    /// is the full day/month model, so an interval cap avoids pointless I/O.
    private func persist() {
        let now = Date()
        guard now.timeIntervalSince(lastPersist) >= 10 else { return }
        lastPersist = now
        let file = File(days: days, months: months, last: last)
        if let data = try? JSONEncoder().encode(file) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func dayKey(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static func monthKey(_ date: Date) -> String {
        String(dayKey(date).prefix(7))
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private struct File: Codable {
        var days: [String: DayBucket]
        var months: [String: TrafficTotals]
        var last: VPNMetrics
    }
}

extension TrafficLedger {
    /// Seeded buckets so Home previews show a populated Ranking card.
    public static var preview: TrafficLedger {
        let ledger = TrafficLedger()
        let dayKey = dayKey(.now)
        let monthKey = monthKey(.now)
        var bucket = DayBucket()
        bucket.totals = TrafficTotals(
            uploadProxy: 98_000_000,
            uploadDirect: 32_000_000,
            downloadProxy: 551_000_000,
            downloadDirect: 178_000_000
        )
        bucket.policy = ["Proxies": 512_000_000, "direct": 97_000_000, "AI": 64_000_000]
        bucket.domain = [
            "github.com": 310_000_000,
            "googleapis.com": 142_000_000,
            "apple.com": 88_000_000,
            "icloud.com": 41_000_000
        ]
        for hour in 0..<24 {
            let total = UInt64(20_000_000 * (hour == 13 ? 5 : 1))
            bucket.hours[hour] = HourBucket(
                total: total,
                proxy: total * 3 / 4,
                direct: total / 4
            )
        }
        ledger.days[dayKey] = bucket
        ledger.months[monthKey] = bucket.totals
        return ledger
    }
}
