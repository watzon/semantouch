import Foundation
import ComputerUseCore

// Pure, deterministic heading-aware cursor path planning.
//
// Clean-room geometry: given a start tip, target tip, and the cursor's current
// motion heading, select one of four path kinds (direct / turn / brake / orbit)
// and sample a bounded cubic-Bézier trajectory. Endpoints are always exact.
// No AppKit, no timers, no shared mutable state.

// MARK: - Path kind

/// Explicit trajectory shape chosen from start→target geometry and the current
/// motion heading. Selection is pure and deterministic.
public enum CursorPathKind: String, Equatable, Sendable, CaseIterable {
    /// Nearly aligned with the current heading: a straight-ish chord.
    case direct
    /// Moderate heading change: bank into the target with an offset curve.
    case turn
    /// Sharp reverse on a short hop: continue briefly, then fold back onto the target.
    case brake
    /// Sharp reverse on a longer hop: sweep an arc around the chord.
    case orbit
}

// MARK: - Trajectory

/// A bounded, pre-sampled tip path. `samples.first` is exactly `start` and
/// `samples.last` is exactly `end` (when non-empty). Interpolation between
/// samples is linear; callers may also read the discrete samples directly.
public struct CursorTrajectory: Equatable, Sendable {
    public let kind: CursorPathKind
    public let start: Point
    public let end: Point
    /// Motion heading (radians, `atan2(y, x)` in panel space) at plan time.
    public let startHeading: Double
    /// Discrete samples along the Bézier, inclusive of both endpoints.
    public let samples: [Point]

    public init(kind: CursorPathKind, start: Point, end: Point, startHeading: Double, samples: [Point]) {
        self.kind = kind
        self.start = start
        self.end = end
        self.startHeading = startHeading
        self.samples = samples
    }

    /// Plan a trajectory from `start` to `end` given the cursor's current
    /// `heading` (radians). Non-finite inputs and zero-length moves collapse to
    /// a direct path that still preserves exact endpoints.
    ///
    /// - Parameters:
    ///   - start: tip position at plan time.
    ///   - end: tip destination (kept exact in the final sample).
    ///   - heading: current motion heading in radians (`atan2(dy, dx)`).
    ///   - sampleCount: maximum discrete samples (clamped to a small bound).
    ///   - epsilon: distance under which the move is treated as zero-length.
    public static func plan(
        from start: Point,
        to end: Point,
        heading: Double,
        sampleCount: Int = 24,
        epsilon: Double = 0.5
    ) -> CursorTrajectory {
        let count = max(2, min(sampleCount, 48))
        let safeHeading = heading.isFinite ? heading : 0

        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else {
            let s = finitePoint(start, fallback: .zero)
            let e = finitePoint(end, fallback: s)
            return CursorTrajectory(
                kind: .direct,
                start: s,
                end: e,
                startHeading: safeHeading,
                samples: [s, e]
            )
        }

        let dx = end.x - start.x
        let dy = end.y - start.y
        let dist = (dx * dx + dy * dy).squareRoot()

        if dist <= max(epsilon, 0) {
            return CursorTrajectory(
                kind: .direct,
                start: start,
                end: end,
                startHeading: safeHeading,
                samples: [start, end]
            )
        }

        let desired = atan2(dy, dx)
        let delta = wrapToPi(desired - safeHeading)
        let absDelta = abs(delta)
        let kind = selectKind(distance: dist, absDelta: absDelta, epsilon: epsilon)

        let controls = controlPoints(
            kind: kind,
            start: start,
            end: end,
            heading: safeHeading,
            desired: desired,
            distance: dist,
            delta: delta
        )
        let samples = sampleCubic(
            p0: controls.0,
            p1: controls.1,
            p2: controls.2,
            p3: controls.3,
            count: count,
            start: start,
            end: end
        )

        return CursorTrajectory(
            kind: kind,
            start: start,
            end: end,
            startHeading: safeHeading,
            samples: samples
        )
    }

    /// Linearly interpolate the pre-sampled path at `t ∈ [0, 1]`. Values outside
    /// the unit interval clamp. The endpoints are exact at `t = 0` and `t = 1`.
    public func point(at t: Double) -> Point {
        let u = clamp01Finite(t)
        guard !samples.isEmpty else { return end }
        if samples.count == 1 || u <= 0 { return samples[0] }
        if u >= 1 { return samples[samples.count - 1] }

        let scaled = u * Double(samples.count - 1)
        let i = min(Int(scaled), samples.count - 2)
        let f = scaled - Double(i)
        let a = samples[i]
        let b = samples[i + 1]
        return Point(
            x: a.x + (b.x - a.x) * f,
            y: a.y + (b.y - a.y) * f
        )
    }

    /// Heading implied by the final sample segment (falls back to `startHeading`).
    public var endHeading: Double {
        guard samples.count >= 2 else { return startHeading }
        let a = samples[samples.count - 2]
        let b = samples[samples.count - 1]
        let dx = b.x - a.x
        let dy = b.y - a.y
        if (dx * dx + dy * dy) < 1e-12 { return startHeading }
        return atan2(dy, dx)
    }
}

// MARK: - Selection + construction

/// Choose a path kind from chord length and absolute heading error.
func selectCursorPathKind(distance: Double, absDelta: Double, epsilon: Double) -> CursorPathKind {
    selectKind(distance: distance, absDelta: absDelta, epsilon: epsilon)
}

private func selectKind(distance: Double, absDelta: Double, epsilon: Double) -> CursorPathKind {
    // Aligned enough → fly straight.
    if absDelta < .pi / 6 { return .direct }
    // Moderate bank → turn into the target.
    if absDelta < (2 * .pi / 3) { return .turn }
    // Near-reverse: short hops fold back (brake); longer ones arc around (orbit).
    let shortHop = max(120.0, epsilon * 40)
    if distance < shortHop { return .brake }
    return .orbit
}

private func controlPoints(
    kind: CursorPathKind,
    start: Point,
    end: Point,
    heading: Double,
    desired: Double,
    distance: Double,
    delta: Double
) -> (Point, Point, Point, Point) {
    let hDir = unitVector(heading)
    let aDir = unitVector(desired)
    // Handle length scales with travel but stays inside the chord so endpoints dominate.
    let handle = min(max(distance * 0.35, 12.0), distance * 0.75)

    switch kind {
    case .direct:
        return (
            start,
            Point(x: start.x + (end.x - start.x) / 3, y: start.y + (end.y - start.y) / 3),
            Point(x: start.x + 2 * (end.x - start.x) / 3, y: start.y + 2 * (end.y - start.y) / 3),
            end
        )

    case .turn:
        // Leave along current heading, arrive along the chord.
        return (
            start,
            Point(x: start.x + hDir.x * handle, y: start.y + hDir.y * handle),
            Point(x: end.x - aDir.x * handle, y: end.y - aDir.y * handle),
            end
        )

    case .brake:
        // Overshoot slightly along the old heading, then fold onto the target.
        let overshoot = handle * 0.45
        return (
            start,
            Point(x: start.x + hDir.x * handle, y: start.y + hDir.y * handle),
            Point(x: end.x + hDir.x * overshoot, y: end.y + hDir.y * overshoot),
            end
        )

    case .orbit:
        // Sweep to the side selected by the heading×chord cross product.
        let side: Double
        if abs(delta) < 1e-9 {
            side = 1
        } else {
            side = delta >= 0 ? 1 : -1
        }
        // Perpendicular to the chord (+y-down: rotate 90° in the heading-error direction).
        let nx = -aDir.y * side
        let ny = aDir.x * side
        let bulge = handle * 0.85
        return (
            start,
            Point(
                x: start.x + hDir.x * handle + nx * bulge,
                y: start.y + hDir.y * handle + ny * bulge
            ),
            Point(
                x: end.x - aDir.x * handle + nx * bulge,
                y: end.y - aDir.y * handle + ny * bulge
            ),
            end
        )
    }
}

private func sampleCubic(
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,
    count: Int,
    start: Point,
    end: Point
) -> [Point] {
    var samples: [Point] = []
    samples.reserveCapacity(count)
    let last = count - 1
    for i in 0...last {
        if i == 0 {
            samples.append(start)
            continue
        }
        if i == last {
            samples.append(end)
            continue
        }
        let t = Double(i) / Double(last)
        samples.append(cubicBezier(p0: p0, p1: p1, p2: p2, p3: p3, t: t))
    }
    return samples
}

private func cubicBezier(p0: Point, p1: Point, p2: Point, p3: Point, t: Double) -> Point {
    let u = 1 - t
    let uu = u * u
    let tt = t * t
    let uuu = uu * u
    let ttt = tt * t
    let x = uuu * p0.x + 3 * uu * t * p1.x + 3 * u * tt * p2.x + ttt * p3.x
    let y = uuu * p0.y + 3 * uu * t * p1.y + 3 * u * tt * p2.y + ttt * p3.y
    return Point(x: x, y: y)
}

// MARK: - Math helpers

private func unitVector(_ radians: Double) -> Point {
    let a = radians.isFinite ? radians : 0
    return Point(x: cos(a), y: sin(a))
}

/// Wrap an angle into (−π, π].
func wrapToPi(_ radians: Double) -> Double {
    guard radians.isFinite else { return 0 }
    var a = radians.truncatingRemainder(dividingBy: 2 * .pi)
    if a <= -.pi { a += 2 * .pi }
    if a > .pi { a -= 2 * .pi }
    return a
}

private func clamp01Finite(_ x: Double) -> Double {
    guard x.isFinite else { return 0 }
    return min(max(x, 0), 1)
}

private func finitePoint(_ p: Point, fallback: Point) -> Point {
    let x = p.x.isFinite ? p.x : fallback.x
    let y = p.y.isFinite ? p.y : fallback.y
    return Point(x: x, y: y)
}

private extension Point {
    static let zero = Point(x: 0, y: 0)
}
