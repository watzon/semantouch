import Foundation
import CoreGraphics
import ComputerUseCore

// The live `InputSynthesizer`: posts public, tagged CGEvents (clean-room: no SAI or
// private frameworks). Every emitted event carries `FallbackTag.userData` in its
// `eventSourceUserData` field so the passive interruption tap can tell our own input apart
// from genuine physical input. This type is impure and is never exercised by the
// permission-free unit tests (those use a recording fake).
//
// Delivery target: events are posted to the session event tap. Coordinate events land at
// the given global point; keyboard events go to the frontmost app. The interference layer
// guarantees the target is frontmost (already, or via a focus transaction) before any
// event is posted — under `background-only` a non-frontmost target is rejected with
// `focus_required` rather than risking input reaching the wrong app.
public final class CGEventSynthesizer: InputSynthesizer {
    private let source: CGEventSource?

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

    // MARK: - Keyboard

    public func keyDown(keyCode: CGKeyCode, flags: CGEventFlags) {
        postKey(keyCode: keyCode, flags: flags, down: true)
    }

    public func keyUp(keyCode: CGKeyCode, flags: CGEventFlags) {
        postKey(keyCode: keyCode, flags: flags, down: false)
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags, down: Bool) {
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
        tagAndPost(event)
    }

    public func typeUnicode(_ string: String) {
        // Reliable arbitrary-Unicode entry, layout-independent: a keyDown/keyUp pair each
        // carrying the literal string via CGEventKeyboardSetUnicodeString.
        let utf16 = Array(string.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            utf16.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            tagAndPost(event)
        }
    }

    // MARK: - Pointer

    public func mouseDown(at point: CGPoint, button: PointerButton, flags: CGEventFlags) {
        postMouse(type: button.downType, at: point, button: button, flags: flags)
    }

    public func mouseUp(at point: CGPoint, button: PointerButton, flags: CGEventFlags) {
        postMouse(type: button.upType, at: point, button: button, flags: flags)
    }

    public func mouseDrag(to point: CGPoint, button: PointerButton, flags: CGEventFlags) {
        postMouse(type: button.dragType, at: point, button: button, flags: flags)
    }

    private func postMouse(type: CGEventType, at point: CGPoint, button: PointerButton, flags: CGEventFlags) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button.cgButton) else { return }
        if !flags.isEmpty { event.flags = flags }
        tagAndPost(event)
    }

    public func scroll(at point: CGPoint, deltaX: Int32, deltaY: Int32, flags: CGEventFlags) {
        // Position the pointer so the scroll targets the intended location, then post a
        // line-unit scroll wheel event.
        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            tagAndPost(move)
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
        tagAndPost(event)
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
        tagAndPost(move)
    }

    // MARK: - Tag + post

    /// Stamp our tag and post to the session tap.
    private func tagAndPost(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: FallbackTag.userData)
        event.post(tap: .cgSessionEventTap)
    }
}
