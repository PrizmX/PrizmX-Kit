#if os(macOS)
import Foundation
import PrizmXProxyHelper
import Testing

/// The helper receives each service's Proxies dictionary as a binary plist;
/// a restore must hand back exactly what the backup held.
@Test func proxiesSurviveTheHelperEncoding() throws {
    let configs: [String: [String: Any]] = [
        "service-a": [
            "HTTPEnable": 1,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": 7890,
            "ExceptionsList": ["localhost", "*.local"],
        ],
        "service-b": [:],
    ]
    let encoded = try #require(ProxyServiceWriter.encode(configs))
    let decoded = try #require(ProxyServiceWriter.decode(encoded))
    #expect(Set(decoded.keys) == ["service-a", "service-b"])
    #expect(NSDictionary(dictionary: decoded["service-a"] ?? [:]).isEqual(to: configs["service-a"] ?? [:]))
    #expect(decoded["service-b"]?.isEmpty == true)
}

@Test func helperRejectsANonDictionaryPayload() throws {
    let list = try PropertyListSerialization.data(fromPropertyList: ["a"], format: .binary, options: 0)
    #expect(ProxyServiceWriter.decode(["service": list]) == nil)
}
#endif
