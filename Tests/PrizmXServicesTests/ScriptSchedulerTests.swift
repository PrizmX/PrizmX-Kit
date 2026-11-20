import Foundation
import Testing
import PrizmXScripts
@testable import PrizmXServices

@MainActor
@Test func scriptSchedulerRunsCronAndNetworkEventsWithPersistentStore() async throws {
    let store = ScriptStore(storage: .memory)
    let kv = InMemoryScriptPersistentStore()
    let cron = ScriptRecord(
        name: "heartbeat",
        enabled: true,
        kind: .cron,
        pattern: "30 14 * * *",
        source: #"$persistentStore.write("cron-ok", "last"); $done({ ok: true })"#
    )
    let event = ScriptRecord(
        name: "net-watch",
        enabled: true,
        kind: .event,
        pattern: "network-changed",
        source: #"$persistentStore.write($network.wifi.ssid || "none", "ssid"); $done($network.wifi.ssid)"#
    )
    try store.upsert(cron)
    try store.upsert(event)

    let scheduler = ScriptScheduler(
        store: store,
        persistentStore: kv,
        networkProvider: { ScriptNetworkInfo(v4PrimaryAddress: "10.0.0.2", wifiSSID: "Office") }
    )

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let matchDate = DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: 11, day: 20, hour: 14, minute: 30).date!

    await scheduler.tickCron(at: matchDate, calendar: cal)
    #expect(kv.read(key: "last") == "cron-ok")
    #expect(scheduler.lastRunByID[cron.id]?.succeeded == true)

    await scheduler.triggerNetworkChangedEventNow()
    #expect(kv.read(key: "ssid") == "Office")
    #expect(scheduler.lastRunByID[event.id]?.succeeded == true)

    let builtIn = ScriptStore.builtInScripts.first { $0.name == "Network Snapshot" }!
    let snapshotSummary = await scheduler.runNow(builtIn)
    #expect(snapshotSummary.succeeded)
    #expect(kv.read(key: "prizmx.lastSnapshotAt") != nil)
}
