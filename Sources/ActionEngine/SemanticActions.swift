import Foundation
import ComputerUseCore

/// `click` and `perform_action`: activation through native AX **actions** (§13.3
/// step 1). Neither ever synthesizes input; an element that does not advertise the
/// requested action yields `unsupported_action`.
public enum SemanticActions {
    /// `click` — the element's primary activation, mapped to `AXPress` in Phase 2.
    /// An element without `AXPress` → `unsupported_action` (`data.supported` = its
    /// raw action names). A coordinate-based click is Phase 4 and unreachable here.
    public static func click(_ element: ActionElement, elementId: String) throws -> ActionResult {
        let actions = element.actionNames()
        guard actions.contains(AXActionName.press) else {
            throw CUError.unsupportedAction(
                elementId: elementId,
                action: AXActionName.press,
                supported: actions,
                reason: "click maps to AXPress, which this element does not expose."
            )
        }
        let before = element.snapshot(AXActionName.value)
        try element.perform(AXActionName.press)
        let after = element.snapshot(AXActionName.value)
        return Self.completed(stateChanged: stateDidChange(before: before, after: after))
    }

    /// `perform_action` — perform a named AX action after validating it against the
    /// element's advertised actions. The client's `name` is matched against both the
    /// `AX`-stripped tree form (`ShowMenu`) and the raw form (`AXShowMenu`).
    public static func performNamed(_ element: ActionElement, name: String, elementId: String) throws -> ActionResult {
        let actions = element.actionNames()
        guard let raw = actions.first(where: { $0 == name || AXActionName.stripped($0) == name }) else {
            throw CUError.unsupportedAction(
                elementId: elementId,
                action: name,
                supported: actions,
                reason: nil
            )
        }
        let before = element.snapshot(AXActionName.value)
        try element.perform(raw)
        let after = element.snapshot(AXActionName.value)
        return Self.completed(stateChanged: stateDidChange(before: before, after: after))
    }

    /// A completed, accessibility-method result with `refreshRecommended` set (§13.4).
    /// `committed` (§18.5) is carried through omit-when-nil, so a non-commit action stays
    /// byte-identical to a pre-v1.5 result.
    static func completed(stateChanged: Bool, warning: String? = nil, committed: Bool? = nil) -> ActionResult {
        ActionResult(
            status: .completed,
            method: .accessibility,
            stateChanged: stateChanged,
            refreshRecommended: true,
            warning: warning,
            committed: committed
        )
    }
}
