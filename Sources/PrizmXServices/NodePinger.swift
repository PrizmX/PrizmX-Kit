import Foundation
import PrizmXConfig
import PrizmXNodes
import PrizmXProtocols

/// Concurrent delay test (Clash "delay"): an HTTP request to `testURL`
/// through each node's own protocol, the same probe url-test groups send.
/// A node that accepts TCP but cannot carry traffic (wrong password, blocked
/// handshake, dead relay exit) reads as a timeout, not as a low ping.
///
/// Returns milliseconds, or `nil` on timeout / failure. Direct nodes are
/// skipped (`nil`). Node hostnames resolve through the profile's DNS and the
/// pinned addresses (`NodeAddressStore`), never the tunnel's FakeDNS.
public struct NodePinger: Sendable {
    public var timeout: Duration
    public var maxConcurrent: Int
    public var testURL: URL

    public init(
        timeout: Duration = .seconds(5),
        maxConcurrent: Int = 8,
        testURL: URL = URL(string: PolicyGroup.defaultTestURL)!
    ) {
        self.timeout = timeout
        self.maxConcurrent = max(1, maxConcurrent)
        self.testURL = testURL
    }

    /// Resolver for a test run against the profile in `configText`.
    public static func resolver(for configText: String?) -> DNSClient {
        EngineFactory.makeAppDNS(
            configText: configText,
            systemDNS: PhysicalDNSSnapshot.capture(),
            pinnedNodeAddresses: NodeAddressStore.load()
        )
    }

    /// Probes a single node. `nil` means timeout or failure.
    public func ping(_ node: OutboundNode, dns: DNSClient) async -> Double? {
        guard node.probeEndpoint != nil else { return nil }
        return await measure(node, dns: dns)
    }

    /// Probes every node with a bounded worker pool and streams results live.
    @discardableResult
    public func pingAll(
        _ nodes: [OutboundNode],
        dns: DNSClient,
        progress: (@MainActor @Sendable (String, Double?) -> Void)? = nil
    ) async -> [String: Double?] {
        guard !nodes.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, Double?).self, returning: [String: Double?].self) { group in
            var iterator = nodes.makeIterator()
            var inFlight = 0
            var results: [String: Double?] = [:]
            results.reserveCapacity(nodes.count)

            func enqueue() {
                while inFlight < maxConcurrent, !Task.isCancelled, let node = iterator.next() {
                    inFlight += 1
                    group.addTask(priority: .utility) {
                        guard node.probeEndpoint != nil else { return (node.id, nil) }
                        return (node.id, await self.measure(node, dns: dns))
                    }
                }
            }

            enqueue()
            for await item in group {
                inFlight -= 1
                results[item.0] = item.1
                if let progress {
                    await progress(item.0, item.1)
                }
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                enqueue()
            }
            return results
        }
    }

    private func measure(_ node: OutboundNode, dns: DNSClient) async -> Double? {
        let delay = await DNSClient.$current.withValue(dns) {
            await NodeDelayTest.measure(node, url: testURL, timeout: timeout)
        }
        guard let delay, !Task.isCancelled else { return nil }
        let components = delay.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
