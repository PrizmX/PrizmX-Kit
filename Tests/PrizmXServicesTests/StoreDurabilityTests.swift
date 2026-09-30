import Foundation
import Testing
@testable import PrizmXServices

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("prizmx-kit-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func backups(in root: URL, prefix: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.hasPrefix("\(prefix).corrupt-") }
}

private let validConfig = "proxies: []\nrules:\n  - MATCH,DIRECT\n"

@MainActor
@Test
func unreadableProfileIndexIsBackedUpBeforeOverwrite() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let index = root.appendingPathComponent("index.json")
    try Data("{ not json".utf8).write(to: index)

    let store = ProfileStore(configuration: .init(rootDirectory: root))
    #expect(store.lastError?.contains("index.json") == true)
    #expect(try backups(in: root, prefix: "index.json").count == 1)

    try store.upsert(ProxyProfile(name: "New", rawConfig: validConfig), makeActive: true)
    let saved = try backups(in: root, prefix: "index.json")
    let copy = try String(contentsOf: root.appendingPathComponent(saved[0]), encoding: .utf8)
    #expect(copy == "{ not json")
}

@MainActor
@Test
func selectingNodeDoesNotRewriteOtherProfileConfigs() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProfileStore(configuration: .init(rootDirectory: root))
    let active = ProxyProfile(name: "A", rawConfig: validConfig)
    let other = ProxyProfile(name: "B", rawConfig: validConfig)
    try store.upsert(active, makeActive: true)
    try store.upsert(other)

    // External edit to B, and A's config goes missing on disk.
    let edited = "# edited outside\n" + validConfig
    try edited.write(to: store.fileURL(for: other.id), atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: store.fileURL(for: active.id))

    let reloaded = ProfileStore(configuration: .init(rootDirectory: root))
    try reloaded.setSelectedNode(id: "DIRECT", groupName: nil)
    try reloaded.rename(id: other.id, to: "B2")

    #expect(try String(contentsOf: reloaded.fileURL(for: other.id), encoding: .utf8) == edited)
    // No placeholder written for the profile whose config failed to load.
    #expect(!FileManager.default.fileExists(atPath: reloaded.fileURL(for: active.id).path))
}

@MainActor
@Test
func invalidSubscriptionKeepsPreviousConfig() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let body = root.appendingPathComponent("sub.yaml")
    try "{ \"outbounds\": [".write(to: body, atomically: true, encoding: .utf8)

    let store = ProfileStore(configuration: .init(rootDirectory: root))
    let profile = ProxyProfile(name: "Sub", subscriptionURL: body, rawConfig: validConfig)
    try store.upsert(profile, makeActive: true)

    await #expect(throws: (any Error).self) {
        try await store.refreshSubscription(id: profile.id)
    }
    #expect(store.activeProfile?.rawConfig == validConfig)
    #expect(store.lastError != nil)
    #expect(try String(contentsOf: store.fileURL(for: profile.id), encoding: .utf8) == validConfig)

    // A parseable body replaces the config.
    let next = "proxies: []\nrules:\n  - DOMAIN-SUFFIX,example.com,DIRECT\n  - MATCH,DIRECT\n"
    try next.write(to: body, atomically: true, encoding: .utf8)
    try await store.refreshSubscription(id: profile.id)
    #expect(store.activeProfile?.rawConfig == next.trimmingCharacters(in: .whitespacesAndNewlines))
}

@MainActor
@Test
func subscriptionRefreshOfRemovedProfileFails() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProfileStore(configuration: .init(rootDirectory: root))
    await #expect(throws: ProfileStoreError.unknownProfile) {
        try await store.refreshSubscription(id: UUID())
    }
}

@MainActor
@Test
func unreadableScriptsFileIsBackedUp() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("garbage".utf8).write(to: root.appendingPathComponent("scripts.json"))

    let store = ScriptStore(configuration: .init(rootDirectory: root))
    #expect(store.lastError != nil)
    try store.upsert(ScriptRecord(name: "New", source: "$done({})"))
    let saved = try backups(in: root, prefix: "scripts.json")
    #expect(saved.count == 1)
    #expect(try String(contentsOf: root.appendingPathComponent(saved[0]), encoding: .utf8) == "garbage")
}
