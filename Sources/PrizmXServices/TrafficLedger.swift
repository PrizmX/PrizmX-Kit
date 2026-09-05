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

    struct DayBucket: Codable {
        var totals = TrafficTotals()
        /// up+down per policy label (group name / "proxy").
        var policy: [String: UInt64] = [:]
        /// up+down per domain.
        var domain: [String: UInt64] = [:]
        /// Hour-of-day (0...23) → bytes.
        var hours: [Int: UInt64] = [:]
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

    /// Top rows for the Ranking card. `app` scope is empty on purpose: a
    /// packet tunnel cannot attribute flows to processes.
    public func rows(for scope: TrafficRankScope, now: Date = .now) -> [TrafficRankRow] {
        guard scope != .app else { return [] }
        let bucket = days[Self.dayKey(now)] ?? DayBucket()
        var source = scope == .domain ? bucket.domain : bucket.policy
        if scope == .policy {
            // Direct traffic bypasses the proxy plane; rank it as its own row.
            let directTotal = bucket.totals.uploadDirect + bucket.totals.downloadDirect
            if directTotal > 0 { source["DIRECT"] = directTotal }
        }
        let sorted = source.sorted { $0.value > $1.value }.prefix(8)
        let peak = max(sorted.first?.value ?? 1, 1)
        return sorted.enumerated().map { index, entry in
            TrafficRankRow(
                id: "\(scope.rawValue)-\(index)",
                name: scope == .policy && entry.key == "proxy" ? "Proxy" : entry.key,
                bytes: entry.value,
                fraction: Double(entry.value) / Double(peak),
                systemImage: scope == .domain ? "globe" : Self.policyIcon(entry.key)
            )
        }
    }

    /// Today's 24 hourly buckets for the Ranking chart.
    public func hourly(now: Date = .now) -> [RankingHourSample] {
        let bucket = days[Self.dayKey(now)] ?? DayBucket()
        return (0..<24).map { hour in
            RankingHourSample(hour: hour, bytes: Double(bucket.hours[hour] ?? 0))
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
        day.totals.uploadProxy &+= uploadDelta - directUpDelta
        day.totals.downloadProxy &+= downloadDelta - directDownDelta
        month.uploadDirect &+= directUpDelta
        month.downloadDirect &+= directDownDelta
        month.uploadProxy &+= uploadDelta - directUpDelta
        month.downloadProxy &+= downloadDelta - directDownDelta

        for (policy, bytes) in policyDeltas {
            day.policy[policy, default: 0] &+= bytes
        }
        for (domain, bytes) in domainDeltas {
            day.domain[domain, default: 0] &+= bytes
        }
        day.hours[hour, default: 0] &+= uploadDelta + downloadDelta

        days[dayKey] = day
        months[monthKey] = month
        persist()
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

    private func persist() {
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
            bucket.hours[hour] = UInt64(20_000_000 * (hour == 13 ? 5 : 1))
        }
        ledger.days[dayKey] = bucket
        ledger.months[monthKey] = bucket.totals
        return ledger
    }
}
