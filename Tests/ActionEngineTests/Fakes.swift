import Foundation
import CoreGraphics
import ComputerUseCore
@testable import ActionEngine

// Permission-free test doubles for the ActionEngine seams. No Accessibility grant,
// no live AXUIElement — every semantic-action and executor path runs against these.

/// A fake `ActionElement` whose advertised actions, settable attributes, snapshot
/// values, named sub-elements, and children are all configurable, and which records
/// every mutation it receives.
final class FakeActionElement: ActionElement {
    var live = true
    var roleValue: String?
    var actions: [String] = []
    var settable: Set<String> = []
    /// Stringified attribute snapshots (`AXValue`, `AXSelectedText`, scrollbar `AXValue`, …).
    var attributes: [String: String] = [:]
    var namedElements: [String: FakeActionElement] = [:]
    var childElements: [FakeActionElement] = []

    /// Optional side effect run when an action is performed (e.g. toggle a value).
    var onPerform: ((String) -> Void)?
    /// When set, `perform` throws it (simulates an AX fault).
    var performError: Error?
    /// v1.5 (§18.6): what `holdsKeyboardFocus()` reports (the AXFocusedUIElement re-read result).
    var focusConfirmed = false

    // Recording.
    private(set) var performed: [String] = []
    private(set) var wroteValue: ActionValue?
    private(set) var wroteRange: (location: Int, length: Int)?
    /// v1.5 (§18.5/§18.6): the number of `setKeyboardFocus()` calls received.
    private(set) var focusRequests = 0

    init(
        role: String? = nil,
        actions: [String] = [],
        settable: Set<String> = [],
        attributes: [String: String] = [:]
    ) {
        self.roleValue = role
        self.actions = actions
        self.settable = settable
        self.attributes = attributes
    }

    var isLive: Bool { live }
    var role: String? { roleValue }
    func actionNames() -> [String] { actions }

    func perform(_ action: String) throws {
        if let performError { throw performError }
        performed.append(action)
        onPerform?(action)
    }

    func isSettable(_ attribute: String) -> Bool { settable.contains(attribute) }
    func snapshot(_ attribute: String) -> String? { attributes[attribute] }

    func writeValue(_ value: ActionValue) throws {
        wroteValue = value
        switch value {
        case let .string(string): attributes[AXActionName.value] = string
        case let .number(number): attributes[AXActionName.value] = FakeActionElement.decimal(number)
        case let .boolean(flag): attributes[AXActionName.value] = flag ? "1" : "0"
        }
    }

    func writeSelectedRange(location: Int, length: Int) throws {
        wroteRange = (location, length)
        attributes[AXActionName.selectedText] = "sel(\(location),\(length))"
    }

    func element(for attribute: String) -> ActionElement? { namedElements[attribute] }
    func children() -> [ActionElement] { childElements }

    func setKeyboardFocus() -> Bool {
        focusRequests += 1
        // Model a settable AXFocused: the write "takes" iff the attribute is marked settable.
        return settable.contains(AXActionName.focused)
    }

    func holdsKeyboardFocus() -> Bool { focusConfirmed }

    static func decimal(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
        return String(number)
    }
}

/// A fake `ActionEnvironment` that drives the executor's validation branches without
/// any live state.
final class FakeActionEnvironment: ActionEnvironment {
    var denyReason: PolicyDenyReason?
    var policyError: Error?
    /// sessionId → current revision (absent ⇒ unknown/ended session).
    var revisions: [String: Int] = [:]
    /// "sessionId/elementId" → element (absent ⇒ resolveElement throws stale_element).
    var elements: [String: ActionElement] = [:]
    /// Whether a session is owned by the gated app (§13.5). Default `true` (the
    /// consistent path); set `false` to drive the confused-deputy rejection branch.
    var sessionOwnedByAppResult = true

    private(set) var policyChecks: [String] = []
    private(set) var ownershipChecks: [String] = []

    func policyCheck(app: String) throws -> PolicyDenyReason? {
        policyChecks.append(app)
        if let policyError { throw policyError }
        return denyReason
    }

    func currentRevision(sessionId: String) -> Int? { revisions[sessionId] }

    func sessionOwnedByApp(sessionId: String, app: String) throws -> Bool {
        ownershipChecks.append(sessionId)
        return sessionOwnedByAppResult
    }

    func resolveElement(sessionId: String, elementId: String, revision: Int) throws -> ActionElement {
        if let element = elements["\(sessionId)/\(elementId)"] { return element }
        throw CUError.staleElement(sessionId: sessionId, elementId: elementId, revision: revision)
    }
}

/// A trivial `ActionEnvironment` that allows everything and resolves one element, so
/// action-implementation tests can go through the full executor when desired.
func target(app: String = "computer-use-fixture", session: String = "s1", revision: Int = 1, element: String = "e1") -> ElementTarget {
    ElementTarget(app: app, sessionId: session, revision: revision, elementId: element)
}

// MARK: - Phase 4 fallback fakes

/// A recording `InputSynthesizer` (+ optional `ProcessTargetedInputSynthesizer`): captures
/// every emitted event and never posts a real CGEvent. `onEmit` lets a test inject an
/// interruption mid-stream. Targeted key/text events record the explicit PID so tests can
/// prove the targeted lane was used without activation.
final class FakeSynthesizer: InputSynthesizer, ProcessTargetedInputSynthesizer {
    enum Event: Equatable {
        case keyDown(CGKeyCode, CGEventFlags)
        case keyUp(CGKeyCode, CGEventFlags)
        case type(String)
        case targetedKeyDown(CGKeyCode, CGEventFlags, pid_t)
        case targetedKeyUp(CGKeyCode, CGEventFlags, pid_t)
        case targetedType(String, pid_t)
        case mouseDown(CGPoint, PointerButton)
        case mouseUp(CGPoint, PointerButton)
        case mouseDrag(CGPoint, PointerButton)
        case scroll(CGPoint, Int32, Int32)
        case movePointer(CGPoint)
    }

    private(set) var events: [Event] = []
    /// Optional hook run after each emitted event (e.g. to flip an interruption flag).
    var onEmit: (() -> Void)?
    /// The pointer position `pointerLocation()` reports. Defaults to `nil` (unreadable
    /// pointer → no restore move) so event-sequence goldens see exactly the delivered
    /// input; restore tests opt in by setting a location.
    var reportedPointerLocation: CGPoint?
    /// When false, this fake does NOT conform as a usable targeted synthesizer from the
    /// executor's perspective: tests set this by wrapping a non-targeted stand-in. The
    /// recording methods below still exist for direct unit use; the executor only casts
    /// `as? ProcessTargetedInputSynthesizer`, so disable via a separate type when needed.
    /// Kept for documentation of the dual-lane recording surface.

    private func record(_ event: Event) {
        events.append(event)
        onEmit?()
    }

    func keyDown(keyCode: CGKeyCode, flags: CGEventFlags) { record(.keyDown(keyCode, flags)) }
    func keyUp(keyCode: CGKeyCode, flags: CGEventFlags) { record(.keyUp(keyCode, flags)) }
    func typeUnicode(_ string: String) { record(.type(string)) }

    func keyDown(keyCode: CGKeyCode, flags: CGEventFlags, toPid pid: pid_t) {
        record(.targetedKeyDown(keyCode, flags, pid))
    }
    func keyUp(keyCode: CGKeyCode, flags: CGEventFlags, toPid pid: pid_t) {
        record(.targetedKeyUp(keyCode, flags, pid))
    }
    func typeUnicode(_ string: String, toPid pid: pid_t) {
        record(.targetedType(string, pid))
    }

    func mouseDown(at: CGPoint, button: PointerButton, flags: CGEventFlags) { record(.mouseDown(at, button)) }
    func mouseUp(at: CGPoint, button: PointerButton, flags: CGEventFlags) { record(.mouseUp(at, button)) }
    func mouseDrag(to: CGPoint, button: PointerButton, flags: CGEventFlags) { record(.mouseDrag(to, button)) }
    func scroll(at: CGPoint, deltaX: Int32, deltaY: Int32, flags: CGEventFlags) { record(.scroll(at, deltaX, deltaY)) }
    func pointerLocation() -> CGPoint? { reportedPointerLocation }
    func movePointer(to point: CGPoint) { record(.movePointer(point)) }
}

/// Global-only synthesizer: does NOT conform to `ProcessTargetedInputSynthesizer`, so the
/// executor cannot take the targeted lane and must return `focus_required` for
/// background-only non-frontmost keyboard when only this synthesizer is available.
final class GlobalOnlyFakeSynthesizer: InputSynthesizer {
    let inner = FakeSynthesizer()

    var events: [FakeSynthesizer.Event] { inner.events }
    var onEmit: (() -> Void)? {
        get { inner.onEmit }
        set { inner.onEmit = newValue }
    }
    var reportedPointerLocation: CGPoint? {
        get { inner.reportedPointerLocation }
        set { inner.reportedPointerLocation = newValue }
    }

    func keyDown(keyCode: CGKeyCode, flags: CGEventFlags) { inner.keyDown(keyCode: keyCode, flags: flags) }
    func keyUp(keyCode: CGKeyCode, flags: CGEventFlags) { inner.keyUp(keyCode: keyCode, flags: flags) }
    func typeUnicode(_ string: String) { inner.typeUnicode(string) }
    func mouseDown(at: CGPoint, button: PointerButton, flags: CGEventFlags) { inner.mouseDown(at: at, button: button, flags: flags) }
    func mouseUp(at: CGPoint, button: PointerButton, flags: CGEventFlags) { inner.mouseUp(at: at, button: button, flags: flags) }
    func mouseDrag(to: CGPoint, button: PointerButton, flags: CGEventFlags) { inner.mouseDrag(to: to, button: button, flags: flags) }
    func scroll(at: CGPoint, deltaX: Int32, deltaY: Int32, flags: CGEventFlags) { inner.scroll(at: at, deltaX: deltaX, deltaY: deltaY, flags: flags) }
    func pointerLocation() -> CGPoint? { inner.pointerLocation() }
    func movePointer(to point: CGPoint) { inner.movePointer(to: point) }
}

/// A fake `WorkspaceControlling` that models frontmost/activate/record/restore with
/// configurable behavior, and records what it was asked to do.
final class FakeWorkspace: WorkspaceControlling {
    var frontmostPID: pid_t?
    var frontmostAppName: String?
    /// When true, `activate(pid:)` succeeds and makes that pid frontmost.
    var activationBringsFrontmost = true
    /// When true, the AX raise fallback (FIX B) foregrounds the target; default `false` so an
    /// activation failure is not silently rescued unless a test opts in.
    var axRaiseBringsFrontmost = false
    /// What `raiseViaAccessibility` returns (the AX call succeeded), independent of whether it
    /// actually reaches frontmost. Defaults to `axRaiseBringsFrontmost` unless set explicitly.
    var axRaiseReturns: Bool?
    /// The token `recordFocusedElement()` returns (nil ⇒ nothing recordable).
    var recordReturns: FocusedElementToken? = FocusedElementToken(payload: "focused")
    /// Whether `restoreFocusedElement` reports success.
    var restoreReturns = true

    private(set) var activatedPIDs: [pid_t] = []
    private(set) var axRaisedPIDs: [pid_t] = []
    private(set) var recordCount = 0
    private(set) var restoredTokens: [FocusedElementToken] = []

    init(frontmostPID: pid_t? = nil, frontmostAppName: String? = nil) {
        self.frontmostPID = frontmostPID
        self.frontmostAppName = frontmostAppName
    }

    func activate(pid: pid_t) -> Bool {
        activatedPIDs.append(pid)
        if activationBringsFrontmost { frontmostPID = pid }
        return activationBringsFrontmost
    }

    func raiseViaAccessibility(pid: pid_t) -> Bool {
        axRaisedPIDs.append(pid)
        if axRaiseBringsFrontmost { frontmostPID = pid }
        return axRaiseReturns ?? axRaiseBringsFrontmost
    }

    func recordFocusedElement() -> FocusedElementToken? {
        recordCount += 1
        return recordReturns
    }

    func restoreFocusedElement(_ token: FocusedElementToken) -> Bool {
        restoredTokens.append(token)
        return restoreReturns
    }
}

/// A fake `FallbackEnvironment` that drives the executor's fallback branches without any
/// live state, workspace, tap, or CGEvent posting.
final class FakeFallbackEnvironment: FallbackEnvironment {
    var denyReason: PolicyDenyReason?
    var policyError: Error?
    var revisions: [String: Int] = [:]
    var sessionOwnedByAppResult = true
    var pids: [String: pid_t] = [:]
    var geometries: [String: WindowGeometry] = [:]
    /// Explicit current window frames (the live coordinate-safety staleness source). When a
    /// session has no explicit entry, `currentWindowFrame` falls back to the captured
    /// geometry frame (i.e. the window has not moved). Add a session id to
    /// `missingCurrentFrames` to model a closed/off-screen window (returns `nil`).
    var currentFrames: [String: Rect] = [:]
    var missingCurrentFrames: Set<String> = []
    /// v1.5 (§18.6): "sessionId/elementId" → element to resolve for element-targeted keys
    /// (absent ⇒ resolveElement throws stale_element).
    var elements: [String: ActionElement] = [:]

    let fakeWorkspace: FakeWorkspace
    let fakeSynthesizer: FakeSynthesizer
    /// Optional global-only synthesizer stand-in. When set, `synthesizer` returns this instead
    /// of `fakeSynthesizer` so the executor cannot cast to `ProcessTargetedInputSynthesizer`.
    let globalOnlySynthesizer: GlobalOnlyFakeSynthesizer?
    let monitor: InterruptionState

    private(set) var policyChecks: [String] = []

    init(
        workspace: FakeWorkspace = FakeWorkspace(),
        synthesizer: FakeSynthesizer = FakeSynthesizer(),
        globalOnlySynthesizer: GlobalOnlyFakeSynthesizer? = nil,
        interruption: InterruptionState = InterruptionState()
    ) {
        self.fakeWorkspace = workspace
        self.fakeSynthesizer = synthesizer
        self.globalOnlySynthesizer = globalOnlySynthesizer
        self.monitor = interruption
    }

    // ActionEnvironment
    func policyCheck(app: String) throws -> PolicyDenyReason? {
        policyChecks.append(app)
        if let policyError { throw policyError }
        return denyReason
    }

    func currentRevision(sessionId: String) -> Int? { revisions[sessionId] }

    func sessionOwnedByApp(sessionId: String, app: String) throws -> Bool { sessionOwnedByAppResult }

    func resolveElement(sessionId: String, elementId: String, revision: Int) throws -> ActionElement {
        // v1.5 (§18.6): element-targeted keys resolve here; an absent entry is stale_element.
        if let element = elements["\(sessionId)/\(elementId)"] { return element }
        throw CUError.staleElement(sessionId: sessionId, elementId: elementId, revision: revision)
    }

    // FallbackEnvironment
    func targetPID(sessionId: String) -> pid_t? { pids[sessionId] }
    func windowGeometry(sessionId: String) -> WindowGeometry? { geometries[sessionId] }
    func currentWindowFrame(sessionId: String) -> Rect? {
        if missingCurrentFrames.contains(sessionId) { return nil }
        return currentFrames[sessionId] ?? geometries[sessionId]?.framePoints
    }
    var workspace: WorkspaceControlling { fakeWorkspace }
    var synthesizer: InputSynthesizer { globalOnlySynthesizer ?? fakeSynthesizer }
    var interruption: InterruptionMonitoring { monitor }
}

/// A fallback target with defaults for the fixture.
func fallbackTarget(
    app: String = "computer-use-fixture",
    session: String = "s1",
    interference: InterferencePolicy = .backgroundOnly
) -> FallbackTarget {
    FallbackTarget(app: app, sessionId: session, interference: interference)
}

/// A default window geometry for coordinate-mapping tests: window at global (100, 200),
/// 400×300 points, delivered as 800×600 screenshot pixels (2× scale).
func fixtureGeometry(
    windowId: Int = 7,
    frame: Rect = Rect(x: 100, y: 200, width: 400, height: 300),
    screenshotPixels: Size? = Size(width: 800, height: 600),
    scale: Double = 2.0
) -> WindowGeometry {
    WindowGeometry(windowId: windowId, framePoints: frame, screenshotPixels: screenshotPixels, scale: scale)
}
