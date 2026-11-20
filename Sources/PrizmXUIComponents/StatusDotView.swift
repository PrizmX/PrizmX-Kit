import SwiftUI
import PrizmXServices

/// Traffic-light status indicator with a time-driven pulse (connected) or
/// breathing (connecting) animation. Driven by `TimelineView` so parent
/// 1 Hz updates never reset or jump the animation state.
public struct StatusDotView: View {
    public var status: VPNStatus
    public var size: CGFloat

    public init(status: VPNStatus, size: CGFloat = 10) {
        self.status = status
        self.size = size
    }

    public var body: some View {
        TimelineView(.animation(paused: status.signal == .bad)) { context in
            let metrics = Self.frameMetrics(for: status, at: context.date)
            ZStack {
                if status.signal != .bad {
                    Circle()
                        .stroke(color.opacity(0.45), lineWidth: 2)
                        .frame(width: size, height: size)
                        .scaleEffect(metrics.ringScale)
                        .opacity(metrics.ringOpacity)
                }

                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .opacity(metrics.dotOpacity)
            }
            .frame(width: size * 2.4, height: size * 2.4)
        }
        .accessibilityLabel(Text(status.rawValue))
    }

    private var color: Color {
        switch status.signal {
        case .good:
            return .green
        case .pending:
            return .yellow
        case .bad:
            return .red
        }
    }

    private static func frameMetrics(
        for status: VPNStatus,
        at date: Date
    ) -> (ringScale: CGFloat, ringOpacity: Double, dotOpacity: Double) {
        let now = date.timeIntervalSinceReferenceDate
        switch status.signal {
        case .good:
            let period = 1.2
            let t = now.truncatingRemainder(dividingBy: period) / period
            let eased = 1 - pow(1 - t, 2)
            return (1 + 1.2 * eased, 0.85 * (1 - eased), 1)
        case .pending:
            let period = 1.8
            let half = period / 2
            let phase = now.truncatingRemainder(dividingBy: period)
            let linear = phase <= half ? (phase / half) : (2 - phase / half)
            let eased = 0.5 - 0.5 * cos(.pi * linear)
            return (1 + 1.2 * eased, 0.85 * (1 - eased), 1 - 0.45 * eased)
        case .bad:
            return (1, 0, 1)
        }
    }
}

#Preview("Connected") {
    StatusDotView(status: .connected)
}

#Preview("Connecting") {
    StatusDotView(status: .connecting)
}

#Preview("Disconnected") {
    StatusDotView(status: .disconnected)
}
