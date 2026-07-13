import Foundation
import ComputerUseCore

// Accessibility-first perception: the live AX wrapper, pure UI-node model,
// tree extraction and rendering, stable element ids, event invalidation,
// incremental diffs, and settle detection.

/// Namespace + constants for the accessibility engine.
public enum AccessibilityEngine {
    /// The tree grammar version this engine emits (§7).
    public static let treeFormat = AppState.TreeInfo.currentFormat

    /// Default and hard-ceiling emitted-node caps (§7.5).
    public static let defaultMaxNodes = 600
    public static let hardMaxNodes = 2000

    /// Max `tree.text` size in UTF-8 bytes (§7.5).
    public static let maxTreeBytes = 120 * 1024

    /// Per-field escaped-string cap in UTF-8 bytes (§7.5).
    public static let maxFieldBytes = 256

    /// Resolve a caller-supplied per-snapshot node budget (§18.2) to an effective render
    /// cap: `nil` uses the default (600); any value is clamped to `1...hardMaxNodes` (2000,
    /// the frozen §7.5 ceiling no configuration may exceed).
    public static func nodeBudget(requested: Int?) -> Int {
        guard let requested else { return defaultMaxNodes }
        return min(max(1, requested), hardMaxNodes)
    }
}
