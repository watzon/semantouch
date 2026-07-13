import Foundation
import ComputerUseCore
#if canImport(AppKit)
import AppKit
#endif
import ApplicationServices

// Focus management (docs/PROTOCOL.md §16). A bounded
// focus transaction records the user's frontmost app + focused element, activates the
// target, runs the delivery body, then restores the prior foreground. The policy logic is
// pure and driven over the `WorkspaceControlling` seam, so it is fully unit-tested with a
// fake workspace; the live `SystemWorkspace` (AppKit + Accessibility) is never touched by
// the permission-free tests.

// MARK: - Seam

/// An opaque handle to a recorded focused UI element (system-wide). The live workspace
/// stores an `AXUIElement`; a fake stores whatever it likes. Restoring focus is
/// best-effort.
public final class FocusedElementToken {
    /// Opaque payload (`AXUIElement` in the live path). `Any?` so the seam stays generic.
    public let payload: Any?
    public init(payload: Any? = nil) { self.payload = payload }
}

/// The workspace operations a focus transaction needs. Injected so record/activate/restore
/// bookkeeping is exercised without a live NSWorkspace or Accessibility grant.
public protocol WorkspaceControlling: AnyObject {
    /// The pid of the current frontmost application, or `nil` when none is resolvable.
    var frontmostPID: pid_t? { get }
    /// The display name of the current frontmost application (for `focus_required` data).
    var frontmostAppName: String? { get }
    /// Bring `pid` to the foreground. Returns whether the activation call succeeded.
    func activate(pid: pid_t) -> Bool
    /// Best-effort PUBLIC Accessibility fallback for foregrounding when `activate(pid:)`
    /// did not bring the target frontmost (macOS 14+ finding: `NSRunningApplication.activate`
    /// returns `true` from a background helper but the app never reaches frontmost). Sets the
    /// app element's `kAXFrontmost` and/or raises its main window via the ALREADY-GRANTED
    /// Accessibility permission — NO new TCC permission (no Apple Events / Automation, no
    /// `osascript`). Returns whether the AX call(s) succeeded; the caller **re-verifies**
    /// frontmost afterward (a `true` here does not by itself prove foregrounding).
    func raiseViaAccessibility(pid: pid_t) -> Bool
    /// Record the system-wide focused UI element so it can be restored later.
    func recordFocusedElement() -> FocusedElementToken?
    /// Best-effort restore of a previously recorded focused element. Returns success.
    func restoreFocusedElement(_ token: FocusedElementToken) -> Bool
}

// MARK: - Outcome

/// What a focus transaction did, feeding the Phase 4 `ActionResult` fields (§16).
public struct FocusOutcome: Equatable, Sendable {
    /// Whether the delivery body actually ran (false when a focus-changing mode failed to
    /// bring the target frontmost — we never deliver to the user's app).
    public var delivered: Bool
    /// Whether the foreground app was changed as part of the transaction.
    public var focusChanged: Bool
    /// Whether the user's prior foreground/focus was restored (only for `activateRestore`).
    public var focusRestored: Bool
    /// Whether the target was frontmost during delivery (drives `targetVerified`).
    public var targetBecameFrontmost: Bool
    /// The frontmost pid recorded before the transaction (for diagnostics).
    public var priorFrontmostPID: pid_t?

    public init(
        delivered: Bool,
        focusChanged: Bool,
        focusRestored: Bool,
        targetBecameFrontmost: Bool,
        priorFrontmostPID: pid_t?
    ) {
        self.delivered = delivered
        self.focusChanged = focusChanged
        self.focusRestored = focusRestored
        self.targetBecameFrontmost = targetBecameFrontmost
        self.priorFrontmostPID = priorFrontmostPID
    }
}

// MARK: - Transaction

/// Runs a delivery body under a bounded focus mode (§16).
public struct FocusTransaction {
    public let workspace: WorkspaceControlling
    /// Bounded wait for an ASYNC activation to take effect. `NSRunningApplication.activate()`
    /// (the live `SystemWorkspace.activate`) is asynchronous — the target is NOT frontmost by
    /// the next statement — so reading `frontmostPID` immediately after `activate` sees the
    /// old foreground and the focus-changing modes would wrongly report `rejected` and deliver
    /// nothing. We instead poll `frontmostPID` up to `activationDeadline`, sleeping
    /// `activationPoll` between checks. A synchronous fake flips frontmost immediately, so the
    /// first check succeeds and no sleep occurs (unit tests stay fast and deterministic).
    let activationDeadline: TimeInterval
    let activationPoll: TimeInterval
    let sleep: (TimeInterval) -> Void
    let now: () -> TimeInterval

    public init(
        workspace: WorkspaceControlling,
        activationDeadline: TimeInterval = 0.6,
        activationPoll: TimeInterval = 0.02,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.workspace = workspace
        self.activationDeadline = activationDeadline
        self.activationPoll = activationPoll
        self.sleep = sleep
        self.now = now
    }

    /// Poll `frontmostPID` until it equals `targetPID` or the deadline expires. Returns whether
    /// the target became frontmost. Runs on the fallback lane's background thread (never the
    /// main thread), so a bounded `Thread.sleep` is safe.
    private func waitUntilFrontmost(_ targetPID: pid_t) -> Bool {
        if workspace.frontmostPID == targetPID { return true }
        let deadline = now() + activationDeadline
        while now() < deadline {
            sleep(activationPoll)
            if workspace.frontmostPID == targetPID { return true }
        }
        return workspace.frontmostPID == targetPID
    }

    /// Deliver under `mode`. For `.none` the body runs directly (the caller already
    /// confirmed the target is frontmost) and the target is re-checked afterward. For a
    /// focus-changing mode the target is activated first and the body runs **only** if the
    /// target actually became frontmost — never delivering input to the user's app — then
    /// `.activateRestore` restores the prior foreground/focus.
    public func run(
        targetPID: pid_t,
        mode: FocusMode,
        deliver: () -> Void
    ) -> FocusOutcome {
        switch mode {
        case .none:
            let prior = workspace.frontmostPID
            deliver()
            let stillFrontmost = workspace.frontmostPID == targetPID
            return FocusOutcome(
                delivered: true,
                focusChanged: false,
                focusRestored: false,
                targetBecameFrontmost: stillFrontmost,
                priorFrontmostPID: prior
            )

        case .activateRestore, .activateLeave:
            let prior = workspace.frontmostPID
            let token = mode == .activateRestore ? workspace.recordFocusedElement() : nil
            _ = workspace.activate(pid: targetPID)
            // Wait — bounded — for the asynchronous activation to actually foreground the
            // target before deciding whether to deliver.
            var became = waitUntilFrontmost(targetPID)

            // FIX B (macOS 14+): from a non-frontmost background helper,
            // `NSRunningApplication.activate()` returns `true` yet the target often never
            // reaches frontmost (live macOS-26 finding). If the bounded wait did not see the
            // target foreground, try a best-effort PUBLIC Accessibility raise (kAXFrontmost /
            // raise main window) using the already-granted Accessibility permission — NO new
            // TCC permission, no osascript — then re-verify frontmost. Still bounded; still
            // fails safe: if neither route foregrounds the target, `became` stays false and
            // nothing is delivered (never to the user's app).
            if !became {
                _ = workspace.raiseViaAccessibility(pid: targetPID)
                became = waitUntilFrontmost(targetPID)
            }

            var delivered = false
            if became {
                deliver()
                delivered = true
            }

            var restored = false
            if mode == .activateRestore {
                if let prior, prior != targetPID {
                    // Restore must be as strong as the FORWARD activation (FIX B). A bare
                    // `activate(prior)` from a helper that is itself still non-frontmost is the
                    // exact call FIX B documents as unreliable — it returns `true` yet often
                    // fails to foreground the app — so if the target was foregrounded via the
                    // AX raise, this restore would predictably fail and silently LEAVE THE
                    // TARGET FRONTMOST (allow-brief-focus degrading into a takeover). Mirror the
                    // forward two-stage path: activate, and if the prior is still not frontmost,
                    // fall back to the PUBLIC Accessibility raise, then re-verify.
                    _ = workspace.activate(pid: prior)
                    var priorFrontmost = waitUntilFrontmost(prior)
                    if !priorFrontmost {
                        _ = workspace.raiseViaAccessibility(pid: prior)
                        priorFrontmost = waitUntilFrontmost(prior)
                    }
                    // Derive `focusRestored` from the ACTUAL `frontmost == prior` re-check
                    // (combined with the best-effort focused-element restore), NOT from a
                    // `restoreFocusedElement` that sets `kAXFocused` — that can return
                    // `.success` against a background element and would misreport
                    // `focusRestored = true` while the user's app never regained the
                    // foreground. A best-effort element restore with no recordable token is
                    // treated as satisfied (nothing to restore), so `focusRestored` then
                    // reflects the frontmost re-check alone.
                    let elementRestored = token.map { workspace.restoreFocusedElement($0) } ?? true
                    restored = priorFrontmost && elementRestored
                } else {
                    // No distinct prior foreground to hand back (prior was nil, or the target
                    // was already frontmost so no foreground was ever taken): nothing to restore.
                    restored = false
                }
            }

            return FocusOutcome(
                delivered: delivered,
                focusChanged: true,
                focusRestored: restored,
                targetBecameFrontmost: became,
                priorFrontmostPID: prior
            )
        }
    }
}

// MARK: - Live workspace (impure; never unit-tested)

/// The live `WorkspaceControlling` over NSWorkspace + the system-wide Accessibility
/// element. Public Apple APIs only.
public final class SystemWorkspace: WorkspaceControlling {
    public init() {}

    public var frontmostPID: pid_t? {
        #if canImport(AppKit)
        NSWorkspace.shared.frontmostApplication?.processIdentifier
        #else
        nil
        #endif
    }

    public var frontmostAppName: String? {
        #if canImport(AppKit)
        NSWorkspace.shared.frontmostApplication?.localizedName
        #else
        nil
        #endif
    }

    public func activate(pid: pid_t) -> Bool {
        #if canImport(AppKit)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if #available(macOS 14.0, *) {
            return app.activate()
        } else {
            return app.activate(options: [.activateIgnoringOtherApps])
        }
        #else
        return false
        #endif
    }

    /// PUBLIC Accessibility foreground fallback (FIX B). Uses only the already-granted
    /// Accessibility permission — `AXUIElementCreateApplication` + `AXUIElementSetAttributeValue`
    /// / `AXUIElementPerformAction`. No Apple Events / Automation TCC, no `osascript`.
    public func raiseViaAccessibility(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        // Ask the application element to become frontmost (public AX attribute).
        let frontErr = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        // Raise the app's main (or focused) window so it also comes forward within the app.
        var raised = false
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var windowRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(app, attribute as CFString, &windowRef)
            guard err == .success, let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { continue }
            let window = windowRef as! AXUIElement
            if AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success { raised = true }
            break
        }
        return frontErr == .success || raised
    }

    public func recordFocusedElement() -> FocusedElementToken? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        return FocusedElementToken(payload: focused)
    }

    public func restoreFocusedElement(_ token: FocusedElementToken) -> Bool {
        guard let payload = token.payload, CFGetTypeID(payload as CFTypeRef) == AXUIElementGetTypeID() else {
            return false
        }
        let element = payload as! AXUIElement
        let err = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return err == .success
    }
}
