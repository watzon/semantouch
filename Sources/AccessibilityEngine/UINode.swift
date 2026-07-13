import Foundation
import ComputerUseCore

/// A pure, permission-free value model of one accessibility element (docs/PROTOCOL.md §7).
///
/// `UINode` is the boundary between the **impure extraction** layer
/// (`AXClient` + `AXTreeBuilder`, which touch the live AX hierarchy) and the
/// **pure rendering** layer (`AXTreeRenderer`). Everything downstream of a built
/// `UINode` tree is deterministic and testable without Accessibility permissions.
///
/// Field notes tied to the `semantouch-ax-tree-v1` grammar (docs/PROTOCOL.md §7):
///
/// - `id` is a **numeric placeholder** for the element id. The renderer emits it as
///   `[e<id>]`. The builder mints it from `StableElementTable` (an `e<N>` counter),
///   so within a session the numeric value equals the `N` in `e<N>`.
/// - `role`/`subrole` are the **verbatim** AX role/subrole (`AXButton`,
///   `AXTextField` / `AXSecureTextField`). The renderer sanitizes any grammar-hostile
///   characters at emit time; the model keeps the source strings.
/// - `title`/`value`/`placeholder`/`description` are raw (source) strings. The
///   renderer applies quoting, escaping (§7.3) and the per-field 256-byte cap (§7.5).
///   The builder may coarse-cap absurdly long strings to bound memory, but the
///   renderer is authoritative for the exact wire truncation.
/// - `value` is already reduced to a **string** by the builder (`AXValue`: strings
///   verbatim; booleans / toggle states as `0`/`1`; numbers as the shortest
///   round-tripping decimal — §7.2). The renderer treats it as opaque text.
/// - `axIdentifier` (`AXIdentifier`) and `settableAttributes` are **not rendered**;
///   they feed fingerprinting (§11) and Phase-2 mutation respectively.
/// - `frame` is in **window points** (§9), already converted from global points by
///   the builder. `nil` renders as `frame=?`; otherwise the renderer rounds to
///   integers (nearest, ties away from zero).
/// - `actions` are **raw** AX action names (`AXPress`); the renderer strips the
///   leading `AX` and sanitizes (§7.2).
public struct UINode: Codable, Equatable, Sendable {
    /// Numeric placeholder id; the renderer emits `[e<id>]`.
    public var id: Int
    /// AX role, verbatim (e.g. `AXButton`).
    public var role: String
    /// AX subrole, verbatim (e.g. `AXSecureTextField`); `nil` when absent.
    public var subrole: String?
    /// `AXTitle` (or the resolved `AXTitleUIElement` text); `nil`/empty renders nothing.
    public var title: String?
    /// Stringified `AXValue`; `nil`/empty renders nothing.
    public var value: String?
    /// `AXDescription`; rendered as `desc="…"` when nonempty.
    public var description: String?
    /// `AXPlaceholderValue`; rendered as `placeholder="…"` when nonempty.
    public var placeholder: String?
    /// `AXIdentifier`; not rendered — used only for fingerprinting (§11).
    public var axIdentifier: String?
    /// `AXEnabled` (default `true`); renders `enabled=false` only when disabled.
    public var enabled: Bool
    /// Focus state; renders `focused=true` only when focused.
    public var focused: Bool
    /// Selection state; renders `selected=true` only when selected.
    public var selected: Bool
    /// Frame in **window points** (§9); `nil` renders `frame=?`.
    public var frame: Rect?
    /// Raw AX action names (`AXPress`); renderer strips `AX` and sanitizes.
    public var actions: [String]
    /// Names of settable attributes (Phase-2 metadata); not rendered.
    public var settableAttributes: [String]
    /// Children in AX child order (already pruned); never re-sorted (§7.4).
    public var children: [UINode]

    public init(
        id: Int,
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        placeholder: String? = nil,
        axIdentifier: String? = nil,
        enabled: Bool = true,
        focused: Bool = false,
        selected: Bool = false,
        frame: Rect? = nil,
        actions: [String] = [],
        settableAttributes: [String] = [],
        children: [UINode] = []
    ) {
        self.id = id
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.description = description
        self.placeholder = placeholder
        self.axIdentifier = axIdentifier
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.frame = frame
        self.actions = actions
        self.settableAttributes = settableAttributes
        self.children = children
    }

    /// Total node count of the subtree rooted at `self` (inclusive), i.e. the
    /// "total pruned nodes" the renderer budgets against (§7.5).
    public var nodeCount: Int {
        var count = 1
        for child in children { count += child.nodeCount }
        return count
    }
}
