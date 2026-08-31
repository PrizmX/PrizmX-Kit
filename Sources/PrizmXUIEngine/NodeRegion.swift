import Foundation
import PrizmXNodes

/// Coarse region bucket used by the node list.
public enum NodeRegion: String, Sendable, Hashable, CaseIterable, Identifiable {
    case china = "CN"
    case hongKong = "HK"
    case japan = "JP"
    case unitedStates = "US"
    case other = "Other"

    public var id: String { rawValue }
    public var title: String { rawValue }

    public static let displayOrder: [NodeRegion] = [.china, .hongKong, .japan, .unitedStates, .other]
}

/// Infers a region from an outbound node's display name or id.
public enum NodeRegionClassifier: Sendable {
    public static func region(for node: OutboundNode) -> NodeRegion {
        classify(node.name) ?? classify(node.id) ?? .other
    }

    public static func classify(_ text: String) -> NodeRegion? {
        let tokens = tokenize(text)
        if tokens.contains("HK") || tokens.contains("HONGKONG") { return .hongKong }
        if tokens.contains("HONG") && tokens.contains("KONG") { return .hongKong }
        if tokens.contains("JP") || tokens.contains("JAPAN") || tokens.contains("TOKYO") || tokens.contains("OSAKA") {
            return .japan
        }
        if tokens.contains("US") || tokens.contains("USA") || tokens.contains("AMERICA") {
            return .unitedStates
        }
        if tokens.contains("CN") || tokens.contains("CHINA") || tokens.contains("CHN") { return .china }
        return nil
    }

    private static func tokenize(_ text: String) -> Set<String> {
        var tokens: Set<String> = []
        var current = ""
        for character in text.uppercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                tokens.insert(current)
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.insert(current)
        }
        return tokens
    }
}

/// How the node list buckets its rows.
public enum NodeListGrouping: Sendable, Hashable {
    /// Profile policy groups (`Auto`, `Proxy`, `Direct`, …).
    case policy
    /// Country / region inferred from node names (`CN`, `US`, `HK`, `JP`).
    case region
}
