import Foundation
import Testing
@testable import PrizmXServices

@Test
func ringBufferDropsOldestWhenFull() {
    var buffer = RingBuffer<Int>(capacity: 3)
    buffer.append(1)
    buffer.append(2)
    buffer.append(3)
    buffer.append(4)
    #expect(buffer.elements == [2, 3, 4])
    buffer.append(5)
    #expect(buffer.elements == [3, 4, 5])
}

@Test
func speedHistoryKeepsSixtyPoints() {
    var history = SpeedHistoryBuffer(capacity: 60)
    for index in 0..<75 {
        history.append(uploadBytesPerSecond: Double(index), downloadBytesPerSecond: Double(index * 2))
    }
    #expect(history.points.count == 60)
    #expect(history.points.first?.uploadBytesPerSecond == 15)
    #expect(history.points.last?.downloadBytesPerSecond == 148)
}

@Test
func byteRateFormatterUsesCompactUnits() {
    #expect(ByteRateFormatter.string(fromBytesPerSecond: 340_000) == "340 KB/s")
    #expect(ByteRateFormatter.string(fromBytesPerSecond: 2_500_000) == "2.5 MB/s")
    #expect(ByteRateFormatter.string(fromBytesPerSecond: 12_800_000) == "12.8 MB/s")
}

@Test
func tunnelIPCRoundTripIncludesActiveConnections() throws {
    let metrics = VPNMetrics(
        uploadBytesPerSecond: 100,
        downloadBytesPerSecond: 200,
        uplinkBytes: 1,
        downlinkBytes: 2,
        activeConnections: 9
    )
    let encoded = try TunnelIPC.encode(TunnelIPC.Response.success(metrics: metrics))
    let decoded = try TunnelIPC.metrics(from: encoded)
    #expect(decoded == metrics)
}

@Test
func mockTrafficStaysNearContractRates() {
    let snapshot = MockTrafficGenerator.metrics(at: Date(timeIntervalSinceReferenceDate: 10))
    #expect(snapshot.uploadBytesPerSecond > 1_500_000)
    #expect(snapshot.uploadBytesPerSecond < 3_500_000)
    #expect(snapshot.downloadBytesPerSecond > 8_000_000)
    #expect(snapshot.downloadBytesPerSecond < 16_000_000)
    #expect(snapshot.activeConnections >= 8)
}

@MainActor
@Test
func ruleLogProviderCapsAtTwoHundred() {
    let provider = RuleLogProvider()
    for index in 0..<205 {
        provider.addLog(
            RuleLogItem(
                host: "host-\(index).example",
                policy: "Proxy",
                outboundNode: "HK-01",
                countryCode: "HK"
            )
        )
    }
    #expect(provider.logs.count == 200)
    #expect(provider.logs.first?.host == "host-5.example")
    #expect(provider.logs.last?.host == "host-204.example")
}

@MainActor
@Test
func mockVPNManagerProducesLiveRates() async {
    let vpn = VPNManager(isMock: true)
    #expect(vpn.status == .connected)
    #expect(vpn.isMock)
    let metrics = await vpn.fetchMetrics()
    #expect(metrics.downloadBytesPerSecond > 0)
    #expect(vpn.uploadSpeedIsFormatted())
    vpn.stopVPN()
    #expect(vpn.status == .disconnected)
    #expect(vpn.uploadBytesPerSecond == 0)
}

private extension VPNManager {
    func uploadSpeedIsFormatted() -> Bool {
        !ByteRateFormatter.string(fromBytesPerSecond: uploadBytesPerSecond).isEmpty
    }
}

@MainActor
@Test
func previewProfileParsesRegionalNodes() {
    let store = ProfileStore.preview
    #expect(store.lastError == nil)
    let ids = Set(store.nodeManager?.nodesByID.keys.map { $0 } ?? [])
    #expect(ids.isSuperset(of: ["HK-01", "US-West", "JP-Tokyo", "CN-01"]))
    #expect(store.nodeManager?.group(named: "Auto") != nil)
    #expect(store.nodeManager?.group(named: "Proxy") != nil)
    #expect(store.nodeManager?.group(named: "Direct") != nil)
}

@Test
@MainActor
func staleConnectedAfterStopIsNotAdopted() {
    let vpn = VPNManager(isMock: true)
    var events: [Bool] = []
    vpn.onExternalStateChange = { events.append($0) }

    vpn.stopVPN()
    // A trailing `.connected` right after an explicit stop (queued NE
    // notification) must not flip the intent back on.
    vpn.applyVPNStatus(.connected)
    #expect(events.isEmpty)

    // A genuinely external start later (outside the grace window) is adopted.
    vpn.applyVPNStatus(.disconnected)
    vpn.applyVPNStatus(.connected)
    // Still within grace of the same stop — nothing.
    #expect(events.isEmpty)
}

@Test
@MainActor
func externalStartIsAdoptedWithoutStop() {
    let vpn = VPNManager(isMock: true)
    var events: [Bool] = []
    vpn.onExternalStateChange = { events.append($0) }
    vpn.applyVPNStatus(.connected)
    #expect(events == [true])
}

@Test
func nodePingerDialsPinnedIPForDomainNodes() {
    let domain = Endpoint(domain: "Node.Example.sbs", port: 5868)
    let pinned = PrizmXProtocols.IPv4Address(203, 0, 113, 7)
    let target = NodePinger.dialTarget(
        for: domain,
        pins: ["node.example.sbs": [pinned]]
    )
    #expect(target.host == .ipv4(pinned))
    #expect(target.port == 5868)

    // Unpinned domains and IP literals pass through unchanged.
    #expect(NodePinger.dialTarget(for: domain, pins: [:]) == domain)
    let literal = Endpoint(host: .ipv4(PrizmXProtocols.IPv4Address(192, 0, 2, 1)), port: 443)
    #expect(NodePinger.dialTarget(for: literal, pins: ["192.0.2.1": [pinned]]) == literal)
}

@Test
func pathLatencyProbeUsesDirectInternetHosts() {
    #expect(PathLatencyProbe.internetHosts.contains("1.1.1.1"))
    #expect(PathLatencyProbe.internetHosts.contains("223.5.5.5"))
    #expect(!PathLatencyProbe.dnsProbeDomain.isEmpty)
}

@MainActor
@Test
func profileOverlayMergesInFrontOfBodyRules() throws {
    let store = ProfileStore(storage: .memory)
    try store.upsert(
        ProxyProfile(name: "Preview", rawConfig: PreviewFixtures.catalogYAML),
        makeActive: true
    )
    let bodyCount = store.rules.count
    try store.saveOverlay(
        ProfileOverlay(rules: [
            OverlayRule(type: .domainSuffix, payload: "corp.internal", policy: "DIRECT"),
        ])
    )
    #expect(store.rules.count == bodyCount + 1)
    #expect(store.rules.first?.displayPayload == "corp.internal")
    #expect(store.rules.first?.displayPolicy == "DIRECT")
    #expect(store.overlay.rules.count == 1)
}

@Test
func subscriptionQuotaParsesClashUserinfo() {
    let quota = SubscriptionQuota.parse(
        "upload=1024; download=2048; total=10737418240; expire=1893456000"
    )
    #expect(quota?.usedBytes == 3072)
    #expect(quota?.totalBytes == 10_737_418_240)
    #expect(quota?.expiresAt == Date(timeIntervalSince1970: 1_893_456_000))
}

@Test
func subscriptionQuotaIgnoresEmptyHeader() {
    #expect(SubscriptionQuota.parse("") == nil)
    #expect(SubscriptionQuota.parse("profile-update-interval=24") == nil)
}

@Test
func decodeSubscriptionAcceptsClashStartingWithMixedPort() {
    let yaml = """
    mixed-port: 7890
    allow-lan: false
    ipv6: false
    mode: rule
    log-level: info
    dns:
      enable: true
      nameserver:
        - 223.5.5.5
    proxies: []
    rules:
      - MATCH,DIRECT
    """
    #expect(!yaml.prefix(64).contains("proxies"))
    let decoded = ProfileStore.decodeSubscriptionBody(Data(yaml.utf8))
    #expect(decoded?.contains("mixed-port: 7890") == true)
    #expect(decoded?.contains("proxies:") == true)
}

@Test
func decodeSubscriptionRejectsHTMLErrorPage() {
    let html = "<!DOCTYPE html><html><body>proxies: not a config</body></html>"
    #expect(ProfileStore.decodeSubscriptionBody(Data(html.utf8)) == nil)
}

@Test
func decodeSubscriptionUnwrapsBase64Clash() {
    let yaml = "proxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n"
    let encoded = Data(yaml.utf8).base64EncodedString()
    let decoded = ProfileStore.decodeSubscriptionBody(Data(encoded.utf8))
    #expect(decoded?.contains("proxies:") == true)
}
