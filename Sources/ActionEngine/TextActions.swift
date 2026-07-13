import Foundation
import ComputerUseCore

/// `set_value` and `select_text`: writes through settable AX **attributes** (§13.3
/// step 2). A non-settable attribute (a non-text element for `select_text`) yields
/// `unsupported_action`; nothing falls back to typing/pointer input.
public enum TextActions {
    /// `set_value` — write `AXValue`. Requires it to be settable; re-reads for
    /// `stateChanged`.
    ///
    /// v1.5 (§18.5): with `commit`, run the semantic commit path — still AX-native only, never
    /// synthesized input (§13.3): (1) best-effort set `AXFocused = true` on the element BEFORE
    /// the write so the app's editing session targets the field; (2) write `AXValue` exactly as
    /// v1.1; (3) perform `AXConfirm` when (and only when) the element advertises it (matching
    /// both the raw `AXConfirm` and stripped `Confirm` forms per §13.3). `committed` is present
    /// only for a commit request: `true` iff `AXConfirm` was advertised and performed
    /// successfully, else `false` with a `warning` advising an element-targeted keyboard commit
    /// (§18.6). `commit: false` is byte-identical to v1.1.
    public static func setValue(_ element: ActionElement, value: ActionValue, commit: Bool = false, elementId: String) throws -> ActionResult {
        guard element.isSettable(AXActionName.value) else {
            throw CUError.unsupportedAction(
                elementId: elementId,
                action: nil,
                supported: element.actionNames(),
                reason: "AXValue is not settable on this element."
            )
        }
        // §18.5 step 1: pre-focus the field (best-effort, only when AXFocused is settable).
        if commit { _ = element.setKeyboardFocus() }
        let before = element.snapshot(AXActionName.value)
        try element.writeValue(value)
        let after = element.snapshot(AXActionName.value)
        let changed = stateDidChange(before: before, after: after)

        guard commit else {
            return SemanticActions.completed(stateChanged: changed)
        }

        // §18.5 step 3: perform AXConfirm iff advertised (raw or stripped), never a synthesized
        // keypress (§13.3). Not advertised → completed with `committed: false` and an advisory to
        // commit via an element-targeted press_key "enter" (§18.6).
        let actions = element.actionNames()
        guard let confirm = actions.first(where: { $0 == AXActionName.confirm || AXActionName.stripped($0) == "Confirm" }) else {
            return SemanticActions.completed(
                stateChanged: changed,
                warning: "The value was written but this element does not advertise a Confirm action; to commit it (e.g. submit/navigate), send an element-targeted press_key \"enter\" with this elementId.",
                committed: false
            )
        }
        do {
            try element.perform(confirm)
            return SemanticActions.completed(stateChanged: changed, committed: true)
        } catch {
            // Advertised but the Confirm action faulted: the value is written, so still completed,
            // but committed is honestly false (§18.5).
            return SemanticActions.completed(
                stateChanged: changed,
                warning: "The value was written but the element's Confirm action failed; to commit it, send an element-targeted press_key \"enter\" with this elementId.",
                committed: false
            )
        }
    }

    /// `select_text` — set the selection `{ start, length }` via `AXSelectedTextRange`
    /// (`length: 0` places the caret at `start`). Requires a settable selection range
    /// (a text element); a non-text element → `unsupported_action`. Re-reads the
    /// selected text for `stateChanged`.
    public static func selectText(_ element: ActionElement, start: Int, length: Int, elementId: String) throws -> ActionResult {
        guard element.isSettable(AXActionName.selectedTextRange) else {
            throw CUError.unsupportedAction(
                elementId: elementId,
                action: nil,
                supported: element.actionNames(),
                reason: "This element does not expose a settable text selection (not a text element)."
            )
        }
        let before = element.snapshot(AXActionName.selectedText)
        try element.writeSelectedRange(location: start, length: length)
        let after = element.snapshot(AXActionName.selectedText)
        return SemanticActions.completed(stateChanged: stateDidChange(before: before, after: after))
    }
}
