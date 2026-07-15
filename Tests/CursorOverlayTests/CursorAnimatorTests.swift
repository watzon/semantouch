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

    // MARK: - Fixed-step spring + settling

    func testFixedStepDeterminismAcrossDtPartitions() {
        // Same total time partitioned as many small frames vs fewer large ones must land
        // within a tight band — the fixed-step integrator + residual accumulator make
        // motion near frame-rate independent.
        func run(partition: Double) -> Point {
            let a = CursorAnimator(config: CursorMotionConfig(
                positionRate: 14,
                epsilon: 0.5,
                fixedStep: 1.0 / 240.0,
                travelDuration: 0.45
            ))
            a.reset(color: color, at: Point(x: 0, y: 0))
            a.retarget(to: Point(x: 240, y: 0), state: .moving)
            var remaining = 0.48
            while remaining > 1e-12 {
                let step = min(partition, remaining)
                _ = a.tick(dt: step)
                remaining -= step
            }
            return a.tick(dt: 0).position
        }

        let fine = run(partition: 1.0 / 120.0)
        let mid = run(partition: 1.0 / 60.0)
        let coarse = run(partition: 1.0 / 30.0)

        XCTAssertEqual(fine.x, mid.x, accuracy: 1.5)
        XCTAssertEqual(fine.y, mid.y, accuracy: 1.5)
        XCTAssertEqual(fine.x, coarse.x, accuracy: 2.5)
        XCTAssertEqual(fine.y, coarse.y, accuracy: 2.5)
    }

    func testSettlesExactlyAtTargetWithinEpsilon() {
        let animator = CursorAnimator(rate: 16, epsilon: 0.5)
        animator.reset(color: color, at: Point(x: 10, y: 20))
        animator.retarget(to: Point(x: 310, y: 220), state: .moving)

        var last = animator.tick(dt: 0.016)
        for _ in 0..<600 {
            last = animator.tick(dt: 0.016)
            if last.settled { break }
        }
        XCTAssertTrue(last.settled)
        XCTAssertEqual(last.position.x, 310, accuracy: 0.5)
        XCTAssertEqual(last.position.y, 220, accuracy: 0.5)
        // Exact snap once settled: further ticks stay put.
        let held = animator.tick(dt: 0.1)
        XCTAssertEqual(held.position.x, 310, accuracy: 1e-9)
        XCTAssertEqual(held.position.y, 220, accuracy: 1e-9)
    }

    func testCriticallyDampedSpringDoesNotUnboundedOscillate() {
        // Mild underdamping may overshoot briefly; residual must die and the tip settle
        // exactly at the target (no unbounded oscillation).
        let animator = CursorAnimator(config: CursorMotionConfig(
            positionRate: 18,
            epsilon: 0.5,
            springStiffness: 400,
            springDamping: 2.0 * 400.0.squareRoot() * 0.75, // underdamped
            travelDuration: 0.35
        ))
        animator.reset(color: color, at: Point(x: 0, y: 0))
        animator.retarget(to: Point(x: 200, y: 0), state: .moving)

        var crossings = 0
        var prevSign = 0
        var lastX = 0.0
        for _ in 0..<400 {
            let f = animator.tick(dt: 0.016)
            let err = f.position.x - 200
            let sign = err > 0.5 ? 1 : (err < -0.5 ? -1 : 0)
            if sign != 0, prevSign != 0, sign != prevSign {
                crossings += 1
            }
            if sign != 0 { prevSign = sign }
            lastX = f.position.x
        }
        // A brief underdamped overshoot is fine; sustained ringing is not.
        XCTAssertLessThanOrEqual(crossings, 4, "expected damped overshoot, not unbounded oscillation")
        XCTAssertEqual(lastX, 200, accuracy: 0.5)
        XCTAssertTrue(animator.isSettled)
    }

    func testRetargetHeadingContinuitySelectsNewPath() throws {
        let animator = CursorAnimator(config: CursorMotionConfig(
            positionRate: 14,
            epsilon: 0.5,
            travelDuration: 0.4
        ))
        animator.reset(color: color, at: Point(x: 0, y: 0))
        // Fly right so heading becomes ~0.
        animator.retarget(to: Point(x: 400, y: 0), state: .moving)
        for _ in 0..<12 { _ = animator.tick(dt: 0.016) }
        XCTAssertEqual(animator.activePathKind, .direct)

        // Retarget reverse while still moving right → brake or orbit (heading-aware).
        animator.retarget(to: Point(x: 0, y: 0), state: .moving)
        let kind = try XCTUnwrap(animator.activePathKind)
        XCTAssertTrue(kind == .brake || kind == .orbit, "reverse retarget should pick brake/orbit, got \(kind)")

        // Continues without exploding; eventually settles at the new target.
        var last = animator.tick(dt: 0.016)
        for _ in 0..<800 {
            last = animator.tick(dt: 0.016)
            XCTAssertTrue(last.position.x.isFinite)
            XCTAssertTrue(last.position.y.isFinite)
            if last.settled { break }
        }
        XCTAssertEqual(last.position.x, 0, accuracy: 0.5)
        XCTAssertEqual(last.position.y, 0, accuracy: 0.5)
    }

    func testNonFiniteAndLargeDtAreContained() {
        let animator = CursorAnimator(rate: 12, epsilon: 0.5)
        animator.reset(color: color, at: Point(x: 50, y: 50))
        animator.retarget(to: Point(x: 150, y: 80), state: .moving)

        // Non-finite dt must not move or NaN the state.
        let before = animator.tick(dt: 0.016).position
        let nanFrame = animator.tick(dt: .nan)
        XCTAssertEqual(nanFrame.position.x, before.x, accuracy: 1e-9)
        XCTAssertEqual(nanFrame.position.y, before.y, accuracy: 1e-9)

        let infFrame = animator.tick(dt: .infinity)
        XCTAssertTrue(infFrame.position.x.isFinite)
        XCTAssertTrue(infFrame.position.y.isFinite)

        // Huge dt is clamped; tip stays finite and progresses toward the target.
        let huge = animator.tick(dt: 10.0)
        XCTAssertTrue(huge.position.x.isFinite)
        XCTAssertTrue(huge.position.y.isFinite)
        XCTAssertGreaterThan(huge.position.x, before.x - 1e-6)

        // Non-finite target is rejected (falls back to previous target / safe point).
        animator.retarget(to: Point(x: .nan, y: .infinity), state: .moving)
        let safe = animator.tick(dt: 0.016)
        XCTAssertTrue(safe.position.x.isFinite)
        XCTAssertTrue(safe.position.y.isFinite)
    }

    func testActivePathKindDirectForAlignedHop() {
        let animator = CursorAnimator()
        animator.reset(color: color, at: Point(x: 0, y: 0))
        // Default heading 0; target straight ahead → direct.
        animator.retarget(to: Point(x: 200, y: 0), state: .moving)
        XCTAssertEqual(animator.activePathKind, .direct)
    }
}
