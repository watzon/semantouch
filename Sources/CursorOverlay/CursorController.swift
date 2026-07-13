import Foundation
import ComputerUseCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Cursor overlay lifecycle (docs/PLAN.md Stage H).
//
// The controller is the impure-free brain of the overlay: it decides WHEN to show,
// update, and hide the overlay and WHERE to place it, driving the pure `CursorPlan`
// geometry into a `CursorPresenting` seam and a `CursorAnimating` seam. All AppKit lives
// behind `CursorPresenting` (see CursorPanel.swift), so every lifecycle branch —
// show-on-action, follow-window-move, hide-on-interrupt/end, honour the hide/dim
// preference — is unit-testable against a fake presenter with no windows and no GUI.
//
// Best-effort by construction: every method is non-throwing and returns promptly.
// The overlay failing, or there being no GUI session at all, NEVER fails or delays an action.

// MARK: - GUI session probe

/// Whether a GUI/windowing session is available to host the overlay: an ACTIVE main display.
///
/// PUBLIC CoreGraphics only (`CGMainDisplayID` / `CGDisplayIsActive`); creates no window and
/// touches no AppKit. This is the SINGLE self-guard shared by two callers so they can never
/// disagree:
/// - `AppKitCursorPresenter.canPresent` (the controller refuses to present when false), and
/// - the `mcp` runtime, which consults it to decide whether to host an AppKit run loop for the
///   overlay at all (task: enabled + GUI → host; disabled/headless → no host).
///
/// False in a headless daemon, over SSH, on a locked login window with no active display, or on
/// a non-CoreGraphics platform — exactly the contexts where the `mcp` server must create no
/// window and keep the Stage H headless-safe proof intact.
public enum GUISession {
    public static var isAvailable: Bool {
        #if canImport(CoreGraphics)
        let main = CGMainDisplayID()
        return main != 0 && CGDisplayIsActive(main) != 0
        #else
        return false
        #endif
    }
}

// MARK: - Presenter seam

/// The overlay presentation seam. The live conformance (`AppKitCursorPresenter`) drives a
/// nonactivating transparent `NSPanel`; tests supply a fake that records calls.
public protocol CursorPresenting: AnyObject {
    /// Whether a GUI/windowing session is available to host an overlay window. The
    /// controller refuses to present when this is false, so the headless `mcp` server
    /// never creates an AppKit window when there is no GUI session.
    var canPresent: Bool { get }

    /// Create/show the overlay for a session with its identity colour.
    func show(color: CursorColor)

    /// Reposition the panel to `panelFrame` (GLOBAL points) and draw the cursor at
    /// `cursorInPanel` (panel-local points) in `visualState`.
    func update(panelFrame: Rect, cursorInPanel: Point, visualState: CursorVisualState)

    /// Tear down / hide the overlay immediately.
    func hide()
}

// MARK: - Hide/dim preference

/// The overlay display preference from `SEMANTOUCH_CURSOR` (`off|dim|on`, default `on`).
public enum CursorPreference: String, Sendable, Equatable {
    /// Solid identity-colour cursor (default).
    case on
    /// Present, but dimmed (translucent).
    case dim
    /// Never present.
    case off

    /// Resolve from an environment dictionary (defaults to the process environment).
    /// Any unrecognised value falls back to `on` (the documented default).
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> CursorPreference {
        switch (environment["SEMANTOUCH_CURSOR"] ?? "").lowercased() {
        case "off": return .off
        case "dim": return .dim
        case "on", "": return .on
        default: return .on
        }
    }

    /// The cursor alpha this preference draws at, or `nil` when the overlay is off.
    var alpha: Double? {
        switch self {
        case .on: return 0.95
        case .dim: return 0.5
        case .off: return nil
        }
    }
}

// MARK: - Controller

/// Owns the overlay lifecycle across the helper process. One overlay cursor is shown at a
/// time (the most recently acting session); it is best-effort and decorative.
public final class CursorController: @unchecked Sendable {
    private let presenter: CursorPresenting
    private let animator: CursorAnimating
    public let preference: CursorPreference

    private let lock = NSLock()
    /// Last-known target-window frame (global points) per session, so a coordinate/element
    /// action can place the overlay and a later `get_app_state` can follow window moves.
    private var windowFrames: [String: Rect] = [:]
    /// Sessions that have had their FIRST pointer-kind action (click / coordinate click /
    /// scroll / drag — semantic or coordinate) and so are permitted to bring the overlay on
    /// screen. A keyboard-only action (type_text / press_key) never adds a session here, so it
    /// never triggers first-show; but once a session IS activated, ALL of its actions —
    /// keyboard included — update/reflect the cursor. Disarmed on that session's teardown.
    private var activatedSessions: Set<String> = []
    /// The session whose overlay is currently shown, if any.
    private var activeSession: String?
    /// The last applied plan for the active session (used to follow window moves and to
    /// drop to idle without recomputing the cursor point).
    private var lastPlan: CursorPlan?

    public init(
        presenter: CursorPresenting,
        animator: CursorAnimating = CursorAnimator(),
        preference: CursorPreference = .fromEnvironment()
    ) {
        self.presenter = presenter
        self.animator = animator
        self.preference = preference
    }

    /// Whether the overlay may present at all: enabled by preference AND a GUI session is
    /// available. When false, every lifecycle method is a no-op — nothing touches AppKit.
    private var enabled: Bool {
        preference != .off && presenter.canPresent
    }

    // MARK: Lifecycle

    /// Record (or refresh) a session's target-window frame — called by `get_app_state`.
    /// If that session's overlay is currently shown, follow the move by repositioning the
    /// panel to the new frame, keeping the current cursor point/visual state (best-effort
    /// geometry following).
    public func noteWindowFrame(sessionId: String, _ frame: Rect) {
        lock.lock(); defer { lock.unlock() }
        windowFrames[sessionId] = frame
        guard enabled, activeSession == sessionId, let previous = lastPlan else { return }
        let plan = CursorPlan.compute(
            windowFrame: frame,
            action: previous.actionKindForReposition,
            targetPointWindow: previous.cursorInPanel,
            progress: previous.progressForReposition
        )
        apply(plan)
    }

    /// Reflect one action for a session and place the cursor at `targetPointWindow` (window
    /// points; `nil` centres it) in the given state. Non-blocking and best-effort.
    ///
    /// First-show is ARMED by `pointerKind` (task step 1): only a pointer-kind action —
    /// click / coordinate click / scroll / drag (semantic or coordinate) — may bring the
    /// overlay on screen for the first time in a session. A non-pointer action (keyboard
    /// `type_text`/`press_key`, and non-pointer semantics) passes `pointerKind: false` and
    /// reflects NOTHING until the session has already been activated by a pointer action;
    /// thereafter it updates the cursor like any other action. Once shown, the overlay
    /// PERSISTS (idle between actions) — see `finish` — until an explicit teardown.
    public func reflect(
        sessionId: String,
        windowFrame: Rect,
        action: CursorActionKind,
        at targetPointWindow: Point? = nil,
        progress: Double = 0,
        pointerKind: Bool
    ) {
        lock.lock(); defer { lock.unlock() }
        windowFrames[sessionId] = windowFrame
        guard enabled else { return }

        // Arm/gate first-show. A pointer-kind action activates the session (and may show);
        // a non-pointer action for a not-yet-activated session reflects nothing.
        if pointerKind {
            activatedSessions.insert(sessionId)
        } else if !activatedSessions.contains(sessionId) {
            return
        }

        // A location-less action (keyboard progress, a semantic action whose element frame
        // was not resolvable) must not YANK an already-visible cursor to the window centre —
        // an independent pointer stays where it last acted (Codex-style persistence). Only a
        // first show with no point falls back to the plan's centre anchor.
        var anchor = targetPointWindow
        if anchor == nil, activeSession == sessionId, let previous = lastPlan {
            anchor = previous.cursorInPanel
        }

        let plan = CursorPlan.compute(
            windowFrame: windowFrame,
            action: action,
            targetPointWindow: anchor,
            progress: progress
        )
        guard plan.presentable else {
            // Degenerate window: hide rather than present a zero-size overlay. The session
            // stays activated, so a later action against a valid window re-shows.
            hideLocked()
            return
        }

        if activeSession != sessionId || lastPlan == nil {
            // (Re)acquire the overlay for this session with its identity colour.
            let alpha = preference.alpha ?? 0.95
            let color = CursorColor.identity(forSession: sessionId, alpha: alpha)
            animator.reset(color: color, at: plan.cursorInPanel)
            presenter.show(color: color)
            activeSession = sessionId
        }
        apply(plan)
    }

    /// An action finished. The overlay does NOT hide on per-action completion (task step 1):
    /// it drops the cursor to an IDLE-but-VISIBLE state, resting at its last point until the
    /// next action. A user-interruption ALSO stays visible — the cursor simply goes idle;
    /// only an explicit teardown (`endSession`/`shutdown`) removes the overlay. `interrupted`
    /// is retained for a possible future paused visual, but both paths currently go idle.
    public func finish(sessionId: String, interrupted: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, activeSession == sessionId else { return }
        guard let frame = windowFrames[sessionId], let previous = lastPlan else { return }
        let plan = CursorPlan.compute(
            windowFrame: frame,
            action: .idle,
            targetPointWindow: previous.cursorInPanel
        )
        apply(plan)
    }

    /// A single app session ended — an explicit teardown entrypoint (task step 1), wired to
    /// `end_app_session`. Hides the overlay if this session owns it, forgets the session's
    /// geometry, and DISARMS its first-show activation. Idempotent for an unknown session.
    public func endSession(sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        windowFrames.removeValue(forKey: sessionId)
        activatedSessions.remove(sessionId)
        guard activeSession == sessionId else { return }
        hideLocked()
    }

    /// Full overlay teardown (task step 1): the connection/session is shutting down — MCP
    /// connection close (stdin EOF) or server shutdown (SIGTERM). Hides the overlay and
    /// forgets ALL per-session state. Exposed now and called from the `mcp` runtime's
    /// EOF/SIGTERM paths; inert (safe) when nothing was ever shown or when disabled/headless.
    public func shutdown() {
        lock.lock(); defer { lock.unlock() }
        // Only touch the presenter when the overlay could ever have shown — keeps the
        // `off`/headless contract fully inert (no AppKit call ever).
        if enabled { hideLocked() }
        activatedSessions.removeAll()
        windowFrames.removeAll()
    }

    /// The action scheduler's decoupled synchronization point. Delegates to the
    /// animator's non-blocking `synchronize()`; returns immediately regardless of animation
    /// state. Present so the action path has an explicit, bounded sync seam that provably
    /// never waits on the overlay.
    public func synchronize() {
        animator.synchronize()
    }

    // MARK: Internals (call under `lock`)

    /// Apply a plan: retarget the animator and update the presenter, remembering it as the
    /// last plan for window-follow/idle transitions.
    private func apply(_ plan: CursorPlan) {
        animator.retarget(to: plan.cursorInPanel, state: plan.visualState)
        presenter.update(
            panelFrame: plan.panelFrame,
            cursorInPanel: plan.cursorInPanel,
            visualState: plan.visualState
        )
        lastPlan = plan
    }

    private func hideLocked() {
        presenter.hide()
        animator.stop()
        activeSession = nil
        lastPlan = nil
    }
}

// MARK: - Reposition helpers

private extension CursorPlan {
    /// The action kind to re-apply when following a window move (preserves the drawn
    /// state without needing to store the original `CursorActionKind`).
    var actionKindForReposition: CursorActionKind {
        switch visualState {
        case .idle: return .idle
        case .moving: return .move
        case .pressed: return .press
        case .dragging: return .drag
        case .progress: return .progress
        }
    }

    /// The progress fraction to re-apply for a `.progress` reposition (0 otherwise).
    var progressForReposition: Double {
        if case let .progress(fraction) = visualState { return fraction }
        return 0
    }
}

// MARK: - Null presenter + factories

/// A presenter that can never present. Used for headless/CLI/test contexts so overlay
/// wiring stays fully inert (no AppKit) unless a live GUI presenter is installed.
public final class NullCursorPresenter: CursorPresenting {
    public init() {}
    public var canPresent: Bool { false }
    public func show(color: CursorColor) {}
    public func update(panelFrame: Rect, cursorInPanel: Point, visualState: CursorVisualState) {}
    public func hide() {}
}

public extension CursorController {
    /// A fully-inert controller (never presents). Default for the CLI and for tests /
    /// contract fixtures that must not create AppKit windows.
    static func disabled() -> CursorController {
        CursorController(presenter: NullCursorPresenter(), animator: CursorAnimator(), preference: .off)
    }
}
