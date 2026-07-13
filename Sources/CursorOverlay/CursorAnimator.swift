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
    /// Per-second exponential approach rate for the tip position. Higher = snappier.
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
        rippleStartAlpha: Double = 0.42
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
    }

    public static let `default` = CursorMotionConfig()
}

/// The deterministic motion model. Eases the drawn tip toward the target with an
/// exponential approach, derives a lifelike pose (lean / skew / stretch) from the tip's
/// velocity, squashes on a held press, and ages click ripples. Pure given its internal
/// state — no clock, no AppKit — so `tickRender(dt:)` is fully unit-testable and the live
/// presenter renders exactly what the model emits.
public final class CursorAnimator: CursorAnimating {
    public private(set) var identityColor: CursorColor?

    private let config: CursorMotionConfig

    private var position = Point(x: 0, y: 0)
    private var target = Point(x: 0, y: 0)
    private var state: CursorVisualState = .idle
    /// Smoothed velocity in points/second (drives lean/skew/stretch).
    private var velocity = Point(x: 0, y: 0)
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

    /// How many times `synchronize()` has been called (diagnostic; proves the sync point
    /// is exercised without ever blocking).
    public private(set) var synchronizeCount = 0

    public init(config: CursorMotionConfig = .default) {
        self.config = config
    }

    /// Back-compat convenience: the pre-pose signature (rate/epsilon) kept so existing
    /// call sites and tests that constructed `CursorAnimator(rate:epsilon:)` still work.
    public convenience init(rate: Double, epsilon: Double = 0.5) {
        self.init(config: CursorMotionConfig(positionRate: rate, epsilon: epsilon))
    }

    public var isSettled: Bool {
        abs(position.x - target.x) <= config.epsilon && abs(position.y - target.y) <= config.epsilon
    }

    public func reset(color: CursorColor, at position: Point) {
        identityColor = color
        self.position = position
        target = position
        state = .idle
        velocity = Point(x: 0, y: 0)
        angle = 0; skew = 0; scale = 1
        ripples.removeAll()
        pendingPress = false
    }

    public func retarget(to target: Point, state: CursorVisualState) {
        if isPressed(state), !isPressed(self.state) {
            // Transition INTO a press: DEFER the ripple until the tip reaches this target, so
            // the bubble blooms under the click destination rather than at the point the
            // cursor is flying away from. Fires in `advance` on arrival.
            pendingPress = true
            pendingPressTarget = target
        } else if pendingPress, !within(target, pendingPressTarget, config.epsilon) {
            // A new action redirected the cursor elsewhere before the deferred click landed:
            // emit the ripple at its INTENDED location now rather than dropping it or letting
            // it bloom at the wrong place.
            ripples.append((center: pendingPressTarget, age: 0))
            pendingPress = false
        }
        self.target = target
        self.state = state
    }

    /// Explicitly spawn a click ripple at the current tip (an escape hatch for a press
    /// reflected without a distinct state transition; fires immediately, in place).
    public func press() {
        ripples.append((center: position, age: 0))
    }

    /// Advance position, velocity, pose, and ripples by `dt` seconds. Shared by `tick` and
    /// `tickRender`; call exactly one of those per frame.
    private func advance(dt: Double) {
        guard dt > 0 else { return }
        // Exponential approach: fraction closed this step = 1 - e^(-rate·dt).
        let step = clamp01(1 - exp(-config.positionRate * dt))
        let previous = position
        position = Point(
            x: position.x + (target.x - position.x) * step,
            y: position.y + (target.y - position.y) * step
        )
        // Instantaneous velocity, low-pass smoothed so lean/skew don't jitter.
        let instant = Point(x: (position.x - previous.x) / dt, y: (position.y - previous.y) / dt)
        let s = clamp01(config.velocitySmoothing)
        velocity = Point(
            x: velocity.x + (instant.x - velocity.x) * s,
            y: velocity.y + (instant.y - velocity.y) * s
        )

        // Velocity-derived pose targets. Lean and skew follow horizontal velocity (the arrow
        // banks into its travel); a small stretch follows overall speed. A held press squashes.
        let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
        let targetAngle = clampSym(velocity.x * config.leanPerSpeed, config.maxLean)
        let targetSkew = clampSym(velocity.x * config.skewPerSpeed, config.maxSkew)
        let stretch = min(speed * config.stretchPerSpeed, config.maxStretch)
        let targetScale = (isPressed(state) ? config.pressScale : 1.0) + stretch

        // Ease the pose deviations toward their targets (framerate-independent).
        let poseStep = clamp01(1 - exp(-config.poseRate * dt))
        angle += (targetAngle - angle) * poseStep
        skew += (targetSkew - skew) * poseStep
        scale += (targetScale - scale) * poseStep

        // A deferred click ripple blooms the moment the tip ARRIVES at its target.
        if pendingPress, within(position, pendingPressTarget, config.epsilon) {
            ripples.append((center: pendingPressTarget, age: 0))
            pendingPress = false
        }

        // Age ripples; drop the finished ones.
        for i in ripples.indices { ripples[i].age += dt }
        ripples.removeAll { $0.age >= config.rippleDuration }
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
}

/// Symmetric clamp to `[-limit, limit]`.
@inline(__always) func clampSym(_ x: Double, _ limit: Double) -> Double {
    min(max(x, -limit), limit)
}

/// Cubic ease-out on `t ∈ [0,1]`.
@inline(__always) func easeOutCubic(_ t: Double) -> Double {
    let u = 1 - clamp01(t)
    return 1 - u * u * u
}
