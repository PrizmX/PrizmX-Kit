import Foundation
import os
import Testing
@testable import PrizmXServices

private let apsd = FlowAttribution(pid: 617, processName: "apsd")

/// The app's own table: root clients are invisible.
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

private func counting(_ clients: [LoopbackClient]?, in count: OSAllocatedUnfairLock<Int>) -> @Sendable () async -> [LoopbackClient]? {
    {
        count.withLock { $0 += 1 }
        return clients
    }
}

@Test func tunnelAssistedAttributorGivesUpWithoutTheTunnel() async {
    let attributor = TunnelAssistedAttributor(local: NoLocalAttribution(), fetch: { nil })
    let late = await attributor.attributeLate(transport: .tcp, localPort: 52_500, remotePort: 7_890, since: Date())
    #expect(late == nil)
}

@Test func tunnelAssistedAttributorFindsAClientTheTunnelListsAndTrustsAMiss() async {
    let client = LoopbackClient(clientPort: 52_500, listenPort: 7_890, attribution: apsd)
    let attributor = TunnelAssistedAttributor(local: NoLocalAttribution(), fetch: { [client] })
    let since = Date()
    #expect(await attributor.attributeLate(transport: .tcp, localPort: 52_500, remotePort: 7_890, since: since) == apsd)
    // Another port on the same listener, and the same port on another listener.
    #expect(await attributor.attributeLate(transport: .tcp, localPort: 52_501, remotePort: 7_890, since: since) == nil)
    #expect(await attributor.attributeLate(transport: .tcp, localPort: 52_500, remotePort: 7_891, since: since) == nil)
}

@Test func tunnelAssistedAttributorSharesAReplyOnlyWithLookupsThatBeganBeforeIt() async {
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let attributor = TunnelAssistedAttributor(local: NoLocalAttribution(), fetch: counting([], in: calls))
    let earlier = Date()
    _ = await attributor.attributeLate(transport: .tcp, localPort: 52_500, remotePort: 7_890, since: earlier)
    _ = await attributor.attributeLate(transport: .tcp, localPort: 52_501, remotePort: 7_890, since: earlier)
    #expect(calls.withLock { $0 } == 1)

    // A socket opened after that request may be missing from its reply.
    try? await Task.sleep(for: .milliseconds(5))
    _ = await attributor.attributeLate(transport: .tcp, localPort: 52_502, remotePort: 7_890, since: Date())
    #expect(calls.withLock { $0 } == 2)
}
