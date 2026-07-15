import Foundation
import XCTest
import ComputerUseCore
@testable import ActionEngine
@testable import ComputerUseService

/// Permission-free lifecycle contract tests for `AppLister` + `AppLauncher`.
///
/// Every path injects environment / metadata / window / launch / clock seams so
/// no live `NSWorkspace.openApplication`, Spotlight query, or Accessibility grant
/// is required. Live-only behavior is documented at the bottom of this file.
final class AppLifecycleTests: XCTestCase {
    // MARK: - AppLister: recency sort + fallbacks

    func testListAppsSortsRunningFirstThenRecencyThenUseCountThenName() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_500)

        let environment = MutableAppEnvironment(records: [
            AppRecord(bundleId: "com.example.zeta", displayName: "Zeta", path: "/Apps/Zeta.app", pid: nil, isRunning: false, windows: 0),
            AppRecord(bundleId: "com.example.alpha", displayName: "Alpha", path: "/Apps/Alpha.app", pid: 11, isRunning: true, windows: 0),
            AppRecord(bundleId: "com.example.beta", displayName: "Beta", path: "/Apps/Beta.app", pid: 12, isRunning: true, windows: 0),
            AppRecord(bundleId: "com.example.gamma", displayName: "Gamma", path: "/Apps/Gamma.app", pid: nil, isRunning: false, windows: 0),
            AppRecord(bundleId: "com.example.delta", displayName: "Delta", path: "/Apps/Delta.app", pid: nil, isRunning: false, windows: 0),
        ])
        let metadata = FakeMetadata(values: [
            "/Apps/Alpha.app": .init(lastUsedAt: older, useCount: 2),
            "/Apps/Beta.app": .init(lastUsedAt: newer, useCount: 1),
            "/Apps/Gamma.app": .init(lastUsedAt: newer, useCount: 9),
            "/Apps/Delta.app": .init(lastUsedAt: newer, useCount: 3),
            // Zeta: no metadata → falls back after dated apps, by name among unknowns.
        ])
        let windows = FakeWindowCounter(counts: [11: 1, 12: 2])

        let apps = AppLister.listApps(environment: environment, metadata: metadata, windows: windows)

        XCTAssertEqual(apps.map(\.id), [
            "com.example.beta",   // running, newer lastUsed
            "com.example.alpha",  // running, older lastUsed
            "com.example.gamma",  // not running, same lastUsed, higher useCount
            "com.example.delta",  // not running, same lastUsed, lower useCount
            "com.example.zeta",   // not running, no metadata, name fallback
        ])
        XCTAssertEqual(apps[0].windows, 2)
        XCTAssertEqual(apps[1].windows, 1)
        XCTAssertEqual(apps[0].useCount, 1)
        XCTAssertEqual(apps[2].useCount, 9)
        XCTAssertNil(apps[4].lastUsedAt)
        XCTAssertNil(apps[4].useCount)
        XCTAssertEqual(apps[0].lastUsedAt, AppLister.iso8601String(from: newer))
    }

    func testListAppsFallsBackToNameWhenMetadataMissing() {
        let environment = MutableAppEnvironment(records: [
            AppRecord(bundleId: "com.example.b", displayName: "Bravo", path: "/Apps/Bravo.app", pid: nil, isRunning: false, windows: 0),
            AppRecord(bundleId: "com.example.a", displayName: "Alpha", path: "/Apps/Alpha.app", pid: nil, isRunning: false, windows: 0),
        ])
        let apps = AppLister.listApps(
            environment: environment,
            metadata: FakeMetadata(values: [:]),
            windows: FakeWindowCounter()
        )
        XCTAssertEqual(apps.map(\.displayName), ["Alpha", "Bravo"])
        XCTAssertTrue(apps.allSatisfy { $0.lastUsedAt == nil && $0.useCount == nil })
    }

    func testListAppsNeverLaunches() {
        let environment = MutableAppEnvironment(records: [
            AppRecord(bundleId: "com.example.app", displayName: "App", path: "/Apps/App.app", pid: nil, isRunning: false, windows: 0),
        ])
        let controller = FakeLaunchController()
        _ = AppLister.listApps(
            environment: environment,
            metadata: FakeMetadata(values: [:]),
            windows: FakeWindowCounter()
        )
        XCTAssertEqual(controller.openCalls.count, 0)
        XCTAssertEqual(controller.unhideCalls.count, 0)
    }

    // MARK: - AppLauncher: not-running launch

    func testLaunchStartsNotRunningApp() async throws {
        let environment = MutableAppEnvironment(records: [
            AppRecord(
                bundleId: "com.example.editor",
                displayName: "Editor",
                path: "/Apps/Editor.app",
                pid: nil,
                isRunning: false,
                windows: 0
            ),
        ])
        let controller = FakeLaunchController()
        controller.openHandler = { url, activate in
            XCTAssertEqual(url.path, "/Apps/Editor.app")
            XCTAssertTrue(activate)
            environment.markRunning(bundleId: "com.example.editor", pid: 4242)
            controller.runningPIDs.insert(4242)
            return 4242
        }
        let windows = FakeWindowCounter(counts: [4242: 1])
        let clock = FakeClock()
        let context = makeContext(environment: environment)

        let result = try await AppLauncher.launch(
            LaunchAppRequest(app: "com.example.editor"),
            context: context,
            controller: controller,
            windows: windows,
            clock: clock
        )

        XCTAssertTrue(result.launched)
        XCTAssertFalse(result.recovered)
        XCTAssertEqual(result.app.id, "com.example.editor")
        XCTAssertEqual(result.app.pid, 4242)
        XCTAssertTrue(result.app.isRunning)
        XCTAssertEqual(result.app.windows, 1)
        XCTAssertEqual(controller.openCalls.count, 1)
        XCTAssertEqual(controller.unhideCalls.count, 0)
    }

    // MARK: - Already running, visible → no-op

    func testAlreadyRunningVisibleIsNoOp() async throws {
        let environment = MutableAppEnvironment(records: [
            AppRecord(
                bundleId: "com.example.running",
                displayName: "Running",
                path: "/Apps/Running.app",
                pid: 100,
                isRunning: true,
                windows: 1
            ),
        ])
        let controller = FakeLaunchController()
        controller.runningPIDs.insert(100)
        let windows = FakeWindowCounter(counts: [100: 2])
        let workspace = RecordingWorkspace(frontmostPID: 50, frontmostAppName: "Other")
        let context = makeContext(environment: environment, workspace: workspace)

        let result = try await AppLauncher.launch(
            LaunchAppRequest(app: "com.example.running", activate: true),
            context: context,
            controller: controller,
            windows: windows,
            clock: FakeClock()
        )

        XCTAssertFalse(result.launched)
        XCTAssertFalse(result.recovered)
        XCTAssertEqual(result.app.pid, 100)
        XCTAssertEqual(result.app.windows, 2)
        XCTAssertEqual(controller.openCalls.count, 0)
        XCTAssertEqual(controller.unhideCalls.count, 0)
        XCTAssertEqual(workspace.activateCalls, [100])
        XCTAssertEqual(workspace.raiseCalls.count, 0)
    }

    // MARK: - Hidden → unhide recovery

    func testHiddenAppUnhideRecovery() async throws {
        let environment = MutableAppEnvironment(records: [
            AppRecord(
                bundleId: "com.example.hidden",
                displayName: "Hidden",
                path: "/Apps/Hidden.app",
                pid: 200,
                isRunning: true,
                windows: 0
            ),
        ])
        let controller = FakeLaunchController()
        controller.runningPIDs.insert(200)
        controller.hiddenPIDs.insert(200)
        controller.unhideHandler = { pid in
            controller.hiddenPIDs.remove(pid)
            return true
        }
        let windows = FakeWindowCounter(counts: [:])
        // After unhide, the next window poll sees a visible window.
        windows.onCount = { pid in
            controller.hiddenPIDs.contains(pid) ? 0 : 1
        }
        let workspace = RecordingWorkspace(frontmostPID: 1, frontmostAppName: "Other")
        let context = makeContext(environment: environment, workspace: workspace)

        let result = try await AppLauncher.launch(
            LaunchAppRequest(app: "com.example.hidden", activate: true),
            context: context,
            controller: controller,
            windows: windows,
            clock: FakeClock()
        )

        XCTAssertFalse(result.launched)
        XCTAssertTrue(result.recovered)
        XCTAssertEqual(controller.unhideCalls, [200])
        XCTAssertEqual(controller.openCalls.count, 0)
        XCTAssertEqual(result.app.windows, 1)
    }

    // MARK: - Minimized → AX raise recovery

    func testMinimizedAppAXRaiseRecovery() async throws {
        let environment = MutableAppEnvironment(records: [
            AppRecord(
                bundleId: "com.example.min",
                displayName: "Min",
                path: "/Apps/Min.app",
                pid: 300,
                isRunning: true,
                windows: 0
            ),
        ])
        let controller = FakeLaunchController()
        controller.runningPIDs.insert(300)
        // Not hidden — minimized (no visible CG window) skips unhide success path.
        let windows = FakeWindowCounter(counts: [300: 0])
        let workspace = RecordingWorkspace(frontmostPID: 1, frontmostAppName: "Other")
        workspace.raiseHandler = { pid in
            windows.counts[pid] = 1
            return true
        }
        // activate alone does not restore a window in this fixture.
        workspace.activateHandler = { _ in true }
        let context = makeContext(environment: environment, workspace: workspace)

        let result = try await AppLauncher.launch(
            LaunchAppRequest(app: "com.example.min", activate: true, waitForWindowMs: 200),
            context: context,
            controller: controller,
            windows: windows,
            clock: FakeClock(autoAdvanceOnSleep: true),
            pollInterval: 0.05
        )

        XCTAssertFalse(result.launched)
        XCTAssertTrue(result.recovered)
        XCTAssertEqual(workspace.raiseCalls, [300])
        XCTAssertEqual(result.app.windows, 1)
        // Activate was attempted before AX raise in the ladder.
        XCTAssertFalse(workspace.activateCalls.isEmpty)
    }

    // MARK: - Reopen recovery

    func testReopenBundleURLRecovery() async throws {
        let environment = MutableAppEnvironment(records: [
            AppRecord(
                bundleId: "com.example.reopen",
                displayName: "Reopen",
                path: "/Apps/Reopen.app",
                pid: 400,
                isRunning: true,
                windows: 0
            ),
        ])
        let controller = FakeLaunchController()
        controller.runningPIDs.insert(400)
        let windows = FakeWindowCounter(counts: [400: 0])
        controller.openHandler = { url, _ in
            XCTAssertEqual(url.path, "/Apps/Reopen.app")
            windows.counts[400] = 1
            return 400
        }
        // Activate does not produce a window; reopen does.
        let workspace = RecordingWorkspace(frontmostPID: 1, frontmostAppName: "Other")
        let context = makeContext(environment: environment, workspace: workspace)

        let result = try await AppLauncher.launch(
            LaunchAppRequest(app: "com.example.reopen", activate: true, waitForWindowMs: 200),
            context: context,
            controller: controller,
            windows: windows,
            clock: FakeClock(autoAdvanceOnSleep: true),
            pollInterval: 0.05
        )

        XCTAssertFalse(result.launched)
        XCTAssertTrue(result.recovered)
        XCTAssertEqual(controller.openCalls.count, 1)
        XCTAssertEqual(result.app.windows, 1)
    }

    // MARK: - Deadline

    func testLaunchDeadlineTimesOutWhenProcessNeverAppears() async {
        let environment = MutableAppEnvironment(records: [
            AppRecord(
                bundleId: "com.example.slow",
                displayName: "Slow",
                path: "/Apps/Slow.app",
                pid: nil,
                isRunning: false,
                windows: 0
            ),
        ])
        let controller = FakeLaunchController()
        // open "succeeds" but the process never becomes running / never updates the environment.
        controller.openHandler = { _, _ in 999 }
        // isProcessRunning stays false (999 not in runningPIDs).
        let clock = FakeClock(autoAdvanceOnSleep: true)
        let context = makeContext(environment: environment)

        do {
            _ = try await AppLauncher.launch(
                LaunchAppRequest(app: "com.example.slow", waitForWindowMs: 100),
                context: context,
                controller: controller,
                windows: FakeWindowCounter(),
                clock: clock,
                pollInterval: 0.05
            )
            XCTFail("expected timeout")
        } catch let error as CUError {
            guard case let .timeout(operation, deadlineMs) = error else {
                return XCTFail("expected timeout, got \(error)")
            }
            XCTAssertEqual(operation, "launch_app")
            XCTAssertEqual(deadlineMs, 100)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertFalse(clock.sleepCalls.isEmpty, "deadline path must poll via clock.sleep, not a blind fixed sleep")
        XCTAssertEqual(controller.openCalls.count, 1)
    }

    // MARK: - Launch failure

    func testLaunchFailureSurfacesInternalError() async {
        let environment = MutableAppEnvironment(records: [
            AppRecord(
                bundleId: "com.example.broken",
                displayName: "Broken",
                path: "/Apps/Broken.app",
                pid: nil,
                isRunning: false,
                windows: 0
            ),
        ])
        let controller = FakeLaunchController()
        controller.openHandler = { _, _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        }
        let context = makeContext(environment: environment)

        do {
            _ = try await AppLauncher.launch(
                LaunchAppRequest(app: "com.example.broken"),
                context: context,
                controller: controller,
                windows: FakeWindowCounter(),
                clock: FakeClock()
            )
            XCTFail("expected failure")
        } catch let error as CUError {
            guard case let .internalError(detail) = error else {
                return XCTFail("expected internal_error, got \(error)")
            }
            XCTAssertTrue(detail?.contains("launch_app failed") == true, detail ?? "nil")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Policy before workspace

    func testPolicyDeniedBeforeAnyWorkspaceCall() async {
        let environment = MutableAppEnvironment(records: [
            AppRecord(
                bundleId: "com.1password.1password",
                displayName: "1Password",
                path: "/Applications/1Password.app",
                pid: nil,
                isRunning: false,
                windows: 0
            ),
        ])
        let controller = FakeLaunchController()
        controller.openHandler = { _, _ in
            XCTFail("openApplication must not run for a denied app")
            return nil
        }
        let workspace = RecordingWorkspace(frontmostPID: nil, frontmostAppName: nil)
        let context = ServiceContext(
            policyEngine: PolicyEngine(appDenylist: ["com.1password.1password"]),
            appResolver: AppResolver(environment: environment),
            workspace: workspace
        )

        do {
            _ = try await AppLauncher.launch(
                LaunchAppRequest(app: "com.1password.1password"),
                context: context,
                controller: controller,
                windows: FakeWindowCounter(),
                clock: FakeClock()
            )
            XCTFail("expected policy_denied")
        } catch let error as CUError {
            guard case let .policyDenied(reason, app, tool) = error else {
                return XCTFail("expected policy_denied, got \(error)")
            }
            XCTAssertEqual(reason, .appDenied)
            XCTAssertEqual(app, "com.1password.1password")
            XCTAssertEqual(tool, "launch_app")
        } catch {
            XCTFail("unexpected error \(error)")
        }

        XCTAssertEqual(controller.openCalls.count, 0)
        XCTAssertEqual(controller.unhideCalls.count, 0)
        XCTAssertEqual(workspace.activateCalls.count, 0)
        XCTAssertEqual(workspace.raiseCalls.count, 0)
    }

    func testPolicyDeniedForRunningAppBeforeRecovery() async {
        let environment = MutableAppEnvironment(records: [
            AppRecord(
                bundleId: "com.example.private",
                displayName: "Private",
                path: "/Apps/Private.app",
                pid: 777,
                isRunning: true,
                windows: 0
            ),
        ])
        let controller = FakeLaunchController()
        controller.runningPIDs.insert(777)
        controller.hiddenPIDs.insert(777)
        let workspace = RecordingWorkspace(frontmostPID: 1, frontmostAppName: "Other")
        let context = ServiceContext(
            policyEngine: PolicyEngine(appDenylist: ["private"]),
            appResolver: AppResolver(environment: environment),
            workspace: workspace
        )

        do {
            _ = try await AppLauncher.launch(
                LaunchAppRequest(app: "com.example.private"),
                context: context,
                controller: controller,
                windows: FakeWindowCounter(counts: [777: 0]),
                clock: FakeClock()
            )
            XCTFail("expected policy_denied")
        } catch let error as CUError {
            guard case .policyDenied = error else {
                return XCTFail("expected policy_denied, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }

        XCTAssertEqual(controller.unhideCalls.count, 0)
        XCTAssertEqual(controller.openCalls.count, 0)
        XCTAssertEqual(workspace.activateCalls.count, 0)
        XCTAssertEqual(workspace.raiseCalls.count, 0)
    }

    // MARK: - Exact launched / recovered flags

    func testLaunchedAndRecoveredFlagsAreMutuallyHonest() async throws {
        // 1) cold launch → launched=true, recovered=false
        let coldEnv = MutableAppEnvironment(records: [
            AppRecord(bundleId: "com.example.cold", displayName: "Cold", path: "/Apps/Cold.app", pid: nil, isRunning: false, windows: 0),
        ])
        let coldController = FakeLaunchController()
        coldController.openHandler = { _, _ in
            coldEnv.markRunning(bundleId: "com.example.cold", pid: 1)
            coldController.runningPIDs.insert(1)
            return 1
        }
        let cold = try await AppLauncher.launch(
            LaunchAppRequest(app: "com.example.cold"),
            context: makeContext(environment: coldEnv),
            controller: coldController,
            windows: FakeWindowCounter(counts: [1: 1]),
            clock: FakeClock()
        )
        XCTAssertTrue(cold.launched)
        XCTAssertFalse(cold.recovered)

        // 2) visible running → both false
        let hotEnv = MutableAppEnvironment(records: [
            AppRecord(bundleId: "com.example.hot", displayName: "Hot", path: "/Apps/Hot.app", pid: 2, isRunning: true, windows: 1),
        ])
        let hotController = FakeLaunchController()
        hotController.runningPIDs.insert(2)
        let hot = try await AppLauncher.launch(
            LaunchAppRequest(app: "com.example.hot", activate: false),
            context: makeContext(environment: hotEnv),
            controller: hotController,
            windows: FakeWindowCounter(counts: [2: 1]),
            clock: FakeClock()
        )
        XCTAssertFalse(hot.launched)
        XCTAssertFalse(hot.recovered)
        XCTAssertEqual(hotController.openCalls.count, 0)

        // 3) recovery → launched=false, recovered=true
        let hidEnv = MutableAppEnvironment(records: [
            AppRecord(bundleId: "com.example.hid", displayName: "Hid", path: "/Apps/Hid.app", pid: 3, isRunning: true, windows: 0),
        ])
        let hidController = FakeLaunchController()
        hidController.runningPIDs.insert(3)
        hidController.hiddenPIDs.insert(3)
        let hidWindows = FakeWindowCounter()
        hidController.unhideHandler = { pid in
            hidController.hiddenPIDs.remove(pid)
            hidWindows.counts[pid] = 1
            return true
        }
        let recovered = try await AppLauncher.launch(
            LaunchAppRequest(app: "com.example.hid"),
            context: makeContext(environment: hidEnv),
            controller: hidController,
            windows: hidWindows,
            clock: FakeClock()
        )
        XCTAssertFalse(recovered.launched)
        XCTAssertTrue(recovered.recovered)
    }

    // MARK: - Helpers / fakes

    private func makeContext(
        environment: AppEnvironment,
        workspace: WorkspaceControlling = RecordingWorkspace(frontmostPID: nil, frontmostAppName: nil),
        denied: Set<String> = []
    ) -> ServiceContext {
        ServiceContext(
            policyEngine: PolicyEngine(appDenylist: denied),
            appResolver: AppResolver(environment: environment),
            workspace: workspace
        )
    }

    final class MutableAppEnvironment: AppEnvironment {
        private let lock = NSLock()
        private var _records: [AppRecord]

        init(records: [AppRecord]) {
            self._records = records
        }

        var records: [AppRecord] {
            lock.lock(); defer { lock.unlock() }
            return _records
        }

        func allApps() -> [AppRecord] { records }

        func app(forPID pid: Int32) -> AppRecord? {
            records.first { $0.pid == pid }
        }

        func pathExists(_ path: String) -> Bool {
            records.contains { $0.path == path } || FileManager.default.fileExists(atPath: path)
        }

        func markRunning(bundleId: String, pid: Int32) {
            lock.lock(); defer { lock.unlock() }
            if let idx = _records.firstIndex(where: { $0.bundleId == bundleId }) {
                _records[idx].pid = pid
                _records[idx].isRunning = true
            }
        }
    }

    struct FakeMetadata: AppMetadataProviding {
        let values: [String: AppPathMetadata]
        func metadata(forPath path: String) -> AppPathMetadata {
            values[path] ?? AppPathMetadata()
        }
    }

    final class FakeWindowCounter: AppWindowCounting, AppLaunchWindowObserving, @unchecked Sendable {
        var counts: [Int32: Int]
        var onCount: ((Int32) -> Int)?

        init(counts: [Int32: Int] = [:]) {
            self.counts = counts
        }

        func visibleWindowCount(forPID pid: Int32) -> Int {
            if let onCount { return onCount(pid) }
            return counts[pid] ?? 0
        }
    }

    final class FakeLaunchController: AppLaunchControlling {
        struct OpenCall {
            let url: URL
            let activate: Bool
        }

        private(set) var openCalls: [OpenCall] = []
        private(set) var unhideCalls: [pid_t] = []
        var runningPIDs: Set<pid_t> = []
        var hiddenPIDs: Set<pid_t> = []
        var openHandler: ((URL, Bool) async throws -> pid_t?)?
        var unhideHandler: ((pid_t) -> Bool)?

        func applicationURL(bundleId: String?, path: String?) -> URL? {
            if let path, !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            if let bundleId {
                return URL(fileURLWithPath: "/Apps/\(bundleId).app", isDirectory: true)
            }
            return nil
        }

        func openApplication(at url: URL, activate: Bool) async throws -> pid_t? {
            openCalls.append(OpenCall(url: url, activate: activate))
            if let openHandler {
                return try await openHandler(url, activate)
            }
            return nil
        }

        func isHidden(pid: pid_t) -> Bool { hiddenPIDs.contains(pid) }

        func unhide(pid: pid_t) -> Bool {
            unhideCalls.append(pid)
            if let unhideHandler { return unhideHandler(pid) }
            hiddenPIDs.remove(pid)
            return true
        }

        func isProcessRunning(pid: pid_t) -> Bool { runningPIDs.contains(pid) }
    }

    final class FakeClock: AppLaunchClock, @unchecked Sendable {
        private let lock = NSLock()
        private var _now: TimeInterval
        private(set) var sleepCalls: [TimeInterval] = []
        var autoAdvanceOnSleep: Bool

        init(now: TimeInterval = 0, autoAdvanceOnSleep: Bool = true) {
            self._now = now
            self.autoAdvanceOnSleep = autoAdvanceOnSleep
        }

        func now() -> TimeInterval {
            lock.withLock { _now }
        }

        func sleep(_ seconds: TimeInterval) async {
            // Mutate under withLock only; never hold the lock across a suspension.
            lock.withLock {
                sleepCalls.append(seconds)
                if autoAdvanceOnSleep {
                    _now += seconds
                }
            }
        }

        func advance(_ seconds: TimeInterval) {
            lock.withLock { _now += seconds }
        }
    }

    final class RecordingWorkspace: WorkspaceControlling {
        var frontmostPID: pid_t?
        var frontmostAppName: String?
        private(set) var activateCalls: [pid_t] = []
        private(set) var raiseCalls: [pid_t] = []
        var activateHandler: ((pid_t) -> Bool)?
        var raiseHandler: ((pid_t) -> Bool)?

        init(frontmostPID: pid_t?, frontmostAppName: String?) {
            self.frontmostPID = frontmostPID
            self.frontmostAppName = frontmostAppName
        }

        func activate(pid: pid_t) -> Bool {
            activateCalls.append(pid)
            if let activateHandler { return activateHandler(pid) }
            frontmostPID = pid
            return true
        }

        func raiseViaAccessibility(pid: pid_t) -> Bool {
            raiseCalls.append(pid)
            if let raiseHandler { return raiseHandler(pid) }
            frontmostPID = pid
            return true
        }

        func recordFocusedElement() -> FocusedElementToken? { nil }
        func restoreFocusedElement(_ token: FocusedElementToken) -> Bool { true }
    }
}

// MARK: - Live-only behavior (not exercised here)
//
// Seams and their live defaults:
// - AppMetadataProviding → SpotlightAppMetadata (MDItemCreate + kMDItemLastUsedDate / kMDItemUseCount)
// - AppWindowCounting / AppLaunchWindowObserving → CGAppWindowCounter / CGAppLaunchWindowObserver
//   (CGWindowListCopyWindowInfo, on-screen normal windows only)
// - AppLister environment → SystemAppEnvironment (NSWorkspace running apps + Application dirs)
// - AppLaunchControlling → SystemAppLaunchController
//   (NSWorkspace.openApplication, urlForApplication(withBundleIdentifier:),
//    NSRunningApplication.isHidden / unhide / isTerminated)
// - AppLaunchClock → SystemAppLaunchClock (ProcessInfo.systemUptime + Task.sleep)
// - ServiceContext.workspace → SystemWorkspace (activate + AX raise)
//
// Live-only paths intentionally not covered by these permission-free tests:
// - Real NSWorkspace.openApplication process creation
// - Real Spotlight MDItem attribute presence/absence on disk
// - Real Accessibility raise of minimized windows
// - Real Dock-hide unhide
// - Interaction with the operator-sensitive default denylist contents
//   (PolicyEngine is injected; SensitiveAppDefaults owns that table)
