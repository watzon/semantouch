import Foundation
import Dispatch
import CoreGraphics
import ComputerUseCore

// AccessibilityEngine is not imported here: optional AX reliability seams
// (`CoordinateClickResolving`, `FocusedElementProviding`, `StringAXValueCapable`)
// live in FallbackInput so the executor stays free of live AX types.

// MARK: - Value + action models

/// A scalar an action may write (`set_value`, scrollbar `AXValue`). Mirrors
/// `set_value`'s `string | number | boolean` (§4.2).
public enum ActionValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
}

/// `scroll.direction` (§4.2).
public enum ScrollDirection: String, Equatable, Sendable {
    case up, down, left, right

    /// Up/down act on the vertical scrollbar; left/right on the horizontal one.
    public var isVertical: Bool { self == .up || self == .down }

    /// Down and right move toward the far end (scrollbar `AXValue` → 1).
    public var increasesValue: Bool { self == .down || self == .right }

    /// The scrollbar attribute this direction manipulates.
    public var scrollBarAttribute: String {
        isVertical ? AXActionName.verticalScrollBar : AXActionName.horizontalScrollBar
    }

    /// The by-page scroll action name for this direction (`AXScrollDownByPage`, …).
    public var byPageActionName: String {
        switch self {
        case .up: return "AXScrollUpByPage"
        case .down: return "AXScrollDownByPage"
        case .left: return "AXScrollLeftByPage"
        case .right: return "AXScrollRightByPage"
        }
    }
}

/// `scroll.by` (§4.2).
public enum ScrollGranularity: String, Equatable, Sendable {
    case line, page
}

/// One element-targeted Phase 2 action with its parameters.
public enum SemanticAction: Equatable, Sendable {
    /// Ordinary left single-click: maps to one `AXPress`.
    case click
    /// Ordinary left multi-click (2 or 3): repeats `AXPress` `count` times. Right/middle
    /// never reach this case — the handler routes them through verified-frame pointer delivery.
    case clickRepeated(count: Int)
    case performAction(name: String)
    /// `set_value`. v1.5 (§18.5): `commit` requests the semantic commit path — best-effort
    /// pre-focus, write, then `AXConfirm` when advertised (never synthesized input).
    case setValue(ActionValue, commit: Bool)
    case selectText(start: Int, length: Int)
    /// Semantic scroll. `count` is a positive magnitude; fractional values are exact on
    /// settable scrollbar AXValue paths and approximated (with a warning) for discrete
    /// AX page actions.
    case scroll(direction: ScrollDirection, by: ScrollGranularity, count: Double)

    /// The wire tool name (used for `policy_denied.data.tool`).
    public var toolName: String {
        switch self {
        case .click, .clickRepeated: return "click"
        case .performAction: return "perform_action"
        case .setValue: return "set_value"
        case .selectText: return "select_text"
        case .scroll: return "scroll"
        }
    }
}

// MARK: - Element seam

/// The seam the semantic actions operate through. The live implementation
/// (`AXActionElement`) wraps an `AXUIElement`; unit tests supply fakes, so every
/// action path is exercised without Accessibility permission.
public protocol ActionElement: AnyObject {
    /// Whether the underlying element still exists.
    var isLive: Bool { get }
    /// AX role (e.g. `AXButton`); `nil` when unavailable.
    var role: String? { get }
    /// Raw AX action names the element exposes (e.g. `["AXPress","AXShowMenu"]`).
    func actionNames() -> [String]
    /// Perform a raw AX action by name.
    func perform(_ action: String) throws
    /// Whether a named attribute is settable.
    func isSettable(_ attribute: String) -> Bool
    /// A stringified snapshot of a named attribute for before/after comparison, or
    /// `nil` when absent/unreadable. Numbers/booleans render as decimal/`0`|`1`.
    func snapshot(_ attribute: String) -> String?
    /// Write `AXValue`.
    func writeValue(_ value: ActionValue) throws
    /// Write `AXSelectedTextRange` from `{ location, length }`.
    func writeSelectedRange(location: Int, length: Int) throws
    /// A named element-valued attribute (e.g. `AXVerticalScrollBar`), or `nil`.
    func element(for attribute: String) -> ActionElement?
    /// Children in AX order.
    func children() -> [ActionElement]
    /// v1.5 (§18.5/§18.6): best-effort set `AXFocused = true` when the attribute is settable.
    /// Returns whether the write actually took (`false` when unsettable or the write faulted).
    /// Never throws — focusing is advisory (the caller opted into a commit / fallback path).
    func setKeyboardFocus() -> Bool
    /// v1.5 (§18.6): whether this element (or a descendant of it) currently holds the owning
    /// application's keyboard focus (its `AXFocusedUIElement`). Best-effort; `false` when the
    /// focus is unreadable or held elsewhere.
    func holdsKeyboardFocus() -> Bool
}

// MARK: - Environment seam

/// The context an `ActionExecutor` needs, injected so the executor stays free of
/// direct dependencies on the session/table/resolver layers (those live in
/// `ComputerUseService`). The live implementation is `ServiceActionEnvironment`.
public protocol ActionEnvironment {
    /// Resolve the target `app` and return its **mutation** policy denial reason, or
    /// `nil` when the app may be mutated. Throws a resolution `CUError`
    /// (`app_not_found` / `ambiguous_app` / …). Runs BEFORE enqueue (§13.2 step 1).
    func policyCheck(app: String) throws -> PolicyDenyReason?

    /// The session's current revision, or `nil` when the session is unknown/ended.
    /// Runs inside the lane (§13.2 step 2/3).
    func currentRevision(sessionId: String) -> Int?

    /// Confirm the live session `sessionId` is owned by the same process that the
    /// gated `app` resolves to. Returns `false` on mismatch — the **confused-deputy**
    /// case where the policy gate evaluated `app` (§13.2 step 1, §13.5) but
    /// `sessionId`'s element table belongs to a different app. Nothing else binds the
    /// mutated element to the selected app, so this check prevents one app selector
    /// from authorizing a mutation against another app's session.
    /// Throws a resolution `CUError` when `app` cannot be resolved. Runs inside the
    /// lane, after session existence (§13.2 step 2).
    func sessionOwnedByApp(sessionId: String, app: String) throws -> Bool

    /// Resolve `elementId` in the session's current element table to a live element,
    /// or throw `stale_element`. Runs inside the lane (§13.2 step 4).
    func resolveElement(sessionId: String, elementId: String, revision: Int) throws -> ActionElement
}

// MARK: - Fallback environment seam (Phase 4, §16)

/// The extra context Phase 4 fallback input needs beyond `ActionEnvironment`: the target
/// process, its captured window geometry (for coordinate mapping), and the process-wide
/// workspace / synthesizer / interruption seams. Injected so the whole interference +
/// delivery pipeline is exercised without a live workspace, event tap, or CGEvent posting.
public protocol FallbackEnvironment: ActionEnvironment {
    /// The target session's owning pid, or `nil` when the session is unknown/not running.
    func targetPID(sessionId: String) -> pid_t?
    /// The session's last-captured window geometry, or `nil` when none is known (no prior
    /// `get_app_state`). Required to map coordinate actions to global points.
    func windowGeometry(sessionId: String) -> WindowGeometry?
    /// The target window's **current** on-screen global-point frame, read fresh at delivery
    /// time (live: `CGWindowListCopyWindowInfo` by the captured window id — public API, no
    /// Screen Recording needed for bounds). `nil` when the window no longer exists on-screen.
    /// A coordinate fallback compares the mapped global point against this so a window that
    /// moved, resized, or closed since the capturing `get_app_state` cannot misroute a
    /// synthesized pointer event onto another app or system UI (§16.3).
    func currentWindowFrame(sessionId: String) -> Rect?
    /// Foreground/focus control (record → activate → restore).
    var workspace: WorkspaceControlling { get }
    /// The tagged CGEvent emitter.
    var synthesizer: InputSynthesizer { get }
    /// The user-interruption monitor (armed around delivery).
    var interruption: InterruptionMonitoring { get }
}

// MARK: - Executor

/// Runs Phase 2 mutations through a per-app-session **serial FIFO lane** (§13.6).
///
/// - The policy gate runs **before** a mutation is enqueued (§13.2 step 1).
/// - Session/revision validation and element resolution run **inside** the lane
///   (steps 2–4), so they observe a consistent view relative to other mutations on
///   the same session.
/// - Distinct sessions have independent lanes and execute concurrently.
///
/// Lanes are `DispatchQueue`s; submitting with `async` preserves submission order
/// (FIFO). `execute` blocks the caller on the lane via a semaphore and returns the
/// result; the MCP runtime already processes one request at a time, so this cannot
/// starve the server, and per-session ordering is guaranteed regardless.
public final class ActionExecutor: @unchecked Sendable {
    private let lanesLock = NSLock()
    private var lanes: [String: DispatchQueue] = [:]

    public init() {}

    /// The serial lane for a session, created on first use.
    private func lane(for sessionId: String) -> DispatchQueue {
        lanesLock.lock()
        defer { lanesLock.unlock() }
        if let queue = lanes[sessionId] { return queue }
        let queue = DispatchQueue(label: "dev.watzon.semantouch.action-lane.\(sessionId)")
        lanes[sessionId] = queue
        return queue
    }

    /// Submit `work` to the session's lane without waiting (FIFO). Exposed for tests
    /// that prove ordering/serialization/cross-session concurrency directly.
    public func submit(sessionId: String, _ work: @escaping () -> Void) {
        lane(for: sessionId).async(execute: work)
    }

    /// Drop a session's lane so its `DispatchQueue` and map entry are reclaimed.
    /// Called from `end_app_session` after the session is truly ended (§13.6). Session
    /// ids are monotonic and never reused (§3), so a dropped lane is never resurrected;
    /// without this the map would grow unbounded over a long-lived server.
    public func releaseLane(sessionId: String) {
        lanesLock.lock()
        defer { lanesLock.unlock() }
        lanes.removeValue(forKey: sessionId)
    }

    /// Run `body` on the session's lane and return its result, blocking the caller.
    public func onLane<R>(sessionId: String, _ body: @escaping () -> R) -> R {
        let box = ResultBox<R>()
        let semaphore = DispatchSemaphore(value: 0)
        lane(for: sessionId).async {
            box.value = body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    /// Execute a Phase 2 action end to end (§13.2). Throws a typed `CUError`.
    @discardableResult
    public func execute(
        _ action: SemanticAction,
        target: ElementTarget,
        environment: ActionEnvironment
    ) throws -> ActionResult {
        // Boundary trace: semantic action dispatch →
        // completion, with a mark once the policy gate clears.
        let trace = Tracer.shared.span("action:\(action.toolName)")
        defer { trace?.end() }

        // 1. Policy gate — BEFORE enqueue, before any AX call (§13.2 step 1, §13.5).
        if let reason = try environment.policyCheck(app: target.app) {
            throw CUError.policyDenied(reason: reason, app: target.app, tool: action.toolName)
        }
        trace?.mark("policy_ok")

        // 2. Resolution + validation + perform — inside the session's serial lane.
        let outcome: Result<ActionResult, Error> = onLane(sessionId: target.sessionId) {
            do {
                return .success(try Self.runInLane(action, target: target, environment: environment))
            } catch {
                return .failure(error)
            }
        }
        return try outcome.get()
    }

    /// The in-lane body: validate session → revision → element, then perform.
    private static func runInLane(
        _ action: SemanticAction,
        target: ElementTarget,
        environment: ActionEnvironment
    ) throws -> ActionResult {
        // Step 2: session existence (unknown/ended → current is null).
        guard let current = environment.currentRevision(sessionId: target.sessionId) else {
            throw CUError.staleRevision(sessionId: target.sessionId, provided: target.revision, current: nil)
        }
        // Step 2.5: confused-deputy guard (§13.5). The policy gate (step 1) evaluated
        // the free-text `target.app`, but the element about to be mutated is resolved
        // solely from `target.sessionId`. Require the session to actually belong to the
        // selected app. A foreign session → policy_denied before revision/element
        // validation or any AX call.
        guard try environment.sessionOwnedByApp(sessionId: target.sessionId, app: target.app) else {
            throw CUError.policyDenied(reason: .appDenied, app: target.app, tool: action.toolName)
        }
        // Step 3: revision match.
        guard current == target.revision else {
            throw CUError.staleRevision(sessionId: target.sessionId, provided: target.revision, current: current)
        }
        // Step 4: element resolution (throws stale_element).
        let element = try environment.resolveElement(
            sessionId: target.sessionId,
            elementId: target.elementId,
            revision: target.revision
        )

        // Dispatch to the semantic action implementation.
        switch action {
        case .click:
            return try SemanticActions.click(element, elementId: target.elementId, clickCount: 1)
        case let .clickRepeated(count):
            return try SemanticActions.click(element, elementId: target.elementId, clickCount: count)
        case let .performAction(name):
            return try SemanticActions.performNamed(element, name: name, elementId: target.elementId)
        case let .setValue(value, commit):
            return try TextActions.setValue(element, value: value, commit: commit, elementId: target.elementId)
        case let .selectText(start, length):
            return try TextActions.selectText(element, start: start, length: length, elementId: target.elementId)
        case let .scroll(direction, by, count):
            return try ScrollActions.scroll(element, direction: direction, by: by, count: count, elementId: target.elementId)
        }
    }

    /// A one-shot box so an awaited lane result can cross the semaphore boundary.
    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}

// MARK: - Phase 4 fallback execution (§16)

public extension ActionExecutor {
    /// Execute a Phase 4 fallback action end to end. Order (§16): mutation policy gate
    /// **before** enqueue; then, inside the session's serial lane — session existence, the
    /// confused-deputy ownership guard, coordinate→global mapping, the interference
    /// decision, the bounded focus transaction, tagged delivery under an armed interruption
    /// monitor, and post-delivery target verification. Throws a typed `CUError`.
    @discardableResult
    func executeFallback(
        _ action: FallbackAction,
        target: FallbackTarget,
        environment: FallbackEnvironment
    ) throws -> ActionResult {
        // Boundary trace: fallback action dispatch →
        // completion, with a mark once the policy gate clears.
        let trace = Tracer.shared.span("action:\(action.toolName)")
        defer { trace?.end() }

        // 1. Policy gate — BEFORE enqueue, before any input (§13.5, same as Phase 2).
        if let reason = try environment.policyCheck(app: target.app) {
            throw CUError.policyDenied(reason: reason, app: target.app, tool: action.toolName)
        }
        trace?.mark("policy_ok")

        let outcome: Result<ActionResult, Error> = onLane(sessionId: target.sessionId) {
            do {
                return .success(try ActionExecutor.runFallbackInLane(action, target: target, environment: environment))
            } catch {
                return .failure(error)
            }
        }
        return try outcome.get()
    }

    /// The in-lane body for a fallback action.
    private static func runFallbackInLane(
        _ action: FallbackAction,
        target: FallbackTarget,
        environment: FallbackEnvironment
    ) throws -> ActionResult {
        // Session existence (a fallback action carries no revision; an unknown/ended session
        // is reported like Phase 2 with `current: null`, `provided: 0` as the sentinel).
        guard let currentRevision = environment.currentRevision(sessionId: target.sessionId) else {
            throw CUError.staleRevision(sessionId: target.sessionId, provided: 0, current: nil)
        }
        // Confused-deputy guard: the session (and its window/pid) must belong to the
        // selected app before input may be delivered.
        guard try environment.sessionOwnedByApp(sessionId: target.sessionId, app: target.app) else {
            throw CUError.policyDenied(reason: .appDenied, app: target.app, tool: action.toolName)
        }

        // §18.6: an element-targeted key action validates its `revision`+`elementId` pair here —
        // inside the lane, after session existence + the confused-deputy guard and BEFORE the
        // Phase-4 target-pid/window checks — per §13.2 steps 3–4: a mismatched revision →
        // `stale_revision` (with the session's current revision), an unresolvable id →
        // `stale_element`. The resolved element is pre-focused during delivery.
        var focusElement: ActionElement?
        if target.targetsElement, let revision = target.revision, let elementId = target.elementId {
            guard currentRevision == revision else {
                throw CUError.staleRevision(sessionId: target.sessionId, provided: revision, current: currentRevision)
            }
            focusElement = try environment.resolveElement(sessionId: target.sessionId, elementId: elementId, revision: revision)
        }

        guard let targetPID = environment.targetPID(sessionId: target.sessionId) else {
            throw CUError.windowNotFound(app: target.app, windowId: nil)
        }

        // Map coordinate actions to global points BEFORE any focus change, so an unmappable
        // coordinate fails without disturbing the user's foreground.
        var resolved = try resolveGlobal(action, target: target, environment: environment)

        // Arm interruption around optional AX reliability work AND any subsequent synthesis.
        let monitor = environment.interruption
        monitor.arm()
        defer { monitor.disarm() }

        // §18.6: `elementFocused` is reported only when an element was targeted; it defaults to
        // `false` (unconfirmed / never attempted, e.g. a focus-changing mode that could not
        // foreground the target) and becomes the confirm re-read's result when delivery runs.
        var elementFocused: Bool? = target.targetsElement ? false : nil

        // --- type_text: settable string AXValue append-first (before CGEvent planning) -----
        if case let .text(text) = resolved {
            if let axValueResult = tryAppendStringAXValue(
                text: text,
                focusElement: focusElement,
                targetPID: targetPID,
                target: target,
                environment: environment,
                monitor: monitor
            ) {
                return axValueResult
            }
        }

        // --- left single coordinate click: optional AX resolve / press before interference ---
        // Right/middle/multi-click keep exact pointer semantics (no semantic AX).
        if case let .click(point, button, flags, clickCount) = resolved,
           button == .left,
           clickCount == 1,
           let resolver = environment as? CoordinateClickResolving {
            let remapped = trySemanticCoordinateClick(
                originalPoint: point,
                button: button,
                flags: flags,
                clickCount: clickCount,
                targetPID: targetPID,
                target: target,
                environment: environment,
                resolver: resolver,
                monitor: monitor
            )
            switch remapped {
            case let .completed(result):
                return result
            case let .synthesize(newResolved):
                resolved = newResolved
            }
        }

        if monitor.isInterrupted {
            return buildResult(
                action: action,
                focus: FocusOutcome(
                    delivered: false,
                    focusChanged: false,
                    focusRestored: false,
                    targetBecameFrontmost: false,
                    priorFrontmostPID: environment.workspace.frontmostPID
                ),
                interrupted: true,
                focusLost: false,
                degraded: monitor.degraded,
                elementFocused: elementFocused
            )
        }

        // Interference decision (§16). No silent escalation: background-only + not-frontmost
        // either takes the process-targeted keyboard lane (eligible keys/text + capable
        // synthesizer) or rejects with `focus_required` for pointer/ineligible paths — never
        // global delivery into the wrong app, and never auto-escalation to focus.
        let synthesizer = environment.synthesizer
        let targetedCapability = synthesizer as? ProcessTargetedInputSynthesizer
        let targetIsFrontmost = environment.workspace.frontmostPID == targetPID
        let plan = InterferencePlan.decide(
            mode: target.interference,
            targetIsFrontmost: targetIsFrontmost,
            actionSupportsTargetedDelivery: action.supportsTargetedDelivery,
            synthesizerSupportsTargetedDelivery: targetedCapability != nil
        )
        if plan == .focusRequired {
            throw CUError.focusRequired(app: target.app, frontmostApp: environment.workspace.frontmostAppName)
        }

        // Process-targeted keyboard lane: re-resolve/bind the current target PID immediately
        // before delivery through the existing environment/session ownership checks. No
        // activation, no FocusTransaction, no global silent fallback. postToPid has no ack, so
        // delivery is reported unconfirmed unless an existing element-focused postcondition
        // proves it.
        if plan == .deliverTargeted {
            guard let targeted = targetedCapability else {
                // Capability disappeared between decide and delivery — refuse rather than
                // silently fall back to global posting into the frontmost app.
                throw CUError.focusRequired(app: target.app, frontmostApp: environment.workspace.frontmostAppName)
            }
            guard let livePID = environment.targetPID(sessionId: target.sessionId),
                  livePID == targetPID,
                  (try? environment.sessionOwnedByApp(sessionId: target.sessionId, app: target.app)) == true else {
                // Target exited / PID reused / ownership lost after the pre-check — post nothing.
                return buildResult(
                    action: action,
                    focus: FocusOutcome(
                        delivered: false,
                        focusChanged: false,
                        focusRestored: false,
                        targetBecameFrontmost: false,
                        priorFrontmostPID: environment.workspace.frontmostPID
                    ),
                    interrupted: false,
                    focusLost: true,
                    degraded: monitor.degraded,
                    elementFocused: elementFocused,
                    targetedDelivery: true,
                    deliveryConfirmed: false
                )
            }

            let deliveryPID = livePID
            let targetGuard = TargetGuard {
                guard let current = environment.targetPID(sessionId: target.sessionId),
                      current == deliveryPID else { return false }
                return (try? environment.sessionOwnedByApp(sessionId: target.sessionId, app: target.app)) == true
            }
            let bound = ProcessTargetedSynthesizerBinding(base: targeted, pid: deliveryPID)
            if let focusElement {
                _ = focusElement.setKeyboardFocus()
                elementFocused = focusElement.holdsKeyboardFocus()
            }
            deliver(resolved, via: bound, interruption: monitor, onTarget: targetGuard)

            let interrupted = monitor.isInterrupted
            let deliveryConfirmed = (elementFocused == true) && !interrupted && !targetGuard.lostTarget
            return buildResult(
                action: action,
                focus: FocusOutcome(
                    delivered: true,
                    focusChanged: false,
                    focusRestored: false,
                    targetBecameFrontmost: false,
                    priorFrontmostPID: environment.workspace.frontmostPID
                ),
                interrupted: interrupted,
                focusLost: targetGuard.lostTarget,
                degraded: monitor.degraded,
                elementFocused: elementFocused,
                targetedDelivery: true,
                deliveryConfirmed: deliveryConfirmed
            )
        }

        // Global / focus-transaction lane (frontmost or explicit focus modes).
        // Re-check the target holds the foreground before EVERY input unit during delivery
        // (§16.3 step 5). A self-activating app steals focus with no HID event, so the
        // interruption monitor cannot see it; this guard stops delivery so remaining keyboard
        // input never lands in the intruder, and pointer input never routes past the target.
        let workspace = environment.workspace
        let targetGuard = TargetGuard { workspace.frontmostPID == targetPID }
        // A coordinate pointer action moves the PHYSICAL cursor (§16.7: public CGEvent
        // delivery routes by screen location). Record where the user's pointer was so it can
        // be returned after delivery — restored only when delivery ran to completion
        // undisturbed (never after a genuine user interruption or a foreground loss, where
        // warping the pointer would fight the user's own hand).
        let pointerOrigin: CGPoint? = resolved.isPointerAction ? synthesizer.pointerLocation() : nil
        let focusOutcome = FocusTransaction(workspace: environment.workspace).run(
            targetPID: targetPID,
            mode: plan.focusMode
        ) {
            // §18.6: inside the focus transaction, after the target is frontmost and immediately
            // before event synthesis, best-effort set AXFocused on the resolved element and
            // re-read the app's AXFocusedUIElement once to confirm. Delivery proceeds regardless
            // of the confirmation (the caller opted into fallback input); the field makes the
            // risk observable. Element targeting never escalates focus by itself (§16 unchanged).
            if let focusElement {
                _ = focusElement.setKeyboardFocus()
                elementFocused = focusElement.holdsKeyboardFocus()
            }
            deliver(resolved, via: synthesizer, interruption: monitor, onTarget: targetGuard)
        }

        let interrupted = monitor.isInterrupted
        if let pointerOrigin, focusOutcome.delivered, !interrupted, !targetGuard.lostTarget {
            synthesizer.movePointer(to: pointerOrigin)
        }
        return buildResult(
            action: action,
            focus: focusOutcome,
            interrupted: interrupted,
            focusLost: targetGuard.lostTarget,
            degraded: monitor.degraded,
            elementFocused: elementFocused
        )
    }

    // MARK: - Optional AX reliability (type_text string AXValue + coordinate press)

    /// Outcome of optional semantic coordinate-click resolution.
    private enum SemanticClickOutcome {
        /// AXPress (or equivalent semantic path) completed; no CGEvents.
        case completed(ActionResult)
        /// Fall through to existing interference + pointer synthesis with this resolved form.
        case synthesize(ResolvedFallback)
    }

    /// Attempt left single-click AX resolution/press. On successful press returns a completed
    /// accessibility result (zero events). On `.coordinate` or press failure, remaps the
    /// click to the resolver's safe anchor (revalidated against captured+current window
    /// frames). Resolver miss keeps the original point. Never escalates focus.
    private static func trySemanticCoordinateClick(
        originalPoint: CGPoint,
        button: PointerButton,
        flags: CGEventFlags,
        clickCount: Int,
        targetPID: pid_t,
        target: FallbackTarget,
        environment: FallbackEnvironment,
        resolver: CoordinateClickResolving,
        monitor: InterruptionMonitoring
    ) -> SemanticClickOutcome {
        // Interruption before AX work: report interrupted without synthesis.
        if monitor.isInterrupted {
            return .completed(buildSemanticResult(
                method: .pointer,
                status: .interrupted,
                stateChanged: false,
                targetVerified: false,
                warning: nil,
                degraded: monitor.degraded
            ))
        }

        // Fresh window frame only — the original point already passed captured+current
        // validation; the resolver needs the live bounds for candidate rejection.
        guard let windowBounds = environment.currentWindowFrame(sessionId: target.sessionId) else {
            return .synthesize(.click(point: originalPoint, button: button, flags: flags, clickCount: clickCount))
        }

        guard let resolution = resolver.resolveCoordinateClick(
            atGlobal: originalPoint,
            windowBounds: windowBounds,
            expectedPID: targetPID
        ) else {
            // Resolver miss / unavailable → keep the original coordinate.
            return .synthesize(.click(point: originalPoint, button: button, flags: flags, clickCount: clickCount))
        }

        if monitor.isInterrupted {
            return .completed(buildSemanticResult(
                method: .pointer,
                status: .interrupted,
                stateChanged: false,
                targetVerified: false,
                warning: semanticClickWarning(reason: resolution.reason, notes: resolution.evidenceNotes, extra: nil),
                degraded: monitor.degraded
            ))
        }

        // Prefer AXPress when the resolver selected press AND delivery-time authorization
        // passes. `.press` is advisory only — never sufficient by itself.
        var pressFailed = false
        if resolution.activation == .press {
            switch attemptSafeAXPress(
                resolution: resolution,
                originalPoint: originalPoint,
                targetPID: targetPID,
                target: target,
                environment: environment,
                monitor: monitor
            ) {
            case let .completed(result):
                return .completed(result)
            case .unauthorized, .pressFailed:
                pressFailed = true
                // Fall through to the resolver safe anchor.
            }
        }

        // Coordinate path: use the resolver's bounded safe anchor when supplied and still
        // over the target window. Do not silently revert to the original point when the
        // resolver supplied an anchor that failed revalidation (refuse synthesis instead).
        // When the resolver did not supply an anchor, keep the original validated point.
        if let anchor = resolution.anchor {
            if let deliveryPoint = revalidatedAnchor(
                anchor,
                target: target,
                environment: environment
            ) {
                // Re-check identity before entering pointer synthesis path.
                guard let livePID = environment.targetPID(sessionId: target.sessionId),
                      livePID == targetPID,
                      (try? environment.sessionOwnedByApp(sessionId: target.sessionId, app: target.app)) == true else {
                    return .completed(buildSemanticResult(
                        method: .pointer,
                        status: .interrupted,
                        stateChanged: false,
                        targetVerified: false,
                        warning: semanticClickWarning(
                            reason: resolution.reason,
                            notes: resolution.evidenceNotes,
                            extra: pressFailed
                                ? "AXPress was not used; target identity changed before pointer fallback."
                                : "Target identity changed before pointer fallback."
                        ),
                        degraded: monitor.degraded
                    ))
                }
                return .synthesize(.click(point: deliveryPoint, button: button, flags: flags, clickCount: clickCount))
            }
            // Anchor failed revalidation — do not fall back to the original point.
            return .completed(buildSemanticResult(
                method: .pointer,
                status: .interrupted,
                stateChanged: false,
                targetVerified: false,
                warning: semanticClickWarning(
                    reason: resolution.reason,
                    notes: resolution.evidenceNotes,
                    extra: "Resolver anchor is no longer over the target window; no pointer event was posted."
                ),
                degraded: monitor.degraded
            ))
        }

        // No anchor from resolver: preserve original validated point.
        return .synthesize(.click(point: originalPoint, button: button, flags: flags, clickCount: clickCount))
    }

    private enum AXPressAttempt {
        case completed(ActionResult)
        case unauthorized
        case pressFailed
    }

    /// Re-check target PID/ownership and selected element PID/frame, then perform AXPress.
    /// Authorization requires: selected PID present and == targetPID, selected frame present
    /// and fully inside the **fresh** target window, and frame contains the original
    /// validated global click point. API success alone does not set `stateChanged`.
    private static func attemptSafeAXPress(
        resolution: AXCoordinateClickResolution,
        originalPoint: CGPoint,
        targetPID: pid_t,
        target: FallbackTarget,
        environment: FallbackEnvironment,
        monitor: InterruptionMonitoring
    ) -> AXPressAttempt {
        // Target identity must still match immediately before press.
        guard let livePID = environment.targetPID(sessionId: target.sessionId),
              livePID == targetPID,
              (try? environment.sessionOwnedByApp(sessionId: target.sessionId, app: target.app)) == true else {
            return .unauthorized
        }
        // Require a known-equal PID (never press when pid is unknown).
        guard let selectedPID = resolution.selectedPID, selectedPID == targetPID else {
            return .unauthorized
        }
        // Fresh window only; frame fully inside; frame contains the original click point.
        guard let windowBounds = environment.currentWindowFrame(sessionId: target.sessionId),
              let frame = resolution.selectedFrame,
              frameFullyInside(frame, window: windowBounds),
              frame.contains(x: Double(originalPoint.x), y: Double(originalPoint.y)) else {
            return .unauthorized
        }
        guard let element = resolution.pressElement, element.isLive else {
            return .unauthorized
        }
        if monitor.isInterrupted {
            return .completed(buildSemanticResult(
                method: .accessibility,
                status: .interrupted,
                stateChanged: false,
                targetVerified: false,
                warning: semanticClickWarning(reason: resolution.reason, notes: resolution.evidenceNotes, extra: nil),
                degraded: monitor.degraded
            ))
        }

        do {
            try element.perform(AXActionName.press)
        } catch {
            return .pressFailed
        }

        // AXPress API success is not an observed UI state change.
        let status: ActionStatus = monitor.isInterrupted ? .interrupted : .completed
        return .completed(buildSemanticResult(
            method: .accessibility,
            status: status,
            stateChanged: false,
            targetVerified: true,
            warning: semanticClickWarning(reason: resolution.reason, notes: resolution.evidenceNotes, extra: nil),
            degraded: monitor.degraded
        ))
    }

    /// Revalidate a resolver anchor against captured + **fresh** current window frames.
    /// Returns `nil` when the anchor is no longer safe (caller must not post a pointer event).
    private static func revalidatedAnchor(
        _ anchor: Point,
        target: FallbackTarget,
        environment: FallbackEnvironment
    ) -> CGPoint? {
        let point = CGPoint(x: anchor.x, y: anchor.y)
        guard let geometry = environment.windowGeometry(sessionId: target.sessionId),
              let current = environment.currentWindowFrame(sessionId: target.sessionId) else {
            return nil
        }
        guard geometry.framePoints.contains(x: Double(point.x), y: Double(point.y)),
              current.contains(x: Double(point.x), y: Double(point.y)) else {
            return nil
        }
        return point
    }

    private static func frameFullyInside(_ frame: Rect, window: Rect) -> Bool {
        frame.x >= window.x
            && frame.y >= window.y
            && (frame.x + frame.width) <= (window.x + window.width)
            && (frame.y + frame.height) <= (window.y + window.height)
    }

    private static func semanticClickWarning(
        reason: String,
        notes: [String],
        extra: String?
    ) -> String {
        var parts = ["Semantic AX click via \(reason)."]
        if !notes.isEmpty {
            parts.append("Evidence: \(notes.joined(separator: ", ")).")
        }
        if let extra { parts.append(extra) }
        return parts.joined(separator: " ")
    }

    /// Append `text` via settable string AXValue on the explicitly targeted element, or the
    /// target PID's currently focused element (only when no element was explicitly targeted).
    ///
    /// After every write attempt — including a thrown write — re-read and classify:
    /// - exact expected → confirmed semantic completion (never synthesize)
    /// - exact original → safe to synthesize the full request
    /// - anything else / unreadable → indeterminate; attempt rollback to original; only
    ///   synthesize if rollback re-read confirms original; otherwise interrupted, no synth
    private static func tryAppendStringAXValue(
        text: String,
        focusElement: ActionElement?,
        targetPID: pid_t,
        target: FallbackTarget,
        environment: FallbackEnvironment,
        monitor: InterruptionMonitoring
    ) -> ActionResult? {
        if monitor.isInterrupted {
            return buildSemanticResult(
                method: .keyboard,
                status: .interrupted,
                stateChanged: false,
                targetVerified: false,
                warning: nil,
                degraded: monitor.degraded
            )
        }

        // Re-check target identity before any AX write.
        guard let livePID = environment.targetPID(sessionId: target.sessionId),
              livePID == targetPID,
              (try? environment.sessionOwnedByApp(sessionId: target.sessionId, app: target.app)) == true else {
            return nil
        }

        // Explicit target: only that element. Never substitute the app-focused element.
        // Untargeted: only the target application's currently focused element.
        let candidate: ActionElement?
        if target.targetsElement {
            candidate = focusElement
        } else if let provider = environment as? FocusedElementProviding {
            candidate = provider.focusedElement(forPID: targetPID)
        } else {
            candidate = nil
        }
        guard let element = candidate, element.isLive else { return nil }

        // Typed string capability — never use snapshot (stringifies numbers/bools).
        guard let stringCapable = element as? StringAXValueCapable,
              stringCapable.canSetStringAXValue(),
              let original = stringCapable.stringAXValue() else {
            return nil
        }

        if monitor.isInterrupted {
            return buildSemanticResult(
                method: .keyboard,
                status: .interrupted,
                stateChanged: false,
                targetVerified: false,
                warning: nil,
                degraded: monitor.degraded
            )
        }

        // Re-check identity immediately before the mutating write.
        guard let livePID2 = environment.targetPID(sessionId: target.sessionId),
              livePID2 == targetPID,
              (try? environment.sessionOwnedByApp(sessionId: target.sessionId, app: target.app)) == true else {
            return nil
        }

        let expected = original + text
        var writeFaulted = false
        do {
            try stringCapable.writeStringAXValue(expected)
        } catch {
            writeFaulted = true
        }

        // Always re-read after an attempted write (including throws).
        let after = stringCapable.stringAXValue()

        if let after, after == expected {
            // Confirmed expected value — never synthesize (would double-append).
            var warning = "Typed via settable AXValue append (confirmed)."
            if writeFaulted {
                warning = "AXValue write reported a fault but the re-read confirmed the appended value; no synthesized input was posted."
            }
            return buildSemanticResult(
                method: .accessibility,
                status: monitor.isInterrupted ? .interrupted : .completed,
                stateChanged: after != original,
                targetVerified: true,
                warning: warning,
                degraded: monitor.degraded
            )
        }

        if let after, after == original {
            // Exact original — safe to synthesize the full request.
            return nil
        }

        // Indeterminate / partial / unreadable. Try rollback to original before any synthesis.
        if monitor.isInterrupted {
            return buildSemanticResult(
                method: .accessibility,
                status: .interrupted,
                stateChanged: after.map { $0 != original } ?? true,
                targetVerified: false,
                warning: "AXValue post-state is indeterminate after interruption; synthesized input was skipped to avoid double-append.",
                degraded: monitor.degraded
            )
        }

        // Attempt rollback to the exact original value.
        do {
            try stringCapable.writeStringAXValue(original)
        } catch {
            // Rollback write faulted — still re-read below.
        }
        if let rolled = stringCapable.stringAXValue(), rolled == original {
            // Rollback confirmed — safe to synthesize the full request once.
            return nil
        }

        // Rollback failed or unreadable — never synthesize.
        return buildSemanticResult(
            method: .accessibility,
            status: .interrupted,
            stateChanged: true,
            targetVerified: false,
            warning: "AXValue post-state is indeterminate and could not be restored to the original value; synthesized input was skipped to avoid double-append or clobbering concurrent edits.",
            degraded: monitor.degraded
        )
    }

    private static func buildSemanticResult(
        method: ActionMethod,
        status: ActionStatus,
        stateChanged: Bool,
        targetVerified: Bool,
        warning: String?,
        degraded: Bool
    ) -> ActionResult {
        var notes: [String] = []
        if let warning, !warning.isEmpty { notes.append(warning) }
        if degraded {
            notes.append("User-interruption monitoring is unavailable; physical input may not cancel this action.")
        }
        return ActionResult(
            status: status,
            method: method,
            stateChanged: stateChanged,
            refreshRecommended: true,
            warning: notes.isEmpty ? nil : notes.joined(separator: " "),
            focusChanged: false,
            focusRestored: false,
            targetVerified: targetVerified
        )
    }

    // MARK: - Coordinate resolution

    /// The delivery-ready form of a fallback action, with coordinate points already mapped
    /// to global points.
    private enum ResolvedFallback {
        case keys([KeyChord])
        case text(String)
        case click(point: CGPoint, button: PointerButton, flags: CGEventFlags, clickCount: Int)
        case drag(from: CGPoint, to: CGPoint, button: PointerButton, flags: CGEventFlags)
        case scroll(point: CGPoint, deltaX: Int32, deltaY: Int32, flags: CGEventFlags)

        /// Whether delivery moves the physical pointer (drives the pointer-restore pass).
        var isPointerAction: Bool {
            switch self {
            case .keys, .text: return false
            case .click, .drag, .scroll: return true
            }
        }
    }

    private static func resolveGlobal(
        _ action: FallbackAction,
        target: FallbackTarget,
        environment: FallbackEnvironment
    ) throws -> ResolvedFallback {
        switch action {
        case let .pressKey(chords):
            return .keys(chords)
        case let .typeText(text):
            return .text(text)
        case let .coordinateClick(at, space, button, modifiers, clickCount):
            let point = try globalPoint(at, space: space, target: target, environment: environment)
            return .click(point: point, button: button, flags: modifiers, clickCount: clickCount)
        case let .drag(from, to, space, button, modifiers):
            let fromGlobal = try globalPoint(from, space: space, target: target, environment: environment)
            let toGlobal = try globalPoint(to, space: space, target: target, environment: environment)
            return .drag(from: fromGlobal, to: toGlobal, button: button, flags: modifiers)
        case let .coordinateScroll(at, space, direction, by, count):
            let point = try globalPoint(at, space: space, target: target, environment: environment)
            let deltas = PointerActions.scrollDeltas(direction: direction, by: by, count: count)
            return .scroll(point: point, deltaX: deltas.deltaX, deltaY: deltas.deltaY, flags: [])
        }
    }

    /// Map a point in `space` to global points using the session's captured geometry (§9),
    /// then **verify the mapped point actually falls over the target window** before it can be
    /// posted. `window` needs only the window origin; `screenshot` needs the delivered pixel
    /// size (absent when no screenshot was captured → `window_not_found`).
    ///
    /// Safety gate (§16.3): a synthesized POINTER event is routed by SCREEN LOCATION, not by
    /// which app is frontmost — so `background-only`'s frontmost check does NOT protect a
    /// mouse event. A coordinate that maps outside the target window (the caller passed an
    /// out-of-window point, or the window moved/resized/closed since the capturing
    /// `get_app_state`) would land over another app's window or system UI. We refuse to
    /// deliver unless the mapped global point lies within BOTH the captured frame (the
    /// geometry the caller's coordinate was relative to) AND the window's CURRENT on-screen
    /// frame — otherwise `window_not_found`, never input to the wrong target.
    private static func globalPoint(
        _ point: Point,
        space: CoordinateSpace,
        target: FallbackTarget,
        environment: FallbackEnvironment
    ) throws -> CGPoint {
        guard let geometry = environment.windowGeometry(sessionId: target.sessionId) else {
            throw CUError.windowNotFound(app: target.app, windowId: nil)
        }
        let global = try mapToGlobal(point, space: space, geometry: geometry, target: target)

        // Re-read the window's CURRENT frame; a missing window (closed/off-screen) is unsafe.
        guard let currentFrame = environment.currentWindowFrame(sessionId: target.sessionId) else {
            throw CUError.windowNotFound(app: target.app, windowId: geometry.windowId)
        }
        // The point must sit within the captured frame it was expressed against AND the live
        // frame (so a moved/resized window that would push the point off-target is refused).
        guard geometry.framePoints.contains(x: Double(global.x), y: Double(global.y)),
              currentFrame.contains(x: Double(global.x), y: Double(global.y)) else {
            throw CUError.windowNotFound(app: target.app, windowId: geometry.windowId)
        }
        return global
    }

    /// Pure coordinate-space → global-point mapping (no bounds/staleness check).
    private static func mapToGlobal(
        _ point: Point,
        space: CoordinateSpace,
        geometry: WindowGeometry,
        target: FallbackTarget
    ) throws -> CGPoint {
        switch space {
        case .window:
            return CGPoint(x: point.x + geometry.framePoints.x, y: point.y + geometry.framePoints.y)
        case .screenshot:
            guard let pixels = geometry.screenshotPixels else {
                // No screenshot was delivered for this session, so screenshot-pixel
                // coordinates have nothing to map against.
                throw CUError.windowNotFound(app: target.app, windowId: geometry.windowId)
            }
            let kx = geometry.framePoints.width == 0 ? 0 : Double(pixels.width) / geometry.framePoints.width
            let ky = geometry.framePoints.height == 0 ? 0 : Double(pixels.height) / geometry.framePoints.height
            let wx = kx == 0 ? 0 : point.x / kx
            let wy = ky == 0 ? 0 : point.y / ky
            return CGPoint(x: wx + geometry.framePoints.x, y: wy + geometry.framePoints.y)
        }
    }

    // MARK: - Delivery + result

    private static func deliver(
        _ resolved: ResolvedFallback,
        via synthesizer: InputSynthesizer,
        interruption: InterruptionMonitoring,
        onTarget: TargetGuard
    ) {
        switch resolved {
        case let .keys(chords):
            KeyboardActions.press(chords, via: synthesizer, interruption: interruption, onTarget: onTarget)
        case let .text(text):
            KeyboardActions.type(text, via: synthesizer, interruption: interruption, onTarget: onTarget)
        case let .click(point, button, flags, clickCount):
            PointerActions.click(
                atGlobal: point,
                button: button,
                flags: flags,
                clickCount: clickCount,
                via: synthesizer,
                interruption: interruption,
                onTarget: onTarget
            )
        case let .drag(from, to, button, flags):
            PointerActions.drag(fromGlobal: from, toGlobal: to, button: button, flags: flags, via: synthesizer, interruption: interruption, onTarget: onTarget)
        case let .scroll(point, deltaX, deltaY, flags):
            PointerActions.scroll(atGlobal: point, deltaX: deltaX, deltaY: deltaY, flags: flags, via: synthesizer, interruption: interruption, onTarget: onTarget)
        }
    }

    private static func buildResult(
        action: FallbackAction,
        focus: FocusOutcome,
        interrupted: Bool,
        focusLost: Bool,
        degraded: Bool,
        elementFocused: Bool? = nil,
        targetedDelivery: Bool = false,
        deliveryConfirmed: Bool = false
    ) -> ActionResult {
        let status: ActionStatus
        if interrupted || focusLost {
            // Either a genuine physical event (monitor) or the target becoming unsafe
            // mid-delivery (foreground loss / PID exit) cut the input short.
            status = .interrupted
        } else if focus.delivered {
            status = .completed
        } else {
            // A focus-changing mode could not bring the target frontmost; input was NOT
            // delivered (never to the user's app).
            status = .rejected
        }

        var notes: [String] = []
        if !focus.delivered && !interrupted && !focusLost {
            notes.append("The target could not be brought to the foreground; no input was delivered.")
        }
        if focusLost {
            if targetedDelivery {
                notes.append("The target process exited or changed identity during delivery; the remaining input was not delivered.")
            } else {
                notes.append("The target lost the foreground during delivery; the remaining input was not delivered.")
            }
        }
        if targetedDelivery, focus.delivered, !interrupted, !focusLost, !deliveryConfirmed {
            // postToPid has no acknowledgement. Report unconfirmed delivery honestly unless an
            // existing element-focused/value postcondition already confirmed it.
            notes.append("Process-targeted delivery was attempted without an observable acknowledgement; delivery is unconfirmed.")
        }
        if degraded {
            notes.append("User-interruption monitoring is unavailable; physical input may not cancel this action.")
        }
        let warning = notes.isEmpty ? nil : notes.joined(separator: " ")

        let targetVerified: Bool
        if targetedDelivery {
            // Never claim the target was frontmost or that focus changed for the targeted lane.
            // Only report verified when an existing postcondition confirms delivery.
            targetVerified = deliveryConfirmed && !focusLost && !interrupted
        } else {
            // For a POINTER action, reaching delivery already proved the point sat over the
            // target window (globalPoint's bounds/staleness gate); for KEYBOARD, the guard
            // confirms the target held the foreground throughout. A mid-delivery focus loss
            // forces this false regardless of the pre-delivery activation result.
            targetVerified = focus.targetBecameFrontmost && !focusLost
        }

        return ActionResult(
            status: status,
            method: action.method,
            stateChanged: false,
            refreshRecommended: true,
            warning: warning,
            focusChanged: focus.focusChanged,
            focusRestored: focus.focusRestored,
            targetVerified: targetVerified,
            // §18.6: whether the resolved element (or a descendant) was confirmed to hold
            // keyboard focus before synthesis. Omitted (nil) unless an element was targeted.
            elementFocused: elementFocused
        )
    }
}
