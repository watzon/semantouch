import Foundation
import CoreGraphics
import ComputerUseCore

// Native fallback input model (docs/PROTOCOL.md §§9, 16).
//
// Fallback actions synthesize keyboard/pointer input through the public CGEvent API.
// They are distinct from the semantic action ladder: the engine never auto-escalates
// from a failed semantic action to synthesized input; the caller opts in explicitly.
//
// Every seam here is injectable so the whole decision + delivery pipeline is exercised
// permission-free: no real CGEvent is ever posted in a unit test, and no test needs a
// live event tap, workspace, or Accessibility grant.

// MARK: - Coordinate space (§16 / §9)

/// The coordinate space a coordinate action's `at`/`from`/`to` points are expressed in
/// (§9). `window` (the default) is window points (origin = window top-left); `screenshot`
/// is delivered-screenshot pixels. Both are mapped to global points before a CGEvent is
/// posted.
public enum CoordinateSpace: String, Equatable, Sendable {
    case window
    case screenshot
}

// MARK: - Pointer button

/// The mouse button a pointer action uses.
public enum PointerButton: String, Equatable, Sendable {
    case left
    case right
    case middle

    /// The CoreGraphics button for down/up events.
    public var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    /// The CoreGraphics event types for this button's down / up / drag.
    public var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    public var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    public var dragType: CGEventType {
        switch self {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }
}

// MARK: - Window geometry (coordinate mapping source)

/// The geometry a coordinate action maps its points against, captured by the last
/// `get_app_state` for the session. `framePoints` is the window's GLOBAL-point frame;
/// `screenshotPixels` is the delivered image size (present only when a screenshot was
/// captured — required to map `screenshot`-space points).
public struct WindowGeometry: Equatable, Sendable {
    public var windowId: Int
    public var framePoints: Rect
    public var screenshotPixels: Size?
    public var scale: Double

    public init(windowId: Int, framePoints: Rect, screenshotPixels: Size?, scale: Double) {
        self.windowId = windowId
        self.framePoints = framePoints
        self.screenshotPixels = screenshotPixels
        self.scale = scale
    }
}

// MARK: - Fallback action model

/// One Phase 4 fallback action with its parameters, already parsed from the wire but
/// still in the caller's coordinate space (global-point mapping happens in the lane,
/// against the session's `WindowGeometry`).
public enum FallbackAction: Equatable, Sendable {
    case pressKey(chords: [KeyChord])
    case typeText(String)
    /// Coordinate click. `clickCount` is clamped to 1...3 at the handler/schema boundary.
    case coordinateClick(at: Point, space: CoordinateSpace, button: PointerButton, modifiers: CGEventFlags, clickCount: Int)
    case drag(from: Point, to: Point, space: CoordinateSpace, button: PointerButton, modifiers: CGEventFlags)
    /// Coordinate scroll. `count` is a positive magnitude; fractional values are meaningful for `by: page`.
    case coordinateScroll(at: Point, space: CoordinateSpace, direction: ScrollDirection, by: ScrollGranularity, count: Double)

    /// The wire tool name (`policy_denied.data.tool`, diagnostics).
    public var toolName: String {
        switch self {
        case .pressKey: return "press_key"
        case .typeText: return "type_text"
        case .coordinateClick: return "click"
        case .drag: return "drag"
        case .coordinateScroll: return "scroll"
        }
    }

    /// Keyboard actions report `method: keyboard`; pointer actions `method: pointer`.
    public var method: ActionMethod {
        switch self {
        case .pressKey, .typeText: return .keyboard
        case .coordinateClick, .drag, .coordinateScroll: return .pointer
        }
    }

    /// Whether this action needs the session's window geometry (coordinate actions do;
    /// key/text do not).
    public var needsGeometry: Bool {
        switch self {
        case .pressKey, .typeText: return false
        case .coordinateClick, .drag, .coordinateScroll: return true
        }
    }

    /// Whether this action may use the process-targeted keyboard lane (`CGEvent.postToPid`)
    /// under `background-only` when the target is not frontmost. Only keyboard / key-equivalent
    /// / text synthesis is eligible; pointer, drag, and scroll stay on the global path and
    /// keep the frontmost/geometry gates.
    public var supportsTargetedDelivery: Bool {
        switch self {
        case .pressKey, .typeText: return true
        case .coordinateClick, .drag, .coordinateScroll: return false
        }
    }
}

/// The app/session/interference triple every fallback action carries (§16). Unlike
/// `ElementTarget`, a fallback action targets the app+session (and, for coordinate
/// actions, its window), not a specific element/revision.
///
/// v1.5 (§18.6): `press_key`/`type_text` MAY additionally carry a `revision`+`elementId`
/// pair (valid only together — one without the other is a `-32602` at decode) so the server
/// sets `AXFocused` on that element before synthesizing the keys.
public struct FallbackTarget: Equatable, Sendable {
    public var app: String
    public var sessionId: String
    public var interference: InterferencePolicy
    /// v1.5 (§18.6): the element to pre-focus and the revision it was observed in. Both nil
    /// (no element targeting) or both set (validated per §13.2 steps 3–4 inside the lane).
    public var revision: Int?
    public var elementId: String?

    public init(
        app: String,
        sessionId: String,
        interference: InterferencePolicy = .backgroundOnly,
        revision: Int? = nil,
        elementId: String? = nil
    ) {
        self.app = app
        self.sessionId = sessionId
        self.interference = interference
        self.revision = revision
        self.elementId = elementId
    }

    /// Whether this action pre-focuses a specific element before synthesis (§18.6).
    public var targetsElement: Bool { revision != nil && elementId != nil }
}

// MARK: - Interference decision (§16 decision table)

/// The bounded focus mode a fallback action runs under.
public enum FocusMode: Equatable, Sendable {
    /// No focus change — the target is already frontmost, so input is delivered directly.
    case none
    /// Record the user's frontmost + focused element, activate the target, deliver, then
    /// restore (`allow-brief-focus`).
    case activateRestore
    /// Activate the target and leave it activated (`foreground-takeover`).
    case activateLeave
}

/// The pure interference-policy decision (§16). Given the requested mode and whether the
/// target is already frontmost, decide how (or whether) to deliver. This is the
/// decision table the unit tests pin down; it never silently escalates.
public enum InterferencePlan: Equatable, Sendable {
    /// The target is already frontmost: deliver with no focus change (any mode).
    case deliverInBackground
    /// `background-only` and the target is not frontmost, and targeted delivery is not
    /// available for this action/synthesizer: reject with `focus_required`.
    case focusRequired
    /// `background-only`, target not frontmost, action is keyboard/text, and the synthesizer
    /// exposes process-targeted delivery: post keys to the target pid with no activation and
    /// no silent global/focus escalation.
    case deliverTargeted
    /// `allow-brief-focus`: run a bounded record→activate→deliver→restore transaction.
    case briefFocus
    /// `foreground-takeover`: activate the target and leave it activated.
    case takeover

    /// The focus mode this plan drives (irrelevant for `focusRequired` / `deliverTargeted`).
    public var focusMode: FocusMode {
        switch self {
        case .deliverInBackground, .focusRequired, .deliverTargeted: return .none
        case .briefFocus: return .activateRestore
        case .takeover: return .activateLeave
        }
    }

    /// Decide the plan. If the target is already frontmost, any mode delivers directly
    /// (no focus change). Otherwise `background-only` either refuses (`focusRequired`) or —
    /// when the action and synthesizer both support it — takes the process-targeted lane
    /// (`deliverTargeted`) without activating; `allow-brief-focus` runs a brief transaction,
    /// and `foreground-takeover` activates. Defaults keep existing pure call sites on the
    /// pre-targeted decision table (no silent escalation).
    public static func decide(
        mode: InterferencePolicy,
        targetIsFrontmost: Bool,
        actionSupportsTargetedDelivery: Bool = false,
        synthesizerSupportsTargetedDelivery: Bool = false
    ) -> InterferencePlan {
        if targetIsFrontmost { return .deliverInBackground }
        switch mode {
        case .backgroundOnly:
            if actionSupportsTargetedDelivery && synthesizerSupportsTargetedDelivery {
                return .deliverTargeted
            }
            return .focusRequired
        case .allowBriefFocus: return .briefFocus
        case .foregroundTakeover: return .takeover
        }
    }
}

// MARK: - Target safety guard (§16.3 step 5)

/// Tracks whether the target is still safe to deliver to DURING synthesis. For the global
/// (frontmost) lane a synthesized KEYBOARD event is routed to whatever app is frontmost AT
/// POST TIME, so if a self-activating agent app steals the foreground mid-delivery the
/// remaining events would type into the intruder. For the process-targeted lane the guard
/// instead re-checks session ownership / PID identity (postToPid does not require frontmost).
/// The delivery loops consult this guard before every input unit, stopping immediately (a
/// drag additionally releases the button) if the predicate fails. The executor then reports
/// the action as `interrupted` with `targetVerified = false`.
public final class TargetGuard {
    private let predicate: () -> Bool
    /// Whether the target became unsafe at any point during delivery (latched).
    public private(set) var lostTarget = false

    public init(_ predicate: @escaping () -> Bool = { true }) { self.predicate = predicate }

    /// True while the target is still safe; latches `lostTarget` on first failure.
    public func stillOnTarget() -> Bool {
        if lostTarget { return false }
        if predicate() { return true }
        lostTarget = true
        return false
    }

    /// A guard that always reports the target safe — for callers that do not supply a
    /// predicate (e.g. focused unit tests of the delivery loops).
    public static var alwaysOn: TargetGuard { TargetGuard() }
}

// MARK: - Input synthesizer seam

/// The seam every synthesized CGEvent goes through. The live conformance
/// (`CGEventSynthesizer`) posts PUBLIC, tagged CGEvents; unit tests supply a recording
/// fake so no real event is ever posted. Every emitted event MUST be tagged as ours
/// (`FallbackTag`) so the interruption monitor never mistakes our own input for the user.
/// Global (session-tap) delivery only — process-targeted keyboard delivery is a separate
/// capability (`ProcessTargetedInputSynthesizer`) so a synthesizer without that lane cannot
/// silently fall back to global posting.
public protocol InputSynthesizer: AnyObject {
    func keyDown(keyCode: CGKeyCode, flags: CGEventFlags)
    func keyUp(keyCode: CGKeyCode, flags: CGEventFlags)
    /// Emit one literal character/string via `CGEventKeyboardSetUnicodeString` (reliable
    /// for arbitrary Unicode, independent of the current keyboard layout).
    func typeUnicode(_ string: String)
    func mouseDown(at: CGPoint, button: PointerButton, flags: CGEventFlags)
    func mouseUp(at: CGPoint, button: PointerButton, flags: CGEventFlags)
    func mouseDrag(to: CGPoint, button: PointerButton, flags: CGEventFlags)
    func scroll(at: CGPoint, deltaX: Int32, deltaY: Int32, flags: CGEventFlags)
    /// The physical pointer's current global-point location, or `nil` when unreadable.
    /// Read before a pointer action so the user's cursor can be returned afterward.
    func pointerLocation() -> CGPoint?
    /// Move the pointer to a global point with no button change (a tagged `.mouseMoved`).
    /// Public CGEvent pointer delivery necessarily moves the physical cursor (§16.7);
    /// returning it afterward is the strongest noninterference the public surface allows.
    func movePointer(to: CGPoint)
}

/// Optional capability: encode CoreGraphics `mouseEventClickState` (1...3) on the next
/// mouse down/up posted by this synthesizer. Global-only; process-targeted bindings ignore it.
/// PointerActions sets the state before each unit of a multi-click so both down and up carry
/// the same click-state field. Synthesizers without this capability still deliver the
/// down/up sequence (single-click semantics).
public protocol ClickStateAwareSynthesizer: AnyObject {
    /// Apply `clickState` to the next mouse down and up events (cleared after each pair
    /// or after the next mouse event if the implementor chooses).
    func prepareMouseClickState(_ clickState: Int64)
}

/// Optional capability: post keyboard / text events to a specific process via public
/// `CGEvent.postToPid` without activating it. PID is always an explicit argument — never a
/// mutable field on a shared synthesizer — so concurrent callers cannot misroute events.
/// Pointer/drag/scroll are intentionally absent: those stay on the global session-tap path.
public protocol ProcessTargetedInputSynthesizer: AnyObject {
    func keyDown(keyCode: CGKeyCode, flags: CGEventFlags, toPid: pid_t)
    func keyUp(keyCode: CGKeyCode, flags: CGEventFlags, toPid: pid_t)
    func typeUnicode(_ string: String, toPid: pid_t)
}

// MARK: - Optional AX reliability capabilities (coordinate press + string AXValue)

/// Preferred activation from optional AX coordinate-click resolution.
///
/// The resolver never posts input: the executor either performs `AXPress` on
/// `pressElement` (when `.press`) or synthesizes a pointer click at `anchor`
/// (when `.coordinate` / press failure).
public enum AXCoordinateClickActivation: String, Equatable, Sendable {
    case press
    case coordinate
}

/// Structured result of optional live coordinate→AX resolution.
///
/// Produced only after policy / session / ownership / PID / window-bounds gates.
/// Never posts input. `pressElement` is the only object the executor may
/// `AXPress`; on press failure the executor synthesizes at `anchor` (revalidated),
/// never at an unrelated candidate or the original miss point when an anchor exists.
public struct AXCoordinateClickResolution {
    public var activation: AXCoordinateClickActivation
    /// Global-point safe anchor for coordinate fallback / evidence.
    public var anchor: Point?
    /// Stable reason slug from the resolver (`direct_press`, `summary_parent_press`, …).
    public var reason: String
    /// Deterministic evidence notes for warnings / diagnostics.
    public var evidenceNotes: [String]
    /// Element to press when `activation == .press`. Re-validate pid/frame before use.
    public var pressElement: ActionElement?
    /// Selected element's owning pid when known (required equal to the target pid before press).
    public var selectedPID: pid_t?
    /// Selected element's global frame when known (must be fully inside the target window).
    public var selectedFrame: Rect?

    public init(
        activation: AXCoordinateClickActivation,
        anchor: Point? = nil,
        reason: String,
        evidenceNotes: [String] = [],
        pressElement: ActionElement? = nil,
        selectedPID: pid_t? = nil,
        selectedFrame: Rect? = nil
    ) {
        self.activation = activation
        self.anchor = anchor
        self.reason = reason
        self.evidenceNotes = evidenceNotes
        self.pressElement = pressElement
        self.selectedPID = selectedPID
        self.selectedFrame = selectedFrame
    }
}

/// Optional capability: resolve a global left single-click via AX (hit-test + selection).
///
/// Environments without this capability keep pure CGEvent coordinate delivery.
/// Existing `FallbackEnvironment` fakes remain source-compatible (no required methods).
/// Class-bound so live adapters and test fakes can share identity without struct boxing.
public protocol CoordinateClickResolving: AnyObject {
    /// Resolve `point` (global points) against `windowBounds` for `expectedPID`.
    /// Returns `nil` on resolver miss / unavailable AX so the executor keeps the
    /// original mapped coordinate. Must not post input or perform `AXPress`.
    func resolveCoordinateClick(
        atGlobal point: CGPoint,
        windowBounds: Rect,
        expectedPID: pid_t
    ) -> AXCoordinateClickResolution?
}

/// Optional capability: look up the target process's currently focused UI element.
///
/// Used by background-safe `type_text` AXValue append when no element was explicitly
/// targeted. Environments without this capability skip the focused-element lane.
public protocol FocusedElementProviding: AnyObject {
    /// The process's `AXFocusedUIElement`, wrapped as an `ActionElement`, or `nil`.
    /// The returned element MUST belong to `pid` (caller re-validates before write).
    func focusedElement(forPID pid: pid_t) -> ActionElement?
}

/// Optional capability: read/write `AXValue` as a real String (not a stringified number/bool).
///
/// `ActionElement.snapshot` stringifies every value type, so it cannot prove the live
/// attribute is a String. String append for `type_text` requires this capability.
public protocol StringAXValueCapable: AnyObject {
    /// Live `AXValue` when it is a String; `nil` when absent or a non-string type.
    func stringAXValue() -> String?
    /// Whether `AXValue` is settable on this element.
    func canSetStringAXValue() -> Bool
    /// Write a String into `AXValue`.
    func writeStringAXValue(_ value: String) throws
}

/// Binds a `ProcessTargetedInputSynthesizer` to one resolved target PID for a single
/// delivery. Implements `InputSynthesizer` so `KeyboardActions` can emit through the usual
/// path without storing a mutable PID on the shared live synthesizer. Pointer methods are
/// unreachable for the targeted lane (only keys/text are eligible) and are no-ops.
public final class ProcessTargetedSynthesizerBinding: InputSynthesizer {
    private let base: ProcessTargetedInputSynthesizer
    private let pid: pid_t

    public init(base: ProcessTargetedInputSynthesizer, pid: pid_t) {
        self.base = base
        self.pid = pid
    }

    public func keyDown(keyCode: CGKeyCode, flags: CGEventFlags) {
        base.keyDown(keyCode: keyCode, flags: flags, toPid: pid)
    }

    public func keyUp(keyCode: CGKeyCode, flags: CGEventFlags) {
        base.keyUp(keyCode: keyCode, flags: flags, toPid: pid)
    }

    public func typeUnicode(_ string: String) {
        base.typeUnicode(string, toPid: pid)
    }

    public func mouseDown(at: CGPoint, button: PointerButton, flags: CGEventFlags) {}
    public func mouseUp(at: CGPoint, button: PointerButton, flags: CGEventFlags) {}
    public func mouseDrag(to: CGPoint, button: PointerButton, flags: CGEventFlags) {}
    public func scroll(at: CGPoint, deltaX: Int32, deltaY: Int32, flags: CGEventFlags) {}
    public func pointerLocation() -> CGPoint? { nil }
    public func movePointer(to: CGPoint) {}
}

/// The distinctive tag every synthesized event carries in its
/// `CGEventField.eventSourceUserData`, so a passive tap can tell our own input apart from
/// genuine physical user input (docs/SECURITY.md §6).
public enum FallbackTag {
    /// An arbitrary, distinctive constant. "OMPCU" in ASCII-ish hex plus a version nibble.
    public static let userData: Int64 = 0x4F4D50_43550001
}
