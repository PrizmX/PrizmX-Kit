import Foundation

/// One sample on the dashboard throughput chart.
public struct SpeedPoint: Identifiable, Sendable, Hashable {
    public var id: Int
    public var timestamp: Date
    public var uploadBytesPerSecond: Double
    public var downloadBytesPerSecond: Double

    public init(
        id: Int,
        timestamp: Date,
        uploadBytesPerSecond: Double,
        downloadBytesPerSecond: Double
    ) {
        self.id = id
        self.timestamp = timestamp
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
    }
}

/// Rolling 60-second window of uplink / downlink rates for Swift Charts.
public struct SpeedHistoryBuffer: Sendable {
    public static let defaultCapacity = 60

    public let capacity: Int
    private var buffer: RingBuffer<SpeedPoint>
    private var nextID: Int

    public init(capacity: Int = SpeedHistoryBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
        self.buffer = RingBuffer(capacity: self.capacity)
        self.nextID = 0
    }

    public init(capacity: Int = SpeedHistoryBuffer.defaultCapacity, points: [SpeedPoint]) {
        self.capacity = max(1, capacity)
        let clipped = Array(points.suffix(self.capacity))
        self.buffer = RingBuffer(capacity: self.capacity, elements: clipped)
        self.nextID = (clipped.map(\.id).max() ?? -1) + 1
    }

    public var points: [SpeedPoint] { buffer.elements }

    public var count: Int { buffer.count }

    public mutating func append(
        uploadBytesPerSecond: Double,
        downloadBytesPerSecond: Double,
        at timestamp: Date = .now
    ) {
        let point = SpeedPoint(
            id: nextID,
            timestamp: timestamp,
            uploadBytesPerSecond: uploadBytesPerSecond,
            downloadBytesPerSecond: downloadBytesPerSecond
        )
        nextID += 1
        buffer.append(point)
    }

    public mutating func append(_ point: SpeedPoint) {
        nextID = max(nextID, point.id + 1)
        buffer.append(point)
    }

    public mutating func reset() {
        buffer.removeAll()
        nextID = 0
    }

    /// Pre-filled 60s wave used by SwiftUI Previews so Charts have data immediately.
    public static func preview(
        tickCount: Int = SpeedHistoryBuffer.defaultCapacity,
        endingAt date: Date = .now
    ) -> SpeedHistoryBuffer {
        SpeedHistoryBuffer(
            capacity: max(tickCount, 1),
            points: MockTrafficGenerator.speedPoints(count: tickCount, endingAt: date)
        )
    }
}
