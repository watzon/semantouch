import Foundation
import CoreGraphics
import ComputerUseCore

// The live `InputSynthesizer` + `ProcessTargetedInputSynthesizer`: posts public, tagged
// CGEvents (clean-room: no SAI or private frameworks). Every emitted event carries
// `FallbackTag.userData` in its `eventSourceUserData` field so the passive interruption tap
// can tell our own input apart from genuine physical input. This type is impure and is never
// exercised by the permission-free unit tests (those use a recording fake).
//
// Delivery target:
// - Global lane (`InputSynthesizer`): events are posted to the session event tap. Coordinate
//   events land at the given global point; keyboard events go to the frontmost app. The
//   interference layer guarantees the target is frontmost (already, or via a focus
//   transaction) before any event is posted — under `background-only` a non-frontmost target
//   is rejected with `focus_required` for ineligible actions rather than risking input
//   reaching the wrong app.
// - Targeted keyboard lane (`ProcessTargetedInputSynthesizer`): key/text events are posted
//   with `CGEvent.postToPid` to an explicit target PID (no activation, no mutable PID state
//   on this shared instance). Pointer/drag/scroll remain global-only.
public final class CGEventSynthesizer: InputSynthesizer, ProcessTargetedInputSynthesizer, ClickStateAwareSynthesizer {
    private let source: CGEventSource?
    /// Pending CoreGraphics click-state for the next mouse down/up pair (1...3).
    private var pendingClickState: Int64 = 1

    public init() {
        // A private-state source keeps our synthetic events off the shared HID/session
        // modifier state; the userData tag is what the tap actually matches on.
        let src = CGEventSource(stateID: .privateState)
        // Stamp the tag on the SOURCE as well as per-event (`tagAndPost`). The source-level
        // user data is the canonical, robust carrier: every event created from this source
        // inherits it, so the tag survives `event.post(...)` and re-observation at the passive
        // tap even if a per-event field override did not. This is what lets the interruption
        // monitor rely on the tag alone (no time-based keyboard debounce) without ever
        // mistaking our own dense synthetic input for the user's. If the tag somehow did not
        // survive the round trip, the failure mode is self-interruption — the SAFE over-yield
        // direction (fallback actions stop early) — never runaway input the user cannot cancel.
        src?.userData = FallbackTag.userData
        self.source = src
    }

    public func prepareMouseClickState(_ clickState: Int64) {
        pendingClickState = max(1, min(3, clickState))
    }

    // MARK: - Keyboard (global)

    public func keyDown(keyCode: CGKeyCode, flags: CGEventFlags) {
        postKey(keyCode: keyCode, flags: flags, down: true, toPid: nil)
    }

    public func keyUp(keyCode: CGKeyCode, flags: CGEventFlags) {
        postKey(keyCode: keyCode, flags: flags, down: false, toPid: nil)
    }

    public func typeUnicode(_ string: String) {
        typeUnicode(string, toPid: nil)
    }

    // MARK: - Keyboard (process-targeted)

    public func keyDown(keyCode: CGKeyCode, flags: CGEventFlags, toPid pid: pid_t) {
        postKey(keyCode: keyCode, flags: flags, down: true, toPid: pid)
    }

    public func keyUp(keyCode: CGKeyCode, flags: CGEventFlags, toPid pid: pid_t) {
        postKey(keyCode: keyCode, flags: flags, down: false, toPid: pid)
    }

    public func typeUnicode(_ string: String, toPid pid: pid_t) {
        typeUnicode(string, toPid: Optional(pid))
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags, down: Bool, toPid: pid_t?) {
        // A modifier chord posts a modifier keyDown and a matching keyUp (KeyboardActions.emit).
        // If a modifier RELEASE were ever silently dropped, that modifier would be stranded
        // held-down at the OS level and corrupt every subsequent user keystroke — a far worse
        // failure than the flag-only chord bug this path replaced. CGEvent construction is
        // effectively infallible for a valid keycode (and keyDown/keyUp construct identically),
        // but to make a dropped release impossible we fall back to a SOURCE-LESS construction if
        // the primary (private-state source) construction ever yields nil. Both are stamped in
        // `tagAndPost`, so neither can be mistaken for physical input (no self-interruption).
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            ?? CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
        else {
            // Doubly-impossible in practice; a stuck modifier is the failure mode if it ever
            // happens mid-chord, so surface it on stderr (never stdout — protocol only).
            FileHandle.standardError.write(Data(
                "CGEventSynthesizer: dropped key event (keyCode=\(keyCode), keyDown=\(down)); a modifier may remain held\n".utf8
            ))
            return
        }
        event.flags = flags
        tagAndPost(event, toPid: toPid)
    }

    private func typeUnicode(_ string: String, toPid: pid_t?) {
        // Reliable arbitrary-Unicode entry, layout-independent: a keyDown/keyUp pair each
        // carrying the literal string via CGEventKeyboardSetUnicodeString.
        let utf16 = Array(string.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            utf16.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            tagAndPost(event, toPid: toPid)
        }
    }

    // MARK: - Pointer (global only)

    public func mouseDown(at point: CGPoint, button: PointerButton, flags: CGEventFlags) {
        postMouse(type: button.downType, at: point, button: button, flags: flags, clickState: pendingClickState)
    }

    public func mouseUp(at point: CGPoint, button: PointerButton, flags: CGEventFlags) {
        // Consume the pending click-state on the matching up so the next click starts fresh.
        let state = pendingClickState
        pendingClickState = 1
        postMouse(type: button.upType, at: point, button: button, flags: flags, clickState: state)
    }

    public func mouseDrag(to point: CGPoint, button: PointerButton, flags: CGEventFlags) {
        // Drag events carry clickState 1 (a held press, not a multi-click sequence).
        postMouse(type: button.dragType, at: point, button: button, flags: flags, clickState: 1)
    }

    private func postMouse(
        type: CGEventType,
        at point: CGPoint,
        button: PointerButton,
        flags: CGEventFlags,
        clickState: Int64
    ) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button.cgButton
        ) else { return }
        if !flags.isEmpty { event.flags = flags }
        // CoreGraphics multi-click: both down and up must carry the same clickState
        // (1, 2, or 3). Without this field a double-click is just two single clicks.
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        tagAndPost(event, toPid: nil)
    }

    public func scroll(at point: CGPoint, deltaX: Int32, deltaY: Int32, flags: CGEventFlags) {
        // Position the pointer so the scroll targets the intended location, then post a
        // line-unit scroll wheel event.
        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            tagAndPost(move, toPid: nil)
        }
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return }
        if !flags.isEmpty { event.flags = flags }
        tagAndPost(event, toPid: nil)
    }

    // MARK: - Pointer restore

    public func pointerLocation() -> CGPoint? {
        // A source-less CGEvent snapshot carries the current pointer position (public,
        // permission-free read).
        CGEvent(source: nil)?.location
    }

    public func movePointer(to point: CGPoint) {
        // A tagged `.mouseMoved` (no button) — the interruption tap ignores our own tag,
        // so returning the cursor can never read as a user interruption.
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        tagAndPost(move, toPid: nil)
    }

    // MARK: - Tag + post

    /// Stamp our tag and post — either to the session tap (global lane) or to an explicit
    /// process (targeted keyboard lane). The tag is identical in both lanes so the passive
    /// interruption tap still recognizes our own synthetic input.
    private func tagAndPost(_ event: CGEvent, toPid: pid_t?) {
        event.setIntegerValueField(.eventSourceUserData, value: FallbackTag.userData)
        if let toPid {
            event.postToPid(toPid)
        } else {
            event.post(tap: .cgSessionEventTap)
        }
    }
}
