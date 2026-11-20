import AppKit
import SwiftUI

/// Feature & platform capability flags distinguishing direct-distributed
/// Community macOS from sandboxed Mac App Store builds.
public struct MacHostCapabilities: Sendable, Equatable {
    /// Developer ID System Extension transport (XPC + runtimeKitRoot). False for MAS App Extension.
    public var usesSystemExtension: Bool
    /// Privileged/authorized System Proxy toggle (disabled in MAS sandbox).
    public var supportsSystemProxy: Bool
    /// libproc-based per-app traffic attribution & Apps pane (disabled in MAS sandbox).
    public var supportsProcessAttribution: Bool
    /// CoreLocation Wi-Fi SSID prompt (disabled when Location entitlement is absent).
    public var supportsLocationSSID: Bool
    /// System On-Demand Always On toggle in TUN Settings.
    public var showsAlwaysOn: Bool

    public init(
        usesSystemExtension: Bool = true,
        supportsSystemProxy: Bool = true,
        supportsProcessAttribution: Bool = true,
        supportsLocationSSID: Bool = true,
        showsAlwaysOn: Bool = true
    ) {
        self.usesSystemExtension = usesSystemExtension
        self.supportsSystemProxy = supportsSystemProxy
        self.supportsProcessAttribution = supportsProcessAttribution
        self.supportsLocationSSID = supportsLocationSSID
        self.showsAlwaysOn = showsAlwaysOn
    }

    public static let community = MacHostCapabilities(
        usesSystemExtension: true,
        supportsSystemProxy: true,
        supportsProcessAttribution: true,
        supportsLocationSSID: true,
        showsAlwaysOn: true
    )

    public static let appStore = MacHostCapabilities(
        usesSystemExtension: false,
        supportsSystemProxy: false,
        supportsProcessAttribution: false,
        supportsLocationSSID: false,
        showsAlwaysOn: true
    )
}

/// Optional host-supplied analytics adapter (e.g. PostHog in Community).
public struct MacAnalyticsAdapter: Sendable {
    public var isEnabled: @MainActor @Sendable () -> Bool
    public var setEnabled: @MainActor @Sendable (Bool) -> Void
    public var updateProxyState: @MainActor @Sendable (_ tun: Bool, _ systemProxy: Bool) -> Void

    public init(
        isEnabled: @escaping @MainActor @Sendable () -> Bool,
        setEnabled: @escaping @MainActor @Sendable (Bool) -> Void,
        updateProxyState: @escaping @MainActor @Sendable (_ tun: Bool, _ systemProxy: Bool) -> Void
    ) {
        self.isEnabled = isEnabled
        self.setEnabled = setEnabled
        self.updateProxyState = updateProxyState
    }
}

/// View & lifecycle extension points allowing Store builds to inject
/// PrizmX-Premium widgets and Pro settings without adding a dependency from
/// open-source PrizmX-Kit on PrizmX-Premium.
@MainActor
public struct MacHostPlugins {
    /// Optional medium Home Dashboard widget (e.g. animated vector Exit Location map).
    public var exitLocationWidget: (@MainActor (AppModel) -> AnyView)?
    /// Optional top Settings section (e.g. PrizmX Pro subscription status).
    public var settingsTopSection: (@MainActor () -> AnyView)?
    /// Optional extra rows inside Settings → General (e.g. ProxyHelperRow in Community).
    public var settingsGeneralExtra: (@MainActor () -> AnyView)?
    /// Optional extra rows inside Settings → Resources (e.g. Automatic Updates in Pro).
    public var settingsResourcesExtra: (@MainActor () -> AnyView)?
    /// Optional Privacy Policy & Open Source Licenses links in Settings → About.
    public var showsComplianceLinks: Bool
    /// Optional launch / foreground hook (e.g. Pro auto-updater).
    public var onAppActive: (@MainActor (AppModel) async -> Void)?

    public init(
        exitLocationWidget: (@MainActor (AppModel) -> AnyView)? = nil,
        settingsTopSection: (@MainActor () -> AnyView)? = nil,
        settingsGeneralExtra: (@MainActor () -> AnyView)? = nil,
        settingsResourcesExtra: (@MainActor () -> AnyView)? = nil,
        showsComplianceLinks: Bool = false,
        onAppActive: (@MainActor (AppModel) async -> Void)? = nil
    ) {
        self.exitLocationWidget = exitLocationWidget
        self.settingsTopSection = settingsTopSection
        self.settingsGeneralExtra = settingsGeneralExtra
        self.settingsResourcesExtra = settingsResourcesExtra
        self.showsComplianceLinks = showsComplianceLinks
        self.onAppActive = onAppActive
    }

    public static let none = MacHostPlugins()
}

/// Complete host injection bag passed into `AppModel(configuration:)`.
@MainActor
public struct MacHostConfiguration {
    public var capabilities: MacHostCapabilities
    public var analytics: MacAnalyticsAdapter?
    /// Developer ID Community passes `TunnelSystemExtension.activate`; MAS leaves `nil`.
    public var activateTunnelExtension: (@MainActor () async throws -> Void)?
    /// True when the bundled system extension is newer than the activated one
    /// so TUN should stop cleanly before replacement.
    public var needsTunnelExtensionUpgrade: (@MainActor () -> Bool)?
    /// Developer ID Community passes `ProxyHelperSetup.prepare`; MAS leaves `nil`.
    public var prepareSystemProxyHelper: (@MainActor () async -> Void)?
    public var plugins: MacHostPlugins

    public init(
        capabilities: MacHostCapabilities = .community,
        analytics: MacAnalyticsAdapter? = nil,
        activateTunnelExtension: (@MainActor () async throws -> Void)? = nil,
        needsTunnelExtensionUpgrade: (@MainActor () -> Bool)? = nil,
        prepareSystemProxyHelper: (@MainActor () async -> Void)? = nil,
        plugins: MacHostPlugins = .none
    ) {
        self.capabilities = capabilities
        self.analytics = analytics
        self.activateTunnelExtension = activateTunnelExtension
        self.needsTunnelExtensionUpgrade = needsTunnelExtensionUpgrade
        self.prepareSystemProxyHelper = prepareSystemProxyHelper
        self.plugins = plugins
    }

    public static let community = MacHostConfiguration(capabilities: .community)
    public static let appStore = MacHostConfiguration(capabilities: .appStore)
}

/// Secondary SwiftUI windows default to zoom (+). Match the main window fullscreen traffic light.
public struct FullScreenPrimaryWindow: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.apply(view.window) }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        Self.apply(nsView.window)
    }

    private static func apply(_ window: NSWindow?) {
        guard let window else { return }
        let next = window.collectionBehavior
            .union([.fullScreenPrimary, .fullScreenAllowsTiling])
            .subtracting(.fullScreenAuxiliary)
        guard next != window.collectionBehavior else { return }
        window.collectionBehavior = next
    }
}
