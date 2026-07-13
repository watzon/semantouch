import Foundation
import CoreGraphics
import ComputerUseCore

// CoordinateMapper — pure conversions between the three protocol coordinate spaces
// (PROTOCOL §9). Every public value here is in a **top-left origin** space
// (`+x` right, `+y` down); there is no AppKit bottom-left coordinate anywhere in
// this API.
//
// ┌──────────────────────────────────────────────────────────────────────────┐
// │ AppKit BOTTOM-LEFT HAZARD                                                   │
// │                                                                            │
// │ `NSScreen.frame`, `NSWindow.frame`, and every AppKit geometry value use a  │
// │ BOTTOM-LEFT origin (`+y` UP), with y measured from the bottom of the       │
// │ primary display. CoreGraphics global coordinates, ScreenCaptureKit frames, │
// │ CGWindowList bounds, and Accessibility (`AXPosition`/`AXSize`) all use a    │
// │ TOP-LEFT origin (`+y` DOWN). This module is defined entirely in the        │
// │ top-left family, so it never touches AppKit geometry. If a caller ever     │
// │ bridges an AppKit rect in, it MUST flip Y first with `topLeftY(...)` before │
// │ handing the value to this mapper. Conflating the two is the single most    │
// │ common capture/coordinate bug, which is why the whole surface below is     │
// │ top-left only.                                                             │
// └──────────────────────────────────────────────────────────────────────────┘

/// Converts points between global points (G), window points (W), and screenshot
/// pixels (S) for one captured window (PROTOCOL §9).
///
/// The instance is constructed with the window's global frame (`framePoints`, in
/// **G**) and the **actual delivered** screenshot pixel size (`screenshotPixels`,
/// in **S**). Per §9 the pixels-per-point ratios `kx`/`ky` are derived from the
/// delivered pixel dimensions vs. `framePoints` — never from `scale` alone — so
/// mappings stay exact against whatever the encoder produced (including after a
/// byte-cap downscale).
public struct CoordinateMapper: Equatable, Sendable {
    /// Window frame in global points (G). Top-left origin.
    public let framePoints: Rect
    /// The delivered screenshot size in pixels (S).
    public let screenshotPixels: Size

    public init(framePoints: Rect, screenshotPixels: Size) {
        self.framePoints = framePoints
        self.screenshotPixels = screenshotPixels
    }

    /// Pixels-per-point on X (`screenshotPixels.width / framePoints.width`); `0`
    /// for a degenerate zero-width frame.
    public var kx: Double {
        framePoints.width == 0 ? 0 : Double(screenshotPixels.width) / framePoints.width
    }

    /// Pixels-per-point on Y (`screenshotPixels.height / framePoints.height`); `0`
    /// for a degenerate zero-height frame.
    public var ky: Double {
        framePoints.height == 0 ? 0 : Double(screenshotPixels.height) / framePoints.height
    }

    // MARK: - Point conversions (§9)

    /// G → W: `wx = gx − F.x`, `wy = gy − F.y`.
    public func windowPoint(fromGlobal p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - framePoints.x, y: p.y - framePoints.y)
    }

    /// W → G: `gx = wx + F.x`, `gy = wy + F.y`.
    public func globalPoint(fromWindow p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + framePoints.x, y: p.y + framePoints.y)
    }

    /// W → S: `sx = wx · kx`, `sy = wy · ky`.
    public func screenshotPoint(fromWindow p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * kx, y: p.y * ky)
    }

    /// S → W: `wx = sx / kx`, `wy = sy / ky`. Degenerate axes map to `0`.
    public func windowPoint(fromScreenshot p: CGPoint) -> CGPoint {
        CGPoint(x: kx == 0 ? 0 : p.x / kx, y: ky == 0 ? 0 : p.y / ky)
    }

    /// G → S: compose G→W then W→S.
    public func screenshotPoint(fromGlobal p: CGPoint) -> CGPoint {
        screenshotPoint(fromWindow: windowPoint(fromGlobal: p))
    }

    /// S → G: compose S→W then W→G.
    public func globalPoint(fromScreenshot p: CGPoint) -> CGPoint {
        globalPoint(fromWindow: windowPoint(fromScreenshot: p))
    }

    // MARK: - Rect conversions

    /// G → W for a rectangle (origin translated; size unchanged). Used to convert
    /// an AX frame read in G into the window points a tree line carries (§7.2, §9).
    public func windowRect(fromGlobal r: Rect) -> Rect {
        Rect(x: r.x - framePoints.x, y: r.y - framePoints.y, width: r.width, height: r.height)
    }

    /// W → G for a rectangle.
    public func globalRect(fromWindow r: Rect) -> Rect {
        Rect(x: r.x + framePoints.x, y: r.y + framePoints.y, width: r.width, height: r.height)
    }
}

// MARK: - Pure sizing + rounding helpers

public extension CoordinateMapper {
    /// Backing-pixel size of a window = `round(width·scale) × round(height·scale)`.
    /// This is the **native capture size** handed to `SCStreamConfiguration`
    /// (WindowCapture); the fit-to-1568 downscale happens later in the encoder.
    static func backingPixelSize(framePoints: Rect, scale: Double) -> Size {
        Size(
            width: roundedInt(framePoints.width * scale),
            height: roundedInt(framePoints.height * scale)
        )
    }

    /// Nominal delivered screenshot size per §9: backing pixels scaled by the
    /// fit factor `d = min(1, maxLongEdge / max(backingW, backingH))`. The encoder
    /// may shrink further to satisfy the byte cap, so the authoritative delivered
    /// dimensions are always taken from the encoder result; this is the target.
    static func screenshotPixelSize(
        framePoints: Rect,
        scale: Double,
        maxLongEdge: Int = CaptureEngine.maxLongEdgePixels
    ) -> Size {
        let backingW = framePoints.width * scale
        let backingH = framePoints.height * scale
        let longEdge = max(backingW, backingH)
        let d = longEdge > 0 ? min(1.0, Double(maxLongEdge) / longEdge) : 1.0
        return Size(width: roundedInt(backingW * d), height: roundedInt(backingH * d))
    }

    /// Round a window-space rect to the integer `frame=x,y,w,h` a tree line emits:
    /// nearest, ties away from zero (§7.2).
    static func roundedWindowFrame(_ r: Rect) -> (x: Int, y: Int, width: Int, height: Int) {
        (roundedInt(r.x), roundedInt(r.y), roundedInt(r.width), roundedInt(r.height))
    }

    /// Round to nearest, ties away from zero (the protocol's frame rounding rule).
    static func roundedInt(_ value: Double) -> Int {
        Int(value.rounded(.toNearestOrAwayFromZero))
    }

    /// AppKit bottom-left → top-left Y flip. `y` and `height` describe an AppKit
    /// (bottom-left origin) rect; `screenHeight` is the containing screen's height
    /// in points. Returns the top-left-origin Y. Provided so a caller that must
    /// bridge an AppKit rect can convert BEFORE constructing a mapper — the mapper
    /// itself never accepts bottom-left values.
    static func topLeftY(fromBottomLeftY y: Double, height: Double, screenHeight: Double) -> Double {
        screenHeight - y - height
    }
}

// MARK: - Rect <-> CGRect bridging (top-left, no flip)

public extension Rect {
    /// Build a `Rect` from a `CGRect` **without any Y flip** — both are treated as
    /// top-left origin. Only pass CoreGraphics/ScreenCaptureKit/CGWindowList rects
    /// here, never AppKit frames.
    init(_ cg: CGRect) {
        self.init(x: cg.origin.x, y: cg.origin.y, width: cg.size.width, height: cg.size.height)
    }

    /// Project to a `CGRect` (top-left origin, no flip).
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
