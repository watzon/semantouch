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

    /// The CoreGraphics button for down/up events.
    public var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        }
    }

    /// The CoreGraphics event types for this button's down / up / drag.
    public var downType: CGEventType { self == .left ? .leftMouseDown : .rightMouseDown }
    public var upType: CGEventType { self == .left ? .leftMouseUp : .rightMouseUp }
    public var dragType: CGEventType { self == .left ? .leftMouseDragged : .rightMouseDragged }
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
    case coordinateClick(at: Point, space: CoordinateSpace, button: PointerButton, modifiers: CGEventFlags)
    case drag(from: Point, to: Point, space: CoordinateSpace, button: PointerButton, modifiers: CGEventFlags)
    case coordinateScroll(at: Point, space: CoordinateSpace, direction: ScrollDirection, by: ScrollGranularity, count: Int)

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
    /// `background-only` and the target is not frontmost: reject with `focus_required`.
    case focusRequired
    /// `allow-brief-focus`: run a bounded record→activate→deliver→restore transaction.
    case briefFocus
    /// `foreground-takeover`: activate the target and leave it activated.
    case takeover

    /// The focus mode this plan drives (irrelevant for `focusRequired`).
    public var focusMode: FocusMode {
        switch self {
        case .deliverInBackground, .focusRequired: return .none
        case .briefFocus: return .activateRestore
        case .takeover: return .activateLeave
        }
    }

    /// Decide the plan. If the target is already frontmost, any mode delivers directly
    /// (no focus change). Otherwise `background-only` refuses (`focusRequired`),
    /// `allow-brief-focus` runs a brief transaction, and `foreground-takeover` activates.
    public static func decide(mode: InterferencePolicy, targetIsFrontmost: Bool) -> InterferencePlan {
        if targetIsFrontmost { return .deliverInBackground }
        switch mode {
        case .backgroundOnly: return .focusRequired
        case .allowBriefFocus: return .briefFocus
        case .foregroundTakeover: return .takeover
        }
    }
}

// MARK: - Target foreground guard (§16.3 step 5)

/// Tracks whether the target still holds the foreground DURING delivery. A synthesized
/// KEYBOARD event is routed to whatever app is frontmost AT POST TIME, so if a self-activating
/// agent app (env note: Orca/Pindrop churn frontmost) steals the foreground mid-delivery, the
/// remaining events would type into the intruder — wrong-target input. A self-activation posts
/// no HID event through the session tap, so the interruption monitor cannot catch it; the
/// delivery loops consult this guard before every input unit instead, stopping immediately (a
/// drag additionally releases the button) if the target is no longer frontmost. The executor
/// then reports the action as `interrupted` with `targetVerified = false`.
public final class TargetGuard {
    private let predicate: () -> Bool
    /// Whether the target lost the foreground at any point during delivery (latched).
    public private(set) var lostTarget = false

    public init(_ predicate: @escaping () -> Bool = { true }) { self.predicate = predicate }

    /// True while the target still holds the foreground; latches `lostTarget` on first loss.
    public func stillOnTarget() -> Bool {
        if lostTarget { return false }
        if predicate() { return true }
        lostTarget = true
        return false
    }

    /// A guard that always reports the target on-foreground — for callers that do not supply a
    /// predicate (e.g. focused unit tests of the delivery loops).
    public static var alwaysOn: TargetGuard { TargetGuard() }
}

// MARK: - Input synthesizer seam

/// The seam every synthesized CGEvent goes through. The live conformance
/// (`CGEventSynthesizer`) posts PUBLIC, tagged CGEvents; unit tests supply a recording
/// fake so no real event is ever posted. Every emitted event MUST be tagged as ours
/// (`FallbackTag`) so the interruption monitor never mistakes our own input for the user.
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

/// The distinctive tag every synthesized event carries in its
/// `CGEventField.eventSourceUserData`, so a passive tap can tell our own input apart from
/// genuine physical user input (docs/SECURITY.md §6).
public enum FallbackTag {
    /// An arbitrary, distinctive constant. "OMPCU" in ASCII-ish hex plus a version nibble.
    public static let userData: Int64 = 0x4F4D50_43550001
}
