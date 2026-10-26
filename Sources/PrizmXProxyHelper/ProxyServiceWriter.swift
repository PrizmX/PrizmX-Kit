import Foundation

#if os(macOS)
import SystemConfiguration

/// Writes whole Proxies dictionaries into network services of the current
/// set, then commits and applies them. Shared by the root helper and the
/// app's own authorized fallback, so both write exactly the same way.
public enum ProxyServiceWriter {
    /// Returns nil on success, otherwise the System Configuration error.
    /// Service IDs missing from the current set are skipped.
    public static func write(_ configs: [String: [String: Any]], to prefs: SCPreferences) -> String? {
        guard let set = SCNetworkSetCopyCurrent(prefs) else { return "no current network set" }
        guard let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            return "no network services"
        }
        for service in services {
            guard let serviceID = SCNetworkServiceGetServiceID(service) as String?,
                  let config = configs[serviceID],
                  let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
            else { continue }
            if !SCNetworkProtocolSetConfiguration(proto, config as CFDictionary) {
                return "set \(serviceID): \(lastError())"
            }
        }
        guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
            return lastError()
        }
        return nil
    }

    public static func encode(_ configs: [String: [String: Any]]) -> [String: Data]? {
        var encoded: [String: Data] = [:]
        for (id, config) in configs {
            guard let data = try? PropertyListSerialization.data(
                fromPropertyList: config,
                format: .binary,
                options: 0
            ) else { return nil }
            encoded[id] = data
        }
        return encoded
    }

    public static func decode(_ encoded: [String: Data]) -> [String: [String: Any]]? {
        var configs: [String: [String: Any]] = [:]
        for (id, data) in encoded {
            guard let config = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else { return nil }
            configs[id] = config
        }
        return configs
    }

    private static func lastError() -> String {
        String(cString: SCErrorString(SCError()))
    }
}
#endif
