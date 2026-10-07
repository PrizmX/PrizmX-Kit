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
    /// Legacy home of the ledger; migrated to `fileURL` once, then removed.
    static let defaultsKey = "trafficLedger.v2"
    /// Days kept for the day buckets (months keep their own totals).
    static let retainedDays = 35
    static let retainedMonths = 24
    /// Per-day cap for domain / app rankings; trimmed back to this once a
    /// bucket grows 20% past it.
    static let maxRankedKeys = 500

    /// Application Support/<bundle id>/TrafficLedger.json.
    public static var defaultFileURL: URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let folder = Bundle.main.bundleIdentifier ?? "PrizmX"
        return support
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("TrafficLedger.json", isDirectory: false)
    }

    struct HourBucket: Codable, Equatable {
        var total: UInt64 = 0
        var proxy: UInt64 = 0
        var direct: UInt64 = 0
    }

    struct DayBucket: Codable {
        var totals = TrafficTotals()
        /// up+down per rule policy, proxied traffic only (direct is in totals).
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
        /// up+down per exit (`DIRECT` or a node), all traffic.
        var exit: [String: UInt64] = [:]
        var exitTCP: [String: UInt64] = [:]
        var exitUDP: [String: UInt64] = [:]
        /// Hour-of-day (0...23) → proxy / direct / total.
        var hours: [Int: HourBucket] = [:]

        /// Keeps the top `limit` domains / apps by bytes and drops their
        /// per-protocol and name entries along with them.
        mutating func trimRankings(limit: Int) {
            if domain.count > limit {
                let kept = Self.topKeys(domain, limit: limit)
                domain = domain.filter { kept.contains($0.key) }
                domainTCP = domainTCP.filter { kept.contains($0.key) }
                domainUDP = domainUDP.filter { kept.contains($0.key) }
            }
            if app.count > limit {
                let kept = Self.topKeys(app, limit: limit)
                app = app.filter { kept.contains($0.key) }
                appTCP = appTCP.filter { kept.contains($0.key) }
                appUDP = appUDP.filter { kept.contains($0.key) }
                appNames = appNames.filter { kept.contains($0.key) }
            }
        }

        private static func topKeys(_ source: [String: UInt64], limit: Int) -> Set<String> {
            Set(source.sorted { $0.value > $1.value }.prefix(limit).map(\.key))
        }

        enum CodingKeys: String, CodingKey {
            case totals, policy, domain, app, appNames, hours
            case appTCP, appUDP, domainTCP, domainUDP, policyTCP, policyUDP
            case exit, exitTCP, exitUDP
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
            exit = try container.decodeIfPresent([String: UInt64].self, forKey: .exit) ?? [:]
            exitTCP = try container.decodeIfPresent([String: UInt64].self, forKey: .exitTCP) ?? [:]
            exitUDP = try container.decodeIfPresent([String: UInt64].self, forKey: .exitUDP) ?? [:]
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
    /// nil keeps the ledger in memory only (previews, tests).
    private let fileURL: URL?
    /// Serial so an older snapshot never lands after a newer one.
    private let writer = DispatchQueue(label: "app.prizmx.traffic-ledger", qos: .utility)

    public convenience init() {
        self.init(fileURL: Self.defaultFileURL, defaults: .standard)
    }

    init(fileURL: URL?, defaults: UserDefaults) {
        self.fileURL = fileURL
        days = [:]
        months = [:]
        last = .zero
        guard let fileURL else { return }
        if let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder().decode(File.self, from: data) {
            load(file)
        } else if let data = defaults.data(forKey: Self.defaultsKey),
                  let file = try? JSONDecoder().decode(File.self, from: data) {
            load(file)
            prune(now: .now)
            if Self.write(file: currentFile(), to: fileURL) {
                defaults.removeObject(forKey: Self.defaultsKey)
            }
        }
    }

    private func load(_ file: File) {
        days = file.days
        months = file.months
        last = file.last
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
            if directTotal > 0 { source[FlowRoute.direct] = directTotal }
        case .exit:
            source = bucket.exit
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
            case .policy, .exit:
                name = entry.key
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
            case .policy where entry.key == FlowRoute.direct:
                // Direct bytes are not in the policy maps; the DIRECT exit holds them.
                tcp = bucket.exitTCP[entry.key] ?? 0
                udp = bucket.exitUDP[entry.key] ?? 0
            case .policy:
                tcp = bucket.policyTCP[entry.key] ?? 0
                udp = bucket.policyUDP[entry.key] ?? 0
            case .exit:
                tcp = bucket.exitTCP[entry.key] ?? 0
                udp = bucket.exitUDP[entry.key] ?? 0
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
        let exitDeltas = Self.diff(metrics.exitBytes, minus: last.exitBytes)
        let exitTCPDeltas = Self.diffCount(metrics.exitTCPBytes, minus: last.exitTCPBytes)
        let exitUDPDeltas = Self.diffCount(metrics.exitUDPBytes, minus: last.exitUDPBytes)
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
        for (exit, bytes) in exitDeltas {
            day.exit[exit, default: 0] &+= bytes
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
        Self.addCounts(&day.exitTCP, exitTCPDeltas)
        Self.addCounts(&day.exitUDP, exitUDPDeltas)
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
        if label == FlowRoute.direct { return "arrow.right" }
        return "arrow.triangle.branch"
    }

    /// Ingest runs on a 1s metrics loop and each write encodes the full
    /// day/month model, so changes are written at most once a minute;
    /// `flush()` covers quit and sleep.
    static let persistInterval: TimeInterval = 60
    private var lastPersist = Date.distantPast
    /// Ingested changes not yet handed to the writer.
    private var hasPendingChanges = false

    private func persist() {
        hasPendingChanges = true
        let now = Date()
        guard now.timeIntervalSince(lastPersist) >= Self.persistInterval else { return }
        enqueueWrite(now: now)
    }

    /// Writes pending changes and waits until they are on disk. For quit and
    /// sleep, where the throttled write may not come.
    public func flush() {
        guard hasPendingChanges else { return }
        enqueueWrite(now: .now)
        writer.sync {}
    }

    /// Encoding and the write run off the main actor.
    private func enqueueWrite(now: Date) {
        lastPersist = now
        hasPendingChanges = false
        prune(now: now)
        guard let fileURL else { return }
        let file = currentFile()
        writer.async {
            Self.write(file: file, to: fileURL)
        }
    }

    /// Flow lists are UI state, not part of the diff baseline.
    private func currentFile() -> File {
        var baseline = last
        baseline.activeFlows = []
        baseline.recentFlows = []
        return File(days: days, months: months, last: baseline)
    }

    @discardableResult
    nonisolated private static func write(file: File, to url: URL) -> Bool {
        do {
            let data = try JSONEncoder().encode(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Drops day buckets past the retention window and trims the long tail
    /// of per-day domain / app keys.
    func prune(now: Date) {
        let calendar = Calendar.current
        if let cutoff = calendar.date(byAdding: .day, value: -Self.retainedDays, to: now) {
            let oldestDay = Self.dayKey(cutoff)
            // yyyy-MM-dd keys sort chronologically.
            days = days.filter { $0.key >= oldestDay }
        }
        if let cutoff = calendar.date(byAdding: .month, value: -Self.retainedMonths, to: now) {
            let oldestMonth = Self.monthKey(cutoff)
            months = months.filter { $0.key >= oldestMonth }
        }
        let threshold = Self.maxRankedKeys + Self.maxRankedKeys / 5
        for (key, bucket) in days where bucket.domain.count > threshold || bucket.app.count > threshold {
            var trimmed = bucket
            trimmed.trimRankings(limit: Self.maxRankedKeys)
            days[key] = trimmed
        }
    }

    static func dayKey(_ date: Date) -> String {
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

    struct File: Codable {
        var days: [String: DayBucket]
        var months: [String: TrafficTotals]
        var last: VPNMetrics
    }
}

extension TrafficLedger {
    /// Seeded buckets so Home previews show a populated Ranking card.
    public static var preview: TrafficLedger {
        let ledger = TrafficLedger(fileURL: nil, defaults: .standard)
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
