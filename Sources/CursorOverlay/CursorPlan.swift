import Foundation
import ComputerUseCore

// Virtual cursor overlay geometry (docs/PLAN.md Stage H).
//
// This file is the TESTED HEART of the overlay: pure, deterministic geometry with no
// AppKit and no windows. Given the target window's frame (global points), an action
// kind, a target point, and progress state, it computes the overlay panel frame, the
// cursor position inside that panel, and the visual state to draw. The impure AppKit
// presentation (CursorPanel / AppKitCursorPresenter) is driven entirely from these
// values, so the correctness of the overlay's placement is provable without a GUI.
//
// Clean-room: every type here is independently authored from public behavior.
// Nothing is copied from the OpenAI Computer Use bundle (no cursor art, no bundle ids,
// no proprietary animation names).

// MARK: - Action + visual vocabulary

/// The kind of action the overlay is reflecting: move, press, progress, idle,
/// or drag.
public enum CursorActionKind: Equatable, Sendable {
    /// No action in flight; the cursor rests (dimmed) at its last point.
    case idle
    /// The cursor is moving toward a target point (e.g. before a coordinate click).
    case move
    /// A press/click at the target point (element `AXPress` or coordinate click).
    case press
    /// A drag from one point to another; the overlay tracks the end point.
    case drag
    /// A long-running/thinking state (e.g. keyboard input, settle wait) with a
    /// 0…1 progress fraction. Carries no specific point (rests at the window centre).
    case progress
}

/// The visual state the presenter renders, derived from `CursorActionKind` (+ progress).
/// Keeping this separate from `CursorActionKind` lets the pure plan own the mapping
/// (tested) while the presenter only switches on the resolved state.
public enum CursorVisualState: Equatable, Sendable {
    case idle
    case moving
    case pressed
    case dragging
    /// Progress fraction, clamped to 0…1.
    case progress(fraction: Double)
}

// MARK: - Identity colour

/// A per-session identity colour as
/// straight RGBA components in 0…1. Deterministic from the session id, so the same
/// session always draws the same hue and tests can pin exact values.
public struct CursorColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// A stable identity colour for `sessionId`. The hue is a deterministic function of
    /// the session id (FNV-1a hash → hue), with fixed saturation/brightness so every
    /// colour is legible; `alpha` is supplied by the caller (the hide/dim preference
    /// picks a solid or translucent alpha). Pure — no randomness, no global state.
    public static func identity(forSession sessionId: String, alpha: Double) -> CursorColor {
        // FNV-1a (64-bit) over the UTF-8 bytes: stable across runs and platforms.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in sessionId.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hue = Double(hash % 360) / 360.0
        let rgb = hsbToRGB(hue: hue, saturation: 0.72, brightness: 0.96)
        return CursorColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: clamp01(alpha))
    }

    /// Standard HSB→RGB. `hue`/`saturation`/`brightness` in 0…1; returns straight RGB.
    static func hsbToRGB(hue: Double, saturation: Double, brightness: Double) -> (Double, Double, Double) {
        let s = clamp01(saturation)
        let v = clamp01(brightness)
        if s == 0 { return (v, v, v) }
        let h = (hue.truncatingRemainder(dividingBy: 1.0) + 1.0).truncatingRemainder(dividingBy: 1.0) * 6.0
        let i = floor(h)
        let f = h - i
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch Int(i) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

/// Clamp to the closed unit interval.
@inline(__always) func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

// MARK: - The plan

/// The pure, deterministic overlay layout for one action frame.
///
/// - `panelFrame` is the overlay window's frame in GLOBAL points (top-left origin,
///   +y down — protocol §9 convention), which exactly matches the target window so the
///   overlay tracks it. Converting global points → the platform's native window
///   coordinates (Cocoa's bottom-left origin) is an IMPURE concern handled only in the
///   live presenter, never here.
/// - `cursorInPanel` is the cursor hotspot in PANEL-LOCAL points (origin at the panel's
///   top-left, +y down), clamped to the panel bounds so the drawn cursor can never
///   escape the target window.
/// - `visualState` is what to draw.
/// - `presentable` is false for a degenerate window (non-positive area); the controller
///   hides rather than presenting a zero-size overlay.
public struct CursorPlan: Equatable, Sendable {
    public let panelFrame: Rect
    public let cursorInPanel: Point
    public let visualState: CursorVisualState
    public let presentable: Bool

    public init(panelFrame: Rect, cursorInPanel: Point, visualState: CursorVisualState, presentable: Bool) {
        self.panelFrame = panelFrame
        self.cursorInPanel = cursorInPanel
        self.visualState = visualState
        self.presentable = presentable
    }

    /// Compute the overlay layout.
    ///
    /// - Parameters:
    ///   - windowFrame: the target window's GLOBAL-point frame. The panel matches it.
    ///   - action: the action kind being reflected.
    ///   - targetPointWindow: the action's target in WINDOW points (origin at the
    ///     window's top-left). `nil` centres the cursor (idle / progress / actions with
    ///     no meaningful location, e.g. keyboard input).
    ///   - progress: 0…1, used only by `.progress`.
    public static func compute(
        windowFrame: Rect,
        action: CursorActionKind,
        targetPointWindow: Point?,
        progress: Double = 0
    ) -> CursorPlan {
        let width = max(windowFrame.width, 0)
        let height = max(windowFrame.height, 0)
        let presentable = windowFrame.width > 0 && windowFrame.height > 0

        let cursor: Point
        if let target = targetPointWindow {
            // Clamp into the panel so the drawn cursor never leaves the target window.
            cursor = Point(x: min(max(target.x, 0), width), y: min(max(target.y, 0), height))
        } else {
            cursor = Point(x: width / 2, y: height / 2)
        }

        let visual: CursorVisualState
        switch action {
        case .idle: visual = .idle
        case .move: visual = .moving
        case .press: visual = .pressed
        case .drag: visual = .dragging
        case .progress: visual = .progress(fraction: clamp01(progress))
        }

        return CursorPlan(
            panelFrame: windowFrame,
            cursorInPanel: cursor,
            visualState: visual,
            presentable: presentable
        )
    }
}
