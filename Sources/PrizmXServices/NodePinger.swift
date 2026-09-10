import Foundation
import Network
import PrizmXNodes
import PrizmXProtocols

/// Concurrent TCP RTT probe against `OutboundNode` servers.
///
/// Returns milliseconds, or `nil` on timeout / connect failure. Direct nodes
/// are skipped (`nil`). This does not dial through the proxy handshake — it
/// measures reachability of the outbound server itself.
///
/// Node domains are dialed via their pinned IPv4 (`NodeAddressStore`), never
/// the system resolver: with TUN on, the system resolver is the tunnel's
/// FakeDNS and would hand back unreachable fake IPs for proxy-routed names.
public struct NodePinger: Sendable {
    public var timeout: Duration
    public var maxConcurrent: Int

    public init(timeout: Duration = .seconds(3), maxConcurrent: Int = 8) {
        self.timeout = timeout
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Probes a single node. `nil` means timeout or unreachable.
    public func ping(_ node: OutboundNode) async -> Double? {
        guard let server = node.probeEndpoint else { return nil }
        return await measure(
            server: Self.dialTarget(for: server, pins: NodeAddressStore.load()),
            serverName: server.host.description
        )
    }

    /// Probes every node with a bounded worker pool and streams results live.
    @discardableResult
    public func pingAll(
        _ nodes: [OutboundNode],
        progress: (@MainActor @Sendable (String, Double?) -> Void)? = nil
    ) async -> [String: Double?] {
        guard !nodes.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, Double?).self, returning: [String: Double?].self) { group in
            var iterator = nodes.makeIterator()
            let pins = NodeAddressStore.load()
            var inFlight = 0
            var results: [String: Double?] = [:]
            results.reserveCapacity(nodes.count)

            func enqueue() {
                while inFlight < maxConcurrent, !Task.isCancelled, let node = iterator.next() {
                    inFlight += 1
                    group.addTask(priority: .utility) {
                        var rtt: Double?
                        if let server = node.probeEndpoint {
                            rtt = await self.measure(
                                server: Self.dialTarget(for: server, pins: pins),
                                serverName: server.host.description
                            )
                        }
                        return (node.id, rtt)
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

    // MARK: - Pin lookup

    /// Pinned-IP dial target for a domain endpoint; IP literals and unpinned
    /// domains pass through unchanged.
    public static func dialTarget(
        for endpoint: Endpoint,
        pins: [String: [PrizmXProtocols.IPv4Address]]
    ) -> Endpoint {
        guard case .domain(let name) = endpoint.host,
              let pinned = pins[name.lowercased()]?.first else { return endpoint }
        return Endpoint(host: .ipv4(pinned), port: endpoint.port)
    }

    // MARK: - Transport

    private func measure(server: Endpoint, serverName: String) async -> Double? {
        guard let nwEndpoint = Self.makeNWEndpoint(server) else { return nil }

        let parameters = NWParameters.tcp
        parameters.expiredDNSBehavior = .allow
        let connection = NWConnection(to: nwEndpoint, using: parameters)
        let start = ContinuousClock.now

        let handshake = await connect(connection, timeout: timeout)
        guard handshake else {
            connection.cancel()
            return nil
        }
        if Task.isCancelled {
            connection.cancel()
            return nil
        }

        connection.cancel()
        return Self.milliseconds(from: start)
    }

    private func connect(_ connection: NWConnection, timeout: Duration) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let gate = ResumeGate()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        gate.finish(true, continuation)
                    case .failed, .cancelled:
                        connection.stateUpdateHandler = nil
                        gate.finish(false, continuation)
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .utility))
                Task {
                    try? await Task.sleep(for: timeout)
                    if gate.finish(false, continuation) {
                        connection.cancel()
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Ensures a `CheckedContinuation` is resumed at most once.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        @discardableResult
        func finish(_ value: Bool, _ continuation: CheckedContinuation<Bool, Never>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            continuation.resume(returning: value)
            return true
        }
    }

    private static func makeNWEndpoint(_ endpoint: Endpoint) -> NWEndpoint? {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return nil }
        let host: NWEndpoint.Host
        switch endpoint.host {
        case .domain(let name):
            host = NWEndpoint.Host(name)
        case .ipv4(let address):
            host = NWEndpoint.Host(address.description)
        case .ipv6(let address):
            host = NWEndpoint.Host(address.description)
        }
        return .hostPort(host: host, port: port)
    }

    private static func milliseconds(from start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
