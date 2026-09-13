import Foundation
import Observation
import PrizmXConfig
import PrizmXNodes
import PrizmXProtocols
import PrizmXRules

/// Persist Clash / sing-box profiles in the App Group container and refresh
/// subscription URLs. Parsing is delegated to `ConfigAdapter` in Foundation.
@MainActor
@Observable
public final class ProfileStore {
    public struct Configuration: Sendable, Equatable {
        public var appGroupIdentifier: String
        /// Folder name inside the App Group container.
        public var directoryName: String

        public init(
            appGroupIdentifier: String = PrizmXAppGroup.identifier,
            directoryName: String = "PrizmXKit"
        ) {
            self.appGroupIdentifier = appGroupIdentifier
            self.directoryName = directoryName
        }

        public static let `default` = Configuration()
    }

    public enum StorageKind: Sendable, Equatable {
        /// App Group persistence.
        case disk
        /// Preview and tests; never touches the file system.
        case memory
    }

    public let configuration: Configuration
    public let storage: StorageKind

    public private(set) var profiles: [ProxyProfile] = []
    public private(set) var activeProfileID: UUID?
    public private(set) var nodeManager: NodeManager?
    public private(set) var rules: [RouteRule] = []
    /// Overlay owned by the active profile (empty when none).
    public private(set) var overlay: ProfileOverlay = .empty
    /// Group names from the profile body, before overlay overrides.
    public private(set) var profileGroupNames: Set<String> = []
    /// Persisted group → member choices. Tracked so Policies repaints on change.
    public private(set) var policySelections: [String: String]
    public private(set) var lastError: String?
    @ObservationIgnored
    private var overlaysByID: [UUID: ProfileOverlay] = [:]

    /// Records an error for the profile UI to surface. Hosts use this when
    /// they catch a throwing mutation (`saveOverlay`, `upsert`, …).
    public func recordError(_ error: Error) {
        lastError = error.localizedDescription
    }

    public var activeProfile: ProxyProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    public var activeProfileName: String? {
        activeProfile?.name
    }

    public var activeNodeName: String? {
        guard let id = activeProfile?.selectedNodeID else { return nil }
        return nodeManager?.node(id: id)?.name
    }

    /// On-disk folder for index.json and config files.
    public var directoryURL: URL { rootURL }

    /// Config file for a profile (`configs/<uuid>.conf`).
    public func fileURL(for id: UUID) -> URL {
        configsURL.appendingPathComponent("\(id.uuidString).conf", isDirectory: false)
    }

    @ObservationIgnored
    private let fileManager: FileManager

    public init(
        configuration: Configuration = .default,
        fileManager: FileManager = .default,
        storage: StorageKind = .disk
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.storage = storage
        policySelections = storage == .disk ? PolicySelectionStore.load() : [:]
        guard storage == .disk else { return }
        do {
            try loadFromDisk()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Mutations

    public func upsert(_ profile: ProxyProfile, makeActive: Bool = false) throws {
        var next = profile
        if next.format == .unknown {
            next.format = ProxyProfile.inferredFormat(for: next.rawConfig)
        }
        if let index = profiles.firstIndex(where: { $0.id == next.id }) {
            profiles[index] = next
        } else {
            profiles.append(next)
        }
        if makeActive || activeProfileID == nil {
            activeProfileID = next.id
        }
        try persist()
        rebuildCatalogIfNeeded()
    }

    public func remove(id: UUID) throws {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            activeProfileID = profiles.first?.id
        }
        try persist()
        overlaysByID[id] = nil
        if storage == .disk {
            try? fileManager.removeItem(at: overlayURL(for: id))
        }
        rebuildCatalogIfNeeded()
        try? fileManager.removeItem(at: configURL(for: id))
    }

    public func rename(id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.unknownProfile
        }
        profiles[index].name = trimmed
        try persist()
    }

    public func selectActiveProfile(id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else {
            throw ProfileStoreError.unknownProfile
        }
        activeProfileID = id
        try persist()
        rebuildCatalogIfNeeded()
    }

    public func setPolicySelection(_ memberID: String, inGroup groupName: String) {
        policySelections[groupName] = memberID
        PolicySelectionStore.set(memberID, inGroup: groupName)
    }

    public func setSelectedNode(id nodeID: String, groupName: String? = nil) throws {
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else {
            throw ProfileStoreError.noActiveProfile
        }
        profiles[index].selectedNodeID = nodeID
        if let groupName {
            profiles[index].selectedGroupName = groupName
        }
        try persist()
    }

    /// Replaces the overlay for `id` (default: active). Subscription refresh
    /// does not touch this file.
    public func saveOverlay(_ overlay: ProfileOverlay, for id: UUID? = nil) throws {
        guard let profileID = id ?? activeProfileID else {
            throw ProfileStoreError.noActiveProfile
        }
        guard profiles.contains(where: { $0.id == profileID }) else {
            throw ProfileStoreError.unknownProfile
        }
        overlaysByID[profileID] = overlay
        if storage == .disk {
            try fileManager.createDirectory(at: overlaysURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(overlay).write(to: overlayURL(for: profileID), options: .atomic)
        }
        if profileID == activeProfileID {
            self.overlay = overlay
            rebuildCatalogIfNeeded()
        }
    }

    /// Downloads a subscription URL and replaces that profile's raw config.
    public func refreshSubscription(id: UUID) async throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.unknownProfile
        }
        guard let url = profiles[index].subscriptionURL else {
            throw ProfileStoreError.missingSubscriptionURL
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("PrizmX/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ProfileStoreError.subscriptionFailed(http.statusCode)
        }
        guard let text = Self.decodeSubscriptionBody(data) else {
            throw ProfileStoreError.unreadableSubscription
        }

        profiles[index].rawConfig = text
        profiles[index].format = ProxyProfile.inferredFormat(for: text)
        profiles[index].lastUpdated = Date()
        profiles[index].applySubscriptionUserInfo(from: response)
        try persist()
        if activeProfileID == id {
            rebuildCatalogIfNeeded()
        }
    }

    // MARK: - Disk

    public func reload() throws {
        try loadFromDisk()
    }

    // MARK: - Private

    private func rebuildCatalogIfNeeded() {
        guard let active = activeProfile, !active.rawConfig.isEmpty else {
            nodeManager = nil
            rules = []
            overlay = .empty
            profileGroupNames = []
            return
        }
        overlay = loadOverlay(for: active.id)
        do {
            let body = try ConfigAdapter.parse(rawString: active.rawConfig)
            profileGroupNames = Set(body.1.groupsByName.keys)
            let parsed = try overlay.apply(to: body)
            rules = parsed.0.rules
            parsed.1.applySelections(PolicySelectionStore.load())
            nodeManager = parsed.1
            lastError = nil
        } catch {
            nodeManager = nil
            rules = []
            profileGroupNames = []
            lastError = error.localizedDescription
        }
    }

    private func loadFromDisk() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: configsURL, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: indexURL.path) else {
            profiles = []
            activeProfileID = nil
            nodeManager = nil
            rules = []
            profileGroupNames = []
            return
        }

        let data = try Data(contentsOf: indexURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(ProfileIndexFile.self, from: data)
        var loaded: [ProxyProfile] = []
        loaded.reserveCapacity(index.profiles.count)
        for record in index.profiles {
            let raw: String
            if let text = try? String(contentsOf: configURL(for: record.id), encoding: .utf8) {
                raw = text
            } else {
                raw = ""
            }
            loaded.append(
                ProxyProfile(
                    id: record.id,
                    name: record.name,
                    format: record.format,
                    subscriptionURL: record.subscriptionURL,
                    selectedNodeID: record.selectedNodeID,
                    selectedGroupName: record.selectedGroupName,
                    lastUpdated: record.lastUpdated,
                    usedBytes: record.usedBytes,
                    totalBytes: record.totalBytes,
                    expiresAt: record.expiresAt,
                    rawConfig: raw
                )
            )
        }
        profiles = loaded
        activeProfileID = index.activeProfileID ?? loaded.first?.id
        rebuildCatalogIfNeeded()
    }

    private func persist() throws {
        guard storage == .disk else { return }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: configsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: overlaysURL, withIntermediateDirectories: true)

        let records = profiles.map { profile in
            ProfileIndexRecord(
                id: profile.id,
                name: profile.name,
                format: profile.format,
                subscriptionURL: profile.subscriptionURL,
                selectedNodeID: profile.selectedNodeID,
                selectedGroupName: profile.selectedGroupName,
                lastUpdated: profile.lastUpdated,
                usedBytes: profile.usedBytes,
                totalBytes: profile.totalBytes,
                expiresAt: profile.expiresAt,
                isActive: profile.id == activeProfileID
            )
        }
        let index = ProfileIndexFile(activeProfileID: activeProfileID, profiles: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(index).write(to: indexURL, options: .atomic)

        for profile in profiles {
            try profile.rawConfig.write(to: configURL(for: profile.id), atomically: true, encoding: .utf8)
        }
    }

    private var rootURL: URL {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier
        ) else {
            preconditionFailure("App Group '\(configuration.appGroupIdentifier)' is unavailable")
        }
        return container.appendingPathComponent(configuration.directoryName, isDirectory: true)
    }

    private var indexURL: URL {
        rootURL.appendingPathComponent("index.json", isDirectory: false)
    }

    private var configsURL: URL {
        rootURL.appendingPathComponent("configs", isDirectory: true)
    }

    private var overlaysURL: URL {
        rootURL.appendingPathComponent("overlays", isDirectory: true)
    }

    private func configURL(for id: UUID) -> URL {
        configsURL.appendingPathComponent("\(id.uuidString).conf", isDirectory: false)
    }

    private func overlayURL(for id: UUID) -> URL {
        overlaysURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func loadOverlay(for id: UUID) -> ProfileOverlay {
        if let cached = overlaysByID[id] { return cached }
        guard storage == .disk else { return .empty }
        guard let data = try? Data(contentsOf: overlayURL(for: id)),
              let overlay = try? JSONDecoder().decode(ProfileOverlay.self, from: data)
        else {
            return .empty
        }
        overlaysByID[id] = overlay
        return overlay
    }

    /// Accepts plain YAML/JSON or a base64-wrapped subscription body.
    /// Anything else (error pages, HTML) returns nil instead of being saved.
    nonisolated public static func decodeSubscriptionBody(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if looksLikeConfig(trimmed) { return trimmed }
        let compact = trimmed.replacingOccurrences(of: "\n", with: "")
        guard let decoded = Data(base64Encoded: compact),
              let inner = String(data: decoded, encoding: .utf8) else {
            return nil
        }
        let innerTrimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return looksLikeConfig(innerTrimmed) ? innerTrimmed : nil
    }

    nonisolated private static func looksLikeConfig(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        if first == "<" {
            let leading = trimmed.prefix(256).lowercased()
            if leading.hasPrefix("<!doctype") || leading.hasPrefix("<html") || leading.hasPrefix("<?xml") {
                return false
            }
        }
        if first == "{" || first == "[" { return true }

        // Clash YAML often starts with mixed-port / dns / comments, so `proxies:`
        // can sit well past a short header window.
        let sample = trimmed.prefix(16_384).lowercased()
        return sample.contains("proxies:")
            || sample.contains("proxy-groups:")
            || sample.contains("proxy-providers:")
            || sample.contains("outbounds:")
            || sample.contains("rules:")
            || sample.contains("rule-providers:")
            || sample.contains("mixed-port:")
            || sample.contains("socks-port:")
    }
}

public enum ProfileStoreError: Error, Sendable, Equatable, LocalizedError {
    case unknownProfile
    case noActiveProfile
    case missingSubscriptionURL
    case unreadableSubscription
    case subscriptionFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .unknownProfile: "The profile no longer exists."
        case .noActiveProfile: "No profile is active."
        case .missingSubscriptionURL: "This profile has no subscription URL."
        case .unreadableSubscription: "The download did not contain a readable profile."
        case .subscriptionFailed(let code): "Subscription download failed (HTTP \(code))."
        }
    }
}
