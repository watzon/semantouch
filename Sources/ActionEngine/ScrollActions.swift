import Foundation
import ComputerUseCore

/// `scroll`: the semantic scroll ladder (§13.3). In order — set the relevant
/// scrollbar's settable `AXValue`; else a by-page scroll action on the scroll area;
/// else `AXScrollToVisible` on a scrollable descendant; else `unsupported_action`
/// with `data.reason`. It never synthesizes wheel/pointer input.
public enum ScrollActions {
    /// Scrollbar `AXValue` delta for one `line` / one `page`, multiplied by `count`.
    /// These are internal heuristics (the scrollbar value is a 0…1 fraction); the
    /// wire contract only fixes direction/granularity/count, not the delta.
    static let lineFraction = 0.1
    static let pageFraction = 0.9

    public static func scroll(
        _ element: ActionElement,
        direction: ScrollDirection,
        by granularity: ScrollGranularity,
        count: Double,
        elementId: String
    ) throws -> ActionResult {
        // Positive magnitude; callers/schema enforce > 0.
        let magnitude = max(0, count)

        // 1. Settable scrollbar AXValue (a 0…1 fraction). Fractional count is exact here.
        if let bar = element.element(for: direction.scrollBarAttribute),
           bar.isSettable(AXActionName.value),
           let currentString = bar.snapshot(AXActionName.value),
           let current = Double(currentString) {
            let unit = granularity == .page ? pageFraction : lineFraction
            let delta = (direction.increasesValue ? unit : -unit) * magnitude
            let next = min(1.0, max(0.0, current + delta))
            try bar.writeValue(.number(next))
            let after = bar.snapshot(AXActionName.value).flatMap(Double.init) ?? next
            return SemanticActions.completed(
                stateChanged: after != current,
                warning: "scrolled via scrollbar AXValue"
            )
        }

        // 2. By-page scroll action on the scroll area.
        // Discrete AX actions cannot express fractions: ceil the magnitude and report
        // the approximation when the requested count was non-integral or when line
        // granularity is approximated by a page action.
        let actions = element.actionNames()
        if actions.contains(direction.byPageActionName) {
            let discreteSteps = max(1, Int(magnitude.rounded(.up)))
            for _ in 0..<discreteSteps {
                try element.perform(direction.byPageActionName)
            }
            var detail: [String] = []
            if granularity == .line {
                detail.append("page granularity; line approximated")
            }
            if magnitude != Double(discreteSteps) {
                detail.append(
                    String(
                        format: "count %.4g approximated as %d discrete page action(s)",
                        magnitude,
                        discreteSteps
                    )
                )
            }
            let warning: String
            if detail.isEmpty {
                warning = "scrolled via \(direction.byPageActionName)"
            } else {
                warning = "scrolled via \(direction.byPageActionName) (\(detail.joined(separator: "; ")))"
            }
            return SemanticActions.completed(stateChanged: false, warning: warning)
        }

        // 3. AXScrollToVisible on a scrollable descendant.
        if let target = firstScrollToVisibleDescendant(element) {
            try target.perform(AXActionName.scrollToVisible)
            return SemanticActions.completed(
                stateChanged: false,
                warning: "scrolled a descendant into view via AXScrollToVisible"
            )
        }

        // 4. Nothing applies — semantic-only, so this is unsupported (not a fallback).
        throw CUError.unsupportedAction(
            elementId: elementId,
            action: nil,
            supported: actions,
            reason: "No semantic scroll method is available (no settable scrollbar, no by-page scroll action, no scrollable descendant)."
        )
    }

    /// First descendant (breadth-first, bounded) that exposes `AXScrollToVisible`.
    static func firstScrollToVisibleDescendant(_ root: ActionElement, limit: Int = 2000) -> ActionElement? {
        var queue = root.children()
        var head = 0
        var visited = 0
        while head < queue.count, visited < limit {
            let element = queue[head]
            head += 1
            visited += 1
            if element.actionNames().contains(AXActionName.scrollToVisible) {
                return element
            }
            queue.append(contentsOf: element.children())
        }
        return nil
    }
}
