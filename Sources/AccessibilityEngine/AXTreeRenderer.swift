import Foundation
import ComputerUseCore

/// Pure renderer for the `semantouch-ax-tree-v1` grammar (docs/PROTOCOL.md §7).
///
/// `render(_:options:)` is a **pure function** of a `UINode` tree: identical input
/// yields byte-for-byte identical output, with no Accessibility access. All grammar
/// concerns live here — indentation, quoting/escaping (§7.3), the fixed key order
/// (§7.2), per-field truncation (§7.5), verbatim role/`AX`-stripped-action tokens
/// (§7.2), and deterministic node/byte budgeting with a single omission marker
/// (§7.5).
public enum AXTreeRenderer {
    /// Rendering limits (§7.5). Defaults match Phase-1 constants.
    public struct Options: Equatable, Sendable {
        /// Max emitted element lines (§7.5, Phase 1 = 600).
        public var maxNodes: Int
        /// Max UTF-8 byte length of `tree.text` (§7.5, 120 KB).
        public var maxBytes: Int
        /// Per-field escaped-form cap in UTF-8 bytes (§7.5, 256).
        public var maxFieldBytes: Int

        public init(
            maxNodes: Int = AccessibilityEngine.defaultMaxNodes,
            maxBytes: Int = AccessibilityEngine.maxTreeBytes,
            maxFieldBytes: Int = AccessibilityEngine.maxFieldBytes
        ) {
            self.maxNodes = maxNodes
            self.maxBytes = maxBytes
            self.maxFieldBytes = maxFieldBytes
        }

        public static let `default` = Options()
    }

    /// Rendered output plus the metadata `AppState.tree` needs (§4.1).
    public struct Result: Equatable, Sendable {
        /// The grammar text; lines joined by `\n`, **no trailing newline** (§7.1).
        public var text: String
        /// Count of emitted **element** lines (the marker line is not an element).
        public var nodeCount: Int
        /// Whether an omission marker was emitted (§7.5).
        public var truncated: Bool

        public init(text: String, nodeCount: Int, truncated: Bool) {
            self.text = text
            self.nodeCount = nodeCount
            self.truncated = truncated
        }
    }

    // MARK: - Entry point

    /// Render a single-rooted `UINode` tree (the window is the depth-0 root, §7.1).
    public static func render(_ root: UINode, options: Options = .default) -> Result {
        // Flatten pre-order (§7.4): parent line, then each child subtree in order.
        var flat: [(depth: Int, node: UINode)] = []
        flatten(root, depth: 0, into: &flat)
        let total = flat.count

        // Pre-render every element line once (deterministic; reused across passes).
        let lines = flat.map { renderLine(depth: $0.depth, node: $0.node, options: options) }

        // Greedy pre-order acceptance under both budgets (§7.5). A pre-order cut
        // removes one contiguous suffix, so at most one marker is ever needed.
        var accepted = 0
        var usedBytes = 0
        var firstOmitted: Int? = nil
        for i in 0..<lines.count {
            let sep = accepted == 0 ? 0 : 1 // one '\n' between lines
            let cost = sep + lines[i].utf8.count
            let exceedsNodes = accepted + 1 > options.maxNodes
            let exceedsBytes = usedBytes + cost > options.maxBytes
            if exceedsNodes || exceedsBytes {
                firstOmitted = i
                break
            }
            usedBytes += cost
            accepted += 1
        }

        guard firstOmitted != nil else {
            // Nothing omitted.
            return Result(text: lines.joined(separator: "\n"), nodeCount: accepted, truncated: false)
        }

        // Reserve room for exactly one marker line, popping accepted trailing lines
        // until the marker fits within the byte budget. Popping only frees bytes, so
        // this terminates; the marker's depth tracks the current first-omitted node.
        while true {
            let omittedCount = total - accepted
            let markerDepth = flat[accepted].depth // depth of the first omitted node
            let marker = markerLine(depth: markerDepth, omitted: omittedCount)
            let sep = accepted == 0 ? 0 : 1
            if usedBytes + sep + marker.utf8.count <= options.maxBytes || accepted == 0 {
                var out = Array(lines[0..<accepted])
                out.append(marker)
                return Result(text: out.joined(separator: "\n"), nodeCount: accepted, truncated: true)
            }
            // Pop the last accepted line and retry with a larger omission count.
            accepted -= 1
            let poppedSep = accepted == 0 ? 0 : 1
            usedBytes -= poppedSep + lines[accepted].utf8.count
        }
    }

    // MARK: - Traversal

    private static func flatten(_ node: UINode, depth: Int, into out: inout [(depth: Int, node: UINode)]) {
        out.append((depth, node))
        for child in node.children {
            flatten(child, depth: depth + 1, into: &out)
        }
    }

    // MARK: - Line rendering (§7.1, §7.2)

    /// The omission marker at a given depth (§7.5): `<indent>… +<N> nodes omitted`.
    static func markerLine(depth: Int, omitted: Int) -> String {
        indent(depth) + "\u{2026} +\(omitted) nodes omitted"
    }

    static func renderLine(depth: Int, node: UINode, options: Options) -> String {
        // A rendered line is the identity segment (§7.1) followed by the attribute
        // segment (§7.2). The attribute segment always carries `frame`, so it is never
        // empty and the single joining space is unconditional.
        indent(depth) + identitySegment(node, options: options) + " " + attributeSegment(node, options: options)
    }

    /// The identity portion of a line (§7.1): `[e<id>] Role(.Subrole)? (" <title>")?`.
    /// This is the part the diff grammar keeps as context and treats as element
    /// identity (a change here is a structural replacement, never a `~` delta).
    static func identitySegment(_ node: UINode, options: Options) -> String {
        var s = "[e\(node.id)] " + sanitizeToken(node.role)
        if let subrole = node.subrole, !subrole.isEmpty {
            s += "." + sanitizeToken(subrole)
        }
        if let title = node.title, !title.isEmpty {
            s += " \"" + renderField(title, cap: options.maxFieldBytes) + "\""
        }
        return s
    }

    /// The attribute portion of a line (§7.2), space-joined in the fixed key order,
    /// omitting keys per their presence rule; `frame` is always present so the result
    /// is never empty. The diff renderer reuses this to detect which keys changed.
    static func attributeSegment(_ node: UINode, options: Options) -> String {
        attributeTokens(node, options: options).map { $0.token }.joined(separator: " ")
    }

    /// The ordered `(key, token)` attribute pairs of a node in §7.2 order, present-only.
    /// `key` is the stable attribute name (`value`, `enabled`, `frame`, `actions`, …);
    /// `token` is its rendered form (`value="V"`, `enabled=false`, `frame=1,2,3,4`).
    static func attributeTokens(_ node: UINode, options: Options) -> [(key: String, token: String)] {
        var parts: [(String, String)] = []
        if let value = node.value, !value.isEmpty {
            parts.append(("value", "value=\"" + renderField(value, cap: options.maxFieldBytes) + "\""))
        }
        if let placeholder = node.placeholder, !placeholder.isEmpty {
            parts.append(("placeholder", "placeholder=\"" + renderField(placeholder, cap: options.maxFieldBytes) + "\""))
        }
        if let desc = node.description, !desc.isEmpty {
            parts.append(("desc", "desc=\"" + renderField(desc, cap: options.maxFieldBytes) + "\""))
        }
        if !node.enabled {
            parts.append(("enabled", "enabled=false"))
        }
        if node.focused {
            parts.append(("focused", "focused=true"))
        }
        if node.selected {
            parts.append(("selected", "selected=true"))
        }
        parts.append(("frame", "frame=" + renderFrame(node.frame)))
        if !node.actions.isEmpty {
            let names = node.actions.map { sanitizeToken(stripAXPrefix($0)) }
            parts.append(("actions", "actions=[" + names.joined(separator: ",") + "]"))
        }
        return parts
    }

    // MARK: - Field rendering (§7.2.7, §7.3, §7.5)

    private static func indent(_ depth: Int) -> String {
        String(repeating: "  ", count: max(0, depth)) // two spaces per depth
    }

    /// Frame in window points, integers rounded nearest / ties away from zero
    /// (§7.2.7). `nil` → `?`.
    static func renderFrame(_ frame: Rect?) -> String {
        guard let frame else { return "?" }
        func r(_ v: Double) -> Int { Int(v.rounded(.toNearestOrAwayFromZero)) }
        return "\(r(frame.x)),\(r(frame.y)),\(r(frame.width)),\(r(frame.height))"
    }

    /// Strip a single leading `AX` from an action name (§7.2). Non-`AX` names verbatim.
    static func stripAXPrefix(_ name: String) -> String {
        name.hasPrefix("AX") ? String(name.dropFirst(2)) : name
    }

    /// Replace grammar-hostile characters in a role/subrole/action token (§7.1):
    /// whitespace, `"`, `[`, `]` → `_`.
    static func sanitizeToken(_ token: String) -> String {
        var out = ""
        out.reserveCapacity(token.count)
        for scalar in token.unicodeScalars {
            if scalar == "\"" || scalar == "[" || scalar == "]"
                || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                out.unicodeScalars.append("_")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Escape one scalar for a quoted string (§7.3). Only these escapes apply; any
    /// other C0 control becomes `\u00XX` (lowercase hex); everything else is verbatim.
    static func escapeUnit(_ scalar: Unicode.Scalar) -> String {
        switch scalar {
        case "\\": return "\\\\"
        case "\"": return "\\\""
        case "\n": return "\\n"
        case "\r": return "\\r"
        case "\t": return "\\t"
        default:
            if scalar.value < 0x20 {
                // `\u00XX`, lowercase hex, zero-padded to 4 digits (§7.3).
                let hex = String(scalar.value, radix: 16)
                return "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
            }
            return String(scalar)
        }
    }

    /// Escape `raw` (§7.3) and cap the **escaped form** at `cap` UTF-8 bytes (§7.5),
    /// suffixing `…` (U+2026) when truncated. Never splits an escape unit or a
    /// multi-byte scalar: units are accumulated whole.
    static func renderField(_ raw: String, cap: Int) -> String {
        // Escape unit-by-unit, tracking byte cost, so truncation lands on a boundary.
        var units: [String] = []
        var total = 0
        for scalar in raw.unicodeScalars {
            let unit = escapeUnit(scalar)
            units.append(unit)
            total += unit.utf8.count
        }
        if total <= cap {
            return units.joined()
        }
        let ellipsis = "\u{2026}"
        let budget = cap - ellipsis.utf8.count // reserve bytes for the suffix
        var out = ""
        var acc = 0
        for unit in units {
            let b = unit.utf8.count
            if acc + b > budget { break }
            out += unit
            acc += b
        }
        return out + ellipsis
    }
}
