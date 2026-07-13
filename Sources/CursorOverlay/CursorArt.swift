import Foundation
import ComputerUseCore

// Pure cursor-art geometry with no AppKit dependency. The arrow outline and the
// animation-pose / click-ripple value types live here so both the live AppKit presenter
// and an offscreen preview render from ONE source of truth, and so the pose math is
// unit-testable without a screen.
//
// Coordinate convention: panel-LOCAL points, top-left origin, +y DOWN (matching
// `CursorPlan.cursorInPanel`). The arrow's HOTSPOT is its tip at local (0,0); every
// outline point is expressed relative to that tip, so placing the tip at the target point
// is exact.

// MARK: - Arrow outline

public enum CursorArt {
    /// The pointer outline as a closed polygon, tip-relative (tip at `(0,0)`), before the
    /// per-art `scale`. A classic north-west arrow with a prominent tail foot, chosen to
    /// read as a real cursor while staying chunky enough to tint and outline cleanly. The
    /// rounded look is produced at draw time by a round-join outline stroke, not by the
    /// polygon itself, so this stays a simple, testable point list.
    public static let baseOutline: [Point] = [
        Point(x: 0.0,  y: 0.0),    // tip (hotspot)
        Point(x: 0.0,  y: 21.0),   // left edge, bottom
        Point(x: 5.2,  y: 16.4),   // inner armpit, left of the tail
        Point(x: 8.6,  y: 24.6),   // tail foot, bottom-left
        Point(x: 12.0, y: 23.0),   // tail foot, bottom-right
        Point(x: 8.8,  y: 15.0),   // inner armpit, right of the tail
        Point(x: 14.6, y: 15.0),   // right shoulder
    ]

    /// The outline scaled by `scale` (the on-screen art size multiplier). Tip stays at
    /// `(0,0)`; every other point scales away from it.
    public static func outline(scale: Double) -> [Point] {
        baseOutline.map { Point(x: $0.x * scale, y: $0.y * scale) }
    }

    /// The outline's bounding box (tip-relative, at `scale`) — used to size the drawing
    /// layer. Always includes the tip at `(0,0)`.
    public static func bounds(scale: Double) -> Rect {
        let pts = outline(scale: scale)
        let minX = min(0, pts.map(\.x).min() ?? 0)
        let minY = min(0, pts.map(\.y).min() ?? 0)
        let maxX = max(0, pts.map(\.x).max() ?? 0)
        let maxY = max(0, pts.map(\.y).max() ?? 0)
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The arrow outline for a `pose`, in panel-local points (top-left origin), ready to
    /// stroke/fill. Applies — about the TIP, in this order — the art `scale`, then the
    /// pose's uniform scale, horizontal skew, and lean rotation, then translates the tip to
    /// `pose.position`. Pure, so the presenter and a preview render identically and the
    /// transform is unit-tested.
    public static func outlinePath(pose: CursorPose, artScale: Double) -> [Point] {
        let cosT = cos(pose.angleRadians)
        let sinT = sin(pose.angleRadians)
        return baseOutline.map { base in
            // Art scale + pose scale (about the tip at local origin).
            let y = base.y * artScale * pose.scale
            // Horizontal shear: x shifts proportional to y.
            let x = base.x * artScale * pose.scale + pose.skewX * y
            // Lean rotation about the tip.
            let rx = x * cosT - y * sinT
            let ry = x * sinT + y * cosT
            // Translate the tip to the target position.
            return Point(x: rx + pose.position.x, y: ry + pose.position.y)
        }
    }
}

// MARK: - Pose

/// One drawn cursor pose: where the tip is, plus the small lifelike deviations
/// derived from motion — a lean (rotation), a horizontal shear (skew), and a scale
/// (speed-stretch / press-squash). Neutral pose is `angle=0, skew=0, scale=1`. Rotation,
/// skew, and scale all pivot about the TIP so the hotspot never drifts off the target.
public struct CursorPose: Equatable, Sendable {
    /// Tip position in panel-local points (top-left origin, +y down).
    public let position: Point
    /// Lean angle in radians (clockwise positive in a +y-down space). 0 = upright.
    public let angleRadians: Double
    /// Horizontal shear factor (x += skewX · y about the tip). 0 = no shear.
    public let skewX: Double
    /// Uniform scale about the tip. 1 = rest.
    public let scale: Double

    public init(position: Point, angleRadians: Double, skewX: Double, scale: Double) {
        self.position = position
        self.angleRadians = angleRadians
        self.skewX = skewX
        self.scale = scale
    }

    public static func rest(at position: Point) -> CursorPose {
        CursorPose(position: position, angleRadians: 0, skewX: 0, scale: 1)
    }
}

// MARK: - Ripple

/// One live click-ripple frame: an expanding,
/// fading ring centred at the tip where the click landed. The model ages ripples and emits
/// their current geometry; the presenter just draws what it is handed.
public struct RippleFrame: Equatable, Sendable {
    /// Ring centre in panel-local points (the tip position at press time).
    public let center: Point
    /// Current radius in points.
    public let radius: Double
    /// Current opacity, 0…1 (fades to 0 as it expands).
    public let alpha: Double

    public init(center: Point, radius: Double, alpha: Double) {
        self.center = center
        self.radius = radius
        self.alpha = alpha
    }
}

/// A full render frame: the cursor pose, its visual state, the live ripples, and whether
/// the whole thing has settled (position at target AND no active ripples) so the presenter
/// can park its display timer.
public struct CursorRenderFrame: Equatable, Sendable {
    public let pose: CursorPose
    public let visualState: CursorVisualState
    public let ripples: [RippleFrame]
    public let settled: Bool

    public init(pose: CursorPose, visualState: CursorVisualState, ripples: [RippleFrame], settled: Bool) {
        self.pose = pose
        self.visualState = visualState
        self.ripples = ripples
        self.settled = settled
    }
}
