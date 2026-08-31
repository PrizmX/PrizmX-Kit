import Foundation

/// Versioned JSON IPC between the host app and `NEPacketTunnelProvider`.
///
/// The tunnel extension should implement `handleAppMessage` by decoding
/// `TunnelIPC.Request` and encoding `TunnelIPC.Response`. Kit never talks
/// to the provider with ad-hoc dictionaries.
public enum TunnelIPC: Sendable {
    public static let protocolVersion = 1

    public enum Method: String, Sendable, Codable {
        case fetchMetrics
        case selectNode
    }

    public struct Request: Sendable, Codable, Equatable {
        public var version: Int
        public var method: Method
        public var nodeID: String?
        public var groupName: String?

        public init(
            method: Method,
            nodeID: String? = nil,
            groupName: String? = nil,
            version: Int = TunnelIPC.protocolVersion
        ) {
            self.version = version
            self.method = method
            self.nodeID = nodeID
            self.groupName = groupName
        }
    }

    public struct Response: Sendable, Codable, Equatable {
        public var version: Int
        public var ok: Bool
        public var metrics: VPNMetrics?
        public var error: String?

        public init(
            ok: Bool,
            metrics: VPNMetrics? = nil,
            error: String? = nil,
            version: Int = TunnelIPC.protocolVersion
        ) {
            self.version = version
            self.ok = ok
            self.metrics = metrics
            self.error = error
        }

        public static func success(metrics: VPNMetrics? = nil) -> Response {
            Response(ok: true, metrics: metrics)
        }

        public static func failure(_ message: String) -> Response {
            Response(ok: false, error: message)
        }
    }

    public static func encode(_ request: Request) throws -> Data {
        try JSONEncoder().encode(request)
    }

    public static func encode(_ response: Response) throws -> Data {
        try JSONEncoder().encode(response)
    }

    public static func decodeRequest(from data: Data) throws -> Request {
        try JSONDecoder().decode(Request.self, from: data)
    }

    /// Accepts a wrapped `Response` or a bare `VPNMetrics` payload so older
    /// providers that only returned throughput JSON still decode.
    public static func decodeResponse(from data: Data?) throws -> Response {
        guard let data, !data.isEmpty else {
            throw VPNError.ipcFailed("empty provider response")
        }
        if let response = try? JSONDecoder().decode(Response.self, from: data) {
            return response
        }
        if let metrics = try? JSONDecoder().decode(VPNMetrics.self, from: data) {
            return .success(metrics: metrics)
        }
        throw VPNError.ipcFailed("unrecognized provider payload")
    }

    public static func metrics(from data: Data?) throws -> VPNMetrics {
        let response = try decodeResponse(from: data)
        if let metrics = response.metrics {
            return metrics
        }
        if response.ok {
            return .zero
        }
        throw VPNError.ipcFailed(response.error ?? "provider error")
    }
}
