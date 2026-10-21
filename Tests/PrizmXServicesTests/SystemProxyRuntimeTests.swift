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

/// A port the kernel just handed out and released. A random pick could
/// land on another test's listener or an ephemeral port in use. Bound on
/// the wildcard address: NWListener refuses a port that a connection holds
/// on any local address (a tunnel flow from 198.18.0.1, say), which a probe
/// on 127.0.0.1 does not see.
private func freePort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return UInt16.random(in: 40_000...48_000) }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = INADDR_ANY
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
        }
    }
    guard bound else { return UInt16.random(in: 40_000...48_000) }
    return UInt16(bigEndian: addr.sin_port)
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
    // Its own free port: the one after `first` may already be taken.
    var second = freePort()
    while second == first { second = freePort() }
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

/// A rule / profile reload on the same port used to close the listener
/// before the new engine was ready, leaving the system proxy pointing at a
/// closed port while geo assets were prepared.
@Test
func reloadOnSamePortKeepsListeningWhilePreparing() async throws {
    let recorder = ProxyRecorder()
    let runtime = SystemProxyRuntime(systemProxy: recorder.control)
    let port = freePort()
    try await runtime.apply(configText: config(port: port), overlay: .empty, allowLAN: false, setSystemProxy: true)
    runtime.invalidate()
    recorder.holdStarts()
    let reload = Task {
        try await runtime.apply(
            configText: config(port: port) + "\n# changed",
            overlay: .empty,
            allowLAN: false,
            setSystemProxy: true
        )
    }
    await recorder.waitUntilHeld()
    #expect(runtime.isRunning)
    #expect(!portIsFree(port))
    recorder.release()
    try await reload.value
    #expect(runtime.isRunning)
    #expect(!recorder.recorded.contains(.restore))
    runtime.shutdown()
    #expect(await eventuallyFree(port))
}

@Test
func brokenReloadKeepsTheRunningListener() async throws {
    let recorder = ProxyRecorder()
    let runtime = SystemProxyRuntime(systemProxy: recorder.control)
    let port = freePort()
    try await runtime.apply(configText: config(port: port), overlay: .empty, allowLAN: false, setSystemProxy: true)
    runtime.invalidate()
    await #expect(throws: (any Error).self) {
        try await runtime.apply(
            configText: "{ \"outbounds\": [",
            overlay: .empty,
            allowLAN: false,
            setSystemProxy: true
        )
    }
    #expect(runtime.isRunning)
    #expect(!recorder.recorded.contains(.restore))
    runtime.shutdown()
    #expect(await eventuallyFree(port))
}
#endif
