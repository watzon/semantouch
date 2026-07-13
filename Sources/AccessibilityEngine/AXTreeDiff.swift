import Foundation
import ComputerUseCore

/// Pure incremental diffing over two `UINode` snapshots (docs/PROTOCOL.md §15).
/// Everything here is a deterministic function of its inputs — no Accessibility
/// access — so the whole revision/diff contract is testable without permissions.
///
/// The unit of the diff is the **element id** (§3). A node keeps its id across
/// revisions when `StableElementTable` matched its structural fingerprint (§11), so
/// two snapshots taken from the same session share ids for unchanged/matched elements
/// and mint fresh ids for genuinely new ones. Against that backdrop the diff is a
/// clean three-way partition keyed by id:
///
/// - **removed** — ids in the previous snapshot, absent from the current one.
/// - **added** — ids in the current snapshot, absent from the previous one, each with
///   its parent id and child index so its position is unambiguous.
/// - **changed** — ids present in both, at the same tree position and identity
///   (role/subrole/title), whose non-identity attributes differ.
///
/// A node whose **position** (parent id or child index) or **identity** (role,
/// subrole, title) changed is represented as a `removed` + `added` pair rather than a
/// `changed` delta. In the common case the real pipeline already mints a fresh id for
/// such a node (the fingerprint churned), so the old id lands only in `removed` and the
/// new id only in `added` — a clean disjoint partition. But the id-reuse fingerprint
/// (§15.2: normalized title + like-role sibling ordinal) is deliberately *coarser* than
/// the diff's notion of identity (raw title) and placement (absolute child index): a
/// case/whitespace-only title change, or a different-role sibling appearing above a kept
/// element, keeps the reused id yet flips the diff's identity/placement. That would put
/// the **same live id** in both `+` and `-`, which the §15.3 wire grammar forbids
/// (`- ` ids are retired). `compute` detects this and sets `Diff.reusedIdConflict`; the
/// caller then discards the diff and emits a full tree with `diff_reset` rather than a
/// wire-invalid diff. A slower full refresh beats a wrong incremental one.
///
/// Correctness contract (the reason this exists): for every pair of trees,
/// `apply(compute(previous, current, …), to: previous)` reconstructs `current`
/// **exactly** — every reconstructed node ends up carrying the current snapshot's
/// (parent, index), so grouping children by parent and ordering by index reproduces
/// the current tree byte-for-byte when re-rendered, and value-for-value structurally.
/// (`apply` remains exact even for a `reusedIdConflict` diff — the internal proof holds
/// regardless — but such a diff is never rendered to the wire.)
public enum AXTreeDiff {
    // MARK: - Model

    /// A node inserted in the current revision, with the placement needed to put it
    /// back exactly. `node` is a **shell** (its `children` are stripped — every child
    /// is itself a separate `added`/matched node addressed by its own id).
    public struct Added: Equatable, Sendable {
        /// The inserted node, children stripped.
        public let node: UINode
        /// Parent element id in the current tree; `nil` only for the root.
        public let parentId: Int?
        /// 0-based child index under `parentId` in the current tree.
        public let index: Int

        public init(node: UINode, parentId: Int?, index: Int) {
            self.node = node
            self.parentId = parentId
            self.index = index
        }
    }

    /// A node present in both revisions at the same position/identity whose
    /// non-identity attributes changed. Both shells are retained (children stripped)
    /// so the renderer can show `old → new` deltas and `apply` can restore the exact
    /// current attributes.
    public struct Changed: Equatable, Sendable {
        public let id: Int
        /// The node as it was in the previous revision (shell).
        public let before: UINode
        /// The node as it is in the current revision (shell).
        public let after: UINode

        public init(id: Int, before: UINode, after: UINode) {
            self.id = id
            self.before = before
            self.after = after
        }
    }

    /// A computed diff from `baseRevision` to `revision`.
    public struct Diff: Equatable, Sendable {
        public let baseRevision: Int
        public let revision: Int
        /// Added nodes, sorted by id ascending (deterministic; order is irrelevant to
        /// `apply`, which places by explicit parent/index).
        public var added: [Added]
        /// Changed nodes, sorted by id ascending.
        public var changed: [Changed]
        /// Removed ids, sorted ascending.
        public var removed: [Int]
        /// True when a still-live, id-reused element appears in **both** `added` and
        /// `removed` because its diff-identity (raw title) or placement (absolute child
        /// index) changed while the coarser reuse fingerprint (§15.2) kept its id. Such a
        /// diff would violate the §15.3 disjoint-partition / "removed ids are retired"
        /// invariants if rendered, so the caller MUST emit a full tree with `diff_reset`
        /// instead. `apply` still reconstructs exactly; only the wire rendering is unsafe.
        public var reusedIdConflict: Bool

        public init(
            baseRevision: Int,
            revision: Int,
            added: [Added],
            changed: [Changed],
            removed: [Int],
            reusedIdConflict: Bool = false
        ) {
            self.baseRevision = baseRevision
            self.revision = revision
            self.added = added
            self.changed = changed
            self.removed = removed
            self.reusedIdConflict = reusedIdConflict
        }

        /// Whether nothing changed between the two revisions.
        public var isEmpty: Bool { added.isEmpty && changed.isEmpty && removed.isEmpty }
    }

    // MARK: - Compute

    /// A node together with its position, used while indexing a tree.
    private struct Located {
        let node: UINode   // shell (children stripped)
        let parentId: Int?
        let index: Int
    }

    /// Compute the diff transforming `previous` (revision `baseRevision`) into
    /// `current` (revision `revision`). Deterministic.
    public static func compute(
        previous: UINode,
        current: UINode,
        baseRevision: Int,
        revision: Int,
        options: AXTreeRenderer.Options = .default
    ) -> Diff {
        var prevIndex: [Int: Located] = [:]
        var curIndex: [Int: Located] = [:]
        index(previous, parentId: nil, childIndex: 0, into: &prevIndex)
        index(current, parentId: nil, childIndex: 0, into: &curIndex)

        var removed: [Int] = []
        var added: [Added] = []
        var changed: [Changed] = []
        var reusedIdConflict = false

        // Removed: in previous, not in current.
        for id in prevIndex.keys where curIndex[id] == nil {
            removed.append(id)
        }

        for (id, cur) in curIndex {
            guard let prev = prevIndex[id] else {
                // Added: in current, not in previous.
                added.append(Added(node: cur.node, parentId: cur.parentId, index: cur.index))
                continue
            }
            // Present in both.
            let placementChanged = prev.parentId != cur.parentId || prev.index != cur.index
            let identityChanged = AXTreeRenderer.identitySegment(prev.node, options: options)
                != AXTreeRenderer.identitySegment(cur.node, options: options)
            if placementChanged || identityChanged {
                // The id was reused (present in both revisions) yet its diff-identity or
                // child position changed. Retiring the old placement/identity and re-adding
                // keeps `apply` reconstruction exact, but it lists the SAME live id in both
                // `removed` and `added`, which the §15.3 wire grammar forbids. Flag it so
                // the caller falls back to a full tree + `diff_reset` instead of rendering.
                // (Reachable in the real pipeline: a case/whitespace-only title change, or a
                // different-role sibling inserted above a kept element — see type docs.)
                reusedIdConflict = true
                removed.append(id)
                added.append(Added(node: cur.node, parentId: cur.parentId, index: cur.index))
            } else if AXTreeRenderer.attributeSegment(prev.node, options: options)
                != AXTreeRenderer.attributeSegment(cur.node, options: options) {
                changed.append(Changed(id: id, before: prev.node, after: cur.node))
            }
            // else: fully unchanged — emit nothing.
        }

        added.sort { $0.node.id < $1.node.id }
        changed.sort { $0.id < $1.id }
        removed.sort()
        return Diff(
            baseRevision: baseRevision, revision: revision,
            added: added, changed: changed, removed: removed,
            reusedIdConflict: reusedIdConflict
        )
    }

    /// Depth-first index of every node by id, recording its parent id and child index.
    /// The stored node is a **shell** (children stripped).
    private static func index(_ node: UINode, parentId: Int?, childIndex: Int, into map: inout [Int: Located]) {
        map[node.id] = Located(node: shell(node), parentId: parentId, index: childIndex)
        for (i, child) in node.children.enumerated() {
            index(child, parentId: node.id, childIndex: i, into: &map)
        }
    }

    /// A copy of `node` with its `children` stripped.
    static func shell(_ node: UINode) -> UINode {
        var copy = node
        copy.children = []
        return copy
    }

    // MARK: - Apply (reconstruction — the correctness proof)

    /// Reconstruct the current tree by applying `diff` to `previous`. When `diff` was
    /// produced by `compute(previous:current:…)`, the result equals `current` exactly.
    public static func apply(_ diff: Diff, to previous: UINode) -> UINode {
        // Flatten previous into shells keyed by id, remembering each node's placement.
        var located: [Int: Located] = [:]
        index(previous, parentId: nil, childIndex: 0, into: &located)

        // Removed nodes drop out. (A moved node appears in both removed and added; the
        // added entry below re-inserts it at its new placement, so removal first is
        // safe.)
        for id in diff.removed {
            located.removeValue(forKey: id)
        }

        // Changed nodes keep their (unchanged) placement but adopt the new attributes.
        for change in diff.changed {
            guard let existing = located[change.id] else { continue }
            located[change.id] = Located(node: shell(change.after), parentId: existing.parentId, index: existing.index)
        }

        // Added nodes are placed at their explicit (parent, index).
        for add in diff.added {
            located[add.node.id] = Located(node: shell(add.node), parentId: add.parentId, index: add.index)
        }

        // Rebuild the tree: group children by parent, order by child index.
        var childrenByParent: [Int: [(index: Int, id: Int)]] = [:]
        var rootId: Int?
        for (id, entry) in located {
            if let parent = entry.parentId {
                childrenByParent[parent, default: []].append((entry.index, id))
            } else {
                rootId = id
            }
        }

        guard let root = rootId else {
            // No root survived — should not happen for a well-formed diff. Fall back to
            // the previous root so the caller still gets a valid single-rooted tree.
            return previous
        }

        func build(_ id: Int) -> UINode {
            var node = located[id]?.node ?? UINode(id: id, role: "AXUnknown")
            let kids = (childrenByParent[id] ?? [])
                .sorted { $0.index < $1.index }
                .map { build($0.id) }
            node.children = kids
            return node
        }
        return build(root)
    }

    // MARK: - Wire text (docs/PROTOCOL.md §15)

    /// The fixed §7.2 key order used for changed-attribute deltas.
    private static let attributeKeyOrder = ["value", "placeholder", "desc", "enabled", "focused", "selected", "frame", "actions"]

    /// Render `diff` to the frozen diff-mode text grammar (§15):
    ///
    /// ```
    /// UI revision <N>, based on <M>
    /// ~ [eID] <identity> <old changed tokens> → <new changed tokens>
    /// + [eID] <full self line> @<parent>:<index>
    /// - [e3,e51..e55]
    /// ```
    ///
    /// Entry order is deterministic: header, then `~` changed (id asc), then `+` added
    /// (id asc), then a single `-` removed line (ids asc, consecutive runs of ≥3
    /// collapsed to `eA..eB`). Lines are joined by `\n` with no trailing newline.
    public static func render(_ diff: Diff, options: AXTreeRenderer.Options = .default) -> String {
        var lines: [String] = ["UI revision \(diff.revision), based on \(diff.baseRevision)"]

        for change in diff.changed {
            lines.append(renderChanged(change, options: options))
        }
        for add in diff.added {
            let body = AXTreeRenderer.renderLine(depth: 0, node: add.node, options: options)
            let parentRef = add.parentId.map { "e\($0)" } ?? "root"
            lines.append("+ \(body) @\(parentRef):\(add.index)")
        }
        if !diff.removed.isEmpty {
            lines.append("- [" + collapseRemoved(diff.removed) + "]")
        }
        return lines.joined(separator: "\n")
    }

    /// Render one `~` changed entry. The identity segment is shown as context; then the
    /// changed keys' **actual** values on each side (`enabled=false → enabled=true`) in
    /// §7.2 key order. Two token classes (§15.3):
    ///
    /// - The always-present keys `enabled`/`focused`/`selected` (and `frame`, always
    ///   present) show their default value too, so a toggle reads `focused=false →
    ///   focused=true`.
    /// - The present-only keys `value`/`placeholder`/`desc`/`actions` follow §7.2
    ///   presence: an absent/empty attribute emits **no token** on that side (it is not
    ///   rendered as `value=""`/`actions=[]`, which the grammar never emits). So clearing
    ///   a field reads `value="draft" →` with the new side elided, not `… → value=""`.
    ///
    /// A side that ends up with no tokens at all (an attribute purely appeared or
    /// disappeared) is elided, leaving the bare arrow.
    private static func renderChanged(_ change: Changed, options: AXTreeRenderer.Options) -> String {
        var olds: [String] = []
        var news: [String] = []
        for key in attributeKeyOrder {
            let oldToken = fullAttributeToken(key: key, node: change.before, options: options)
            let newToken = fullAttributeToken(key: key, node: change.after, options: options)
            if oldToken != newToken {
                // Include only the side(s) where the attribute is present: a `nil` token is
                // an absent present-only attribute and is elided (§7.2 / §15.3).
                if let oldToken { olds.append(oldToken) }
                if let newToken { news.append(newToken) }
            }
        }
        let identity = AXTreeRenderer.identitySegment(change.after, options: options)
        let oldPart = olds.isEmpty ? "" : " " + olds.joined(separator: " ")
        let newPart = news.isEmpty ? "" : " " + news.joined(separator: " ")
        return "~ \(identity)\(oldPart) →\(newPart)"
    }

    /// The rendering of one attribute key for a node in a `~` delta. Returns `nil` for a
    /// present-only key (`value`/`placeholder`/`desc`/`actions`) whose attribute is
    /// absent/empty — that side is elided per §7.2 presence and §15.3, since the grammar
    /// never emits `value=""`/`actions=[]`. The always-present keys
    /// (`enabled`/`focused`/`selected`/`frame`) always return a token so both sides of a
    /// boolean/frame delta stay legible. Reuses the renderer's escaping/frame helpers for
    /// consistency with `semantouch-ax-tree-v1`.
    private static func fullAttributeToken(key: String, node: UINode, options: AXTreeRenderer.Options) -> String? {
        switch key {
        case "value":
            guard let value = node.value, !value.isEmpty else { return nil }
            return "value=\"" + AXTreeRenderer.renderField(value, cap: options.maxFieldBytes) + "\""
        case "placeholder":
            guard let placeholder = node.placeholder, !placeholder.isEmpty else { return nil }
            return "placeholder=\"" + AXTreeRenderer.renderField(placeholder, cap: options.maxFieldBytes) + "\""
        case "desc":
            guard let desc = node.description, !desc.isEmpty else { return nil }
            return "desc=\"" + AXTreeRenderer.renderField(desc, cap: options.maxFieldBytes) + "\""
        case "enabled":
            return "enabled=\(node.enabled)"
        case "focused":
            return "focused=\(node.focused)"
        case "selected":
            return "selected=\(node.selected)"
        case "frame":
            return "frame=" + AXTreeRenderer.renderFrame(node.frame)
        case "actions":
            guard !node.actions.isEmpty else { return nil }
            let names = node.actions.map { AXTreeRenderer.sanitizeToken(AXTreeRenderer.stripAXPrefix($0)) }
            return "actions=[" + names.joined(separator: ",") + "]"
        default:
            return nil
        }
    }

    /// Collapse a sorted, unique id list to the removed-line body: consecutive runs of
    /// length ≥ 3 render as `e<first>..e<last>`; shorter runs are listed individually;
    /// pieces are comma-joined. e.g. `[3, 51, 52, 53, 54, 55]` → `e3,e51..e55`.
    static func collapseRemoved(_ ids: [Int]) -> String {
        guard !ids.isEmpty else { return "" }
        var pieces: [String] = []
        var runStart = ids[0]
        var runEnd = ids[0]

        func flush() {
            let length = runEnd - runStart + 1
            if length >= 3 {
                pieces.append("e\(runStart)..e\(runEnd)")
            } else {
                for value in runStart...runEnd { pieces.append("e\(value)") }
            }
        }

        for id in ids.dropFirst() {
            if id == runEnd + 1 {
                runEnd = id
            } else {
                flush()
                runStart = id
                runEnd = id
            }
        }
        flush()
        return pieces.joined(separator: ",")
    }
}
