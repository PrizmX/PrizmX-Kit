import AppKit
import SwiftUI
import PrizmXServices

/// Tunnel runtime events (App Group `logs/tunnel.log`), oldest first.
/// Per-flow request data belongs to the Inspector, not this log.
struct EventsPane: View {
    // Populated by the first `refresh()` — reading the log synchronously here
    // would block the main actor while the pane appears.
    @State private var lines: [String] = []
    @State private var followsTail = true
    @State private var userInteracting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .modifier(ScrollTailTrackingModifier(
                    userInteracting: $userInteracting,
                    followsTail: $followsTail
                ))
                .onChange(of: lines.count) {
                    if followsTail {
                        scrollToLatest(proxy)
                    }
                }
                .onAppear {
                    scrollToLatest(proxy, animated: false)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followsTail, !lines.isEmpty {
                        Button {
                            followsTail = true
                            scrollToLatest(proxy)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.body.weight(.semibold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                        .padding(12)
                        .help("Scroll to latest")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
            )
            .overlay {
                if lines.isEmpty {
                    ConsoleEmptyState(
                        title: "No Events",
                        systemImage: SidebarItem.events.systemImage,
                        description: "Tunnel runtime events will appear here."
                    )
                }
            }
        }
        .padding(20)
        .navigationTitle("Events")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                IconControlGroup {
                    Button("Show in Finder", systemImage: "folder") {
                        if let url = TunnelLog.fileURL() {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .help("Show in Finder")
                    Button("Clear", systemImage: "xmark.circle") {
                        TunnelLog.clear()
                        Task { await refresh() }
                    }
                    .help("Clear")
                    .disabled(lines.isEmpty)
                }
            }
        }
        .task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await refresh()
            }
        }
    }

    private nonisolated static func readLines() -> [String] {
        // Log lines are always non-empty. Omitting empties keeps the list
        // truly empty when the log is missing ("".split with false yields
        // one empty element) and drops the trailing newline's blank row.
        TunnelLog.read().split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// `TunnelLog.read()` blocks on file I/O; keep it off the main actor.
    private func refresh() async {
        let next = await Task.detached(priority: .utility) { Self.readLines() }.value
        guard next != lines else { return }
        lines = next
    }



    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let last = lines.indices.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    private func color(for line: String) -> Color {
        if line.contains("[error]") { return .red }
        if line.contains("[warn]") { return .orange }
        if line.contains("[debug]") { return .secondary }
        return .primary
    }
}

#Preview("Events") {
    EventsPane()
}

private struct ScrollTailTrackingModifier: ViewModifier {
    @Binding var userInteracting: Bool
    @Binding var followsTail: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollPhaseChange { _, phase in
                    userInteracting = phase == .interacting
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 32
                } action: { _, atBottom in
                    if atBottom {
                        followsTail = true
                    } else if userInteracting {
                        followsTail = false
                    }
                }
        } else {
            content
        }
    }
}
