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

    /// Runs every poll over up to `capacity` rows, so known rows are updated
    /// in place and only new ones are sorted, then merged into the kept order.
    public mutating func ingest(_ snapshot: TrafficSnapshot, now: Date = .now) {
        var rows = flows
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(rows.count)
        for index in rows.indices {
            indexByID[rows[index].id] = index
        }
        var added: [UUID: FlowRecord] = [:]
        var needsResort = false
        func upsert(_ flow: FlowRecord) {
            if let index = indexByID[flow.id] {
                if rows[index].startedAt != flow.startedAt { needsResort = true }
                rows[index] = flow
            } else {
                added[flow.id] = flow
            }
        }
        for flow in snapshot.activeFlows {
            upsert(flow)
        }
        for flow in snapshot.recentFlows
        where indexByID[flow.id] != nil || added[flow.id] != nil || !endedBeforeClear(flow) {
            upsert(flow)
        }
        // A complete open list (nothing cut) is authoritative: a row still open
        // here but missing there closed between polls without its record
        // reaching us (more closes than the window, or the engine stopped).
        if snapshot.activeFlows.count >= snapshot.tcpConnections {
            let open = Set(snapshot.activeFlows.map(\.id))
            for index in rows.indices where !rows[index].closed && !open.contains(rows[index].id) {
                rows[index] = Self.closing(rows[index], at: now)
            }
            for (id, flow) in added where !flow.closed && !open.contains(id) {
                added[id] = Self.closing(flow, at: now)
            }
        }
        let ordered: [FlowRecord]
        if needsResort {
            ordered = (rows + added.values).sorted(by: Self.newerFirst)
        } else {
            ordered = Self.merged(rows, added.values.sorted(by: Self.newerFirst))
        }
        flows = Self.trimmed(ordered, to: capacity)
    }

    /// Merges two lists already in `newerFirst` order.
    private static func merged(_ lhs: [FlowRecord], _ rhs: [FlowRecord]) -> [FlowRecord] {
        guard !rhs.isEmpty else { return lhs }
        guard !lhs.isEmpty else { return rhs }
        var result: [FlowRecord] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var left = 0
        var right = 0
        while left < lhs.count, right < rhs.count {
            if newerFirst(rhs[right], lhs[left]) {
                result.append(rhs[right])
                right += 1
            } else {
                result.append(lhs[left])
                left += 1
            }
        }
        result.append(contentsOf: lhs[left...])
        result.append(contentsOf: rhs[right...])
        return result
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
