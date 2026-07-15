import Foundation
import ComputerUseCore
import CaptureEngine
import ActionEngine
#if canImport(AppKit)
import AppKit
#endif

// MARK: - AppLauncher seams

/// Workspace operations unique to launch/recovery (open / hide state).
///
/// Activation and AX raise reuse `ServiceContext.workspace` (`WorkspaceControlling`)
/// so focus-path fakes stay shared with Phase 4 tests.
public protocol AppLaunchControlling: AnyObject {
    /// Resolve a launchable file URL for the installed app, if any.
    func applicationURL(bundleId: String?, path: String?) -> URL?
    /// Start (or re-open) the application at `url`. Returns the running pid when known.
    func openApplication(at url: URL, activate: Bool) async throws -> pid_t?
    /// Whether the process is currently hidden (Dock-hide), when resolvable.
    func isHidden(pid: pid_t) -> Bool
    /// Unhide a hidden process. Returns whether the call reported success.
    func unhide(pid: pid_t) -> Bool
    /// Whether a process with `pid` is still alive.
    func isProcessRunning(pid: pid_t) -> Bool
}

/// Counts normal visible windows for recovery/wait decisions.
public protocol AppLaunchWindowObserving: Sendable {
    func visibleWindowCount(forPID pid: Int32) -> Int
}

/// Monotonic clock + awaitable sleep for bounded polling (no fixed blind sleeps).
public protocol AppLaunchClock: Sendable {
    func now() -> TimeInterval
    func sleep(_ seconds: TimeInterval) async
}

/// Live `NSWorkspace` / `NSRunningApplication` controller (public AppKit only).
public final class SystemAppLaunchController: AppLaunchControlling {
    public init() {}

    public func applicationURL(bundleId: String?, path: String?) -> URL? {
        if let path, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #if canImport(AppKit)
        if let bundleId, !bundleId.isEmpty {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        }
        #endif
        return nil
    }

    public func openApplication(at url: URL, activate: Bool) async throws -> pid_t? {
        #if canImport(AppKit)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return app.processIdentifier
        #else
        throw CUError.internalError(detail: "launch_app is unavailable on this platform")
        #endif
    }

    public func isHidden(pid: pid_t) -> Bool {
        #if canImport(AppKit)
        return NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
        #else
        return false
        #endif
    }

    public func unhide(pid: pid_t) -> Bool {
        #if canImport(AppKit)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.unhide()
        #else
        return false
        #endif
    }

    public func isProcessRunning(pid: pid_t) -> Bool {
        #if canImport(AppKit)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
        #else
        return false
        #endif
    }
}

/// Live CGWindowList observer (permission-free for normal on-screen windows).
public struct CGAppLaunchWindowObserver: AppLaunchWindowObserving {
    public init() {}

    public func visibleWindowCount(forPID pid: Int32) -> Int {
        WindowCatalog.cgWindows(includeOffscreen: false)
            .filter { $0.ownerPID == pid && $0.isNormalVisible }
            .count
    }
}

/// Live uptime clock.
public struct SystemAppLaunchClock: AppLaunchClock {
    public init() {}

    public func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    public func sleep(_ seconds: TimeInterval) async {
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        if nanos == 0 { return }
        try? await Task.sleep(nanoseconds: nanos)
    }
}

/// Explicit `launch_app` lifecycle engine.
///
/// Launch and hidden/minimized recovery happen **only** through this type. Ordinary
/// app resolution (`AppResolver` / `list_apps` / read tools) never opens, activates,
/// unhides, or reopens an application. Policy is enforced before any workspace or
/// launch-controller call.
public enum AppLauncher {
    /// Default inter-poll interval while waiting for a process/window (seconds).
    public static let defaultPollInterval: TimeInterval = 0.05

    /// Launch or recover `request.app` under `context` policy.
    ///
    /// Order is fixed:
    /// 1. resolve via `context.appResolver`
    /// 2. mutation policy gate (throws `policy_denied` before any launch/recovery)
    /// 3. already-running + visible → optional activate only (`launched=false`, `recovered=false`)
    /// 4. already-running + no visible window → recovery ladder (unhide → activate → reopen → AX raise)
    /// 5. not running → `openApplication` only (never from ordinary resolution)
    ///
    /// Polling is deadline-bounded (`waitForWindowMs`) and uses the injected clock —
    /// never a single fixed blind sleep.
    public static func launch(
        _ request: LaunchAppRequest,
        context: ServiceContext,
        controller: AppLaunchControlling = SystemAppLaunchController(),
        windows: any AppLaunchWindowObserving = CGAppLaunchWindowObserver(),
        clock: any AppLaunchClock = SystemAppLaunchClock(),
        pollInterval: TimeInterval = defaultPollInterval
    ) async throws -> LaunchAppResult {
        try CancellationToken.checkpoint()

        let initial = try resolve(request.app, context: context)
        try enforcePolicy(record: initial, context: context, app: request.app)

        let deadline = clock.now() + max(0, Double(request.waitForWindowMs)) / 1000.0

        if initial.isRunning, let pid = initial.pid {
            let visible = windows.visibleWindowCount(forPID: pid)
            if visible > 0 {
                if request.activate {
                    _ = context.workspace.activate(pid: pid)
                }
                let summary = try currentSummary(
                    app: request.app,
                    context: context,
                    windows: windows,
                    preferredPID: pid
                )
                return LaunchAppResult(app: summary, launched: false, recovered: false)
            }

            // Running but no visible window: bounded recovery ladder.
            // Each step is followed by a short probe (≤ one poll interval, capped by the
            // overall deadline) so later steps still run; the full waitForWindowMs budget
            // is only spent waiting for a process after a cold launch.
            var recovered = false

            if controller.isHidden(pid: pid) {
                try enforcePolicy(record: initial, context: context, app: request.app)
                if controller.unhide(pid: pid) {
                    recovered = true
                }
                if let summary = try await probeVisibleWindow(
                    app: request.app,
                    context: context,
                    windows: windows,
                    clock: clock,
                    deadline: deadline,
                    pollInterval: pollInterval,
                    preferredPID: pid
                ) {
                    if request.activate {
                        _ = context.workspace.activate(pid: pid)
                    }
                    return LaunchAppResult(app: summary, launched: false, recovered: true)
                }
            }

            if request.activate {
                try enforcePolicy(record: initial, context: context, app: request.app)
                if context.workspace.activate(pid: pid) {
                    recovered = true
                }
                if let summary = try await probeVisibleWindow(
                    app: request.app,
                    context: context,
                    windows: windows,
                    clock: clock,
                    deadline: deadline,
                    pollInterval: pollInterval,
                    preferredPID: pid
                ) {
                    return LaunchAppResult(app: summary, launched: false, recovered: true)
                }
            }

            if let url = controller.applicationURL(bundleId: initial.bundleId, path: initial.path) {
                try enforcePolicy(record: initial, context: context, app: request.app)
                do {
                    _ = try await controller.openApplication(at: url, activate: request.activate)
                    recovered = true
                } catch let error as CUError {
                    throw error
                } catch {
                    throw CUError.internalError(detail: "launch_app reopen failed: \(error.localizedDescription)")
                }
                if let summary = try await probeVisibleWindow(
                    app: request.app,
                    context: context,
                    windows: windows,
                    clock: clock,
                    deadline: deadline,
                    pollInterval: pollInterval,
                    preferredPID: pid
                ) {
                    return LaunchAppResult(app: summary, launched: false, recovered: true)
                }
            }

            try enforcePolicy(record: initial, context: context, app: request.app)
            if context.workspace.raiseViaAccessibility(pid: pid) {
                recovered = true
            }
            // Final recovery step: spend any remaining deadline waiting for a window.
            if let summary = try await waitForVisibleWindow(
                app: request.app,
                context: context,
                windows: windows,
                clock: clock,
                deadline: deadline,
                pollInterval: pollInterval,
                preferredPID: pid
            ) {
                return LaunchAppResult(app: summary, launched: false, recovered: true)
            }

            // Deadline elapsed (or ladder exhausted): return honest running summary.
            let summary = try currentSummary(
                app: request.app,
                context: context,
                windows: windows,
                preferredPID: pid
            )
            return LaunchAppResult(app: summary, launched: false, recovered: recovered)
        }

        // Not running: explicit launch only.
        guard let url = controller.applicationURL(bundleId: initial.bundleId, path: initial.path) else {
            throw CUError.internalError(
                detail: "launch_app could not resolve a launchable URL for \"\(request.app)\""
            )
        }

        // Policy already enforced above; re-check immediately before the workspace open.
        try enforcePolicy(record: initial, context: context, app: request.app)

        let launchedPID: pid_t?
        do {
            launchedPID = try await controller.openApplication(at: url, activate: request.activate)
        } catch let error as CUError {
            throw error
        } catch {
            throw CUError.internalError(detail: "launch_app failed: \(error.localizedDescription)")
        }

        // Wait until the process is resolvable as running (and prefer a visible window).
        if let summary = try await waitForRunningApp(
            app: request.app,
            context: context,
            controller: controller,
            windows: windows,
            clock: clock,
            deadline: deadline,
            pollInterval: pollInterval,
            preferredPID: launchedPID
        ) {
            return LaunchAppResult(app: summary, launched: true, recovered: false)
        }

        throw CUError.timeout(operation: "launch_app", deadlineMs: request.waitForWindowMs)
    }

    // MARK: - Helpers

    static func resolve(_ app: String, context: ServiceContext) throws -> AppRecord {
        switch context.appResolver.resolve(app) {
        case let .success(record):
            return record
        case let .failure(error):
            throw error
        }
    }

    static func enforcePolicy(record: AppRecord, context: ServiceContext, app: String) throws {
        if let reason = context.policyEngine.mutationDenialReason(
            bundleId: record.bundleId,
            displayName: record.displayName,
            path: record.path
        ) {
            throw CUError.policyDenied(reason: reason, app: app, tool: "launch_app")
        }
    }

    /// Re-resolve and project an up-to-date `AppSummary` with live window counts.
    static func currentSummary(
        app: String,
        context: ServiceContext,
        windows: any AppLaunchWindowObserving,
        preferredPID: pid_t?
    ) throws -> AppSummary {
        let record = try resolve(app, context: context)
        var summary = record.toSummary()
        if let pid = record.pid ?? preferredPID {
            summary.pid = Int(pid)
            summary.isRunning = true
            summary.windows = windows.visibleWindowCount(forPID: pid)
        } else {
            summary.windows = 0
        }
        return summary
    }

    /// One immediate window check, plus at most a single poll-interval sleep if the
    /// overall deadline still has room. Used between recovery-ladder steps so later
    /// steps are not starved by an earlier full-deadline wait.
    static func probeVisibleWindow(
        app: String,
        context: ServiceContext,
        windows: any AppLaunchWindowObserving,
        clock: any AppLaunchClock,
        deadline: TimeInterval,
        pollInterval: TimeInterval,
        preferredPID: pid_t?
    ) async throws -> AppSummary? {
        try CancellationToken.checkpoint()
        let summary = try currentSummary(
            app: app,
            context: context,
            windows: windows,
            preferredPID: preferredPID
        )
        if let pid = summary.pid.map(Int32.init), windows.visibleWindowCount(forPID: pid) > 0 {
            var visible = summary
            visible.windows = windows.visibleWindowCount(forPID: pid)
            return visible
        }
        if clock.now() >= deadline {
            return nil
        }
        let remaining = deadline - clock.now()
        await clock.sleep(min(pollInterval, max(0, remaining)))
        try CancellationToken.checkpoint()
        let again = try currentSummary(
            app: app,
            context: context,
            windows: windows,
            preferredPID: preferredPID
        )
        if let pid = again.pid.map(Int32.init), windows.visibleWindowCount(forPID: pid) > 0 {
            var visible = again
            visible.windows = windows.visibleWindowCount(forPID: pid)
            return visible
        }
        return nil
    }

    /// Poll until a visible window exists for the (re-resolved) app, or the deadline elapses.
    static func waitForVisibleWindow(
        app: String,
        context: ServiceContext,
        windows: any AppLaunchWindowObserving,
        clock: any AppLaunchClock,
        deadline: TimeInterval,
        pollInterval: TimeInterval,
        preferredPID: pid_t?
    ) async throws -> AppSummary? {
        while true {
            try CancellationToken.checkpoint()
            let summary = try currentSummary(
                app: app,
                context: context,
                windows: windows,
                preferredPID: preferredPID
            )
            if let pid = summary.pid.map(Int32.init), windows.visibleWindowCount(forPID: pid) > 0 {
                var visible = summary
                visible.windows = windows.visibleWindowCount(forPID: pid)
                return visible
            }
            if clock.now() >= deadline {
                return nil
            }
            let remaining = deadline - clock.now()
            await clock.sleep(min(pollInterval, max(0, remaining)))
            if clock.now() >= deadline {
                // Final check after the last slice of the budget.
                let finalSummary = try currentSummary(
                    app: app,
                    context: context,
                    windows: windows,
                    preferredPID: preferredPID
                )
                if let pid = finalSummary.pid.map(Int32.init), windows.visibleWindowCount(forPID: pid) > 0 {
                    var visible = finalSummary
                    visible.windows = windows.visibleWindowCount(forPID: pid)
                    return visible
                }
                return nil
            }
        }
    }

    /// Poll until the app resolves as running (optionally with a window), or the deadline elapses.
    static func waitForRunningApp(
        app: String,
        context: ServiceContext,
        controller: AppLaunchControlling,
        windows: any AppLaunchWindowObserving,
        clock: any AppLaunchClock,
        deadline: TimeInterval,
        pollInterval: TimeInterval,
        preferredPID: pid_t?
    ) async throws -> AppSummary? {
        while true {
            try CancellationToken.checkpoint()
            if let preferredPID, controller.isProcessRunning(pid: preferredPID) {
                let summary = try currentSummary(
                    app: app,
                    context: context,
                    windows: windows,
                    preferredPID: preferredPID
                )
                if summary.isRunning {
                    // Prefer returning once a window is visible, but a running process is enough
                    // to honor `launched` if the deadline is about to expire.
                    if windows.visibleWindowCount(forPID: preferredPID) > 0 || clock.now() >= deadline {
                        return summary
                    }
                }
            } else {
                let record = try resolve(app, context: context)
                if record.isRunning, let pid = record.pid {
                    let summary = try currentSummary(
                        app: app,
                        context: context,
                        windows: windows,
                        preferredPID: pid
                    )
                    if windows.visibleWindowCount(forPID: pid) > 0 || clock.now() >= deadline {
                        return summary
                    }
                }
            }

            if clock.now() >= deadline {
                // Last-chance: if the process is running, return it; else nil → timeout.
                if let preferredPID, controller.isProcessRunning(pid: preferredPID) {
                    return try currentSummary(
                        app: app,
                        context: context,
                        windows: windows,
                        preferredPID: preferredPID
                    )
                }
                let record = try? resolve(app, context: context)
                if let record, record.isRunning {
                    return try currentSummary(
                        app: app,
                        context: context,
                        windows: windows,
                        preferredPID: record.pid
                    )
                }
                return nil
            }

            let remaining = deadline - clock.now()
            await clock.sleep(min(pollInterval, max(0, remaining)))
        }
    }
}
