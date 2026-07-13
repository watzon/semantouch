import Foundation
import ComputerUseCore

/// Static description of one tool: its name, the phase it is introduced in, and
/// whether it is enabled in the current build (§4). Disabled tools are omitted
/// from `tools/list` and answer `policy_denied`/`tool_disabled` when called.
public struct ToolDescriptorInfo: Equatable, Sendable {
    public let name: String
    public let phase: Int
    public let enabledNow: Bool

    public init(name: String, phase: Int, enabledNow: Bool) {
        self.name = name
        self.phase = phase
        self.enabledNow = enabledNow
    }
}

/// The frozen tool table (§4). This mirrors the protocol's enablement matrix and
/// is the single source of truth for `tools/list` filtering.
public enum ToolCatalog {
    public static let all: [ToolDescriptorInfo] = [
        // Phase 1 — enabled now.
        ToolDescriptorInfo(name: "doctor", phase: 1, enabledNow: true),
        ToolDescriptorInfo(name: "list_apps", phase: 1, enabledNow: true),
        ToolDescriptorInfo(name: "get_app_state", phase: 1, enabledNow: true),
        // v1.5 (§18.9) — read-only capture-only tool. Grouped with get_app_state (the two
        // window-observation tools): captures the window as a JPEG without an accessibility
        // tree and does not advance the revision.
        ToolDescriptorInfo(name: "screenshot", phase: 1, enabledNow: true),
        ToolDescriptorInfo(name: "end_app_session", phase: 1, enabledNow: true),
        // Phase 2 — enabled now (semantic actions, Stage E / §13).
        ToolDescriptorInfo(name: "click", phase: 2, enabledNow: true),
        ToolDescriptorInfo(name: "perform_action", phase: 2, enabledNow: true),
        ToolDescriptorInfo(name: "set_value", phase: 2, enabledNow: true),
        ToolDescriptorInfo(name: "select_text", phase: 2, enabledNow: true),
        ToolDescriptorInfo(name: "scroll", phase: 2, enabledNow: true),
        // Phase 4 — enabled now (native fallback input, Stage G / §16).
        ToolDescriptorInfo(name: "press_key", phase: 4, enabledNow: true),
        ToolDescriptorInfo(name: "type_text", phase: 4, enabledNow: true),
        ToolDescriptorInfo(name: "drag", phase: 4, enabledNow: true),
        // v1.5 — read-only outcome verification (§18.7). Appended after drag (USAGE tool #13).
        ToolDescriptorInfo(name: "wait_for", phase: 4, enabledNow: true),
    ]

    /// Tools that appear in `tools/list` right now.
    public static var enabled: [ToolDescriptorInfo] {
        all.filter { $0.enabledNow }
    }

    /// Names of currently-enabled tools, in table order.
    public static var enabledNames: [String] {
        enabled.map { $0.name }
    }

    /// Whether a tool exists in the catalog at all.
    public static func exists(_ name: String) -> Bool {
        all.contains { $0.name == name }
    }

    /// Whether a tool is enabled in this build.
    public static func isEnabled(_ name: String) -> Bool {
        all.first { $0.name == name }?.enabledNow ?? false
    }
}
