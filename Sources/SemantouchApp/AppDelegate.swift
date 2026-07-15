import AppKit
import Foundation
import ComputerUseCore
import ComputerUseService
import MCPServer

/// Accessory-app delegate for the resident `SemantouchHost` process.
///
/// Owns `HostController` and the onboarding/status window. Starts the host on
/// every launch; constructs UI only when the user explicitly launched the app
/// or a required grant is missing. Never activates merely because MCP connected.
///
/// ## HostController integration assumptions
/// Sibling-owned `HostController` (same target) exposes:
/// - `init(showOnboarding: @escaping @Sendable () -> Void = {})`
/// - `start() throws`
/// - `stop()` (idempotent)
/// - `activeSessionCount: Int`
/// - `isRunning: Bool` (optional for this UI surface)
///
/// AppDelegate:
/// 1. Lazy-inits with a main-async onboarding callback; HostController never builds UI.
/// 2. Calls `start()` once in `applicationDidFinishLaunching`.
/// 3. Calls `stop()` from `applicationWillTerminate`.
/// 4. Reads `activeSessionCount` for quit confirmation and status labels.
/// 5. Host may invoke `showOnboarding` for control-plane requests; activation is
///    decided here, not by MCP connect alone.
/// 6. Headless/background host still serves without constructing a window until
///    the callback runs or this delegate shows UI for missing grants / explicit launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Passive recheck interval while the status window is visible.
    static let recheckInterval: TimeInterval = 3.0

    private lazy var hostController: HostController = {
        HostController(showOnboarding: { [weak self] in
            DispatchQueue.main.async {
                self?.showOnboarding(activate: true)
            }
        })
    }()

    private var onboardingWindowController: OnboardingWindowController?
    private var presentationModel = PermissionPresentationModel()
    private var recheckTimer: Timer?
    private var isTerminating = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            try hostController.start()
        } catch {
            // Host failed to bind/start — still offer the status window so the
            // operator can see permissions/signing and quit cleanly.
            fputs("semantouch-host: failed to start: \(error)\n", stderr)
        }

        refreshPresentation(requestOnboarding: false)

        if HostLaunchIntent.shouldShowOnboarding(
            isExplicitLaunch: HostLaunchIntent.isExplicitUserLaunch(
                arguments: CommandLine.arguments,
                environment: ProcessInfo.processInfo.environment
            ),
            model: presentationModel
        ) {
            showOnboarding(activate: true)
        }
        // Background MCP with grants: no window, no activation.
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        stopRecheckTimer()
        hostController.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showOnboarding(activate: true)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Recheck grants after the user returns from System Settings.
        refreshPresentation(requestOnboarding: false)
        onboardingWindowController?.apply(presentationModel)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating {
            return .terminateNow
        }

        let count = hostController.activeSessionCount
        presentationModel.applyActiveSessionCount(count)

        guard presentationModel.hasActiveSessions else {
            return .terminateNow
        }

        // Confirm quit when automation sessions are still live.
        let alert = NSAlert()
        alert.messageText = "Quit Semantouch?"
        alert.informativeText = presentationModel.quitWarningMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: - Onboarding presentation

    func showOnboarding(activate: Bool = true) {
        let controller = ensureOnboardingWindow()
        refreshPresentation(requestOnboarding: false)
        controller.apply(presentationModel)
        controller.showWindow(activate: activate)
        startRecheckTimer()
    }

    private func ensureOnboardingWindow() -> OnboardingWindowController {
        if let onboardingWindowController {
            return onboardingWindowController
        }

        let controller = OnboardingWindowController(model: presentationModel)
        controller.onRecheck = { [weak self] in
            self?.handleRecheck()
        }
        controller.onRequestPermissions = { [weak self] in
            self?.handleRequestPermissions()
        }
        controller.onOpenPrivacySettings = { [weak self] in
            self?.handleOpenPrivacySettings()
        }
        controller.onCheckForUpdates = { [weak self] in
            self?.handleCheckForUpdates()
        }
        controller.onReopen = { [weak self] in
            self?.handleReopen()
        }
        controller.onQuit = { [weak self] in
            self?.handleQuit()
        }
        onboardingWindowController = controller
        return controller
    }

    // MARK: - Passive / explicit doctor refresh

    /// Passive checks use `requestOnboarding: false` (no OS dialog).
    /// Explicit Request Permissions uses `true` once.
    func refreshPresentation(requestOnboarding: Bool) {
        let doctor = DoctorService.run(requestOnboarding: requestOnboarding)
        presentationModel.applyPassiveDoctor(doctor)
        presentationModel.applyActiveSessionCount(hostController.activeSessionCount)
    }

    private func handleRecheck() {
        refreshPresentation(requestOnboarding: false)
        onboardingWindowController?.apply(presentationModel)
    }

    private func handleRequestPermissions() {
        // Only the explicit button path may prompt.
        refreshPresentation(requestOnboarding: true)
        onboardingWindowController?.apply(presentationModel)
    }

    private func handleOpenPrivacySettings() {
        Self.openPrivacySettings()
    }

    private func handleCheckForUpdates() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let version = presentationModel.helperVersion.isEmpty
                ? MCPServer.serverVersion
                : presentationModel.helperVersion
            let check = await UpdateService().check(currentVersion: version)
            presentationModel.applyUpdate(check)
            onboardingWindowController?.apply(presentationModel)
        }
    }

    private func handleReopen() {
        showOnboarding(activate: true)
    }

    private func handleQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Bounded passive timer

    private func startRecheckTimer() {
        stopRecheckTimer()
        let timer = Timer(timeInterval: Self.recheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Timer path is always passive — never prompt in the background.
                self.refreshPresentation(requestOnboarding: false)
                self.onboardingWindowController?.apply(self.presentationModel)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recheckTimer = timer
    }

    private func stopRecheckTimer() {
        recheckTimer?.invalidate()
        recheckTimer = nil
    }

    // MARK: - Privacy Settings

    static func openPrivacySettings() {
        // Prefer modern System Settings deep links; fall back to the Privacy root.
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
