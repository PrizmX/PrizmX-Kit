import Foundation
import PrizmXCore

/// Inspector request history, Surge-style: one list of requests keyed by flow
/// ID, where a row is updated in place as it goes from Active to Completed.
/// Recent shows every row; Active is the open ones.
///
/// Snapshots only carry a window (open splices plus the newest closed ones),
/// so rows are accumulated here across polls, up to `capacity`.
public struct FlowHistory: Sendable {
    public static let defaultCapacity = 1_000

    public let capacity: Int
    /// Newest first (by start time).
    public private(set) var flows: [FlowRecord] = []
    /// Closed records that ended before this are not re-added (Clear).
    private var clearedAt: Date?

    public init(capacity: Int = FlowHistory.defaultCapacity) {
        precondition(capacity > 0, "FlowHistory capacity must be positive")
        self.capacity = capacity
    }

    public mutating func ingest(_ snapshot: TrafficSnapshot, now: Date = .now) {
        var byID: [UUID: FlowRecord] = [:]
        byID.reserveCapacity(flows.count + snapshot.activeFlows.count + snapshot.recentFlows.count)
        for flow in flows {
            byID[flow.id] = flow
        }
        for flow in snapshot.activeFlows {
            byID[flow.id] = flow
        }
        for flow in snapshot.recentFlows where byID[flow.id] != nil || !endedBeforeClear(flow) {
            byID[flow.id] = flow
        }
        // A complete open list (nothing cut) is authoritative: a row still open
        // here but missing there closed between polls without its record
        // reaching us (more closes than the window, or the engine stopped).
        if snapshot.activeFlows.count >= snapshot.tcpConnections {
            let open = Set(snapshot.activeFlows.map(\.id))
            let gone = byID.values.filter { !$0.closed && !open.contains($0.id) }
            for flow in gone {
                byID[flow.id] = Self.closing(flow, at: now)
            }
        }
        flows = Self.trimmed(byID.values.sorted(by: Self.newerFirst), to: capacity)
    }

    /// Drops finished rows and keeps open ones (they are still Active).
    /// Closed records that ended before `now` are not re-added afterwards.
    public mutating func clear(now: Date = .now) {
        clearedAt = now
        flows.removeAll(where: \.closed)
    }

    private func endedBeforeClear(_ flow: FlowRecord) -> Bool {
        guard let clearedAt else { return false }
        return flow.startedAt.addingTimeInterval(Double(flow.milliseconds) / 1_000) <= clearedAt
    }

    /// The real close time is unknown; use when the gap was seen.
    private static func closing(_ flow: FlowRecord, at now: Date) -> FlowRecord {
        var closed = flow
        closed.closed = true
        closed.milliseconds = max(flow.milliseconds, Int(now.timeIntervalSince(flow.startedAt) * 1_000))
        return closed
    }

    /// Over capacity, the oldest finished rows go first; open ones stay.
    private static func trimmed(_ flows: [FlowRecord], to capacity: Int) -> [FlowRecord] {
        var excess = flows.count - capacity
        guard excess > 0 else { return flows }
        var kept: [FlowRecord] = []
        kept.reserveCapacity(capacity)
        for flow in flows.reversed() {
            if excess > 0, flow.closed {
                excess -= 1
                continue
            }
            kept.append(flow)
        }
        return Array(kept.reversed().prefix(capacity))
    }

    /// Stable order so an unchanged history compares equal across polls.
    private static func newerFirst(_ lhs: FlowRecord, _ rhs: FlowRecord) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}
