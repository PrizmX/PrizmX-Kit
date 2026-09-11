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
        return VPNMetrics(
            uploadBytesPerSecond: upload,
            downloadBytesPerSecond: download,
            activeConnections: max(8, connections),
            activeFlows: previewActiveFlows(at: date),
            recentFlows: [previewRecentFlow(at: date)]
        )
    }

    private static func previewActiveFlows(at date: Date) -> [FlowRecord] {
        let safari = FlowAttribution(pid: 1, processName: "Safari", bundleID: "com.apple.Safari")
        let music = FlowAttribution(pid: 2, processName: "Music", bundleID: "com.apple.Music")
        return [
            FlowRecord(
                startedAt: date.addingTimeInterval(-8),
                endpoint: Endpoint(domain: "github.com", port: 443),
                via: "Proxies",
                uplinkBytes: 4_200,
                downlinkBytes: 88_000,
                closed: false,
                attribution: safari
            ),
            FlowRecord(
                startedAt: date.addingTimeInterval(-3),
                endpoint: Endpoint(domain: "apple.com", port: 443),
                via: "Direct",
                uplinkBytes: 1_100,
                downlinkBytes: 22_000,
                closed: false,
                attribution: music
            )
        ]
    }

    private static func previewRecentFlow(at date: Date) -> FlowRecord {
        FlowRecord(
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
