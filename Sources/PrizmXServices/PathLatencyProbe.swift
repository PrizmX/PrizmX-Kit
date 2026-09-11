import Foundation
import Network
import PrizmXProtocols

/// Direct-path probes for the Home Latency tile.
///
/// Internet RTT is a TCP handshake to a public IP (not the selected node).
/// DNS is a UDP A-query to the physical resolver, never FakeIP `198.18.0.2`.
/// `preferNoProxies` keeps both off System Proxy / mixed-port.
public struct PathLatencyProbe: Sendable {
    public var timeout: Duration

    /// Cloudflare then AliDNS — first success wins so a blocked `1.1.1.1`
    /// still yields a number on a mainland path.
    public static let internetHosts = ["1.1.1.1", "223.5.5.5"]
    public static let dnsProbeDomain = "www.apple.com"

    public init(timeout: Duration = .seconds(2)) {
        self.timeout = timeout
    }

    public func measureInternet() async -> Double? {
        await withTaskGroup(of: Double?.self) { group in
            for host in Self.internetHosts {
                group.addTask { await self.tcpRTT(host: host, port: 443) }
            }
            var first: Double?
            for await sample in group {
                guard let sample else { continue }
                first = sample
                group.cancelAll()
                break
            }
            return first
        }
    }

    public func measureDNS() async -> Double? {
        let servers = PhysicalDNSSnapshot.capture()
        guard let ip = servers.first,
              let endpoint = NameserverEndpoint.udp(ip: ip),
              let transport = try? NameserverFactory.make(endpoint)
        else { return nil }
        let start = ContinuousClock.now
        do {
            _ = try await transport.query(Self.dnsProbeDomain)
            return Self.milliseconds(from: start)
        } catch {
            return nil
        }
    }

    private func tcpRTT(host: String, port: UInt16) async -> Double? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        parameters.expiredDNSBehavior = .allow
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )
        let start = ContinuousClock.now
        let ok = await connect(connection)
        connection.cancel()
        guard ok else { return nil }
        return Self.milliseconds(from: start)
    }

    private func connect(_ connection: NWConnection) async -> Bool {
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

    private static func milliseconds(from start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
