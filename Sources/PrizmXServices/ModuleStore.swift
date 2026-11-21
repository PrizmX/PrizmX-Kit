import CryptoKit
import Foundation
import Observation
import PrizmXConfig
import PrizmXScripts

/// One installed Surge `.sgmodule` or Stash `.stoverride` module.
public struct ModuleRecord: Sendable, Hashable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var summary: String
    public var category: String?
    public var enabled: Bool
    public var format: ModuleFormat
    public var rawContent: String
    public var sourceURL: URL?
    public var argumentOverrides: [String: String]
    public var lastUpdated: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        category: String? = nil,
        enabled: Bool = true,
        format: ModuleFormat = .sgmodule,
        rawContent: String,
        sourceURL: URL? = nil,
        argumentOverrides: [String: String] = [:],
        lastUpdated: Date? = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.category = category
        self.enabled = enabled
        self.format = format
        self.rawContent = rawContent
        self.sourceURL = sourceURL
        self.argumentOverrides = argumentOverrides
        self.lastUpdated = lastUpdated
    }
}

/// Persists installed Modules next to profiles in the kit folder and builds the
/// combined non-MITM overlay for all enabled modules.
@MainActor
@Observable
public final class ModuleStore {
    private struct File: Sendable, Codable, Equatable {
        static let currentVersion = 1
        var version: Int
        var modules: [ModuleRecord]
    }

    public private(set) var modules: [ModuleRecord] = []
    public private(set) var lastError: String?
    @ObservationIgnored
    private var unreadableFile: StoreFileBackup.LoadError?
    @ObservationIgnored
    private var parsedCache: [UUID: ParsedModule] = [:]
    @ObservationIgnored
    private var scriptSourceCache: [URL: String] = [:]

    public let configuration: ProfileStore.Configuration
    public let storage: ProfileStore.StorageKind

    @ObservationIgnored
    private let fileManager: FileManager

    public init(
        configuration: ProfileStore.Configuration = .default,
        fileManager: FileManager = .default,
        storage: ProfileStore.StorageKind = .disk
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.storage = storage
        guard storage == .disk else { return }
        do {
            try loadFromDisk()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public var fileURL: URL { modulesURL }

    public var modulesDirectoryURL: URL {
        rootURL.appendingPathComponent("modules", isDirectory: true)
    }

    /// Parses and caches `record`, preferring fresher on-disk edits when available.
    public func parsed(for record: ModuleRecord) -> ParsedModule {
        if let cached = parsedCache[record.id] {
            return cached
        }
        let content = resolvedContent(for: record)
        let parsed = (try? ModuleParser.parse(
            content,
            fallbackName: record.name,
            argumentOverrides: record.argumentOverrides
        )) ?? ParsedModule(format: record.format, name: record.name, summary: record.summary, category: record.category)
        parsedCache[record.id] = parsed
        return parsed
    }

    /// Re-reads on-disk module files and clears the parse cache.
    public func reloadFromDiskFiles() {
        parsedCache.removeAll()
    }

    /// Combined `ProfileOverlay` across all enabled modules (earlier modules take
    /// precedence over later ones; user local overlay still sits in front).
    public var combinedOverlay: ProfileOverlay {
        var combined = ProfileOverlay.empty
        for record in modules where record.enabled {
            combined = combined.merging(parsed(for: record).overlay)
        }
        return combined
    }

    /// Parallel module-name array aligned 1:1 with `combinedOverlay.rules` so
    /// RulesPane can label each rule's source module.
    public func moduleRuleSources() -> [String] {
        var names: [String] = []
        for record in modules where record.enabled {
            let count = parsed(for: record).rawRules.count
            if count > 0 {
                names.append(contentsOf: repeatElement(record.name, count: count))
            }
        }
        return names
    }

    public func moveUp(id: UUID) {
        guard let idx = modules.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        modules.swapAt(idx, idx - 1)
        try? persist()
    }

    public func moveDown(id: UUID) {
        guard let idx = modules.firstIndex(where: { $0.id == id }), idx + 1 < modules.count else { return }
        modules.swapAt(idx, idx + 1)
        try? persist()
    }

    /// Downloads and caches non-MITM cron/event scripts referenced by enabled modules.
    public func prefetchModuleScripts() async {
        let urls = modules
            .filter(\.enabled)
            .flatMap { parsed(for: $0).scripts.map(\.scriptURL) }
        for url in Set(urls) {
            if cachedModuleScriptSource(for: url) != nil { continue }
            if let fetched = try? await Self.fetchContent(from: url),
               !fetched.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                storeModuleScriptSource(fetched, for: url)
            }
        }
    }

    /// Ready-to-run `ScriptRecord`s for all enabled modules' cron & event scripts
    /// whose JS source has been cached.
    public func enabledModuleScripts() -> [ScriptRecord] {
        var records: [ScriptRecord] = []
        for module in modules where module.enabled {
            let parsedModule = parsed(for: module)
            for script in parsedModule.scripts {
                guard let source = cachedModuleScriptSource(for: script.scriptURL) else { continue }
                let kind: ScriptRecord.Kind = script.kind == .cron ? .cron : .event
                records.append(ScriptRecord(
                    id: Self.stableScriptID(moduleID: module.id, scriptName: script.name),
                    name: "\(module.name): \(script.name)",
                    enabled: true,
                    kind: kind,
                    pattern: script.pattern,
                    source: source,
                    argument: script.argument,
                    timeout: script.timeout,
                    sourceURL: script.scriptURL
                ))
            }
        }
        return records
    }

    /// Test / pre-seed helper for module script source cache.
    public func seedModuleScriptSource(_ source: String, for url: URL) {
        storeModuleScriptSource(source, for: url)
    }

    private func cachedModuleScriptSource(for url: URL) -> String? {
        if let hit = scriptSourceCache[url] { return hit }
        guard storage == .disk else { return nil }
        let file = cachedModuleScriptFileURL(for: url)
        if let text = try? String(contentsOf: file, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scriptSourceCache[url] = text
            return text
        }
        return nil
    }

    private func storeModuleScriptSource(_ source: String, for url: URL) {
        scriptSourceCache[url] = source
        guard storage == .disk else { return }
        let dir = modulesDirectoryURL.appendingPathComponent("scripts", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(source.utf8).write(to: cachedModuleScriptFileURL(for: url), options: .atomic)
    }

    private func cachedModuleScriptFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return modulesDirectoryURL
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("\(hex).js", isDirectory: false)
    }

    private static func stableScriptID(moduleID: UUID, scriptName: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(moduleID.uuidString):\(scriptName)".utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    @discardableResult
    public func importRaw(
        _ rawContent: String,
        fallbackName: String,
        sourceURL: URL? = nil,
        enabled: Bool = true
    ) throws -> ModuleRecord {
        let parsed = try ModuleParser.parse(rawContent, fallbackName: fallbackName)
        let record = ModuleRecord(
            name: parsed.name,
            summary: parsed.summary,
            category: parsed.category,
            enabled: enabled,
            format: parsed.format,
            rawContent: rawContent,
            sourceURL: sourceURL,
            argumentOverrides: [:],
            lastUpdated: Date()
        )
        try upsert(record, parsed: parsed)
        return record
    }

    @discardableResult
    public func importFile(from url: URL) throws -> ModuleRecord {
        let content = try String(contentsOf: url, encoding: .utf8)
        let fallback = url.deletingPathExtension().lastPathComponent
        return try importRaw(content, fallbackName: fallback.isEmpty ? "Imported Module" : fallback)
    }

    @discardableResult
    public func installFromURL(_ url: URL) async throws -> ModuleRecord {
        let content = try await Self.fetchContent(from: url)
        let fallback = url.deletingPathExtension().lastPathComponent
        return try importRaw(
            content,
            fallbackName: fallback.isEmpty ? (url.host ?? "Remote Module") : fallback,
            sourceURL: url
        )
    }

    public func refresh(id: UUID) async throws {
        guard let index = modules.firstIndex(where: { $0.id == id }),
              let url = modules[index].sourceURL
        else { throw ModuleStoreError.missingSourceURL }
        let content = try await Self.fetchContent(from: url)
        let existing = modules[index]
        let parsed = try ModuleParser.parse(
            content,
            fallbackName: existing.name,
            argumentOverrides: existing.argumentOverrides
        )
        var next = existing
        next.name = parsed.name
        next.summary = parsed.summary
        next.category = parsed.category
        next.format = parsed.format
        next.rawContent = content
        next.lastUpdated = Date()
        try upsert(next, parsed: parsed)
    }

    public func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        modules[index].enabled = enabled
        try? persist()
    }

    public func updateArguments(_ overrides: [String: String], id: UUID) throws {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        var next = modules[index]
        next.argumentOverrides = overrides
        let parsed = try ModuleParser.parse(
            resolvedContent(for: next),
            fallbackName: next.name,
            argumentOverrides: overrides
        )
        try upsert(next, parsed: parsed)
    }

    public func remove(id: UUID) throws {
        let removed = modules.first { $0.id == id }
        modules.removeAll { $0.id == id }
        parsedCache.removeValue(forKey: id)
        try persist()
        if storage == .disk, let removed {
            try? fileManager.removeItem(at: moduleFileURL(for: removed))
        }
    }

    public func ensureModuleFile(for record: ModuleRecord) throws -> URL {
        guard storage == .disk else { throw ModuleStoreError.fileUnavailable }
        let url = moduleFileURL(for: record)
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: modulesDirectoryURL, withIntermediateDirectories: true)
            try Data(record.rawContent.utf8).write(to: url, options: .atomic)
        }
        return url
    }

    private func upsert(_ record: ModuleRecord, parsed: ParsedModule) throws {
        if let index = modules.firstIndex(where: { $0.id == record.id }) {
            modules[index] = record
        } else {
            modules.append(record)
        }
        parsedCache[record.id] = parsed
        try persist()
        writeModuleFileIfNeeded(record)
    }

    private func resolvedContent(for record: ModuleRecord) -> String {
        guard storage == .disk else { return record.rawContent }
        let url = moduleFileURL(for: record)
        if let onDisk = try? String(contentsOf: url, encoding: .utf8),
           !onDisk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return onDisk
        }
        return record.rawContent
    }

    private func moduleFileURL(for record: ModuleRecord) -> URL {
        let ext = record.format == .sgmodule ? "sgmodule" : "stoverride"
        return modulesDirectoryURL.appendingPathComponent("\(record.id.uuidString).\(ext)", isDirectory: false)
    }

    private func writeModuleFileIfNeeded(_ record: ModuleRecord) {
        guard storage == .disk else { return }
        try? fileManager.createDirectory(at: modulesDirectoryURL, withIntermediateDirectories: true)
        try? Data(record.rawContent.utf8).write(to: moduleFileURL(for: record), options: .atomic)
    }

    private func loadFromDisk() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: modulesURL.path) else {
            modules = []
            return
        }
        let file: File
        do {
            let data = try Data(contentsOf: modulesURL)
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            let backup = StoreFileBackup.preserve(modulesURL, fileManager: fileManager)
            let failure = StoreFileBackup.LoadError(file: "modules.json", backup: backup, underlying: error)
            unreadableFile = backup == nil ? failure : nil
            throw failure
        }
        unreadableFile = nil
        modules = file.modules
        parsedCache.removeAll()
        lastError = nil
    }

    private func persist() throws {
        guard storage == .disk else {
            lastError = nil
            return
        }
        if let unreadableFile { throw unreadableFile }
        lastError = nil
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let file = File(version: File.currentVersion, modules: modules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: modulesURL, options: .atomic)
    }

    private static func fetchContent(from url: URL) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ModuleStoreError.downloadFailed("HTTP \(http.statusCode)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private var rootURL: URL { configuration.resolvedRoot() }
    private var modulesURL: URL { rootURL.appendingPathComponent("modules.json", isDirectory: false) }
}

public enum ModuleStoreError: Error, Sendable, Equatable, LocalizedError {
    case missingSourceURL
    case fileUnavailable
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingSourceURL: "Module does not have a source URL."
        case .fileUnavailable: "Module file is unavailable in memory-only mode."
        case .downloadFailed(let detail): "Download failed (\(detail))."
        }
    }
}
