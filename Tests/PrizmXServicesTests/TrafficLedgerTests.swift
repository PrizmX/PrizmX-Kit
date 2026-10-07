import Foundation
import Testing
@testable import PrizmXServices

private func sample(uplink: UInt64, domains: [String: UInt64]) -> VPNMetrics {
    var metrics = VPNMetrics.zero
    metrics.uplinkBytes = uplink
    metrics.domainBytes = domains.mapValues { TrafficByteCount(up: $0, down: 0) }
    return metrics
}

@MainActor
@Test
func trafficLedgerPrunesOldDaysAndCapsDomains() {
    let ledger = TrafficLedger(fileURL: nil, defaults: .standard)
    ledger.ingest(.zero)
    var domains: [String: UInt64] = [:]
    for index in 0..<(TrafficLedger.maxRankedKeys * 2) {
        domains["host-\(index).example"] = UInt64(index + 1)
    }
    ledger.ingest(sample(uplink: 1_000_000, domains: domains))

    let now = Date()
    // 40 days later the bucket above is outside the retention window.
    let later = Calendar.current.date(byAdding: .day, value: 40, to: now)!
    ledger.prune(now: now)
    #expect(ledger.totals(for: .day, now: now).uploadProxy > 0)
    let top = ledger.rows(for: .domain, now: now)
    #expect(top.first?.name == "host-\(TrafficLedger.maxRankedKeys * 2 - 1).example")

    ledger.prune(now: later)
    #expect(ledger.totals(for: .day, now: now).uploadProxy == 0)
}

@MainActor
@Test
func trafficLedgerMigratesFromUserDefaultsOnce() throws {
    let suite = "prizmx.tests.ledger.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("ledger-\(UUID().uuidString)")
        .appendingPathComponent("TrafficLedger.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    var bucket = TrafficLedger.DayBucket()
    bucket.totals.uploadProxy = 4_096
    bucket.domain = ["a.example": 4_096]
    let legacy = TrafficLedger.File(
        days: [TrafficLedger.dayKey(.now): bucket],
        months: [:],
        last: .zero
    )
    defaults.set(try JSONEncoder().encode(legacy), forKey: TrafficLedger.defaultsKey)

    let migrated = TrafficLedger(fileURL: file, defaults: defaults)
    #expect(migrated.totals(for: .day).uploadProxy == 4_096)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(defaults.data(forKey: TrafficLedger.defaultsKey) == nil)
}

@MainActor
@Test
func trafficLedgerRanksExitsAndCountsGroupDirectAsDirect() throws {
    let ledger = TrafficLedger(fileURL: nil, defaults: .standard)
    let counter = TrafficCounter()
    ledger.ingest(counter.snapshot())
    // A rule on a group that selects DIRECT, and a proxied UDP flow.
    counter.addBytes(up: 100, down: 900, route: FlowRoute([FlowRoute.direct, "🎯Direct"]), transport: .tcp)
    counter.addBytes(up: 50, down: 450, route: FlowRoute(["JP 03", "AI"]), transport: .udp)
    ledger.ingest(counter.snapshot())

    let totals = ledger.totals(for: .day)
    #expect(totals.uploadDirect == 100)
    #expect(totals.downloadDirect == 900)
    #expect(totals.uploadProxy == 50)
    #expect(totals.downloadProxy == 450)

    let exits = ledger.rows(for: .exit)
    #expect(exits.map(\.name) == [FlowRoute.direct, "JP 03"])
    #expect(exits.map(\.tcpBytes) == [1_000, 0])
    #expect(exits.map(\.udpBytes) == [0, 500])

    let policies = ledger.rows(for: .policy)
    #expect(policies.map(\.name) == [FlowRoute.direct, "AI"])
    // DIRECT's protocol split comes from the DIRECT exit.
    #expect(policies.first?.tcpBytes == 1_000)
    #expect(policies.last?.udpBytes == 500)
}

@MainActor
@Test
func trafficLedgerFlushWritesThrottledChanges() throws {
    let suite = "ledger-flush-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("ledger-\(UUID().uuidString)")
        .appendingPathComponent("TrafficLedger.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let ledger = TrafficLedger(fileURL: file, defaults: defaults)
    let counter = TrafficCounter()
    ledger.ingest(counter.snapshot())
    counter.addBytes(up: 100, down: 900, route: FlowRoute(["Proxies"]), transport: .tcp)
    // First change writes at once; the next one falls inside the interval.
    ledger.ingest(counter.snapshot())
    counter.addBytes(up: 50, down: 450, route: FlowRoute(["Proxies"]), transport: .tcp)
    ledger.ingest(counter.snapshot())

    ledger.flush()
    let reloaded = TrafficLedger(fileURL: file, defaults: defaults)
    let totals = reloaded.totals(for: .day)
    #expect(totals.uploadProxy == 150)
    #expect(totals.downloadProxy == 1_350)
}
