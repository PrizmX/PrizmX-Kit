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
    public private(set) var lastError: String?

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
    }

    public func remove(id: UUID) throws {
        scripts.removeAll { $0.id == id }
        try persist()
    }

    public func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].enabled = enabled
        try? persist()
    }

    public var fileURL: URL { scriptsURL }

    private func loadFromDisk() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: scriptsURL.path) else {
            scripts = []
            return
        }
        let data = try Data(contentsOf: scriptsURL)
        let file = try JSONDecoder().decode(File.self, from: data)
        scripts = file.scripts
        lastError = nil
    }

    private func persist() throws {
        lastError = nil
        guard storage == .disk else { return }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let file = File(version: File.currentVersion, scripts: scripts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: scriptsURL, options: .atomic)
    }

    private var rootURL: URL {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier
        ) else {
            preconditionFailure("App Group '\(configuration.appGroupIdentifier)' is unavailable")
        }
        return container.appendingPathComponent(configuration.directoryName, isDirectory: true)
    }

    private var scriptsURL: URL {
        rootURL.appendingPathComponent("scripts.json", isDirectory: false)
    }
}

public enum ScriptStoreError: Error, Sendable, Equatable, LocalizedError {
    case emptyName
    case emptySource

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Name is required."
        case .emptySource: "Script source is empty."
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
