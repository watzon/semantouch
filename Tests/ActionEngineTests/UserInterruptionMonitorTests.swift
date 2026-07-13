import XCTest
import CoreGraphics
@testable import ActionEngine

/// The pure interruption state machine, fed injected synthetic events (no live tap).
final class UserInterruptionMonitorTests: XCTestCase {
    func testOurTaggedEventsNeverInterrupt() {
        let state = InterruptionState()
        state.arm()
        for t in stride(from: 0.0, to: 1.0, by: 0.1) {
            state.observe(isOurs: true, at: t)
        }
        XCTAssertFalse(state.isInterrupted, "our own tagged events must never interrupt")
    }

    func testUserEventWhileArmedInterrupts() {
        let state = InterruptionState()
        state.arm()
        state.observe(isOurs: false, at: 1.0)
        XCTAssertTrue(state.isInterrupted)
    }

    func testUserEventWhileDisarmedIsIgnored() {
        let state = InterruptionState()
        state.observe(isOurs: false, at: 1.0) // not armed
        XCTAssertFalse(state.isInterrupted)
    }

    func testArmClearsPriorInterruptionOnFreshWindow() {
        let state = InterruptionState()
        state.arm()
        state.observe(isOurs: false, at: 1.0)
        XCTAssertTrue(state.isInterrupted)
        state.disarm()
        state.arm() // fresh window (0 → 1) clears
        XCTAssertFalse(state.isInterrupted)
    }

    func testNestedArmDoesNotResetInterruption() {
        let state = InterruptionState()
        state.arm() // count 1
        state.arm() // count 2 (concurrent action)
        state.observe(isOurs: false, at: 1.0)
        XCTAssertTrue(state.isInterrupted)
        state.disarm() // count 1 — still interrupted for the remaining action
        XCTAssertTrue(state.isInterrupted)
    }

    func testGenuineKeyboardInterruptsEvenDuringDenseSyntheticDelivery() {
        // Regression: the old blanket debounce suppressed any untagged event within 50 ms of
        // one of ours, so a user keypress during a tight type_text/press_key loop (events
        // back-to-back) was silently ignored — the user could not cancel. The tag alone must
        // discriminate: a genuine keyDown right after our own synthetic event interrupts NOW.
        let state = InterruptionState(debounce: 0.05)
        state.arm()
        state.observe(isOurs: true, type: .keyDown, at: 1.000)   // our synthetic key
        state.observe(isOurs: false, type: .keyDown, at: 1.001)  // user key 1 ms later
        XCTAssertTrue(state.isInterrupted, "a genuine keyDown must interrupt even inside the echo window")
    }

    func testGenuineButtonAndScrollAreNeverEchoSuppressed() {
        for type in [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .flagsChanged] {
            let state = InterruptionState(debounce: 0.05)
            state.arm()
            state.observe(isOurs: true, type: .mouseMoved, at: 1.000)
            state.observe(isOurs: false, type: type, at: 1.001)
            XCTAssertTrue(state.isInterrupted, "\(type) must interrupt immediately, never be debounced")
        }
    }

    func testOnlyMouseMoveEchoIsSuppressed() {
        // The one narrow guard: an untagged mouse MOVE just after our cursor warp is treated as
        // an echo and ignored; a later genuine move still interrupts.
        let state = InterruptionState(debounce: 0.05)
        state.arm()
        state.observe(isOurs: true, type: .mouseMoved, at: 1.00)   // our warp
        state.observe(isOurs: false, type: .mouseMoved, at: 1.02)  // untagged move within 50 ms → echo, ignored
        XCTAssertFalse(state.isInterrupted, "an untagged mouse move within the echo window is ignored")
        state.observe(isOurs: false, type: .mouseMoved, at: 1.20)  // well outside → genuine
        XCTAssertTrue(state.isInterrupted)
    }

    func testInterruptionSignalIsProcessGlobalAcrossOverlappingWindows() {
        // Documents the intentional process-global model (one physical user, one passive tap):
        // while two fallback deliveries are armed concurrently, a single genuine event trips
        // BOTH — the safe over-yield direction, never an under-yield. A window armed AFTER the
        // signal has fully drained (all disarmed) starts clean, so no stale flag leaks forward.
        let state = InterruptionState()
        state.arm()                           // window A
        state.arm()                           // window B (overlapping)
        state.observe(isOurs: false, at: 1.0) // one physical event
        XCTAssertTrue(state.isInterrupted, "a genuine event trips every concurrently-armed window")
        state.disarm()
        state.disarm()                        // both drained → flag cleared on full disarm
        state.arm()                           // a later window
        XCTAssertFalse(state.isInterrupted, "a window armed after the signal drained starts clean")
    }

    func testDegradedFlag() {
        let state = InterruptionState()
        XCTAssertFalse(state.degraded)
        state.markDegraded()
        XCTAssertTrue(state.degraded)
    }

    func testResetClearsEverything() {
        let state = InterruptionState()
        state.arm()
        state.observe(isOurs: false, at: 1.0)
        state.reset()
        XCTAssertFalse(state.isInterrupted)
        // After reset the window is closed, so a user event is ignored until re-armed.
        state.observe(isOurs: false, at: 2.0)
        XCTAssertFalse(state.isInterrupted)
    }
}
