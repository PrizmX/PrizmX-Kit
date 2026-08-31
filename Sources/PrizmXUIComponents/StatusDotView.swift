import SwiftUI
import PrizmXUIEngine

/// Traffic-light status indicator with a pulse (connected) or breathing
/// (connecting) animation.
public struct StatusDotView: View {
    public var status: VPNStatus
    public var size: CGFloat

    @State private var animationPhase = false

    public init(status: VPNStatus, size: CGFloat = 10) {
        self.status = status
        self.size = size
    }

    public var body: some View {
        ZStack {
            if status.signal != .bad {
                Circle()
                    .stroke(color.opacity(0.45), lineWidth: 2)
                    .frame(width: size, height: size)
                    .scaleEffect(animationPhase ? 2.2 : 1)
                    .opacity(animationPhase ? 0 : 0.85)
            }

            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .opacity(status.signal == .pending && animationPhase ? 0.55 : 1)
        }
        .frame(width: size * 2.4, height: size * 2.4)
        .accessibilityLabel(Text(status.rawValue))
        .onAppear { restartAnimation() }
        .onChange(of: status) { _, _ in restartAnimation() }
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

    private func restartAnimation() {
        animationPhase = false
        switch status.signal {
        case .good:
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                animationPhase = true
            }
        case .pending:
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                animationPhase = true
            }
        case .bad:
            break
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
