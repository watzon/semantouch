import Foundation
import ComputerUseCore

// Cursor animation model. The animator interpolates the DRAWN cursor
// toward the action target for move/press/progress/drag states and owns the per-session
// identity colour.
//
// Core invariant: the overlay's animation is
// DECORATIVE and MUST NOT gate action correctness. The action scheduler never blocks on
// the animation finishing. `synchronize()` is that decoupling point — it returns
// immediately and is independent of whether the interpolation has reached its target.
// A separate, bounded synchronization exists so nothing in the action path ever waits
// on `isSettled`.
//
// This model is PURE (no AppKit, no timers): `tick(dt:)` advances the interpolation by a
// caller-supplied time step and returns the drawn frame, so the easing is fully
// deterministic and unit-testable. The live AppKit presenter performs its own on-screen
// interpolation via Core Animation; this model is the tested reference and the seam the
// controller drives.
//
// Motion: heading-aware trajectory planning (direct/turn/brake/orbit) plus a fixed-step
// critically-damped spring that tracks the planned path. Results are near frame-rate
// independent and settle without unbounded oscillation. Endpoints stay exact within
// the configured epsilon.

// MARK: - Frame

/// One drawn cursor frame: the interpolated position (panel-local points), the visual
/// state, and whether the interpolation has settled at its target.
public struct CursorFrame: Equatable, Sendable {
    public let position: Point
    public let visualState: CursorVisualState
    public let settled: Bool

    public init(position: Point, visualState: CursorVisualState, settled: Bool) {
        self.position = position
        self.visualState = visualState
        self.settled = settled
    }
}

// MARK: - Seam

/// The animation seam the `CursorController` drives. Injected so the controller's
/// decoupling from animation completion is provable with a fake animator that never
/// settles.
public protocol CursorAnimating: AnyObject {
    /// The identity colour set by `reset(color:at:)`, or `nil` before a session starts.
    var identityColor: CursorColor? { get }

    /// Whether the interpolation has reached its target. Advisory only — NOTHING in the
    /// action path may block on this.
    var isSettled: Bool { get }

    /// Begin/reset for a session: adopt `color` and snap the drawn position to `position`.
    func reset(color: CursorColor, at position: Point)

    /// Retarget the drawn cursor toward `target` in `state`. Non-blocking; the on-screen
    /// cursor eases toward `target` over subsequent `tick`s.
    func retarget(to target: Point, state: CursorVisualState)

    /// Advance the interpolation by `dt` seconds and return the current drawn frame.
    func tick(dt: Double) -> CursorFrame

    /// The action scheduler's SYNCHRONIZATION POINT. MUST return immediately and MUST NOT
    /// block on `isSettled` or animation completion. Bounded to a no-op here.
    func synchronize()

    /// Stop and reset to idle (session end/pause).
    func stop()
}

// MARK: - Live model

/// Tunable feel of the lifelike cursor motion. Defaults chosen to read as a
/// cursor "flying" to its target and settling upright; the presenter can pass custom values
/// and tests pin the math against explicit ones.
public struct CursorMotionConfig: Equatable, Sendable {
    /// Per-second approach rate kept for public API compatibility. When
    /// `springStiffness` is `0`, stiffness is derived as `positionRate²`.
    public var positionRate: Double
    /// Distance (panel points) under which the tip counts as settled.
    public var epsilon: Double
    /// Per-second rate the lean/skew/scale ease toward their velocity-derived targets.
    public var poseRate: Double
    /// Radians of lean per (point/second) of velocity, before clamping.
    public var leanPerSpeed: Double
    /// Maximum absolute lean (radians).
    public var maxLean: Double
    /// Horizontal shear per (point/second) of horizontal velocity, before clamping.
    public var skewPerSpeed: Double
    /// Maximum absolute shear.
    public var maxSkew: Double
    /// Extra scale per (point/second) of speed, before clamping (the "stretch").
    public var stretchPerSpeed: Double
    /// Maximum extra stretch scale.
    public var maxStretch: Double
    /// Scale the cursor squashes to while a press is held.
    public var pressScale: Double
    /// Low-pass smoothing for velocity (0 = ignore new, 1 = no smoothing). Keeps lean/skew
    /// from jittering on a single noisy step.
    public var velocitySmoothing: Double
    /// Click-ripple lifetime (seconds).
    public var rippleDuration: Double
    /// Click-ripple maximum radius (points).
    public var rippleMaxRadius: Double
    /// Click-ripple starting opacity (fades to 0).
    public var rippleStartAlpha: Double
    /// Fixed integration step in seconds for the damped spring (frame-rate independence).
    public var fixedStep: Double
    /// Spring stiffness (ω²). `0` means derive from `positionRate` (`≈ rate²`).
    public var springStiffness: Double
    /// Spring damping coefficient. `0` selects the default overdamped coefficient (`2.4 · √stiffness`).
    public var springDamping: Double
    /// Nominal path-progress duration (seconds) for a typical travel distance.
    public var travelDuration: Double
    /// Number of discrete samples when planning a trajectory (clamped by the planner).
    public var trajectorySamples: Int

    public init(
        positionRate: Double = 12.0,
        epsilon: Double = 0.5,
        poseRate: Double = 16.0,
        leanPerSpeed: Double = 0.00016,
        maxLean: Double = 0.20,
        skewPerSpeed: Double = 0.00012,
        maxSkew: Double = 0.16,
        stretchPerSpeed: Double = 0.00003,
        maxStretch: Double = 0.10,
        pressScale: Double = 0.82,
        velocitySmoothing: Double = 0.35,
        rippleDuration: Double = 0.45,
        rippleMaxRadius: Double = 26.0,
        rippleStartAlpha: Double = 0.42,
        fixedStep: Double = 1.0 / 240.0,
        springStiffness: Double = 0,
        springDamping: Double = 0,
        travelDuration: Double = 0.55,
        trajectorySamples: Int = 24
    ) {
        self.positionRate = positionRate
        self.epsilon = epsilon
        self.poseRate = poseRate
        self.leanPerSpeed = leanPerSpeed
        self.maxLean = maxLean
        self.skewPerSpeed = skewPerSpeed
        self.maxSkew = maxSkew
        self.stretchPerSpeed = stretchPerSpeed
        self.maxStretch = maxStretch
        self.pressScale = pressScale
        self.velocitySmoothing = velocitySmoothing
        self.rippleDuration = rippleDuration
        self.rippleMaxRadius = rippleMaxRadius
        self.rippleStartAlpha = rippleStartAlpha
        self.fixedStep = fixedStep
        self.springStiffness = springStiffness
        self.springDamping = springDamping
        self.travelDuration = travelDuration
        self.trajectorySamples = trajectorySamples
    }

    public static let `default` = CursorMotionConfig()

    /// Resolved spring stiffness (ω²).
    var resolvedStiffness: Double {
        if springStiffness > 0, springStiffness.isFinite { return springStiffness }
        let r = positionRate.isFinite && positionRate > 0 ? positionRate : 12.0
        // Slightly stiffer than rate² so the tip stays tight on the path sample.
        return r * r * 1.6
    }

    /// Resolved damping coefficient. Default is overdamped (`2.4 · √stiffness`) so the
    /// tip tracks the path sample without free oscillation or endpoint overshoot.
    var resolvedDamping: Double {
        if springDamping > 0, springDamping.isFinite { return springDamping }
        return 2.4 * resolvedStiffness.squareRoot()
    }

    /// Clamped fixed step used by the integrator.
    var resolvedFixedStep: Double {
        let h = fixedStep
        guard h.isFinite, h > 0 else { return 1.0 / 240.0 }
        return min(max(h, 1.0 / 1000.0), 1.0 / 30.0)
    }
}

/// The deterministic motion model. Tracks a heading-aware planned path with a
/// fixed-step damped spring, derives a lifelike pose (lean / skew / stretch) from the
/// tip's velocity, squashes on a held press, and ages click ripples. Pure given its
/// internal state — no clock, no AppKit — so `tickRender(dt:)` is fully unit-testable
/// and the live presenter renders exactly what the model emits.
public final class CursorAnimator: CursorAnimating {
    public private(set) var identityColor: CursorColor?

    private let config: CursorMotionConfig

    private var position = Point(x: 0, y: 0)
    private var target = Point(x: 0, y: 0)
    private var state: CursorVisualState = .idle
    /// Smoothed velocity in points/second (drives lean/skew/stretch).
    private var velocity = Point(x: 0, y: 0)
    /// Integrator velocity (points/second) for the tracking spring.
    private var tipVelocity = Point(x: 0, y: 0)
    /// Current eased pose deviations (toward velocity-derived targets).
    private var angle = 0.0
    private var skew = 0.0
    private var scale = 1.0

    /// Live click ripples, oldest first. Each carries its centre and age (seconds).
    private var ripples: [(center: Point, age: Double)] = []
    /// A click whose ripple is DEFERRED until the tip arrives at `pendingPressTarget`, so the
    /// bubble blooms under the click destination — not at the departure point the cursor is
    /// flying away from (ripple on arrival, not on retarget).
    private var pendingPress = false
    private var pendingPressTarget = Point(x: 0, y: 0)

    /// Active planned path (retarget allocates a small value).
    private var trajectory: CursorTrajectory?
    /// Progress along the active trajectory, 0…1.
    private var pathProgress = 1.0
    /// Residual time not yet consumed by a full fixed step (for determinism across dt partitions).
    private var timeAccumulator = 0.0
    /// Heading used for the next plan (updated from travel / trajectory end).
    private var motionHeading = 0.0

    /// How many times `synchronize()` has been called (diagnostic; proves the sync point
    /// is exercised without ever blocking).
    public private(set) var synchronizeCount = 0

    /// The path kind of the active (or most recent) trajectory, for diagnostics/tests.
    public var activePathKind: CursorPathKind? { trajectory?.kind }

    /// Current motion heading in radians (`atan2(dy, dx)`), for diagnostics/tests.
    public var currentHeading: Double { motionHeading }

    public init(config: CursorMotionConfig = .default) {
        self.config = config
    }

    /// Back-compat convenience: the pre-pose signature (rate/epsilon) kept so existing
    /// call sites and tests that constructed `CursorAnimator(rate:epsilon:)` still work.
    public convenience init(rate: Double, epsilon: Double = 0.5) {
        self.init(config: CursorMotionConfig(positionRate: rate, epsilon: epsilon))
    }

    public var isSettled: Bool {
        abs(position.x - target.x) <= config.epsilon
            && abs(position.y - target.y) <= config.epsilon
            && pathProgress >= 1.0 - 1e-9
            && tipSpeed() <= max(config.epsilon * 40, 8)
    }

    public func reset(color: CursorColor, at position: Point) {
        identityColor = color
        let p = finitePoint(position, fallback: Point(x: 0, y: 0))
        self.position = p
        target = p
        state = .idle
        velocity = Point(x: 0, y: 0)
        tipVelocity = Point(x: 0, y: 0)
        angle = 0; skew = 0; scale = 1
        ripples.removeAll()
        pendingPress = false
        trajectory = nil
        pathProgress = 1.0
        timeAccumulator = 0
        motionHeading = 0
    }

    public func retarget(to target: Point, state: CursorVisualState) {
        let next = finitePoint(target, fallback: self.target)

        if isPressed(state), !isPressed(self.state) {
            // Transition INTO a press: DEFER the ripple until the tip reaches this target, so
            // the bubble blooms under the click destination rather than at the point the
            // cursor is flying away from. Fires in `advance` on arrival.
            pendingPress = true
            pendingPressTarget = next
        } else if pendingPress, !within(next, pendingPressTarget, config.epsilon) {
            // A new action redirected the cursor elsewhere before the deferred click landed:
            // emit the ripple at its INTENDED location now rather than dropping it or letting
            // it bloom at the wrong place.
            ripples.append((center: pendingPressTarget, age: 0))
            pendingPress = false
        }

        self.target = next
        self.state = state
        planTrajectory(to: next)
    }

    /// Explicitly spawn a click ripple at the current tip (an escape hatch for a press
    /// reflected without a distinct state transition; fires immediately, in place).
    public func press() {
        ripples.append((center: position, age: 0))
    }

    /// Advance position, velocity, pose, and ripples by `dt` seconds. Shared by `tick` and
    /// `tickRender`; call exactly one of those per frame.
    private func advance(dt: Double) {
        // Non-finite or non-positive dt does not advance motion. Oversized dt is capped
        // so a stalled host frame cannot explode the integrator.
        guard dt.isFinite, dt > 0 else { return }
        let clampedDt = min(dt, 0.25)

        let previous = position
        integrate(dt: clampedDt)

        // Instantaneous tip velocity from actual displacement (drives lean/skew/stretch).
        let inv = 1.0 / clampedDt
        let instant = Point(
            x: (position.x - previous.x) * inv,
            y: (position.y - previous.y) * inv
        )
        let s = clamp01(config.velocitySmoothing)
        velocity = Point(
            x: velocity.x + (instant.x - velocity.x) * s,
            y: velocity.y + (instant.y - velocity.y) * s
        )
        if !velocity.x.isFinite { velocity.x = 0 }
        if !velocity.y.isFinite { velocity.y = 0 }

        updatePose(dt: clampedDt)
        ageRipples(dt: clampedDt)
    }

    private func planTrajectory(to end: Point) {
        let start = position
        let path = CursorTrajectory.plan(
            from: start,
            to: end,
            heading: motionHeading,
            sampleCount: config.trajectorySamples,
            epsilon: config.epsilon
        )
        trajectory = path
        pathProgress = 0

        // Soft-cap runaway integrator velocity on retarget; preserve heading continuity
        // by keeping a bounded residual speed rather than zeroing hard.
        let speed = tipSpeed()
        if speed > 6000 {
            let scale = 6000 / speed
            tipVelocity = Point(x: tipVelocity.x * scale, y: tipVelocity.y * scale)
        }

        // Zero-length: already there.
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dist = (dx * dx + dy * dy).squareRoot()
        if dist <= config.epsilon {
            pathProgress = 1
            position = end
            tipVelocity = Point(x: 0, y: 0)
            velocity = Point(x: 0, y: 0)
            return
        }

        // Modest feed-forward along the first segment so lean/skew read early and
        // mid-flight retargets keep heading continuity without flinging past the path.
        if path.samples.count >= 2 {
            let a = path.samples[0]
            let b = path.samples[1]
            let sdx = b.x - a.x
            let sdy = b.y - a.y
            let seg = (sdx * sdx + sdy * sdy).squareRoot()
            if seg > 1e-9 {
                let duration = max(config.travelDuration, 0.1)
                let push = min(max(dist / duration * 0.40, 90), 900)
                let ux = sdx / seg
                let uy = sdy / seg
                tipVelocity = Point(
                    x: tipVelocity.x * 0.45 + ux * push * 0.55,
                    y: tipVelocity.y * 0.45 + uy * push * 0.55
                )
            }
        }
    }

    /// Fixed-step overdamped spring tracking the moving path sample.
    ///
    /// State: tip position `p`, tip velocity `v`.
    /// Desired: `d = path.point(at: progress)`.
    /// Semi-implicit Euler:
    ///   a = k·(d − p) − c·v
    ///   v += a·h
    ///   p += v·h
    private func integrate(dt: Double) {
        let h = config.resolvedFixedStep
        timeAccumulator += dt
        if timeAccumulator > 0.5 { timeAccumulator = 0.5 }

        let k = config.resolvedStiffness
        let c = config.resolvedDamping
        let progressRate = pathProgressRate()

        var steps = 0
        let maxSteps = 512
        while timeAccumulator >= h, steps < maxSteps {
            timeAccumulator -= h
            steps += 1

            if pathProgress < 1 {
                let remain = 1 - pathProgress
                let step = 1 - exp(-progressRate * h)
                pathProgress = min(1, pathProgress + remain * step)
                if pathProgress > 1 - 1e-6 { pathProgress = 1 }
            }

            let desired = pathSample(at: pathProgress)
            var px = position.x
            var py = position.y
            var vx = tipVelocity.x
            var vy = tipVelocity.y

            if pathProgress >= 1 {
                // Path complete: exponential approach to the exact endpoint.
                // Guarantees no overshoot past the target and exact settling, while the
                // mid-path spring still carries the curved heading feel.
                let settle = clamp01(1 - exp(-config.positionRate * h))
                let rate = max(config.positionRate, 1)
                px += (desired.x - px) * settle
                py += (desired.y - py) * settle
                // Velocity consistent with the exponential step (for pose lean).
                vx = (desired.x - px) * rate
                vy = (desired.y - py) * rate
            } else {
                let ax = k * (desired.x - px) - c * vx
                let ay = k * (desired.y - py) - c * vy
                vx += ax * h
                vy += ay * h

                // Contain non-finite / runaway velocities.
                if !vx.isFinite || abs(vx) > 50_000 { vx = 0 }
                if !vy.isFinite || abs(vy) > 50_000 { vy = 0 }

                px += vx * h
                py += vy * h
            }

            if !px.isFinite { px = desired.x }
            if !py.isFinite { py = desired.y }
            if !vx.isFinite { vx = 0 }
            if !vy.isFinite { vy = 0 }

            // Direct paths stay inside the start→end axis-aligned box so a stiff
            // tracking step cannot overshoot the endpoint (existing settle contract).
            if let path = trajectory, path.kind == .direct {
                let minX = min(path.start.x, path.end.x)
                let maxX = max(path.start.x, path.end.x)
                let minY = min(path.start.y, path.end.y)
                let maxY = max(path.start.y, path.end.y)
                if px < minX { px = minX; if vx < 0 { vx = 0 } }
                if px > maxX { px = maxX; if vx > 0 { vx = 0 } }
                if py < minY { py = minY; if vy < 0 { vy = 0 } }
                if py > maxY { py = maxY; if vy > 0 { vy = 0 } }
            }

            position = Point(x: px, y: py)
            tipVelocity = Point(x: vx, y: vy)

            // Track heading from tip motion while moving.
            let mdx = vx
            let mdy = vy
            if (mdx * mdx + mdy * mdy) > 1.0 {
                motionHeading = atan2(mdy, mdx)
            }
        }

        if timeAccumulator < h * 1e-6 {
            timeAccumulator = 0
        }

        // Snap exactly onto the target once path is complete and residual error/speed
        // are inside tolerance — settling is exact, no residual oscillation.
        if pathProgress >= 1,
           abs(position.x - target.x) <= config.epsilon,
           abs(position.y - target.y) <= config.epsilon,
           tipSpeed() <= max(config.epsilon * 40, 8) {
            position = target
            tipVelocity = Point(x: 0, y: 0)
            if let path = trajectory {
                motionHeading = path.endHeading
            }
        }
    }

    private func pathProgressRate() -> Double {
        // Map travelDuration to an exponential rate so progress ≈ 1 in ~travelDuration.
        // e^(-rate·T) ≈ 0.02 → rate ≈ -ln(0.02)/T ≈ 3.9/T.
        let duration = config.travelDuration.isFinite && config.travelDuration > 0.05
            ? config.travelDuration
            : 0.55
        let dist: Double
        if let t = trajectory {
            let dx = t.end.x - t.start.x
            let dy = t.end.y - t.start.y
            dist = (dx * dx + dy * dy).squareRoot()
        } else {
            dist = 0
        }
        // Short hops finish faster; long flights stay near the nominal duration.
        let scale = dist > 1 ? min(max(180.0 / dist, 0.55), 2.4) : 2.2
        return (3.9 / duration) * scale
    }

    private func pathSample(at t: Double) -> Point {
        if let path = trajectory {
            return path.point(at: t)
        }
        return target
    }

    private func updatePose(dt: Double) {
        let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
        let targetAngle = clampSym(velocity.x * config.leanPerSpeed, config.maxLean)
        let targetSkew = clampSym(velocity.x * config.skewPerSpeed, config.maxSkew)
        let stretch = min(speed * config.stretchPerSpeed, config.maxStretch)
        let targetScale = (isPressed(state) ? config.pressScale : 1.0) + stretch

        let poseStep = clamp01(1 - exp(-config.poseRate * dt))
        angle += (targetAngle - angle) * poseStep
        skew += (targetSkew - skew) * poseStep
        scale += (targetScale - scale) * poseStep
        if !angle.isFinite { angle = 0 }
        if !skew.isFinite { skew = 0 }
        if !scale.isFinite { scale = 1 }
    }

    private func ageRipples(dt: Double) {
        // A deferred click ripple blooms the moment the tip ARRIVES at its target.
        if pendingPress, within(position, pendingPressTarget, config.epsilon) {
            ripples.append((center: pendingPressTarget, age: 0))
            pendingPress = false
        }

        for i in ripples.indices { ripples[i].age += dt }
        ripples.removeAll { $0.age >= config.rippleDuration }
    }

    private func tipSpeed() -> Double {
        let x = tipVelocity.x
        let y = tipVelocity.y
        if !x.isFinite || !y.isFinite { return 0 }
        return (x * x + y * y).squareRoot()
    }

    /// Rich render frame: pose + visual state + live ripples + settled. The presenter's
    /// per-frame entry point.
    public func tickRender(dt: Double) -> CursorRenderFrame {
        advance(dt: dt)
        let pose = CursorPose(position: position, angleRadians: angle, skewX: skew, scale: scale)
        let rippleFrames = ripples.map { r -> RippleFrame in
            let t = clamp01(r.age / config.rippleDuration)
            // Radius eases out (fast then slow); alpha fades linearly to 0.
            let radius = easeOutCubic(t) * config.rippleMaxRadius
            let alpha = (1 - t) * config.rippleStartAlpha
            return RippleFrame(center: r.center, radius: radius, alpha: alpha)
        }
        // "Settled" for the presenter means safe to park the timer: tip at target, no live
        // ripples, no deferred click still waiting to bloom, AND a resting state.
        let atRest = isSettled && ripples.isEmpty && !pendingPress && isRestState(state)
        return CursorRenderFrame(pose: pose, visualState: state, ripples: rippleFrames, settled: atRest)
    }

    public func tick(dt: Double) -> CursorFrame {
        advance(dt: dt)
        return CursorFrame(position: position, visualState: state, settled: isSettled)
    }

    /// Returns immediately, unconditionally. Deliberately does NOT consult `isSettled` —
    /// the decoupling invariant depends on this never waiting for the animation.
    public func synchronize() {
        synchronizeCount += 1
    }

    public func stop() {
        state = .idle
        target = position
        velocity = Point(x: 0, y: 0)
        tipVelocity = Point(x: 0, y: 0)
        pathProgress = 1
        trajectory = nil
        pendingPress = false
        timeAccumulator = 0
    }

    // MARK: - Helpers

    private func isPressed(_ state: CursorVisualState) -> Bool {
        if case .pressed = state { return true }
        return false
    }

    /// A "resting" state for timer-parking purposes: idle only. Moving/pressed/dragging/
    /// progress all keep the timer alive.
    private func isRestState(_ state: CursorVisualState) -> Bool {
        if case .idle = state { return true }
        return false
    }

    /// Whether two points are within `epsilon` on both axes.
    private func within(_ a: Point, _ b: Point, _ epsilon: Double) -> Bool {
        abs(a.x - b.x) <= epsilon && abs(a.y - b.y) <= epsilon
    }

    private func finitePoint(_ p: Point, fallback: Point) -> Point {
        let x = p.x.isFinite ? p.x : fallback.x
        let y = p.y.isFinite ? p.y : fallback.y
        return Point(x: x, y: y)
    }
}

/// Symmetric clamp to `[-limit, limit]`.
@inline(__always) func clampSym(_ x: Double, _ limit: Double) -> Double {
    min(max(x, -limit), limit)
}

/// Cubic ease-out on `t ∈ [0,1]`.
@inline(__always) func easeOutCubic(_ t: Double) -> Double {
    let u = 1 - t
    return 1 - u * u * u
}
