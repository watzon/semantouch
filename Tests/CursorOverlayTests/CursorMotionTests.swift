import XCTest
import ComputerUseCore
@testable import CursorOverlay

/// The lifelike-motion model: velocity-derived lean/skew/
/// stretch, press squash, and click ripples — all pure and deterministic via `tickRender`.
/// Also covers heading-aware trajectory planning (direct/turn/brake/orbit).
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

    // MARK: - Trajectory path kinds

    func testTrajectorySelectsDirectWhenAligned() {
        let path = CursorTrajectory.plan(
            from: Point(x: 0, y: 0),
            to: Point(x: 200, y: 0),
            heading: 0
        )
        XCTAssertEqual(path.kind, .direct)
        assertExactEndpoints(path, start: Point(x: 0, y: 0), end: Point(x: 200, y: 0))
    }

    func testTrajectorySelectsTurnForModerateHeadingChange() {
        // Heading east, target north → ~90° change → turn.
        let path = CursorTrajectory.plan(
            from: Point(x: 0, y: 0),
            to: Point(x: 0, y: 180),
            heading: 0
        )
        XCTAssertEqual(path.kind, .turn)
        assertExactEndpoints(path, start: Point(x: 0, y: 0), end: Point(x: 0, y: 180))
        // Turn bulges off the chord (not a straight line of samples).
        let mid = path.point(at: 0.5)
        XCTAssertGreaterThan(abs(mid.x), 1.0, "turn path should leave the vertical chord")
    }

    func testTrajectorySelectsBrakeForSharpShortReverse() {
        // Heading east, short hop west → brake.
        let path = CursorTrajectory.plan(
            from: Point(x: 100, y: 0),
            to: Point(x: 40, y: 0),
            heading: 0
        )
        XCTAssertEqual(path.kind, .brake)
        assertExactEndpoints(path, start: Point(x: 100, y: 0), end: Point(x: 40, y: 0))
    }

    func testTrajectorySelectsOrbitForSharpLongReverse() {
        // Heading east, long hop west → orbit.
        let path = CursorTrajectory.plan(
            from: Point(x: 0, y: 0),
            to: Point(x: -300, y: 0),
            heading: 0
        )
        XCTAssertEqual(path.kind, .orbit)
        assertExactEndpoints(path, start: Point(x: 0, y: 0), end: Point(x: -300, y: 0))
        let mid = path.point(at: 0.5)
        XCTAssertGreaterThan(abs(mid.y), 5.0, "orbit should bulge off the horizontal chord")
    }

    func testTrajectoryEndpointsAndSampleBounds() {
        let start = Point(x: 12, y: 34)
        let end = Point(x: 210, y: -40)
        let path = CursorTrajectory.plan(from: start, to: end, heading: .pi / 4, sampleCount: 24)

        XCTAssertEqual(path.samples.count, 24)
        let first = path.samples[0]
        let last = path.samples[path.samples.count - 1]
        XCTAssertEqual(first.x, start.x, accuracy: 0)
        XCTAssertEqual(first.y, start.y, accuracy: 0)
        XCTAssertEqual(last.x, end.x, accuracy: 0)
        XCTAssertEqual(last.y, end.y, accuracy: 0)

        // Interpolation clamps and preserves endpoints exactly.
        let p0 = path.point(at: -1)
        let p1 = path.point(at: 0)
        let pEnd = path.point(at: 1)
        let pPast = path.point(at: 2)
        XCTAssertEqual(p0.x, start.x, accuracy: 0)
        XCTAssertEqual(p0.y, start.y, accuracy: 0)
        XCTAssertEqual(p1.x, start.x, accuracy: 0)
        XCTAssertEqual(p1.y, start.y, accuracy: 0)
        XCTAssertEqual(pEnd.x, end.x, accuracy: 0)
        XCTAssertEqual(pEnd.y, end.y, accuracy: 0)
        XCTAssertEqual(pPast.x, end.x, accuracy: 0)
        XCTAssertEqual(pPast.y, end.y, accuracy: 0)

        // Interior samples stay finite.
        for s in path.samples {
            XCTAssertTrue(s.x.isFinite)
            XCTAssertTrue(s.y.isFinite)
        }
    }

    func testTrajectoryZeroDistanceAndNonFiniteCollapseSafely() {
        let start = Point(x: 7, y: 9)
        let zero = CursorTrajectory.plan(from: start, to: start, heading: 1.2)
        XCTAssertEqual(zero.kind, .direct)
        XCTAssertEqual(zero.samples.count, 2)
        XCTAssertEqual(zero.samples[0], start)
        XCTAssertEqual(zero.samples[1], start)

        let bad = CursorTrajectory.plan(
            from: Point(x: .nan, y: 1),
            to: Point(x: 3, y: .infinity),
            heading: .nan
        )
        XCTAssertEqual(bad.kind, .direct)
        XCTAssertTrue(bad.samples[0].x.isFinite)
        XCTAssertTrue(bad.samples[0].y.isFinite)
        XCTAssertTrue(bad.samples.last!.x.isFinite)
        XCTAssertTrue(bad.samples.last!.y.isFinite)
    }

    func testTrajectorySampleCountIsBounded() {
        let tiny = CursorTrajectory.plan(
            from: Point(x: 0, y: 0),
            to: Point(x: 10, y: 0),
            heading: 0,
            sampleCount: 1
        )
        XCTAssertEqual(tiny.samples.count, 2) // at least endpoints

        let huge = CursorTrajectory.plan(
            from: Point(x: 0, y: 0),
            to: Point(x: 10, y: 0),
            heading: 0,
            sampleCount: 10_000
        )
        XCTAssertLessThanOrEqual(huge.samples.count, 48)
    }

    func testAnimatorUsesAllFourPathKindsAcrossHeadings() {
        // Direct
        let direct = CursorTrajectory.plan(from: .init(x: 0, y: 0), to: .init(x: 100, y: 0), heading: 0)
        // Turn (~90°)
        let turn = CursorTrajectory.plan(from: .init(x: 0, y: 0), to: .init(x: 0, y: 100), heading: 0)
        // Brake (reverse, short)
        let brake = CursorTrajectory.plan(from: .init(x: 50, y: 0), to: .init(x: 0, y: 0), heading: 0)
        // Orbit (reverse, long)
        let orbit = CursorTrajectory.plan(from: .init(x: 0, y: 0), to: .init(x: -250, y: 0), heading: 0)

        XCTAssertEqual(direct.kind, .direct)
        XCTAssertEqual(turn.kind, .turn)
        XCTAssertEqual(brake.kind, .brake)
        XCTAssertEqual(orbit.kind, .orbit)

        // All four kinds are distinct and cover the enum surface.
        let kinds: Set<CursorPathKind> = [direct.kind, turn.kind, brake.kind, orbit.kind]
        XCTAssertEqual(kinds, Set(CursorPathKind.allCases))
    }

    func testPressArrivalRippleAfterCurvedPath() throws {
        // Press via a turn path: ripple still deferred until arrival at the intended tip.
        let m = CursorAnimator(config: CursorMotionConfig(travelDuration: 0.35))
        m.reset(color: .identity(forSession: "s", alpha: 1), at: Point(x: 0, y: 0))
        // Seed a non-zero heading by flying east briefly, then press north.
        m.retarget(to: Point(x: 200, y: 0), state: .moving)
        for _ in 0..<8 { _ = m.tickRender(dt: 0.016) }

        m.retarget(to: Point(x: 200, y: 180), state: .pressed)
        XCTAssertEqual(m.activePathKind, .turn)
        XCTAssertTrue(m.tickRender(dt: 0.016).ripples.isEmpty)

        m.retarget(to: Point(x: 200, y: 180), state: .idle)
        var landed: RippleFrame?
        for _ in 0..<800 {
            let f = m.tickRender(dt: 0.016)
            if let r = f.ripples.first { landed = r; break }
        }
        let ripple = try XCTUnwrap(landed)
        XCTAssertEqual(ripple.center.x, 200, accuracy: 5.0)
        XCTAssertEqual(ripple.center.y, 180, accuracy: 5.0)
    }

    // MARK: - Helpers

    private func assertExactEndpoints(_ path: CursorTrajectory, start: Point, end: Point, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(path.start.x, start.x, accuracy: 0, file: file, line: line)
        XCTAssertEqual(path.start.y, start.y, accuracy: 0, file: file, line: line)
        XCTAssertEqual(path.end.x, end.x, accuracy: 0, file: file, line: line)
        XCTAssertEqual(path.end.y, end.y, accuracy: 0, file: file, line: line)
        XCTAssertFalse(path.samples.isEmpty, file: file, line: line)
        let first = path.samples[0]
        let last = path.samples[path.samples.count - 1]
        XCTAssertEqual(first.x, start.x, accuracy: 0, file: file, line: line)
        XCTAssertEqual(first.y, start.y, accuracy: 0, file: file, line: line)
        XCTAssertEqual(last.x, end.x, accuracy: 0, file: file, line: line)
        XCTAssertEqual(last.y, end.y, accuracy: 0, file: file, line: line)
    }
}
