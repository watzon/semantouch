import Foundation
import CoreGraphics
import ComputerUseCore

// Pointer fallback (docs/PROTOCOL.md §16): coordinate click, drag, and scroll,
// all operating on global points (the caller maps window/screenshot
// points to global before calling here) through the injected synthesizer, checking the
// interruption monitor so physical input cancels promptly. A drag that is interrupted
// mid-move releases the button so it never leaves a stuck drag.
public enum PointerActions {
    /// Line-unit magnitude for one `line` / one `page` scroll step (internal heuristic;
    /// the wire contract fixes only direction/granularity/count, not the delta).
    static let linesPerLineStep: Int32 = 3
    static let linesPerPageStep: Int32 = 10
    /// Interpolation steps for a drag (bounds interruption granularity).
    static let dragSteps = 10

    // MARK: - Click

    /// Click at a global point (button down then up). Checks interruption and target-foreground
    /// before pressing (a pointer event is routed by screen location; §16.3).
    public static func click(
        atGlobal point: CGPoint,
        button: PointerButton,
        flags: CGEventFlags,
        via synthesizer: InputSynthesizer,
        interruption: InterruptionMonitoring,
        onTarget: TargetGuard = .alwaysOn
    ) {
        if interruption.isInterrupted { return }
        if !onTarget.stillOnTarget() { return }
        synthesizer.mouseDown(at: point, button: button, flags: flags)
        synthesizer.mouseUp(at: point, button: button, flags: flags)
    }

    // MARK: - Drag

    /// Drag from one global point to another: button down at `from`, interpolated moves,
    /// button up at `to`. On interruption mid-drag the button is released at the last
    /// point so no stuck drag is left behind.
    public static func drag(
        fromGlobal from: CGPoint,
        toGlobal to: CGPoint,
        button: PointerButton,
        flags: CGEventFlags,
        via synthesizer: InputSynthesizer,
        interruption: InterruptionMonitoring,
        onTarget: TargetGuard = .alwaysOn
    ) {
        if interruption.isInterrupted { return }
        if !onTarget.stillOnTarget() { return }
        synthesizer.mouseDown(at: from, button: button, flags: flags)
        var last = from
        for step in 1...dragSteps {
            // Interruption OR a foreground steal ends the drag; release the button at the last
            // point either way so no stuck drag is left behind (§16.3, §16.6).
            if interruption.isInterrupted || !onTarget.stillOnTarget() {
                synthesizer.mouseUp(at: last, button: button, flags: flags)
                return
            }
            let t = Double(step) / Double(dragSteps)
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            synthesizer.mouseDrag(to: point, button: button, flags: flags)
            last = point
        }
        synthesizer.mouseUp(at: to, button: button, flags: flags)
    }

    // MARK: - Scroll

    /// Scroll at a global point. `deltaX`/`deltaY` are line units (see `scrollDeltas`).
    public static func scroll(
        atGlobal point: CGPoint,
        deltaX: Int32,
        deltaY: Int32,
        flags: CGEventFlags,
        via synthesizer: InputSynthesizer,
        interruption: InterruptionMonitoring,
        onTarget: TargetGuard = .alwaysOn
    ) {
        if interruption.isInterrupted { return }
        if !onTarget.stillOnTarget() { return }
        synthesizer.scroll(at: point, deltaX: deltaX, deltaY: deltaY, flags: flags)
    }

    /// Map a direction/granularity/count to line-unit `(deltaX, deltaY)`. Convention
    /// (internal): `up`/`left` are positive, `down`/`right` are negative; vertical
    /// directions move `deltaY`, horizontal move `deltaX`. Magnitude scales with `count`.
    public static func scrollDeltas(
        direction: ScrollDirection,
        by granularity: ScrollGranularity,
        count: Int
    ) -> (deltaX: Int32, deltaY: Int32) {
        let steps = Int32(max(1, count))
        let magnitude = (granularity == .page ? linesPerPageStep : linesPerLineStep) * steps
        switch direction {
        case .up: return (0, magnitude)
        case .down: return (0, -magnitude)
        case .left: return (magnitude, 0)
        case .right: return (-magnitude, 0)
        }
    }
}
