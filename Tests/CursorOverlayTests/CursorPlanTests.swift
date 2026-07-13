import XCTest
import ComputerUseCore
@testable import CursorOverlay

/// Goldens for the pure overlay geometry. No AppKit, no windows.
final class CursorPlanTests: XCTestCase {

    // MARK: Panel frame follows the target window

    func testPanelFrameEqualsWindowFrame() {
        let plan = CursorPlan.compute(
            windowFrame: .fixtureWindow,
            action: .press,
            targetPointWindow: Point(x: 50, y: 60)
        )
        XCTAssertEqual(plan.panelFrame, .fixtureWindow)
        XCTAssertEqual(plan.cursorInPanel, Point(x: 50, y: 60))
        XCTAssertEqual(plan.visualState, .pressed)
        XCTAssertTrue(plan.presentable)
    }

    func testPanelFrameTracksAMovedWindow() {
        let plan = CursorPlan.compute(
            windowFrame: .fixtureWindowMoved,
            action: .idle,
            targetPointWindow: Point(x: 10, y: 10)
        )
        XCTAssertEqual(plan.panelFrame, .fixtureWindowMoved)
        // The cursor point is panel-local, so it is unchanged by the panel's global move.
        XCTAssertEqual(plan.cursorInPanel, Point(x: 10, y: 10))
    }

    // MARK: Clamping into the panel

    func testCursorClampsToPanelBounds() {
        // Below/left of the window → clamps to the top-left corner.
        let low = CursorPlan.compute(windowFrame: .fixtureWindow, action: .move, targetPointWindow: Point(x: -10, y: -50))
        XCTAssertEqual(low.cursorInPanel, Point(x: 0, y: 0))

        // Beyond the far edges → clamps to (width, height).
        let high = CursorPlan.compute(windowFrame: .fixtureWindow, action: .move, targetPointWindow: Point(x: 999, y: 999))
        XCTAssertEqual(high.cursorInPanel, Point(x: 400, y: 300))

        // Mixed: x in range, y past the bottom.
        let mixed = CursorPlan.compute(windowFrame: .fixtureWindow, action: .move, targetPointWindow: Point(x: 123, y: 5000))
        XCTAssertEqual(mixed.cursorInPanel, Point(x: 123, y: 300))
    }

    func testNilTargetCentersTheCursor() {
        let plan = CursorPlan.compute(windowFrame: .fixtureWindow, action: .progress, targetPointWindow: nil, progress: 0.5)
        XCTAssertEqual(plan.cursorInPanel, Point(x: 200, y: 150))
    }

    // MARK: Visual-state mapping (multi-state golden)

    func testEachActionKindMapsToItsVisualState() {
        func state(_ kind: CursorActionKind, progress: Double = 0) -> CursorVisualState {
            CursorPlan.compute(windowFrame: .fixtureWindow, action: kind, targetPointWindow: nil, progress: progress).visualState
        }
        XCTAssertEqual(state(.idle), .idle)
        XCTAssertEqual(state(.move), .moving)
        XCTAssertEqual(state(.press), .pressed)
        XCTAssertEqual(state(.drag), .dragging)
        XCTAssertEqual(state(.progress, progress: 0.25), .progress(fraction: 0.25))
    }

    func testProgressFractionIsClamped() {
        let over = CursorPlan.compute(windowFrame: .fixtureWindow, action: .progress, targetPointWindow: nil, progress: 1.7)
        XCTAssertEqual(over.visualState, .progress(fraction: 1.0))
        let under = CursorPlan.compute(windowFrame: .fixtureWindow, action: .progress, targetPointWindow: nil, progress: -3)
        XCTAssertEqual(under.visualState, .progress(fraction: 0.0))
    }

    // MARK: Degenerate windows

    func testZeroSizeWindowIsNotPresentable() {
        let zeroWidth = CursorPlan.compute(windowFrame: Rect(x: 0, y: 0, width: 0, height: 300), action: .press, targetPointWindow: nil)
        XCTAssertFalse(zeroWidth.presentable)
        let zeroHeight = CursorPlan.compute(windowFrame: Rect(x: 0, y: 0, width: 400, height: 0), action: .press, targetPointWindow: nil)
        XCTAssertFalse(zeroHeight.presentable)
        // A degenerate window still centres the cursor safely (no NaN/negative).
        XCTAssertEqual(zeroWidth.cursorInPanel, Point(x: 0, y: 150))
    }

    func testDeterministicForIdenticalInput() {
        let a = CursorPlan.compute(windowFrame: .fixtureWindow, action: .drag, targetPointWindow: Point(x: 12, y: 34))
        let b = CursorPlan.compute(windowFrame: .fixtureWindow, action: .drag, targetPointWindow: Point(x: 12, y: 34))
        XCTAssertEqual(a, b)
    }

    // MARK: Identity colour

    func testIdentityColorIsDeterministicPerSession() {
        let a = CursorColor.identity(forSession: "s7", alpha: 0.95)
        let b = CursorColor.identity(forSession: "s7", alpha: 0.95)
        XCTAssertEqual(a, b)
    }

    func testDifferentSessionsGetDifferentColors() {
        XCTAssertNotEqual(
            CursorColor.identity(forSession: "s1", alpha: 0.95),
            CursorColor.identity(forSession: "s2", alpha: 0.95)
        )
    }

    func testAlphaPassesThroughAndComponentsAreInRange() {
        let solid = CursorColor.identity(forSession: "s3", alpha: 0.95)
        let dim = CursorColor.identity(forSession: "s3", alpha: 0.5)
        XCTAssertEqual(solid.alpha, 0.95)
        XCTAssertEqual(dim.alpha, 0.5)
        // Same hue regardless of alpha.
        XCTAssertEqual(solid.red, dim.red)
        XCTAssertEqual(solid.green, dim.green)
        XCTAssertEqual(solid.blue, dim.blue)
        for c in [solid.red, solid.green, solid.blue] {
            XCTAssertGreaterThanOrEqual(c, 0)
            XCTAssertLessThanOrEqual(c, 1)
        }
    }

    func testHSBToRGBKnownValues() {
        // Pure red at hue 0.
        let red = CursorColor.hsbToRGB(hue: 0, saturation: 1, brightness: 1)
        XCTAssertEqual(red.0, 1, accuracy: 1e-9)
        XCTAssertEqual(red.1, 0, accuracy: 1e-9)
        XCTAssertEqual(red.2, 0, accuracy: 1e-9)
        // Zero saturation → greyscale at the brightness.
        let grey = CursorColor.hsbToRGB(hue: 0.5, saturation: 0, brightness: 0.4)
        XCTAssertEqual(grey.0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(grey.1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(grey.2, 0.4, accuracy: 1e-9)
    }
}
