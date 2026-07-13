import XCTest
import CursorOverlay
@testable import ComputerUseService

/// The `mcp` runtime's overlay host/no-host DECISION (persistent-cursor task): host an AppKit
/// run loop iff the cursor overlay is ENABLED (`SEMANTOUCH_CURSOR != off`) AND a GUI session is
/// available. The run-loop hosting itself is proven live in Stage H; here we pin the pure
/// decision over a fake environment + a fake GUI flag so the headless-safe contract is locked
/// (disabled/headless → NEVER host → no NSApp, no window).
final class MCPRuntimeHostingTests: XCTestCase {

    // MARK: Enabled preference + GUI present → HOST

    func testDefaultPreferenceWithGuiHosts() {
        // No `SEMANTOUCH_CURSOR` set → default `on`.
        XCTAssertTrue(MCPRuntime.shouldHostOverlay(environment: [:], guiSessionAvailable: true))
    }

    func testOnPreferenceWithGuiHosts() {
        XCTAssertTrue(MCPRuntime.shouldHostOverlay(environment: ["SEMANTOUCH_CURSOR": "on"], guiSessionAvailable: true))
    }

    func testDimPreferenceWithGuiHosts() {
        // `dim` still presents (translucent), so it must host.
        XCTAssertTrue(MCPRuntime.shouldHostOverlay(environment: ["SEMANTOUCH_CURSOR": "dim"], guiSessionAvailable: true))
    }

    func testUnrecognizedPreferenceFallsBackToOnAndHostsWithGui() {
        // Any unrecognized value resolves to the documented default `on`.
        XCTAssertTrue(MCPRuntime.shouldHostOverlay(environment: ["SEMANTOUCH_CURSOR": "sparkle"], guiSessionAvailable: true))
    }

    // MARK: Disabled preference → NEVER host (even with a GUI)

    func testOffPreferenceNeverHostsEvenWithGui() {
        XCTAssertFalse(MCPRuntime.shouldHostOverlay(environment: ["SEMANTOUCH_CURSOR": "off"], guiSessionAvailable: true))
    }

    func testOffPreferenceCaseInsensitiveNeverHosts() {
        XCTAssertFalse(MCPRuntime.shouldHostOverlay(environment: ["SEMANTOUCH_CURSOR": "OFF"], guiSessionAvailable: true))
    }

    // MARK: No GUI session (headless/CI/ssh) → NEVER host (even when enabled)

    func testEnabledButHeadlessNeverHosts() {
        XCTAssertFalse(MCPRuntime.shouldHostOverlay(environment: ["SEMANTOUCH_CURSOR": "on"], guiSessionAvailable: false))
    }

    func testDefaultButHeadlessNeverHosts() {
        XCTAssertFalse(MCPRuntime.shouldHostOverlay(environment: [:], guiSessionAvailable: false))
    }

    func testDisabledAndHeadlessNeverHosts() {
        XCTAssertFalse(MCPRuntime.shouldHostOverlay(environment: ["SEMANTOUCH_CURSOR": "off"], guiSessionAvailable: false))
    }

    // MARK: The decision is exactly (enabled AND gui) across the full truth table

    func testDecisionIsEnabledAndGui() {
        for pref in ["on", "dim", "off", ""] {
            for gui in [true, false] {
                let env = pref.isEmpty ? [:] : ["SEMANTOUCH_CURSOR": pref]
                let enabled = CursorPreference.fromEnvironment(env) != .off
                XCTAssertEqual(
                    MCPRuntime.shouldHostOverlay(environment: env, guiSessionAvailable: gui),
                    enabled && gui,
                    "pref=\(pref.isEmpty ? "<unset>" : pref) gui=\(gui)"
                )
            }
        }
    }
}
