import XCTest
import CoreGraphics
import ComputerUseCore
@testable import ActionEngine

/// Pointer fallback delivery + scroll-delta mapping over a recording synthesizer.
final class PointerActionsTests: XCTestCase {
    private func armedMonitor() -> InterruptionState {
        let m = InterruptionState(); m.arm(); return m
    }

    // MARK: - Click

    func testClickEmitsDownThenUp() {
        let synth = FakeSynthesizer()
        PointerActions.click(atGlobal: CGPoint(x: 10, y: 20), button: .left, flags: [], via: synth, interruption: armedMonitor())
        XCTAssertEqual(synth.events, [
            .mouseDown(CGPoint(x: 10, y: 20), .left),
            .mouseUp(CGPoint(x: 10, y: 20), .left),
        ])
    }

    func testDoubleClickEmitsTwoDownUpPairs() {
        let synth = FakeSynthesizer()
        PointerActions.click(
            atGlobal: CGPoint(x: 1, y: 2),
            button: .left,
            flags: [],
            clickCount: 2,
            via: synth,
            interruption: armedMonitor()
        )
        XCTAssertEqual(synth.events, [
            .mouseDown(CGPoint(x: 1, y: 2), .left),
            .mouseUp(CGPoint(x: 1, y: 2), .left),
            .mouseDown(CGPoint(x: 1, y: 2), .left),
            .mouseUp(CGPoint(x: 1, y: 2), .left),
        ])
    }

    func testTripleClickEmitsThreeDownUpPairs() {
        let synth = FakeSynthesizer()
        PointerActions.click(
            atGlobal: .zero,
            button: .left,
            flags: [],
            clickCount: 3,
            via: synth,
            interruption: armedMonitor()
        )
        XCTAssertEqual(synth.events.count, 6)
        XCTAssertEqual(synth.events.filter { if case .mouseDown = $0 { return true }; return false }.count, 3)
        XCTAssertEqual(synth.events.filter { if case .mouseUp = $0 { return true }; return false }.count, 3)
    }

    func testMiddleClickUsesMiddleButton() {
        let synth = FakeSynthesizer()
        PointerActions.click(atGlobal: CGPoint(x: 5, y: 5), button: .middle, flags: [], via: synth, interruption: armedMonitor())
        XCTAssertEqual(synth.events, [
            .mouseDown(CGPoint(x: 5, y: 5), .middle),
            .mouseUp(CGPoint(x: 5, y: 5), .middle),
        ])
    }

    func testRightClickUsesRightButton() {
        let synth = FakeSynthesizer()
        PointerActions.click(atGlobal: CGPoint(x: 3, y: 4), button: .right, flags: [], via: synth, interruption: armedMonitor())
        XCTAssertEqual(synth.events, [
            .mouseDown(CGPoint(x: 3, y: 4), .right),
            .mouseUp(CGPoint(x: 3, y: 4), .right),
        ])
    }

    func testClickSkipsWhenAlreadyInterrupted() {
        let synth = FakeSynthesizer()
        let monitor = InterruptionState()
        monitor.arm()
        monitor.observe(isOurs: false, at: 1.0) // interrupted before delivery
        PointerActions.click(atGlobal: .zero, button: .left, flags: [], via: synth, interruption: monitor)
        XCTAssertTrue(synth.events.isEmpty, "no input is delivered once interrupted")
    }

    func testMultiClickStopsBetweenUnitsOnInterruption() {
        let synth = FakeSynthesizer()
        let monitor = InterruptionState()
        monitor.arm()
        var count = 0
        synth.onEmit = {
            count += 1
            // After first down/up pair (2 events), interrupt before unit 2.
            if count == 2 { monitor.observe(isOurs: false, at: 1.0) }
        }
        PointerActions.click(
            atGlobal: .zero,
            button: .left,
            flags: [],
            clickCount: 3,
            via: synth,
            interruption: monitor
        )
        XCTAssertEqual(synth.events.count, 2, "only the first click unit is delivered after interruption")
    }

    func testPointerButtonEventTypes() {
        XCTAssertEqual(PointerButton.left.downType, .leftMouseDown)
        XCTAssertEqual(PointerButton.left.upType, .leftMouseUp)
        XCTAssertEqual(PointerButton.right.downType, .rightMouseDown)
        XCTAssertEqual(PointerButton.right.upType, .rightMouseUp)
        XCTAssertEqual(PointerButton.middle.downType, .otherMouseDown)
        XCTAssertEqual(PointerButton.middle.upType, .otherMouseUp)
        XCTAssertEqual(PointerButton.middle.cgButton, .center)
        XCTAssertEqual(PointerButton.middle.dragType, .otherMouseDragged)
    }

    // MARK: - Drag

    func testDragEmitsDownInterpolatedMovesThenUp() {
        let synth = FakeSynthesizer()
        PointerActions.drag(
            fromGlobal: CGPoint(x: 0, y: 0),
            toGlobal: CGPoint(x: 100, y: 0),
            button: .left, flags: [], via: synth, interruption: armedMonitor()
        )
        guard case .mouseDown(let start, .left) = synth.events.first else {
            return XCTFail("first event must be mouseDown")
        }
        XCTAssertEqual(start, CGPoint(x: 0, y: 0))
        guard case .mouseUp(let end, .left) = synth.events.last else {
            return XCTFail("last event must be mouseUp")
        }
        XCTAssertEqual(end, CGPoint(x: 100, y: 0))
        // 1 down + 10 interpolated drags + 1 up.
        XCTAssertEqual(synth.events.count, 1 + PointerActions.dragSteps + 1)
        let dragCount = synth.events.filter { if case .mouseDrag = $0 { return true } else { return false } }.count
        XCTAssertEqual(dragCount, PointerActions.dragSteps)
    }

    func testDragInterruptedMidwayReleasesButton() {
        let synth = FakeSynthesizer()
        let monitor = InterruptionState()
        monitor.arm()
        // Interrupt after the mouseDown + first drag move.
        var count = 0
        synth.onEmit = {
            count += 1
            if count == 2 { monitor.observe(isOurs: false, at: 1.0) }
        }
        PointerActions.drag(
            fromGlobal: .zero, toGlobal: CGPoint(x: 100, y: 100),
            button: .left, flags: [], via: synth, interruption: monitor
        )
        // Must end with a mouseUp so no stuck drag is left behind.
        guard case .mouseUp = synth.events.last else {
            return XCTFail("an interrupted drag must release the button")
        }
        // Far fewer than a full 12-event drag.
        XCTAssertLessThan(synth.events.count, 1 + PointerActions.dragSteps + 1)
    }

    // MARK: - Scroll

    func testScrollEmitsWheelEvent() {
        let synth = FakeSynthesizer()
        PointerActions.scroll(atGlobal: CGPoint(x: 5, y: 6), deltaX: 0, deltaY: -9, flags: [], via: synth, interruption: armedMonitor())
        XCTAssertEqual(synth.events, [.scroll(CGPoint(x: 5, y: 6), 0, -9)])
    }

    func testScrollDeltasDirectionAndMagnitude() {
        // Vertical uses deltaY; horizontal uses deltaX. up/left positive, down/right negative.
        XCTAssertEqual(PointerActions.scrollDeltas(direction: .up, by: .line, count: 1).deltaY, 3)
        XCTAssertEqual(PointerActions.scrollDeltas(direction: .down, by: .line, count: 1).deltaY, -3)
        XCTAssertEqual(PointerActions.scrollDeltas(direction: .left, by: .line, count: 1).deltaX, 3)
        XCTAssertEqual(PointerActions.scrollDeltas(direction: .right, by: .line, count: 1).deltaX, -3)
        // count scales magnitude; page is larger than line.
        XCTAssertEqual(PointerActions.scrollDeltas(direction: .down, by: .line, count: 4).deltaY, -12)
        XCTAssertEqual(PointerActions.scrollDeltas(direction: .down, by: .page, count: 1).deltaY, -10)
        // Horizontal directions leave the other axis at 0.
        XCTAssertEqual(PointerActions.scrollDeltas(direction: .up, by: .line, count: 1).deltaX, 0)
    }

    func testScrollDeltasFractionalPage() {
        // Half a page → half of 10 line-units → 5.
        XCTAssertEqual(PointerActions.scrollDeltas(direction: .down, by: .page, count: 0.5).deltaY, -5)
        // Integer Double remains compatible with historical Int call sites.
        XCTAssertEqual(PointerActions.scrollDeltas(direction: .down, by: .line, count: 2.0).deltaY, -6)
    }
}
