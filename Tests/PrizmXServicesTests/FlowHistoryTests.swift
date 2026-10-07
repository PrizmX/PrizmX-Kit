import Foundation
import Testing
@testable import PrizmXServices

private let base = Date(timeIntervalSince1970: 1_800_000_000)

private func flow(
    _ id: UUID = UUID(),
    startedAt seconds: Double,
    closed: Bool,
    up: UInt64 = 0,
    milliseconds: Int = 0
) -> FlowRecord {
    FlowRecord(
        id: id,
        startedAt: base.addingTimeInterval(seconds),
        endpoint: Endpoint(domain: "example.com", port: 443),
        route: FlowRoute(["Proxies"]),
        uplinkBytes: up,
        milliseconds: milliseconds,
        closed: closed
    )
}

/// `tcp` defaults to the active count, i.e. a complete open list.
private func snapshot(
    active: [FlowRecord] = [],
    recent: [FlowRecord] = [],
    tcp: Int? = nil
) -> TrafficSnapshot {
    TrafficSnapshot(
        tcpConnections: tcp ?? active.count,
        activeFlows: active,
        recentFlows: recent
    )
}

@Test func flowHistoryUpdatesRowInPlaceWhenFlowCloses() {
    let id = UUID()
    var history = FlowHistory()
    history.ingest(snapshot(active: [flow(id, startedAt: 0, closed: false, up: 10)]))
    #expect(history.flows.map(\.closed) == [false])

    history.ingest(snapshot(recent: [flow(id, startedAt: 0, closed: true, up: 40, milliseconds: 900)]))
    #expect(history.flows.count == 1)
    #expect(history.flows[0].closed)
    #expect(history.flows[0].uplinkBytes == 40)
    #expect(history.flows[0].milliseconds == 900)
}

@Test func flowHistoryListsOpenAndFinishedNewestFirst() {
    let older = flow(startedAt: 0, closed: true, milliseconds: 5)
    let open = flow(startedAt: 1, closed: false)
    let newer = flow(startedAt: 2, closed: true, milliseconds: 5)
    var history = FlowHistory()
    history.ingest(snapshot(active: [open], recent: [older]))
    // A later window no longer has `older`; the row stays.
    history.ingest(snapshot(active: [open], recent: [newer]))
    #expect(history.flows.map(\.id) == [newer.id, open.id, older.id])
}

@Test func flowHistoryClosesOpenRowMissingFromCompleteList() {
    let open = flow(startedAt: 0, closed: false)
    var history = FlowHistory()
    history.ingest(snapshot(active: [open]))
    // Its closed record never arrived (window overflow / engine stopped).
    history.ingest(snapshot(), now: base.addingTimeInterval(3))
    #expect(history.flows.count == 1)
    #expect(history.flows[0].closed)
    #expect(history.flows[0].milliseconds == 3_000)
}

@Test func flowHistoryKeepsOpenRowWhenListIsCut() {
    let old = flow(startedAt: 0, closed: false)
    let new = flow(startedAt: 1, closed: false)
    var history = FlowHistory()
    history.ingest(snapshot(active: [new, old]))
    // Two splices still open, only the newest one listed.
    history.ingest(snapshot(active: [new], tcp: 2))
    #expect(history.flows.map(\.closed) == [false, false])
}

@Test func flowHistoryClearKeepsOpenRowsAndOlderRecordsStayGone() {
    let open = flow(startedAt: 0, closed: false)
    let done = flow(startedAt: 1, closed: true, milliseconds: 1_000)
    var history = FlowHistory()
    history.ingest(snapshot(active: [open], recent: [done]))

    history.clear(now: base.addingTimeInterval(10))
    #expect(history.flows.map(\.id) == [open.id])

    // The tunnel may still report `done` until it handles clearFlows.
    let later = flow(startedAt: 12, closed: true, milliseconds: 1_000)
    history.ingest(snapshot(active: [open], recent: [later, done]))
    #expect(history.flows.map(\.id) == [later.id, open.id])
}

@Test func flowHistoryTrimsOldestFinishedRowsFirst() {
    let longLived = flow(startedAt: 0, closed: false)
    let finished = (1...4).map { flow(startedAt: Double($0), closed: true, milliseconds: 5) }
    var history = FlowHistory(capacity: 3)
    history.ingest(snapshot(active: [longLived], recent: finished))
    #expect(history.flows.map(\.id) == [finished[3].id, finished[2].id, longLived.id])
}

@Test func flowHistoryMergesLateRowsBetweenKnownOnes() {
    let first = flow(startedAt: 0, closed: true, milliseconds: 5)
    let third = flow(startedAt: 2, closed: true, milliseconds: 5)
    let second = flow(startedAt: 1, closed: true, milliseconds: 5)
    let fourth = flow(startedAt: 3, closed: false)
    var history = FlowHistory()
    history.ingest(snapshot(recent: [first, third]))
    history.ingest(snapshot(active: [fourth], recent: [second]))
    #expect(history.flows.map(\.id) == [fourth.id, third.id, second.id, first.id])
}

@Test func flowHistoryReordersRowWhoseStartMoved() {
    let id = UUID()
    let other = flow(startedAt: 1, closed: true, milliseconds: 5)
    var history = FlowHistory()
    history.ingest(snapshot(recent: [flow(id, startedAt: 0, closed: true, milliseconds: 5), other]))
    #expect(history.flows.map(\.id) == [other.id, id])

    history.ingest(snapshot(recent: [flow(id, startedAt: 2, closed: true, milliseconds: 5)]))
    #expect(history.flows.map(\.id) == [id, other.id])
}

/// The full rebuild-and-sort `ingest` used before the incremental merge.
private func referenceIngest(_ flows: [FlowRecord], _ snapshot: TrafficSnapshot, now: Date) -> [FlowRecord] {
    var byID = Dictionary(uniqueKeysWithValues: flows.map { ($0.id, $0) })
    for flow in snapshot.activeFlows + snapshot.recentFlows {
        byID[flow.id] = flow
    }
    if snapshot.activeFlows.count >= snapshot.tcpConnections {
        let open = Set(snapshot.activeFlows.map(\.id))
        for flow in byID.values where !flow.closed && !open.contains(flow.id) {
            var closed = flow
            closed.closed = true
            closed.milliseconds = max(flow.milliseconds, Int(now.timeIntervalSince(flow.startedAt) * 1_000))
            byID[flow.id] = closed
        }
    }
    return byID.values.sorted {
        $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.id.uuidString > $1.id.uuidString
    }
}

@Test func flowHistoryMatchesFullSortAcrossPolls() {
    var seed: UInt64 = 0x5EED
    func next(_ bound: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((seed >> 33) % UInt64(bound))
    }
    let ids = (0..<40).map { _ in UUID() }
    var history = FlowHistory()
    var reference: [FlowRecord] = []
    for poll in 0..<200 {
        // Shared start times exercise the ID tie-break.
        let picks = (0..<next(8)).map { _ in ids[next(ids.count)] }
        let flows = picks.map { flow($0, startedAt: Double(next(30)), closed: next(2) == 0) }
        let active = flows.filter { !$0.closed }
        let snap = snapshot(
            active: active,
            recent: flows.filter(\.closed),
            tcp: active.count + next(2)
        )
        let now = base.addingTimeInterval(Double(poll))
        history.ingest(snap, now: now)
        reference = referenceIngest(reference, snap, now: now)
        #expect(history.flows == reference, "poll \(poll)")
    }
}
