import Foundation
import Network
import PrizmXNodes
import PrizmXProtocols

/// Delay-test strategy for `NodePinger`.
public enum NodePingMethod: Sendable, Hashable {
    /// TCP handshake against the node's server endpoint.
    case tcp
    /// TCP handshake followed by a raw HTTP/1.1 `HEAD` on the same connection.
    case http(path: String = "/")
}

/// Concurrent TCP / HTTP RTT probe against `OutboundNode` servers.
///
/// Returns milliseconds, or `nil` on timeout / connect failure. Direct nodes
/// are skipped (`nil`). This does not dial through the proxy handshake — it
/// measures reachability of the outbound server itself.
public struct NodePinger: Sendable {
    public var timeout: Duration
    public var maxConcurrent: Int

    public init(timeout: Duration = .seconds(3), maxConcurrent: Int = 8) {
        self.timeout = timeout
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Probes a single node. `nil` means timeout or unreachable.
    public func ping(_ node: OutboundNode, method: NodePingMethod = .tcp) async -> Double? {
        guard let server = node.probeServer else { return nil }
        return await measure(server: server, method: method)
    }

    /// Probes every node with a bounded worker pool and streams results live.
    @discardableResult
    public func pingAll(
        _ nodes: [OutboundNode],
        method: NodePingMethod = .tcp,
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
                        let rtt = await self.ping(node, method: method)
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

    // MARK: - Transport

    private func measure(server: Endpoint, method: NodePingMethod) async -> Double? {
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

        switch method {
        case .tcp:
            connection.cancel()
            return Self.milliseconds(from: start)
        case .http(let path):
            let ok = await sendHEAD(connection, host: server.host.description, path: path)
            connection.cancel()
            return ok ? Self.milliseconds(from: start) : nil
        }
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

    private func sendHEAD(_ connection: NWConnection, host: String, path: String) async -> Bool {
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        let request = Data(
            "HEAD \(normalizedPath) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8
        )

        let sent: Bool = await withCheckedContinuation { continuation in
            connection.send(content: request, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
        guard sent else { return false }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ResumeGate()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, error in
                let ok = error == nil && (data?.isEmpty == false)
                gate.finish(ok, continuation)
            }
            Task {
                try? await Task.sleep(for: timeout)
                gate.finish(false, continuation)
            }
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
