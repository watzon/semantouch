import XCTest
import ComputerUseCore
@testable import CursorOverlay

/// The lifelike-motion model: velocity-derived lean/skew/
/// stretch, press squash, and click ripples — all pure and deterministic via `tickRender`.
final class CursorMotionTests: XCTestCase {

    private func makeMotion() -> CursorAnimator {
        let m = CursorAnimator()
        m.reset(color: .identity(forSession: "s1", alpha: 0.95), at: Point(x: 0, y: 0))
        return m
    }

    // MARK: - Pose at rest

    func testRestPoseIsNeutral() {
        let m = makeMotion()
        let f = m.tickRender(dt: 0.016)
        XCTAssertEqual(f.pose.angleRadians, 0, accuracy: 1e-9)
        XCTAssertEqual(f.pose.skewX, 0, accuracy: 1e-9)
        XCTAssertEqual(f.pose.scale, 1, accuracy: 1e-6)
        XCTAssertTrue(f.ripples.isEmpty)
    }

    func testSettledWhenAtTargetIdleNoRipples() {
        let m = makeMotion()
        // No retarget: already at rest at the origin.
        XCTAssertTrue(m.tickRender(dt: 0.016).settled)
    }

    // MARK: - Travel produces a lean and eventually settles upright

    func testMovingRightLeansAndSkewsThenSettlesUpright() {
        let m = makeMotion()
        m.retarget(to: Point(x: 800, y: 0), state: .moving)
        // Early in the flight the arrow is fast → it should lean and skew.
        var leaned = false
        for _ in 0..<6 {
            let f = m.tickRender(dt: 0.016)
            if abs(f.pose.angleRadians) > 0.02 && abs(f.pose.skewX) > 0.01 { leaned = true }
        }
        XCTAssertTrue(leaned, "a fast rightward flight should lean and skew the arrow")

        // Let it arrive and go idle; the pose returns to neutral and it settles.
        m.retarget(to: Point(x: 800, y: 0), state: .idle)
        var last = m.tickRender(dt: 0.016)
        for _ in 0..<600 { last = m.tickRender(dt: 0.016) }
        XCTAssertEqual(last.pose.position.x, 800, accuracy: 1.0)
        XCTAssertEqual(last.pose.angleRadians, 0, accuracy: 0.02)
        XCTAssertEqual(last.pose.skewX, 0, accuracy: 0.02)
        XCTAssertEqual(last.pose.scale, 1, accuracy: 0.02)
        XCTAssertTrue(last.settled)
    }

    func testLeanIsClampedForVeryFastTravel() {
        let m = CursorAnimator(config: CursorMotionConfig(maxLean: 0.20))
        m.reset(color: .identity(forSession: "s", alpha: 1), at: Point(x: 0, y: 0))
        m.retarget(to: Point(x: 100000, y: 0), state: .moving)
        for _ in 0..<5 {
            let f = m.tickRender(dt: 0.016)
            XCTAssertLessThanOrEqual(abs(f.pose.angleRadians), 0.20 + 1e-9)
        }
    }

    // MARK: - Press ripple

    func testPressSpawnsOneExpandingFadingRipple() {
        let m = makeMotion()
        m.retarget(to: Point(x: 0, y: 0), state: .pressed)   // press transition → one ripple
        let f0 = m.tickRender(dt: 0.016)
        XCTAssertEqual(f0.ripples.count, 1)
        let first = f0.ripples[0]

        // It grows and fades over subsequent frames.
        var prevR = first.radius
        var prevA = first.alpha
        for _ in 0..<5 {
            let r = m.tickRender(dt: 0.03).ripples.first
            guard let r else { break }
            XCTAssertGreaterThanOrEqual(r.radius, prevR)   // expands
            XCTAssertLessThanOrEqual(r.alpha, prevA)        // fades
            prevR = r.radius; prevA = r.alpha
        }
    }

    func testRippleExpiresAndModelSettles() {
        let m = makeMotion()
        m.retarget(to: Point(x: 0, y: 0), state: .pressed)
        _ = m.tickRender(dt: 0.016)
        m.retarget(to: Point(x: 0, y: 0), state: .idle)   // click released → idle at same spot
        // Past the ripple duration, no ripple remains and the model reports settled.
        var f = m.tickRender(dt: 0.016)
        for _ in 0..<60 { f = m.tickRender(dt: 0.016) }
        XCTAssertTrue(f.ripples.isEmpty)
        XCTAssertTrue(f.settled)
    }

    func testPressRippleFiresOnArrivalNotDeparture() throws {
        let m = makeMotion()   // tip at the origin
        // Press a DISTANT target: no ripple during the flight (the bubble must bloom under
        // the click destination, not where the cursor departed from).
        m.retarget(to: Point(x: 500, y: 0), state: .pressed)
        XCTAssertTrue(m.tickRender(dt: 0.016).ripples.isEmpty)
        XCTAssertTrue(m.tickRender(dt: 0.016).ripples.isEmpty)
        // The follow-up idle (like `finish`) at the same target keeps the deferred press alive.
        m.retarget(to: Point(x: 500, y: 0), state: .idle)

        var landed: RippleFrame?
        for _ in 0..<600 {
            if let r = m.tickRender(dt: 0.016).ripples.first { landed = r; break }
        }
        let ripple = try XCTUnwrap(landed, "the deferred ripple should fire once the tip arrives")
        XCTAssertEqual(ripple.center.x, 500, accuracy: 5.0)   // at the click, not the origin
        XCTAssertEqual(ripple.center.y, 0, accuracy: 5.0)
    }

    func testPendingPressFiresAtIntendedLocationIfRedirectedMidFlight() throws {
        let m = makeMotion()
        m.retarget(to: Point(x: 500, y: 0), state: .pressed)
        _ = m.tickRender(dt: 0.016)
        XCTAssertTrue(m.tickRender(dt: 0.016).ripples.isEmpty, "no ripple yet, still in flight")
        // A new action redirects the cursor before the click landed: the ripple must still
        // appear at the INTENDED click location, not be dropped or misplaced.
        m.retarget(to: Point(x: -500, y: 0), state: .moving)
        let r = try XCTUnwrap(m.tickRender(dt: 0.016).ripples.first)
        XCTAssertEqual(r.center.x, 500, accuracy: 5.0)
    }

    func testDistinctPressesEachSpawnARipple() {
        let m = makeMotion()
        m.retarget(to: Point(x: 0, y: 0), state: .pressed)
        _ = m.tickRender(dt: 0.016)
        m.retarget(to: Point(x: 0, y: 0), state: .idle)
        _ = m.tickRender(dt: 0.016)
        m.retarget(to: Point(x: 0, y: 0), state: .pressed)   // second distinct press
        let f = m.tickRender(dt: 0.016)
        XCTAssertEqual(f.ripples.count, 2, "two live ripples (the first not yet expired)")
    }

    // MARK: - Outline transform

    func testOutlineTipTracksPoseExactly() {
        // The tip (base point 0) must land exactly on the pose position regardless of
        // rotation/skew/scale — the hotspot never drifts off the target.
        let pose = CursorPose(position: Point(x: 321, y: 654), angleRadians: 0.15, skewX: 0.1, scale: 1.3)
        let pts = CursorArt.outlinePath(pose: pose, artScale: 1.25)
        XCTAssertEqual(pts[0].x, 321, accuracy: 1e-9)
        XCTAssertEqual(pts[0].y, 654, accuracy: 1e-9)
    }

    func testOutlineNeutralPoseIsTranslatedArtScaledBase() {
        let pose = CursorPose.rest(at: Point(x: 10, y: 20))
        let pts = CursorArt.outlinePath(pose: pose, artScale: 2.0)
        // Second base point (0, 21) → art-scaled (0, 42) → translated (10, 62).
        XCTAssertEqual(pts[1].x, 10, accuracy: 1e-9)
        XCTAssertEqual(pts[1].y, 62, accuracy: 1e-9)
    }
}
