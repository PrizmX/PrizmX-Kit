import PrizmXNodes
import PrizmXProtocols

extension OutboundNode {
    /// Server used for TCP / HTTP delay probes. Direct nodes have no peer.
    public var probeServer: Endpoint? {
        switch protocolConfig {
        case .shadowsocks(let server, _, _):
            return server
        case .vless(let server, _, _, _, _):
            return server
        case .trojan(let server, _, _):
            return server
        case .anytls(let server, _, _):
            return server
        case .direct:
            return nil
        }
    }
}
