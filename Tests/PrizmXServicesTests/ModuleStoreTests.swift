import Foundation
import Testing
import PrizmXConfig
import PrizmXScripts
@testable import PrizmXServices

@MainActor
@Test func moduleStoreCombinesEnabledModulesOrdersPriorityAndLinksScripts() async throws {
    let store = ModuleStore(storage: .memory)
    let scriptURL = URL(string: "https://example.com/hook.js")!
    let first = try store.importRaw("""
    #!name=Privacy
    [Rule]
    DOMAIN-SUFFIX,ads.example.com,REJECT
    IP-CIDR,198.51.100.0/24,DIRECT,no-resolve
    [Host]
    service.local = 127.0.0.1
    [Script]
    net-hook = type=event, event-name=network-changed, script-path=https://example.com/hook.js
    """, fallbackName: "Privacy")
    let second = try store.importRaw("""
    name: Dev
    rules:
      - DOMAIN,dev.example.com,DIRECT
    dns:
      fake-ip-filter:
        - "*.dev.local"
    """, fallbackName: "Dev")

    #expect(store.combinedOverlay.rawRules.count == 3)
    #expect(store.moduleRuleSources() == ["Privacy", "Privacy", "Dev"])
    #expect(store.combinedOverlay.hosts["service.local"] == ["127.0.0.1"])
    #expect(store.combinedOverlay.fakeIPFilters == ["*.dev.local"])

    // Reordering moves Dev ahead of Privacy.
    store.moveUp(id: second.id)
    #expect(store.moduleRuleSources() == ["Dev", "Privacy", "Privacy"])

    // Module event script runs via ScriptScheduler when module is enabled.
    let kv = InMemoryScriptPersistentStore()
    store.seedModuleScriptSource(#"$persistentStore.write("from-module", "m"); $done(1)"#, for: scriptURL)
    let scheduler = ScriptScheduler(
        store: ScriptStore(storage: .memory),
        persistentStore: kv,
        moduleScriptsProvider: { store.enabledModuleScripts() }
    )
    await scheduler.triggerNetworkChangedEventNow()
    #expect(kv.read(key: "m") == "from-module")

    // Disabling Privacy removes its rules, hosts, and scripts.
    store.setEnabled(false, id: first.id)
    #expect(store.combinedOverlay.rawRules.count == 1)
    #expect(store.moduleRuleSources() == ["Dev"])
    #expect(store.combinedOverlay.hosts.isEmpty)
    #expect(store.enabledModuleScripts().isEmpty)

    let profiles = ProfileStore(storage: .memory)
    let yaml = """
    proxies: []
    proxy-groups: []
    rules:
      - MATCH,DIRECT
    """
    try profiles.upsert(ProxyProfile(name: "Base", rawConfig: yaml), makeActive: true)
    try profiles.saveOverlay(ProfileOverlay(rules: [OverlayRule(type: .domain, payload: "local.first", policy: "DIRECT")]))
    profiles.applyModuleOverlay(store.combinedOverlay)
    #expect(profiles.rules.count == 3)
    #expect(profiles.rules[0].displayPayload == "local.first")
    #expect(profiles.rules[1].displayPayload == "dev.example.com")
    #expect(second.format == .stoverride)
}
