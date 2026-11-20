import Foundation
import PrizmXConfig
import PrizmXCore
import PrizmXProtocols

#if os(macOS)
/// The app's side of `TunnelXPC`: asks the Packet Tunnel system extension for
/// its metrics. Connects on first use and again after the extension restarts;
/// `nil` means the tunnel is not reachable.
final class TunnelXPCClient: @unchecked Sendable {
    static let shared = TunnelXPCClient()

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var reachable: Bool?

    func fetchMetrics() async -> TrafficSnapshot? {
        let data = await request { $0.fetchMetrics(reply: $1) }
        let snapshot = data.flatMap { try? JSONDecoder().decode(TrafficSnapshot.self, from: $0) }
        note(reachable: snapshot != nil)
        return snapshot
    }

    /// The local clients of the mixed-port listeners, as the tunnel sees
    /// them right now.
    func fetchProxyClients() async -> [LoopbackClient]? {
        let data = await request { $0.fetchProxyClients(reply: $1) }
        return data.flatMap { try? JSONDecoder().decode([LoopbackClient].self, from: $0) }
    }

    private static let requestTimeout: Duration = .seconds(2)

    private func request(
        _ call: (any TunnelXPCService, @escaping (Data?) -> Void) -> Void
    ) async -> Data? {
        let connection = currentConnection()
        let identity = ObjectIdentifier(connection)
        return await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.requestTimeout)
                guard !Task.isCancelled else { return }
                self?.dropConnection(identity: identity)
                once.resume(nil)
            }
            once.armTimeout(task: timeoutTask)

            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                self?.dropConnection(identity: identity)
                once.resume(nil)
            } as? any TunnelXPCService
            guard let proxy else {
                dropConnection(identity: identity)
                once.resume(nil)
                return
            }
            call(proxy) { once.resume($0) }
        }
    }

    private func dropConnection(identity: ObjectIdentifier) {
        lock.lock()
        let target: NSXPCConnection?
        if let current = connection, ObjectIdentifier(current) == identity {
            target = current
            connection = nil
        } else {
            target = nil
        }
        lock.unlock()
        target?.invalidate()
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let created = NSXPCConnection(machServiceName: TunnelXPC.machServiceName, options: .privileged)
        created.remoteObjectInterface = NSXPCInterface(with: TunnelXPCService.self)
        created.setCodeSigningRequirement(TunnelXPC.tunnelRequirement)
        let identity = ObjectIdentifier(created)
        let drop: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if let current = self.connection, ObjectIdentifier(current) == identity {
                self.connection = nil
            }
            self.lock.unlock()
        }
        created.interruptionHandler = drop
        created.invalidationHandler = drop
        created.resume()
        connection = created
        return created
    }

    /// Logs each change of reachability once, not every second.
    private func note(reachable now: Bool) {
        lock.lock()
        let changed = reachable != now
        reachable = now
        lock.unlock()
        guard changed else { return }
        TunnelLog.write(
            now ? .info : .warn,
            now ? "xpc: metrics reachable" : "xpc: tunnel not reachable"
        )
    }

    /// The reply and the error handler may both fire; only the first counts.
    private final class OnceResume: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        private var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Data?, Never>) {
            self.continuation = continuation
        }

        func armTimeout(task: Task<Void, Never>) {
            lock.lock()
            if continuation == nil {
                task.cancel()
            } else {
                timeoutTask = task
            }
            lock.unlock()
        }

        func resume(_ value: Data?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            let task = timeoutTask
            timeoutTask = nil
            lock.unlock()
            task?.cancel()
            pending?.resume(returning: value)
        }
    }
}
#endif
