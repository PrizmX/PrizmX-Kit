import Foundation
import Observation
import PrizmXScripts

/// Persists Scripts next to profiles in the App Group kit folder.
@MainActor
@Observable
public final class ScriptStore {
    private struct File: Sendable, Codable, Equatable {
        static let currentVersion = 1
        var version: Int
        var scripts: [ScriptRecord]
    }

    public private(set) var scripts: [ScriptRecord] = []
    public private(set) var disabledBuiltInIDs: Set<UUID> = []
    public private(set) var lastError: String?
    private static let disabledBuiltInsKey = "prizmx.scripts.disabledBuiltIns"
    /// Set when scripts.json was unreadable and could not be backed up:
    /// writes stay blocked so the original is never overwritten.
    @ObservationIgnored
    private var unreadableFile: StoreFileBackup.LoadError?

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
        let storedDisabled = UserDefaults.standard.stringArray(forKey: Self.disabledBuiltInsKey) ?? []
        disabledBuiltInIDs = Set(storedDisabled.compactMap(UUID.init(uuidString:)))
        do {
            try loadFromDisk()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func isEnabled(_ script: ScriptRecord) -> Bool {
        if script.isBuiltIn {
            return !disabledBuiltInIDs.contains(script.id)
        }
        return script.enabled
    }

    public func setBuiltInEnabled(_ enabled: Bool, id: UUID) {
        if enabled {
            disabledBuiltInIDs.remove(id)
        } else {
            disabledBuiltInIDs.insert(id)
        }
        if storage == .disk {
            UserDefaults.standard.set(disabledBuiltInIDs.map(\.uuidString), forKey: Self.disabledBuiltInsKey)
        }
    }

    public func upsert(_ script: ScriptRecord) throws {
        var next = script
        next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
        next.pattern = next.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        next.argument = next.argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.name.isEmpty else { throw ScriptStoreError.emptyName }
        guard !next.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScriptStoreError.emptySource
        }
        if let index = scripts.firstIndex(where: { $0.id == next.id }) {
            scripts[index] = next
        } else {
            scripts.append(next)
        }
        try persist()
        writeSourceFileIfNeeded(next)
    }

    public func remove(id: UUID) throws {
        scripts.removeAll { $0.id == id }
        try persist()
        if storage == .disk {
            try? fileManager.removeItem(at: scriptFileURL(forID: id))
        }
    }

    /// Directory holding materialized `.js` files for external editors.
    public var scriptsDirectoryURL: URL {
        rootURL.appendingPathComponent("scripts", isDirectory: true)
    }

    /// Returns the on-disk `.js` path for a user script, materializing it
    /// from the stored source if needed so external editors can open it directly.
    public func ensureSourceFile(for script: ScriptRecord) throws -> URL {
        guard storage == .disk else { throw ScriptStoreError.fileUnavailable }
        let url = scriptFileURL(forID: script.id)
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: scriptsDirectoryURL, withIntermediateDirectories: true)
            try Data(script.source.utf8).write(to: url, options: .atomic)
        }
        return url
    }

    /// Imports a local `.js` file into the managed scripts directory.
    @discardableResult
    public func importFile(
        from url: URL,
        name: String = "",
        kind: ScriptRecord.Kind = .script,
        pattern: String = "",
        argument: String = ""
    ) throws -> ScriptRecord {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScriptStoreError.emptySource
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = url.deletingPathExtension().lastPathComponent
        let resolvedName = !trimmedName.isEmpty ? trimmedName : (!fallback.isEmpty ? fallback : "Imported Script")
        let record = ScriptRecord(
            name: resolvedName,
            enabled: true,
            kind: kind,
            pattern: pattern,
            source: text,
            argument: argument
        )
        try upsert(record)
        return record
    }

    /// Reads the freshest JS source for `script`, preferring the on-disk `.js`
    /// file when present so external edits apply immediately on the next run.
    public func resolvedSource(for script: ScriptRecord) -> String {
        guard !script.isBuiltIn, storage == .disk else { return script.source }
        let url = scriptFileURL(forID: script.id)
        if let onDisk = try? String(contentsOf: url, encoding: .utf8),
           !onDisk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return onDisk
        }
        return script.source
    }

    private func scriptFileURL(forID id: UUID) -> URL {
        scriptsDirectoryURL.appendingPathComponent("\(id.uuidString).js", isDirectory: false)
    }

    private func writeSourceFileIfNeeded(_ script: ScriptRecord) {
        guard !script.isBuiltIn, storage == .disk else { return }
        try? fileManager.createDirectory(at: scriptsDirectoryURL, withIntermediateDirectories: true)
        try? Data(script.source.utf8).write(to: scriptFileURL(forID: script.id), options: .atomic)
    }

    /// Bundled read-only system scripts ready to run out of the box.
    public static let builtInScripts: [ScriptRecord] = [
        ScriptRecord(
            id: UUID(uuidString: "11111111-1111-4111-8111-000000000001")!,
            name: "Exit IP & Geo",
            enabled: true,
            kind: .script,
            pattern: "",
            source: """
            $httpClient.get("https://ipwho.is/", function (err, resp, data) {
              if (err) {
                console.error("Lookup failed:", err);
                $done({ ok: false, error: String(err) });
                return;
              }
              try {
                var info = JSON.parse(data);
                var location = [info.city, info.region, info.country].filter(Boolean).join(", ");
                var org = (info.connection && (info.connection.org || info.connection.isp)) || "";
                console.log("IP:", info.ip);
                console.log("Location:", location || "Unknown");
                if (org) console.log("Org:", org);
                $done({ ip: info.ip, country: info.country_code, location: location, org: org });
              } catch (e) {
                $done({ ok: false, status: resp && resp.status, error: String(e) });
              }
            });
            """,
            timeout: 10,
            isBuiltIn: true
        ),
        ScriptRecord(
            id: UUID(uuidString: "11111111-1111-4111-8111-000000000002")!,
            name: "Connectivity Probe",
            enabled: true,
            kind: .script,
            pattern: "",
            source: """
            var targets = [
              { name: "Apple", url: "https://captive.apple.com/hotspot-detect.html" },
              { name: "GitHub", url: "https://github.com/robots.txt" },
              { name: "Google", url: "https://www.gstatic.com/generate_204" }
            ];
            var results = {};
            var remaining = targets.length;
            targets.forEach(function (t) {
              var started = Date.now();
              $httpClient.get({ url: t.url, timeout: 6 }, function (err, resp) {
                var ms = Date.now() - started;
                if (err) {
                  results[t.name] = "error";
                  console.log(t.name + ": failed (" + err + ")");
                } else {
                  results[t.name] = resp.status + " (" + ms + "ms)";
                  console.log(t.name + ": HTTP " + resp.status + " in " + ms + "ms");
                }
                remaining -= 1;
                if (remaining === 0) $done(results);
              });
            });
            """,
            timeout: 10,
            isBuiltIn: true
        ),
        ScriptRecord(
            id: UUID(uuidString: "11111111-1111-4111-8111-000000000003")!,
            name: "Network Snapshot",
            enabled: true,
            kind: .script,
            pattern: "",
            source: """
            var prev = $persistentStore.read("prizmx.lastSnapshotAt");
            var now = new Date().toISOString();
            $persistentStore.write(now, "prizmx.lastSnapshotAt");
            var ip = ($network.v4 && $network.v4.primaryAddress) || "unknown";
            var ssid = ($network.wifi && $network.wifi.ssid) || "n/a";
            console.log("System:", $environment.system, $environment.version);
            console.log("IPv4:", ip, "Wi-Fi:", ssid);
            if (prev) console.log("Previous snapshot:", prev);
            $done({ ipv4: ip, wifi: ssid, recordedAt: now });
            """,
            timeout: 5,
            isBuiltIn: true
        ),
    ]

    public func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].enabled = enabled
        try? persist()
    }

    /// Downloads JavaScript source from `url` and installs a new script record.
    @discardableResult
    public func installFromURL(
        _ url: URL,
        name: String = "",
        kind: ScriptRecord.Kind = .script,
        pattern: String = "",
        argument: String = ""
    ) async throws -> ScriptRecord {
        let source = try await Self.fetchSource(from: url)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = url.deletingPathExtension().lastPathComponent
        let resolvedName = !trimmedName.isEmpty
            ? trimmedName
            : (!fallbackName.isEmpty ? fallbackName : (url.host ?? "Remote Script"))
        let record = ScriptRecord(
            name: resolvedName,
            enabled: true,
            kind: kind,
            pattern: pattern,
            source: source,
            argument: argument,
            sourceURL: url
        )
        try upsert(record)
        return record
    }

    /// Re-downloads source for a URL-backed script.
    public func refresh(id: UUID) async throws {
        guard let index = scripts.firstIndex(where: { $0.id == id }),
              let url = scripts[index].sourceURL
        else { throw ScriptStoreError.missingSourceURL }
        let source = try await Self.fetchSource(from: url)
        var next = scripts[index]
        next.source = source
        try upsert(next)
    }

    private static func fetchSource(from url: URL) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ScriptStoreError.downloadFailed("HTTP \(http.statusCode)")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScriptStoreError.emptySource
        }
        return text
    }

    public var fileURL: URL { scriptsURL }

    private func loadFromDisk() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: scriptsURL.path) else {
            scripts = []
            return
        }
        let file: File
        do {
            let data = try Data(contentsOf: scriptsURL)
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            // Keep a copy before the next persist() replaces it.
            let backup = StoreFileBackup.preserve(scriptsURL, fileManager: fileManager)
            let failure = StoreFileBackup.LoadError(file: "scripts.json", backup: backup, underlying: error)
            unreadableFile = backup == nil ? failure : nil
            throw failure
        }
        unreadableFile = nil
        scripts = file.scripts
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
        let file = File(version: File.currentVersion, scripts: scripts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: scriptsURL, options: .atomic)
    }

    private var rootURL: URL {
        configuration.resolvedRoot()
    }

    private var scriptsURL: URL {
        rootURL.appendingPathComponent("scripts.json", isDirectory: false)
    }
}

public enum ScriptStoreError: Error, Sendable, Equatable, LocalizedError {
    case emptyName
    case emptySource
    case missingSourceURL
    case fileUnavailable
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Name is required."
        case .emptySource: "Script source is empty."
        case .missingSourceURL: "Script does not have a source URL."
        case .fileUnavailable: "Script file is unavailable in memory-only mode."
        case .downloadFailed(let detail): "Download failed (\(detail))."
        }
    }
}

extension ScriptStore {
    public static var preview: ScriptStore {
        let store = ScriptStore(storage: .memory)
        try? store.upsert(
            ScriptRecord(
                name: "Sample",
                kind: .httpRequest,
                pattern: "^https://example\\.com/",
                source: ScriptRecord.sampleSource
            )
        )
        return store
    }
}
