import Foundation
import ComputerUseCore

// Semantic Accessibility actions and guarded native-input fallback
// (docs/PROTOCOL.md §§13, 16).
//
// Element-targeted mutations prefer native AX actions and settable AX attributes.
// Semantic dispatch never silently escalates to synthesized input; callers must
// opt into the keyboard or pointer fallback path explicitly.

/// Namespace for engine-wide metadata.
public enum ActionEngine {
    /// Element-targeted semantic tools (§4.2).
    public static let phase2Tools = ["click", "perform_action", "set_value", "select_text", "scroll"]

    /// App/session-targeted fallback-input tools (§4.3).
    public static let phase4Tools = ["press_key", "type_text", "drag"]

    /// Default interference policy for actions until a mode is explicitly chosen.
    public static let defaultInterference: InterferencePolicy = .backgroundOnly
}

/// Raw AX attribute / action name strings used by the semantic actions. Written as
/// literals (not `kAX…` constants) so the engine does not depend on which constants a
/// given SDK re-exports to Swift; the on-the-wire names are stable.
public enum AXActionName {
    public static let value = "AXValue"
    public static let selectedText = "AXSelectedText"
    public static let selectedTextRange = "AXSelectedTextRange"
    public static let press = "AXPress"
    public static let verticalScrollBar = "AXVerticalScrollBar"
    public static let horizontalScrollBar = "AXHorizontalScrollBar"
    public static let scrollToVisible = "AXScrollToVisible"
    // v1.5 §18.5/§18.6: keyboard-focus attribute + the semantic commit action / focused-element read.
    public static let focused = "AXFocused"
    public static let confirm = "AXConfirm"
    public static let focusedUIElement = "AXFocusedUIElement"
    public static let parent = "AXParent"

    /// Strip a leading `AX` from an action name (`AXPress` → `Press`); other names
    /// are returned verbatim. Mirrors the tree grammar (§7.2).
    public static func stripped(_ name: String) -> String {
        name.hasPrefix("AX") ? String(name.dropFirst(2)) : name
    }
}

/// Whether a best-effort before/after snapshot indicates the state changed (§13.4).
/// Two `nil`s (nothing observable) compare equal → `false` (null-equivalent).
func stateDidChange(before: String?, after: String?) -> Bool {
    before != after
}
