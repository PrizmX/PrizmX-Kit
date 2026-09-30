#if os(macOS)
import Foundation
import Network
import os
import Testing
@testable import PrizmXServices

/// Records System Configuration calls instead of touching the real prefs.
private final class ProxyRecorder: @unchecked Sendable {
    enum Event: Equatable {
        case apply(http: Int, socks: Int)
        case restore
    }

    private let events = OSAllocatedUnfairLock<[Event]>(initialState: [])
    /// (entered prepare, released) for the gated start seam.
    private let gate = OSAllocatedUnfairLock<(entered: Bool, released: Bool)>(initialState: (false, true))

    var recorded: [Event] { events.withLock { $0 } }

    /// Blocks the next start after geo prepare until `release()`.
    func holdStarts() { gate.withLock { $0 = (false, false) } }
    func release() { gate.withLock { $0.released = true } }

    func waitUntilHeld() async {
        while !gate.withLock({ $0.entered }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    var control: SystemProxyRuntime.SystemProxyControl {
        SystemProxyRuntime.SystemProxyControl(
            apply: { [events] _, http, socks in events.withLock { $0.append(.apply(http: http, socks: socks)) } },
            restore: { [events] in events.withLock { $0.append(.restore) } },
            afterPrepare: { [gate] in
                gate.withLock { $0.entered = true }
                while !gate.withLock({ $0.released }) {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
        )
    }
}

private func freePort() -> UInt16 {
    UInt16.random(in: 40_000...59_000)
}

private func config(port: UInt16) -> String {
    """
    mixed-port: \(port)
    proxies: []
    rules:
      - MATCH,DIRECT
    """
}

/// NWListener releases its socket asynchronously after cancel.
private func eventuallyFree(_ port: UInt16) async -> Bool {
    for _ in 0..<100 {
        if portIsFree(port) { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

/// True when nothing is listening on 127.0.0.1:port.
private func portIsFree(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}

@Test
func systemProxyRestoredWhenApplyFails() async {
    let recorder = ProxyRecorder()
    let runtime = SystemProxyRuntime(systemProxy: recorder.control)
    await #expect(throws: (any Error).self) {
        try await runtime.apply(
            configText: "{ \"outbounds\": [",
            overlay: .empty,
            allowLAN: false,
            setSystemProxy: true
        )
    }
    #expect(recorder.recorded == [.restore])
    #expect(!runtime.isRunning)
}

@Test
func shutdownSupersedesInFlightApply() async throws {
    let recorder = ProxyRecorder()
    let runtime = SystemProxyRuntime(systemProxy: recorder.control)
    let port = freePort()
    recorder.holdStarts()
    let pending = Task {
        try await runtime.apply(
            configText: config(port: port),
            overlay: .empty,
            allowLAN: false,
            setSystemProxy: true
        )
    }
    // Toggle off while the apply is still preparing.
    await recorder.waitUntilHeld()
    runtime.shutdown()
    recorder.release()
    try await pending.value
    // The stale apply must neither re-enable the proxy nor keep a listener.
    #expect(recorder.recorded == [.restore])
    #expect(!runtime.isRunning)
    #expect(await eventuallyFree(port))
}

@Test
func concurrentAppliesDoNotLeakListeners() async throws {
    let recorder = ProxyRecorder()
    let runtime = SystemProxyRuntime(systemProxy: recorder.control)
    let first = freePort()
    let second = first + 1
    async let a: Void = runtime.apply(
        configText: config(port: first), overlay: .empty, allowLAN: false, setSystemProxy: true
    )
    async let b: Void = runtime.apply(
        configText: config(port: second), overlay: .empty, allowLAN: false, setSystemProxy: true
    )
    _ = try await (a, b)
    #expect(runtime.isRunning)
    // Whichever request came last owns the one live listener.
    guard case .apply(let http, _) = recorder.recorded.last else {
        Issue.record("system proxy not applied: \(recorder.recorded)")
        return
    }
    let loser = UInt16(http) == first ? second : first
    #expect(await eventuallyFree(loser))
    #expect(!portIsFree(UInt16(http)))

    runtime.shutdown()
    #expect(!runtime.isRunning)
    #expect(await eventuallyFree(UInt16(http)))
    #expect(recorder.recorded.last == .restore)
}

@Test
func invalidateKeepsListenerUntilRebuild() async throws {
    let recorder = ProxyRecorder()
    let runtime = SystemProxyRuntime(systemProxy: recorder.control)
    let port = freePort()
    try await runtime.apply(configText: config(port: port), overlay: .empty, allowLAN: false, setSystemProxy: false)
    runtime.invalidate()
    #expect(runtime.isRunning)
    #expect(!portIsFree(port))
    try await runtime.apply(configText: config(port: port), overlay: .empty, allowLAN: false, setSystemProxy: false)
    #expect(runtime.isRunning)
    runtime.shutdown()
    #expect(await eventuallyFree(port))
}
#endif
