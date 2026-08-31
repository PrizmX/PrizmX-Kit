import Foundation

/// Shared Clash catalog used by Preview factories and tests.
public enum PreviewFixtures: Sendable {
    public static let catalogYAML = """
    proxies:
      - name: HK-01
        type: ss
        server: hk.example.com
        port: 8388
        cipher: aes-256-gcm
        password: preview
      - name: US-West
        type: vless
        server: us.example.com
        port: 443
        uuid: 00000000-0000-4000-8000-000000000001
        tls: true
        servername: us.example.com
      - name: JP-Tokyo
        type: trojan
        server: jp.example.com
        port: 443
        password: preview
        sni: jp.example.com
      - name: CN-01
        type: ss
        server: cn.example.com
        port: 8388
        cipher: aes-256-gcm
        password: preview

    proxy-groups:
      - name: Auto
        type: url-test
        proxies:
          - HK-01
          - US-West
          - JP-Tokyo
      - name: Proxy
        type: select
        proxies:
          - HK-01
          - US-West
          - JP-Tokyo
          - CN-01
      - name: Direct
        type: select
        proxies:
          - CN-01

    rules:
      - GEOIP,CN,Direct
      - MATCH,Proxy
    """

    public static let previewLatencies: [String: Double?] = [
        "HK-01": 38,
        "US-West": 168,
        "JP-Tokyo": 72,
        "CN-01": 24
    ]
}

extension ProfileStore {
    /// In-memory Clash catalog with HK / US / JP / CN nodes for Previews.
    public static var preview: ProfileStore {
        let store = ProfileStore(storage: .memory)
        let profile = ProxyProfile(
            name: "Preview",
            format: .clash,
            selectedNodeID: "HK-01",
            selectedGroupName: "Proxy",
            lastUpdated: Date(),
            rawConfig: PreviewFixtures.catalogYAML
        )
        try? store.upsert(profile, makeActive: true)
        return store
    }
}
