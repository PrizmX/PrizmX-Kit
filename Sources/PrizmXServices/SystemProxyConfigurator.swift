import Foundation
import os
import PrizmXProtocols

#if os(macOS)
import Security
import SystemConfiguration

/// Writes the macOS System Configuration HTTP/HTTPS/SOCKS proxy (what
/// System Settings → Network → Proxies shows).
///
/// `apply` / `restore` are no-ops when the desired state is already in
/// effect (our applied flag). Authorization is copied once per process.
public enum SystemProxyConfigurator {
    private static let backupKey = "prizmx.systemProxy.backup"
    private static let appliedKey = "prizmx.systemProxy.applied"
    private static let endpointKey = "prizmx.systemProxy.endpoint"
    private static let log = Logger(subsystem: "app.prizmx", category: "SystemProxy")
    private static let box = AuthBox()

    private final class AuthBox: @unchecked Sendable {
        let lock = NSLock()
        var auth: AuthorizationRef?
        var copiedRights = false
    }

    public static func apply(host: String = "127.0.0.1", port: Int = TunnelProviderKeys.defaultMixedPort) {
        apply(host: host, httpPort: port, socksPort: port)
    }

    public static func apply(
        host: String = "127.0.0.1",
        httpPort: Int,
        socksPort: Int
    ) {
        let endpoint = "\(host):\(httpPort)/\(socksPort)"
        box.lock.lock()
        defer { box.lock.unlock() }
        if UserDefaults.standard.bool(forKey: appliedKey),
           UserDefaults.standard.string(forKey: endpointKey) == endpoint {
            return
        }
        let ok = mutateServices { current, _ in
            var next = current
            next[kSCPropNetProxiesHTTPEnable as String] = 1
            next[kSCPropNetProxiesHTTPProxy as String] = host
            next[kSCPropNetProxiesHTTPPort as String] = httpPort
            next[kSCPropNetProxiesHTTPSEnable as String] = 1
            next[kSCPropNetProxiesHTTPSProxy as String] = host
            next[kSCPropNetProxiesHTTPSPort as String] = httpPort
            next[kSCPropNetProxiesSOCKSEnable as String] = 1
            next[kSCPropNetProxiesSOCKSProxy as String] = host
            next[kSCPropNetProxiesSOCKSPort as String] = socksPort
            next[kSCPropNetProxiesExcludeSimpleHostnames as String] = 1
            next[kSCPropNetProxiesProxyAutoConfigEnable as String] = 0
            next[kSCPropNetProxiesExceptionsList as String] = [
                "127.0.0.1", "localhost", "*.local", "198.18.0.0/16"
            ]
            return next
        }
        guard ok else { return }
        UserDefaults.standard.set(true, forKey: appliedKey)
        UserDefaults.standard.set(endpoint, forKey: endpointKey)
        TunnelLog.write(.info, "system proxy apply \(endpoint)")
        log.info("applied \(endpoint, privacy: .public)")
    }

    public static func restore() {
        box.lock.lock()
        defer { box.lock.unlock() }
        guard UserDefaults.standard.bool(forKey: appliedKey) else { return }
        let backups = loadBackup()
        let ok = mutateServices { current, serviceID in
            if let backup = backups[serviceID] { return backup }
            // Backup entry missing (its write failed or the store was lost):
            // fail closed — switch every proxy off rather than leaving the
            // machine pointing at 127.0.0.1 forever.
            var cleared = current
            cleared[kSCPropNetProxiesHTTPEnable as String] = 0
            cleared[kSCPropNetProxiesHTTPSEnable as String] = 0
            cleared[kSCPropNetProxiesSOCKSEnable as String] = 0
            cleared[kSCPropNetProxiesProxyAutoConfigEnable as String] = 0
            return cleared
        }
        guard ok else { return }
        clearFlags()
        TunnelLog.write(.info, "system proxy restore")
        log.info("restored previous proxy settings")
    }

    @discardableResult
    private static func mutateServices(_ body: ([String: Any], String) -> [String: Any]) -> Bool {
        if box.copiedRights {
            guard let prefs = preferencesWithAuth() else { return false }
            return commit(prefs, body: body)
        }
        if let prefs = SCPreferencesCreate(nil, "PrizmX" as CFString, nil),
           commit(prefs, body: body) {
            return true
        }
        guard let prefs = preferencesWithAuth() else { return false }
        return commit(prefs, body: body)
    }

    private static func preferencesWithAuth() -> SCPreferences? {
        guard let auth = ensuredAuthorization() else { return nil }
        guard let prefs = SCPreferencesCreateWithAuthorization(
            nil,
            "PrizmX" as CFString,
            nil,
            auth
        ) else {
            log.error("SCPreferencesCreateWithAuthorization failed")
            TunnelLog.write(.error, "system proxy preferences create failed")
            return nil
        }
        return prefs
    }

    private static func ensuredAuthorization() -> AuthorizationRef? {
        if let auth = box.auth, box.copiedRights { return auth }
        var auth = box.auth
        if auth == nil {
            var created: AuthorizationRef?
            let status = AuthorizationCreate(nil, nil, [], &created)
            guard status == errAuthorizationSuccess, let created else {
                log.error("AuthorizationCreate failed \(status)")
                TunnelLog.write(.error, "system proxy auth failed \(status)")
                return nil
            }
            auth = created
            box.auth = created
        }
        guard let auth else { return nil }
        guard copyNetworkRight(auth) else { return nil }
        box.copiedRights = true
        return auth
    }

    private static func copyNetworkRight(_ auth: AuthorizationRef) -> Bool {
        let right = "system.services.systemconfiguration.network"
        let ok = right.withCString { name -> Bool in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var requested = AuthorizationRights(count: 1, items: pointer)
                let flags: AuthorizationFlags = [.extendRights, .interactionAllowed, .preAuthorize]
                return AuthorizationCopyRights(auth, &requested, nil, flags, nil) == errAuthorizationSuccess
            }
        }
        if !ok {
            log.error("AuthorizationCopyRights failed")
            TunnelLog.write(.error, "system proxy AuthorizationCopyRights failed")
        }
        return ok
    }

    private static func commit(
        _ prefs: SCPreferences,
        body: ([String: Any], String) -> [String: Any]
    ) -> Bool {
        guard let set = SCNetworkSetCopyCurrent(prefs) else { return false }
        guard let cfServices = SCNetworkSetCopyServices(set) else { return false }

        var snapshots: [String: [String: Any]] = [:]
        for case let service as SCNetworkService in cfServices as NSArray {
            guard SCNetworkServiceGetEnabled(service) else { continue }
            guard let serviceID = SCNetworkServiceGetServiceID(service) as String? else { continue }
            if shouldSkip(service) { continue }
            guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else {
                continue
            }
            let current = (SCNetworkProtocolGetConfiguration(proto) as? [String: Any]) ?? [:]
            snapshots[serviceID] = current
            let next = body(current, serviceID)
            if !SCNetworkProtocolSetConfiguration(proto, next as CFDictionary) {
                log.error("SetConfiguration failed for \(serviceID, privacy: .public)")
            }
        }

        snapshotIfNeeded(snapshots)

        if SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) {
            return true
        }
        let err = String(cString: SCErrorString(SCError()))
        log.error("commit/apply failed \(err, privacy: .public)")
        TunnelLog.write(.error, "system proxy commit failed \(err)")
        return false
    }

    private static func snapshotIfNeeded(_ current: [String: [String: Any]]) {
        guard UserDefaults.standard.data(forKey: backupKey) == nil else { return }
        saveBackup(current)
    }

    private static func shouldSkip(_ service: SCNetworkService) -> Bool {
        guard let iface = SCNetworkServiceGetInterface(service),
              let type = SCNetworkInterfaceGetInterfaceType(iface) as String? else {
            return false
        }
        let skipped = [
            kSCNetworkInterfaceTypePPP as String,
            kSCNetworkInterfaceTypeIPSec as String,
            kSCNetworkInterfaceType6to4 as String
        ]
        if skipped.contains(type) { return true }
        return type.lowercased().contains("vpn")
    }

    private static func clearFlags() {
        UserDefaults.standard.removeObject(forKey: backupKey)
        UserDefaults.standard.removeObject(forKey: endpointKey)
        UserDefaults.standard.set(false, forKey: appliedKey)
        UserDefaults.standard.removeObject(forKey: "prizmx.systemProxy.pacInstalled")
    }

    private static func saveBackup(_ snapshots: [String: [String: Any]]) {
        var encoded: [String: Data] = [:]
        for (id, dict) in snapshots {
            if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0) {
                encoded[id] = data
            }
        }
        if let data = try? JSONEncoder().encode(encoded.mapValues { $0.base64EncodedString() }) {
            UserDefaults.standard.set(data, forKey: backupKey)
        }
    }

    private static func loadBackup() -> [String: [String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: backupKey),
              let encoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        var result: [String: [String: Any]] = [:]
        for (id, b64) in encoded {
            guard let plist = Data(base64Encoded: b64),
                  let dict = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any] else {
                continue
            }
            result[id] = dict
        }
        return result
    }
}

#else

public enum SystemProxyConfigurator {
    public static func apply(host: String = "127.0.0.1", port: Int = TunnelProviderKeys.defaultMixedPort) {
        _ = host
        _ = port
    }

    public static func restore() {}
}

#endif
