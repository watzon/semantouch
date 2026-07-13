import Foundation
import ComputerUseCore
@testable import CursorOverlay

// Permission-free, window-free test doubles for the CursorOverlay seams. No AppKit, no GUI
// session — every plan/controller/animator path runs against these.

/// A recording `CursorPresenting` that captures every call and can be toggled between
/// "GUI available" and "headless".
final class FakeCursorPresenter: CursorPresenting {
    enum Call: Equatable {
        case show(CursorColor)
        case update(panelFrame: Rect, cursorInPanel: Point, visualState: CursorVisualState)
        case hide
    }

    var canPresent: Bool
    private(set) var calls: [Call] = []

    init(canPresent: Bool = true) { self.canPresent = canPresent }

    func show(color: CursorColor) { calls.append(.show(color)) }
    func update(panelFrame: Rect, cursorInPanel: Point, visualState: CursorVisualState) {
        calls.append(.update(panelFrame: panelFrame, cursorInPanel: cursorInPanel, visualState: visualState))
    }
    func hide() { calls.append(.hide) }

    // Convenience projections.
    var showCount: Int { calls.reduce(0) { if case .show = $1 { return $0 + 1 }; return $0 } }
    var hideCount: Int { calls.reduce(0) { if case .hide = $1 { return $0 + 1 }; return $0 } }
    var updateCount: Int { calls.reduce(0) { if case .update = $1 { return $0 + 1 }; return $0 } }
    var shownColors: [CursorColor] {
        calls.compactMap { if case let .show(color) = $0 { return color }; return nil }
    }
    var updates: [(panelFrame: Rect, cursorInPanel: Point, visualState: CursorVisualState)] {
        calls.compactMap {
            if case let .update(panelFrame, cursorInPanel, visualState) = $0 {
                return (panelFrame, cursorInPanel, visualState)
            }
            return nil
        }
    }
    var lastUpdate: (panelFrame: Rect, cursorInPanel: Point, visualState: CursorVisualState)? { updates.last }
}

/// A `CursorAnimating` that NEVER settles — used to prove the controller/scheduler never
/// waits on animation completion (the overlay decoupling invariant).
final class NeverSettlingAnimator: CursorAnimating {
    private(set) var identityColor: CursorColor?
    /// Always false: the interpolation is defined never to reach its target.
    var isSettled: Bool { false }

    private(set) var resetCount = 0
    private(set) var retargets: [(Point, CursorVisualState)] = []
    private(set) var tickCount = 0
    private(set) var synchronizeCount = 0
    private(set) var stopCount = 0

    func reset(color: CursorColor, at position: Point) {
        identityColor = color
        resetCount += 1
    }
    func retarget(to target: Point, state: CursorVisualState) {
        retargets.append((target, state))
    }
    func tick(dt: Double) -> CursorFrame {
        tickCount += 1
        return CursorFrame(position: Point(x: 0, y: 0), visualState: .idle, settled: false)
    }
    func synchronize() { synchronizeCount += 1 }
    func stop() { stopCount += 1 }
}

// Common fixtures.
extension Rect {
    /// A window at global (100, 200), 400×300 points — the standard overlay fixture.
    static let fixtureWindow = Rect(x: 100, y: 200, width: 400, height: 300)
    /// The window after a move to global (140, 260), same size.
    static let fixtureWindowMoved = Rect(x: 140, y: 260, width: 400, height: 300)
}
