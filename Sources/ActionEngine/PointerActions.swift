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
    static let linesPerLineStep: Double = 3
    static let linesPerPageStep: Double = 10
    /// Interpolation steps for a drag (bounds interruption granularity).
    static let dragSteps = 10

    // MARK: - Click

    /// Click at a global point. Emits `clickCount` down/up pairs (1...3). When the
    /// synthesizer is `ClickStateAwareSynthesizer`, each unit is tagged with CoreGraphics
    /// click-state 1...N on both down and up. Interruption and target safety are checked
    /// before every unit so a multi-click aborts cleanly mid-sequence.
    public static func click(
        atGlobal point: CGPoint,
        button: PointerButton,
        flags: CGEventFlags,
        clickCount: Int = 1,
        via synthesizer: InputSynthesizer,
        interruption: InterruptionMonitoring,
        onTarget: TargetGuard = .alwaysOn
    ) {
        let units = max(1, min(3, clickCount))
        let clickAware = synthesizer as? ClickStateAwareSynthesizer
        for state in 1...units {
            if interruption.isInterrupted { return }
            if !onTarget.stillOnTarget() { return }
            clickAware?.prepareMouseClickState(Int64(state))
            synthesizer.mouseDown(at: point, button: button, flags: flags)
            synthesizer.mouseUp(at: point, button: button, flags: flags)
        }
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
        (synthesizer as? ClickStateAwareSynthesizer)?.prepareMouseClickState(1)
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
    /// Fractional `count` is meaningful for `by: page` (and line); wheel deltas are
    /// rounded to the nearest non-zero `Int32` unit when the scaled magnitude is nonzero.
    public static func scrollDeltas(
        direction: ScrollDirection,
        by granularity: ScrollGranularity,
        count: Double
    ) -> (deltaX: Int32, deltaY: Int32) {
        let steps = max(0, count)
        let unit = granularity == .page ? linesPerPageStep : linesPerLineStep
        let magnitude = unit * steps
        guard magnitude > 0 else { return (0, 0) }
        let rounded = max(1, Int32(magnitude.rounded()))
        switch direction {
        case .up: return (0, rounded)
        case .down: return (0, -rounded)
        case .left: return (rounded, 0)
        case .right: return (-rounded, 0)
        }
    }
}
