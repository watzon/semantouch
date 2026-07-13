import XCTest
import ComputerUseCore
@testable import CursorOverlay

/// Animator interpolation and the decoupling invariant. No AppKit, no clock.
final class CursorAnimatorTests: XCTestCase {

    private let color = CursorColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 0.95)

    func testIdentityColorNilBeforeReset() {
        XCTAssertNil(CursorAnimator().identityColor)
    }

    func testResetSnapsPositionAndAdoptsColor() {
        let animator = CursorAnimator()
        animator.reset(color: color, at: Point(x: 5, y: 5))
        XCTAssertEqual(animator.identityColor, color)
        // Target == position → already settled; a tick does not move it.
        XCTAssertTrue(animator.isSettled)
        let frame = animator.tick(dt: 0.016)
        XCTAssertEqual(frame.position, Point(x: 5, y: 5))
        XCTAssertTrue(frame.settled)
        XCTAssertEqual(frame.visualState, .idle)
    }

    func testRetargetInterpolatesTowardTarget() {
        let animator = CursorAnimator(rate: 14, epsilon: 0.5)
        animator.reset(color: color, at: Point(x: 0, y: 0))
        animator.retarget(to: Point(x: 100, y: 0), state: .moving)

        // Not settled immediately after retargeting to a far point.
        XCTAssertFalse(animator.isSettled)

        var last = 0.0
        // A sequence of small ticks approaches the target monotonically without overshoot.
        for _ in 0..<200 {
            let frame = animator.tick(dt: 0.016)
            XCTAssertGreaterThanOrEqual(frame.position.x, last - 1e-9) // monotonic
            XCTAssertLessThanOrEqual(frame.position.x, 100 + 1e-9)     // no overshoot
            XCTAssertEqual(frame.visualState, .moving)                 // state passes through
            last = frame.position.x
        }
        XCTAssertTrue(animator.isSettled)
        XCTAssertEqual(animator.tick(dt: 0.016).position.x, 100, accuracy: 0.5)
    }

    func testNonPositiveDtDoesNotAdvance() {
        let animator = CursorAnimator()
        animator.reset(color: color, at: Point(x: 0, y: 0))
        animator.retarget(to: Point(x: 50, y: 50), state: .dragging)
        let frame = animator.tick(dt: 0)
        XCTAssertEqual(frame.position, Point(x: 0, y: 0))
        XCTAssertEqual(frame.visualState, .dragging)
    }

    func testStopReturnsToIdleAndHolds() {
        let animator = CursorAnimator()
        animator.reset(color: color, at: Point(x: 10, y: 10))
        animator.retarget(to: Point(x: 90, y: 90), state: .pressed)
        _ = animator.tick(dt: 0.016)
        animator.stop()
        // After stop, the target is pinned to the current position and the state is idle.
        XCTAssertTrue(animator.isSettled)
        XCTAssertEqual(animator.tick(dt: 1).visualState, .idle)
    }

    // MARK: Decoupling invariant

    func testSynchronizeReturnsImmediatelyWhileUnsettled() {
        let animator = CursorAnimator()
        animator.reset(color: color, at: Point(x: 0, y: 0))
        animator.retarget(to: Point(x: 500, y: 500), state: .moving)
        XCTAssertFalse(animator.isSettled)

        // The scheduler's sync point returns without waiting for the animation to settle.
        animator.synchronize()
        XCTAssertEqual(animator.synchronizeCount, 1)
        // Still unsettled — synchronize() did NOT drive the animation to completion.
        XCTAssertFalse(animator.isSettled)
    }

    /// The core decoupling proof: a controller driven by an animator that NEVER settles
    /// still runs the entire action lifecycle (reflect → synchronize → finish) to
    /// completion without blocking. Action completion never awaits animation completion.
    func testControllerNeverBlocksOnAnUnsettlingAnimator() {
        let presenter = FakeCursorPresenter()
        let animator = NeverSettlingAnimator()
        let controller = CursorController(presenter: presenter, animator: animator, preference: .on)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 10, y: 20), pointerKind: true)
        // The action scheduler's sync point — must return even though the animator reports
        // it will never settle.
        controller.synchronize()
        controller.finish(sessionId: "s1", interrupted: false)

        // The animator was driven (retargeted, synced, and settled==false throughout) but
        // nothing waited on it.
        XCTAssertFalse(animator.isSettled)
        XCTAssertEqual(animator.synchronizeCount, 1)
        XCTAssertGreaterThanOrEqual(animator.retargets.count, 1)
        XCTAssertEqual(animator.resetCount, 1)
        // The presenter still received the full show/update sequence.
        XCTAssertEqual(presenter.showCount, 1)
        XCTAssertGreaterThanOrEqual(presenter.updateCount, 1)
    }
}
