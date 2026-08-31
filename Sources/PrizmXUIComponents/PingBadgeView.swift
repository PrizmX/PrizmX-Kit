import SwiftUI

/// Pill badge for a node delay. `nil` (or values past `timeoutThreshold`)
/// render as a red `Timeout` capsule.
public struct PingBadgeView: View {
    public var milliseconds: Double?
    public var goodThreshold: Double
    public var fairThreshold: Double
    public var timeoutThreshold: Double

    public init(
        milliseconds: Double?,
        goodThreshold: Double = 100,
        fairThreshold: Double = 300,
        timeoutThreshold: Double = 2_000
    ) {
        self.milliseconds = milliseconds
        self.goodThreshold = goodThreshold
        self.fairThreshold = fairThreshold
        self.timeoutThreshold = timeoutThreshold
    }

    public var body: some View {
        Text(label)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule())
            .accessibilityLabel(Text(label))
    }

    private var isTimeout: Bool {
        guard let milliseconds else { return true }
        return milliseconds > timeoutThreshold || milliseconds < 0
    }

    private var label: String {
        guard !isTimeout, let milliseconds else { return "Timeout" }
        if milliseconds < 10 {
            return String(format: "%.0f ms", milliseconds)
        }
        return "\(Int(milliseconds.rounded())) ms"
    }

    private var tint: Color {
        guard !isTimeout, let milliseconds else { return .red }
        if milliseconds < goodThreshold { return .green }
        if milliseconds < fairThreshold { return .yellow }
        return .red
    }
}

#Preview("Good") {
    PingBadgeView(milliseconds: 45)
}

#Preview("Fair") {
    PingBadgeView(milliseconds: 180)
}

#Preview("Timeout") {
    PingBadgeView(milliseconds: nil)
}
