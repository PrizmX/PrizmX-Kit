import Foundation

#if os(macOS)
import os
import PrizmXProtocols
import PrizmXProxyHelper
import ServiceManagement

/// The app's side of `ProxyHelperXPC`: registers the privileged helper and
/// asks it to write proxy settings.
///
/// Registering only adds the helper to Login Items; it runs once the user
/// allows it there. Until then `write` reports `.unavailable` and
/// `SystemProxyConfigurator` falls back to asking for authorization.
public enum ProxyHelper {
    enum WriteResult {
        case written
        case failed(String)
        /// Not approved, not installed, or not reachable.
        case unavailable
    }

    private static let log = Logger(subsystem: "app.prizmx", category: "ProxyHelper")
    private static let timeout: DispatchTimeInterval = .seconds(2)

    private static var service: SMAppService {
        SMAppService.daemon(plistName: ProxyHelperXPC.plistName)
    }

    public static var status: SMAppService.Status { service.status }

    /// Registers the helper unless it already is. Returns true when this call
    /// registered it, so the caller can point the user at Login Items once.
    @discardableResult
    public static func registerIfNeeded() throws -> Bool {
        let service = service
        guard service.status == .notRegistered || service.status == .notFound else { return false }
        do {
            try service.register()
        } catch where service.status == .requiresApproval {
            // A daemon still waiting for approval in Login Items is
            // registered, though `register` reports it as an error.
        } catch {
            TunnelLog.write(.warn, "proxy helper register failed status=\(service.status.rawValue): \(error)")
            throw error
        }
        TunnelLog.write(.info, "proxy helper registered status=\(service.status.rawValue)")
        return true
    }

    /// Blocks until the helper replies or `timeout` passes.
    static func write(_ configs: [String: [String: Any]]) -> WriteResult {
        guard service.status == .enabled else { return .unavailable }
        guard let encoded = ProxyServiceWriter.encode(configs) else {
            return .failed("proxy settings are not a property list")
        }
        let connection = NSXPCConnection(machServiceName: ProxyHelperXPC.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ProxyHelperXPCService.self)
        connection.setCodeSigningRequirement(ProxyHelperXPC.helperRequirement)
        connection.resume()
        defer { connection.invalidate() }

        let outcome = Outcome()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            log.error("helper unreachable \(error.localizedDescription, privacy: .public)")
            outcome.finish(.unavailable)
        } as? any ProxyHelperXPCService
        guard let proxy else { return .unavailable }
        proxy.writeProxies(encoded) { error in
            outcome.finish(error.map(WriteResult.failed) ?? .written)
        }
        if let result = outcome.wait(timeout: timeout) {
            return result
        }
        log.error("helper timed out")
        return .unavailable
    }

    /// First reply wins; XPC may call both the reply and the error handler.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var result: WriteResult?

        func finish(_ value: WriteResult) {
            lock.lock()
            let first = result == nil
            if first { result = value }
            lock.unlock()
            if first { done.signal() }
        }

        func wait(timeout: DispatchTimeInterval) -> WriteResult? {
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }
}
#endif
