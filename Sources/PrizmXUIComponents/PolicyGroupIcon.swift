import NetworkExtension
import SwiftUI

/// Policy group icon loaded from Clash group `icon` URL via `CachedAsyncImage`,
/// falling back to the policy-routing SF Symbol when unset or unavailable.
public struct PolicyGroupIcon: View {
    public var url: URL?
    public var size: CGFloat
    @State private var retryNonce = 0
    @Environment(\.scenePhase) private var scenePhase

    public init(url: URL?, size: CGFloat = 20) {
        self.url = url
        self.size = size
    }

    public var body: some View {
        CachedAsyncImage(url: url) { image in
            image
                .resizable()
                .scaledToFit()
        } placeholder: {
            fallbackGlyph
        }
        .id(TaskKey(url: url, nonce: retryNonce))
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            retryNonce += 1
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                retryNonce += 1
            }
        }
    }

    private struct TaskKey: Hashable {
        var url: URL?
        var nonce: Int
    }

    private var fallbackGlyph: some View {
        Image(systemName: "point.3.connected.trianglepath.dotted")
            .font(.system(size: size * 0.65, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
