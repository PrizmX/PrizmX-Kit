import Foundation
import PrizmXCore
import PrizmXProtocols

/// Deterministic oscillating throughput used by `VPNManager(isMock:)` and Previews.
///
/// Nominal rates match the dashboard mock contract: 2.5 MB/s uplink and
/// 12.8 MB/s downlink, with a gentle sine-wave wobble so Charts look alive.
public enum MockTrafficGenerator: Sendable {
    public static let uploadBytesPerSecond: Double = 2_500_000
    public static let downloadBytesPerSecond: Double = 12_800_000

    public static func metrics(at date: Date = .now) -> VPNMetrics {
        let epoch = date.timeIntervalSinceReferenceDate
        let upload = oscillate(
            base: uploadBytesPerSecond,
            epoch: epoch,
            amplitude: 0.18,
            frequency: 0.90
        )
        let download = oscillate(
            base: downloadBytesPerSecond,
            epoch: epoch,
            amplitude: 0.14,
            frequency: 1.17,
            phase: 0.6
        )
        let connections = Int((48.0 + 10.0 * sin(epoch * 0.35)).rounded())
        let sample = FlowRecord(
            startedAt: date.addingTimeInterval(-2),
            endpoint: Endpoint(domain: "github.com", port: 443),
            via: "Proxies",
            uplinkBytes: 12_000,
            downlinkBytes: 180_000,
            milliseconds: 1_800,
            clientEnd: "eof",
            remoteEnd: "eof",
            closed: true
        )
        return VPNMetrics(
            uploadBytesPerSecond: upload,
            downloadBytesPerSecond: download,
            activeConnections: max(8, connections),
            recentFlows: [sample]
        )
    }

    public static func speedPoints(
        count: Int = SpeedHistoryBuffer.defaultCapacity,
        endingAt date: Date = .now
    ) -> [SpeedPoint] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let timestamp = date.addingTimeInterval(Double(index - (count - 1)))
            let snapshot = metrics(at: timestamp)
            return SpeedPoint(
                id: index,
                timestamp: timestamp,
                uploadBytesPerSecond: snapshot.uploadBytesPerSecond,
                downloadBytesPerSecond: snapshot.downloadBytesPerSecond
            )
        }
    }

    private static func oscillate(
        base: Double,
        epoch: Double,
        amplitude: Double,
        frequency: Double,
        phase: Double = 0
    ) -> Double {
        max(0, base * (1 + amplitude * sin(epoch * frequency + phase)))
    }
}
