import Foundation
import Observation
import PrizmXProtocols
import PrizmXScripts

/// Result summary of one script evaluation, surfaced in ScriptsPane and logs.
public struct ScriptRunSummary: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var scriptName: String
    public var ranAt: Date
    public var durationMs: Int
    public var succeeded: Bool
    public var resultText: String
    public var logs: [String]
    public var errorMessage: String?
    public var trigger: String

    public init(
        id: UUID,
        scriptName: String,
        ranAt: Date = Date(),
        durationMs: Int,
        succeeded: Bool,
        resultText: String,
        logs: [String] = [],
        errorMessage: String? = nil,
        trigger: String = "manual"
    ) {
        self.id = id
        self.scriptName = scriptName
        self.ranAt = ranAt
        self.durationMs = durationMs
        self.succeeded = succeeded
        self.resultText = resultText
        self.logs = logs
        self.errorMessage = errorMessage
        self.trigger = trigger
    }
}

/// Runs Scripts manually, on Cron schedules, and on `network-changed` events.
@MainActor
@Observable
public final class ScriptScheduler {
    public let store: ScriptStore
    public private(set) var lastRunByID: [UUID: ScriptRunSummary] = [:]
    public private(set) var runningIDs: Set<UUID> = []

    @ObservationIgnored
    private let engine: ScriptEngine
    @ObservationIgnored
    private let persistentStore: any ScriptPersistentStorage
    @ObservationIgnored
    private let httpClient: ScriptHTTPHandler
    @ObservationIgnored
    private let networkProvider: @MainActor () -> ScriptNetworkInfo
    @ObservationIgnored
    private let moduleScriptsProvider: @MainActor () -> [ScriptRecord]
    @ObservationIgnored
    private let prizmxBridgeProvider: @MainActor () -> ScriptPrizmXBridge
    @ObservationIgnored
    private let notificationHandler: ScriptNotificationHandler?
    @ObservationIgnored
    private let appVersion: String
    @ObservationIgnored
    private var cronTask: Task<Void, Never>?
    @ObservationIgnored
    private var networkEventTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastCronMinuteKey: String?

    public init(
        store: ScriptStore,
        persistentStore: any ScriptPersistentStorage = InMemoryScriptPersistentStore(),
        httpClient: @escaping ScriptHTTPHandler = ScriptEnvironmentContext.defaultHTTPClient,
        networkProvider: @escaping @MainActor () -> ScriptNetworkInfo = { ScriptNetworkInfo() },
        moduleScriptsProvider: @escaping @MainActor () -> [ScriptRecord] = { [] },
        prizmxBridgeProvider: @escaping @MainActor () -> ScriptPrizmXBridge = { .empty },
        notificationHandler: ScriptNotificationHandler? = nil,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    ) {
        self.store = store
        self.persistentStore = persistentStore
        self.httpClient = httpClient
        self.networkProvider = networkProvider
        self.moduleScriptsProvider = moduleScriptsProvider
        self.prizmxBridgeProvider = prizmxBridgeProvider
        self.notificationHandler = notificationHandler
        self.appVersion = appVersion
        self.engine = ScriptEngine(environment: ScriptEnvironmentContext(
            httpClient: httpClient,
            persistentStore: persistentStore,
            notificationHandler: notificationHandler,
            version: appVersion
        ))
    }

    deinit {
        cronTask?.cancel()
        networkEventTask?.cancel()
    }

    public func start() {
        guard cronTask == nil else { return }
        cronTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date()
                let secondsIntoMinute = Calendar.current.component(.second, from: now)
                let delay = max(1, 60 - secondsIntoMinute)
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                await self.tickCron(at: Date())
            }
        }
    }

    public func stop() {
        cronTask?.cancel()
        cronTask = nil
        networkEventTask?.cancel()
        networkEventTask = nil
    }

    /// Evaluates one script immediately with a fresh `$network` snapshot.
    @discardableResult
    public func runNow(_ script: ScriptRecord, trigger: String = "manual") async -> ScriptRunSummary {
        runningIDs.insert(script.id)
        defer { runningIDs.remove(script.id) }

        let env = ScriptEnvironmentContext(
            httpClient: httpClient,
            persistentStore: persistentStore,
            notificationHandler: notificationHandler,
            network: networkProvider(),
            version: appVersion,
            prizmx: prizmxBridgeProvider()
        )
        var request = script.request
        request.source = store.resolvedSource(for: script)
        request.environment = env

        let start = ContinuousClock.now
        let summary: ScriptRunSummary
        do {
            let result = try await engine.evaluate(request)
            let ms = Int(start.duration(to: .now) / .milliseconds(1))
            summary = ScriptRunSummary(
                id: script.id,
                scriptName: script.name,
                ranAt: Date(),
                durationMs: max(0, ms),
                succeeded: true,
                resultText: result.value.jsonString,
                logs: result.logs,
                errorMessage: nil,
                trigger: trigger
            )
            TunnelLog.write(.info, "script [\(trigger)] \(script.name) ok (\(ms)ms)")
            for line in result.logs.prefix(8) {
                TunnelLog.write(.info, "script \(script.name): \(line)")
            }
        } catch {
            let ms = Int(start.duration(to: .now) / .milliseconds(1))
            summary = ScriptRunSummary(
                id: script.id,
                scriptName: script.name,
                ranAt: Date(),
                durationMs: max(0, ms),
                succeeded: false,
                resultText: "",
                logs: [],
                errorMessage: error.localizedDescription,
                trigger: trigger
            )
            TunnelLog.write(.error, "script [\(trigger)] \(script.name) failed: \(error.localizedDescription)")
        }
        lastRunByID[script.id] = summary
        return summary
    }

    /// Runs all enabled `.cron` scripts whose schedule matches `date`.
    /// Guarded so each minute bucket triggers at most once.
    public func tickCron(at date: Date = Date(), calendar: Calendar = .current) async {
        let key = Self.minuteKey(for: date, calendar: calendar)
        guard key != lastCronMinuteKey else { return }
        lastCronMinuteKey = key

        let candidates = (store.scripts + moduleScriptsProvider()).filter { $0.enabled && $0.kind == .cron }
        for script in candidates {
            guard let schedule = try? CronSchedule.parse(script.pattern),
                  schedule.matches(date, calendar: calendar, ignoreSeconds: true)
            else { continue }
            guard !runningIDs.contains(script.id) else { continue }
            _ = await runNow(script, trigger: "cron")
        }
    }

    /// Debounced trigger for enabled `.event` scripts listening to `network-changed`.
    public func handleNetworkChanged(debounce: Duration = .milliseconds(500)) {
        networkEventTask?.cancel()
        networkEventTask = Task { [weak self] in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard let self, !Task.isCancelled else { return }
            await self.triggerNetworkChangedEventNow()
        }
    }

    /// Immediate trigger used by `handleNetworkChanged` and unit tests.
    public func triggerNetworkChangedEventNow() async {
        let candidates = (store.scripts + moduleScriptsProvider()).filter { script in
            guard script.enabled, script.kind == .event else { return false }
            let trimmed = script.pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty || trimmed == "network-changed"
        }
        for script in candidates where !runningIDs.contains(script.id) {
            _ = await runNow(script, trigger: "network-changed")
        }
    }

    private static func minuteKey(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)-\(c.hour ?? 0)-\(c.minute ?? 0)"
    }
}
