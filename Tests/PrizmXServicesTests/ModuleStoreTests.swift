import Foundation
import Testing
import PrizmXConfig
@testable import PrizmXServices

@MainActor
@Test func moduleStoreCombinesEnabledModulesBehindLocalOverlay() throws {
    let store = ModuleStore(storage: .memory)
    let first = try store.importRaw("""
    #!name=Privacy
    [Rule]
    DOMAIN-SUFFIX,ads.example.com,REJECT
    [Host]
    service.local = 127.0.0.1
    """, fallbackName: "Privacy")
    let second = try store.importRaw("""
    name: Dev
    rules:
      - DOMAIN,dev.example.com,DIRECT
    dns:
      fake-ip-filter:
        - "*.dev.local"
    """, fallbackName: "Dev")

    #expect(store.combinedOverlay.rules.count == 2)
    #expect(store.moduleRuleSources() == ["Privacy", "Dev"])
    #expect(store.combinedOverlay.hosts["service.local"] == ["127.0.0.1"])
    #expect(store.combinedOverlay.fakeIPFilters == ["*.dev.local"])

    store.setEnabled(false, id: first.id)
    #expect(store.combinedOverlay.rules.count == 1)
    #expect(store.moduleRuleSources() == ["Dev"])
    #expect(store.combinedOverlay.hosts.isEmpty)

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
