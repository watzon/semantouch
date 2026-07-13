import XCTest
import ComputerUseCore
@testable import ActionEngine

/// The pure interference-policy decision table (§16). No silent escalation.
final class InterferencePlanTests: XCTestCase {
    func testAlreadyFrontmostDeliversInBackgroundForEveryMode() {
        for mode in InterferencePolicy.allCases {
            XCTAssertEqual(
                InterferencePlan.decide(mode: mode, targetIsFrontmost: true),
                .deliverInBackground,
                "already-frontmost \(mode.rawValue) should deliver with no focus change"
            )
        }
    }

    func testBackgroundOnlyNotFrontmostRequiresFocus() {
        XCTAssertEqual(
            InterferencePlan.decide(mode: .backgroundOnly, targetIsFrontmost: false),
            .focusRequired
        )
    }

    func testAllowBriefFocusNotFrontmostPlansBriefFocus() {
        XCTAssertEqual(
            InterferencePlan.decide(mode: .allowBriefFocus, targetIsFrontmost: false),
            .briefFocus
        )
    }

    func testForegroundTakeoverNotFrontmostPlansTakeover() {
        XCTAssertEqual(
            InterferencePlan.decide(mode: .foregroundTakeover, targetIsFrontmost: false),
            .takeover
        )
    }

    func testFocusModeMapping() {
        XCTAssertEqual(InterferencePlan.deliverInBackground.focusMode, .none)
        XCTAssertEqual(InterferencePlan.focusRequired.focusMode, .none)
        XCTAssertEqual(InterferencePlan.briefFocus.focusMode, .activateRestore)
        XCTAssertEqual(InterferencePlan.takeover.focusMode, .activateLeave)
    }
}
