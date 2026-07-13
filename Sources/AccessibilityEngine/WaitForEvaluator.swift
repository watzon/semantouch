import Foundation
import ApplicationServices

/// Condition evaluation for the read-only `wait_for` tool (docs/PROTOCOL.md §18.7).
///
/// The evaluation logic is **pure** over the `WaitForWindowProbe` seam — window title,
/// document URL, and a bounded element snapshot — so it is fully unit-tested with a fake
/// probe (mirrors the `WorkspaceControlling` / `WebAXAppElement` precedents). The live
/// conformance (`LiveWaitForProbe`) is the impure adapter: a bounded raw AX walk of the
/// window that NEVER touches the session element table.
public enum WaitFor {
    /// `wait_for.mode` (§18.7): combine the per-condition results with all/any.
    public enum Mode: String, Equatable, Sendable {
        case all
        case any
    }

    /// The element matcher shared by `element_exists` / `element_gone` (§18.7). At least one
    /// field is set (enforced at decode). `role` matches exactly; the text matchers are
    /// Unicode case-insensitive `contains`.
    public struct ElementMatcher: Equatable, Sendable {
        public var role: String?
        public var titleContains: String?
        public var valueContains: String?

        public init(role: String? = nil, titleContains: String? = nil, valueContains: String? = nil) {
            self.role = role
            self.titleContains = titleContains
            self.valueContains = valueContains
        }
    }

    /// One `wait_for` condition (§18.7). A discriminated union; the wire `kind` is `discriminant`.
    public enum Condition: Equatable, Sendable {
        case titleChanged(from: String)
        case titleContains(value: String)
        case urlChanged(from: String)
        case urlContains(value: String)
        case elementExists(ElementMatcher)
        case elementGone(ElementMatcher)

        /// The wire discriminant echoed in each `ConditionResult` (§18.7).
        public var discriminant: String {
            switch self {
            case .titleChanged: return "title_changed"
            case .titleContains: return "title_contains"
            case .urlChanged: return "url_changed"
            case .urlContains: return "url_contains"
            case .elementExists: return "element_exists"
            case .elementGone: return "element_gone"
            }
        }
    }

    /// One element observed by a bounded raw walk (§18.7): role plus the resolved title/value
    /// the text matchers compare against.
    public struct ProbedElement: Equatable, Sendable {
        public var role: String?
        public var title: String?
        public var value: String?

        public init(role: String? = nil, title: String? = nil, value: String? = nil) {
            self.role = role
            self.title = title
            self.value = value
        }
    }

    /// The observable window state a single poll reads. The live conformance performs one
    /// bounded raw AX walk; a fake supplies fixed data. `documentURL` / `elements()` may be
    /// computed lazily so a title-only poll never walks the tree.
    public protocol WaitForWindowProbe {
        /// The window's current `AXTitle`, or `nil` when unreadable.
        var windowTitle: String? { get }
        /// The §18.4 principal-web-area document URL, or `nil` when absent/unreadable.
        var documentURL: String? { get }
        /// A bounded snapshot of the window's live element hierarchy (role/title/value).
        func elements() -> [ProbedElement]
    }

    /// The outcome of evaluating a condition set against one poll's observations (§18.7).
    public struct Evaluation: Equatable, Sendable {
        /// The mode-combined outcome.
        public var satisfied: Bool
        /// Per-condition results in request order (`true` iff satisfied).
        public var conditionResults: [Bool]
        /// Best-effort window title at this poll (omitted from the wire when nil).
        public var observedTitle: String?
        /// Best-effort document URL at this poll (omitted from the wire when nil).
        public var observedURL: String?

        public init(satisfied: Bool, conditionResults: [Bool], observedTitle: String?, observedURL: String?) {
            self.satisfied = satisfied
            self.conditionResults = conditionResults
            self.observedTitle = observedTitle
            self.observedURL = observedURL
        }
    }

    /// Evaluate `conditions` (in request order) against one probe under `mode` (§18.7). Reads
    /// title/URL once and walks the element list at most once (only when an element or URL
    /// condition needs it). Pure and total.
    public static func evaluate(
        conditions: [Condition],
        mode: Mode,
        probe: WaitForWindowProbe
    ) -> Evaluation {
        let title = probe.windowTitle
        // The document URL and element list are pulled lazily so a title-only condition set
        // never triggers the (bounded) tree walk.
        var urlCache: String??
        func url() -> String? {
            if let cached = urlCache { return cached }
            let value = probe.documentURL
            urlCache = value
            return value
        }
        var elementsCache: [ProbedElement]?
        func elements() -> [ProbedElement] {
            if let cached = elementsCache { return cached }
            let value = probe.elements()
            elementsCache = value
            return value
        }

        let results = conditions.map { condition -> Bool in
            switch condition {
            case let .titleChanged(from):
                // §18.7: satisfied when the observable title differs from `from`. An unreadable
                // title is treated as empty, so a window that lost its title still counts as
                // changed from a nonempty `from`.
                return (title ?? "") != from
            case let .titleContains(value):
                return containsCaseInsensitive(title, value)
            case let .urlChanged(from):
                return (url() ?? "") != from
            case let .urlContains(value):
                return containsCaseInsensitive(url(), value)
            case let .elementExists(matcher):
                return elements().contains { matches($0, matcher) }
            case let .elementGone(matcher):
                return !elements().contains { matches($0, matcher) }
            }
        }

        let satisfied: Bool
        switch mode {
        case .all: satisfied = results.allSatisfy { $0 }
        case .any: satisfied = results.contains(true)
        }
        return Evaluation(satisfied: satisfied, conditionResults: results, observedTitle: title, observedURL: url())
    }

    /// Whether a probed element matches every set field of `matcher` (§18.7): role exact,
    /// title/value case-insensitive `contains`.
    static func matches(_ element: ProbedElement, _ matcher: ElementMatcher) -> Bool {
        if let role = matcher.role, element.role != role { return false }
        if let title = matcher.titleContains, !containsCaseInsensitive(element.title, title) { return false }
        if let value = matcher.valueContains, !containsCaseInsensitive(element.value, value) { return false }
        return true
    }

    /// Unicode case-insensitive `contains`. A `nil` haystack never matches; an empty needle
    /// matches any present haystack (a caller that supplied an empty matcher value asked for
    /// "present with any text").
    static func containsCaseInsensitive(_ haystack: String?, _ needle: String) -> Bool {
        guard let haystack else { return false }
        if needle.isEmpty { return true }
        return haystack.range(of: needle, options: [.caseInsensitive]) != nil
    }
}

/// The live `WaitForWindowProbe` (§18.7): a bounded raw AX walk of a window element that reads
/// the window title, the principal web area's URL (§18.4 rule: largest frame area; ties → first
/// in pre-order), and a role/title/value snapshot of every element — all through `AXClient`
/// (public APIs only) and **never** touching the session's `StableElementTable`. Impure; the
/// pure evaluation above is the unit-tested part.
public final class LiveWaitForProbe: WaitFor.WaitForWindowProbe {
    private let windowElement: AXUIElement
    private let client: AXClient
    private let maxDepth: Int
    private let nodeCeiling: Int

    // One-shot lazy walk state (a probe is created per poll, so caching per instance is enough).
    private var walked = false
    private var collected: [WaitFor.ProbedElement] = []
    private var principalURL: String?

    /// - Parameters mirror the AXTreeBuilder ceilings (§7.5): `maxDepth` 64, node ceiling 2000.
    public init(
        windowElement: AXUIElement,
        client: AXClient,
        maxDepth: Int = 64,
        nodeCeiling: Int = AccessibilityEngine.hardMaxNodes
    ) {
        self.windowElement = windowElement
        self.client = client
        self.maxDepth = maxDepth
        self.nodeCeiling = nodeCeiling
    }

    public var windowTitle: String? {
        Self.nonEmpty(client.copyString(windowElement, AXAttr.title))
    }

    public var documentURL: String? {
        ensureWalked()
        return principalURL
    }

    public func elements() -> [WaitFor.ProbedElement] {
        ensureWalked()
        return collected
    }

    /// Walk the window once (bounded), collecting elements and the principal web area's URL.
    private func ensureWalked() {
        guard !walked else { return }
        walked = true
        var count = 0
        var principalArea = -1.0
        walk(windowElement, depth: 0, count: &count, principalArea: &principalArea)
    }

    private func walk(_ element: AXUIElement, depth: Int, count: inout Int, principalArea: inout Double) {
        guard depth <= maxDepth, count < nodeCeiling else { return }
        count += 1

        let role = client.role(of: element)
        let title = Self.nonEmpty(client.copyString(element, AXAttr.title))
            ?? Self.nonEmpty(client.copyString(element, AXAttr.description))
        collected.append(WaitFor.ProbedElement(role: role, title: title, value: Self.value(of: element, client: client)))

        // §18.4: the principal web area is the largest-area AXWebArea (ties → first pre-order,
        // since only a strictly-larger area replaces the incumbent). Read AXURL only then.
        if role == "AXWebArea" {
            let area = client.frame(of: element).map { Double($0.width) * Double($0.height) } ?? 0
            if area > principalArea {
                principalArea = area
                principalURL = client.copyURLString(element, AXAttr.url)
            }
        }

        guard depth < maxDepth else { return }
        for child in client.children(of: element) {
            if count >= nodeCeiling { break }
            walk(child, depth: depth + 1, count: &count, principalArea: &principalArea)
        }
    }

    /// Stringify `AXValue` for the value matcher (§7.2 conventions): strings verbatim,
    /// booleans/toggles as `0`/`1`, numbers as the shortest round-tripping decimal.
    private static func value(of element: AXUIElement, client: AXClient) -> String? {
        guard let raw = try? client.copyAttribute(element, AXAttr.value) else { return nil }
        if CFGetTypeID(raw) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((raw as! CFBoolean)) ? "1" : "0"
        }
        if let number = raw as? NSNumber {
            return AXTreeBuilderValue.shortestDecimal(number)
        }
        if let string = raw as? String {
            return nonEmpty(string)
        }
        return nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

/// Shared shortest-decimal rendering for AX numeric values (§7.2), reused by the `wait_for`
/// live probe so its value matcher stringifies numbers exactly like the tree builder.
enum AXTreeBuilderValue {
    static func shortestDecimal(_ number: NSNumber) -> String {
        let objcType = String(cString: number.objCType)
        if objcType == "f" || objcType == "d" {
            let d = number.doubleValue
            if d == d.rounded(), abs(d) < 1e15 {
                return String(Int64(d))
            }
            return String(d)
        }
        if objcType == "c" || objcType == "B" {
            return number.boolValue ? "1" : "0"
        }
        return number.stringValue
    }
}
