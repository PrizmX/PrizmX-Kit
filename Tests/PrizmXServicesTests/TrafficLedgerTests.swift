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
