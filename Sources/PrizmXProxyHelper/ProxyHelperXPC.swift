import Foundation

#if os(macOS)
/// XPC between the app (client) and the privileged proxy helper (listener).
///
/// The helper is a launchd daemon the app registers with
/// `SMAppService.daemon(plistName:)`. Once the user approves it under
/// System Settings → General → Login Items, it runs as root and writes the
/// System Configuration proxy settings, so toggling System Proxy no longer
/// asks for an administrator password in every app session.
///
/// The helper only writes: the app reads the current settings itself, keeps
/// the backup, and sends the complete Proxies dictionary of each service.
@objc public protocol ProxyHelperXPCService {
    /// `configs` maps a network service ID to the binary plist of its whole
    /// Proxies dictionary (`ProxyServiceWriter.encode`). Replies nil once
    /// committed and applied, otherwise the failure.
    func writeProxies(_ configs: [String: Data], reply: @escaping @Sendable (String?) -> Void)
}

public enum ProxyHelperXPC: Sendable {
    /// Also the `Label` and `MachServices` key in the launchd plist.
    public static let machServiceName = "app.prizmx.macos.helper"

    /// The launchd plist in `PrizmX.app/Contents/Library/LaunchDaemons`.
    public static let plistName = "\(machServiceName).plist"

    private static let teamID = "N49M3Z72D3"

    /// What the helper requires of the app that connects.
    public static let appRequirement = requirement(identifier: "app.prizmx.macos")

    /// What the app requires of the helper it connected to.
    public static let helperRequirement = requirement(identifier: machServiceName)

    private static func requirement(identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
#endif
