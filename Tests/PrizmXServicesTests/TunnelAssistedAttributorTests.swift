import Foundation
import os
import Testing
@testable import PrizmXServices

private let apsd = FlowAttribution(pid: 617, processName: "apsd")

/// The sandboxed app's own table: root clients are invisible.
private struct NoLocalAttribution: FlowAttributing {
    func attribute(
        transport: FlowTransport,
        localAddress: String,
        localPort: UInt16,
        remoteAddress: String,
        remotePort: UInt16
    ) -> FlowAttribution? {
        nil
    }
}

@Test func tunnelAssistedAttributorGivesUpWithoutTheTunnel() async {
    let attributor = TunnelAssistedAttributor(local: NoLocalAttribution(), load: { nil })
    let started = ContinuousClock.now
    let late = await attributor.attributeLate(transport: .tcp, localPort: 52_500, remotePort: 7_890, since: Date())
    #expect(late == nil)
    #expect(started.duration(to: .now) < TunnelAssistedAttributor.pollInterval)
}

@Test func tunnelAssistedAttributorWaitsForAWriteAfterTheLookup() async {
    let since = Date()
    let client = LoopbackClient(clientPort: 52_500, listenPort: 7_890, attribution: apsd)
    // The first file predates the lookup (it may miss the socket); the next is newer.
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let attributor = TunnelAssistedAttributor(local: NoLocalAttribution(), load: {
        let read = reads.withLock { count -> Int in
            count += 1
            return count
        }
        return ProxyClientStore.Snapshot(
            writtenAt: since.timeIntervalSince1970 + (read == 1 ? -0.5 : 0.5),
            clients: read == 1 ? [] : [client]
        )
    })
    let late = await attributor.attributeLate(transport: .tcp, localPort: 52_500, remotePort: 7_890, since: since)
    #expect(late == apsd)
    #expect(reads.withLock { $0 } == 2)
}

@Test func tunnelAssistedAttributorTrustsAFreshMiss() async {
    let since = Date()
    let attributor = TunnelAssistedAttributor(local: NoLocalAttribution(), load: {
        ProxyClientStore.Snapshot(writtenAt: since.timeIntervalSince1970 + 0.5, clients: [])
    })
    let late = await attributor.attributeLate(transport: .tcp, localPort: 52_500, remotePort: 7_890, since: since)
    #expect(late == nil)
}
