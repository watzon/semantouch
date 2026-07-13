import Foundation

/// A rectangle in one of the protocol's coordinate spaces (§9). Units and origin
/// depend on the space of the value that carries it (global points, window points).
/// Encoded as `{ "x", "y", "width", "height" }`.
public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Whether the point `(px, py)` — expressed in this rectangle's own coordinate space —
    /// lies within the rectangle, inclusive of its edges. Used by the Phase 4 coordinate
    /// fallback to refuse delivering a synthesized pointer event to a global location that
    /// falls outside the target window (wrong-target input; PROTOCOL §16.3).
    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= x + width && py >= y && py <= y + height
    }
}

/// A point in one of the protocol's coordinate spaces (§9). Units and origin depend
/// on the space of the value that carries it (window points or screenshot pixels for
/// the Phase 4 coordinate actions). Encoded as `{ "x", "y" }`.
public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A pixel/point size. `AppState.window.screenshotPixels` is measured in whole
/// pixels, so this is integral. Encoded as `{ "width", "height" }`.
public struct Size: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}
