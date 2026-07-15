import Foundation
import ComputerUseCore

/// `click` and `perform_action`: activation through native AX **actions** (§13.3
/// step 1). Ordinary left single/multi clicks stay on the AXPress path; right /
/// middle and any click that needs pointer semantics are routed by the executor
/// through the element's verified frame (never a bare invented coordinate).
public enum SemanticActions {
    /// `click` — the element's primary activation, mapped to `AXPress` in Phase 2.
    /// An element without `AXPress` → `unsupported_action` (`data.supported` = its
    /// raw action names). Repeated ordinary left clicks re-perform AXPress
    /// `clickCount` times (1...3). Right/middle and pointer-semantic forms never
    /// reach here — the executor routes those through verified-frame delivery.
    public static func click(
        _ element: ActionElement,
        elementId: String,
        clickCount: Int = 1
    ) throws -> ActionResult {
        let actions = element.actionNames()
        guard actions.contains(AXActionName.press) else {
            throw CUError.unsupportedAction(
                elementId: elementId,
                action: AXActionName.press,
                supported: actions,
                reason: "click maps to AXPress, which this element does not expose."
            )
        }
        let units = max(1, min(3, clickCount))
        let before = element.snapshot(AXActionName.value)
        for _ in 0..<units {
            try element.perform(AXActionName.press)
        }
        let after = element.snapshot(AXActionName.value)
        return Self.completed(stateChanged: stateDidChange(before: before, after: after))
    }

    /// Whether a semantic element click can stay on the pure AXPress path.
    /// Ordinary left clicks (any count 1...3) do; right/middle need pointer semantics.
    public static func usesAXPress(button: PointerButton) -> Bool {
        button == .left
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
