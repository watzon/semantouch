import XCTest
@testable import AccessibilityEngine

/// The observer coordinator's pure state core (`ObserverActivityState`, docs/PROTOCOL.md
/// §15.3), driven by injected notifications and a fake clock. The live AXObserver glue
/// is not exercised here (it needs Accessibility); this proves the state machine that it
/// feeds.
final class AXObserverCoordinatorTests: XCTestCase {

    /// A controllable monotonic clock.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval
        init(_ t: TimeInterval = 0) { self.t = t }
        func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t += dt; lock.unlock() }
        func set(_ v: TimeInterval) { lock.lock(); t = v; lock.unlock() }
    }

    private func makeState(_ clock: FakeClock, loadingWindow: TimeInterval = 0.5) -> ObserverActivityState {
        ObserverActivityState(clock: { clock.now() }, loadingWindow: loadingWindow)
    }

    private let pid: pid_t = 4242

    // MARK: - Attach / dirty lifecycle

    func testAttachStartsDirtyWithActivityNow() {
        let clock = FakeClock(10)
        let state = makeState(clock)
        state.attach(pid: pid)
        let snap = state.snapshot(pid: pid)
        XCTAssertTrue(snap.dirty, "a freshly attached app needs its first build")
        XCTAssertEqual(snap.lastActivityAt, 10)
        XCTAssertFalse(snap.loading)
        XCTAssertFalse(snap.degraded)
        XCTAssertTrue(state.isTracking(pid: pid))
    }

    func testClearDirtyAfterBuild() {
        let clock = FakeClock()
        let state = makeState(clock)
        state.attach(pid: pid)
        state.clearDirty(pid: pid)
        XCTAssertFalse(state.snapshot(pid: pid).dirty)
    }

    func testMarkDirtyReDirtiesAndStampsActivity() {
        let clock = FakeClock(1)
        let state = makeState(clock)
        state.attach(pid: pid)
        state.clearDirty(pid: pid)
        clock.set(5)
        state.markDirty(pid: pid)
        let snap = state.snapshot(pid: pid)
        XCTAssertTrue(snap.dirty)
        XCTAssertEqual(snap.lastActivityAt, 5)
    }

    func testDetachStopsTracking() {
        let clock = FakeClock()
        let state = makeState(clock)
        state.attach(pid: pid)
        state.detach(pid: pid)
        XCTAssertFalse(state.isTracking(pid: pid))
        let snap = state.snapshot(pid: pid)
        XCTAssertFalse(snap.dirty, "an untracked pid is reported quiet + clean")
    }

    // MARK: - Notifications

    func testNotificationMarksDirtyAndUpdatesActivity() {
        let clock = FakeClock(1)
        let state = makeState(clock)
        state.attach(pid: pid)
        state.clearDirty(pid: pid)

        clock.set(3)
        state.recordNotification(pid: pid, busy: false)
        var snap = state.snapshot(pid: pid)
        XCTAssertTrue(snap.dirty)
        XCTAssertEqual(snap.lastActivityAt, 3)
        XCTAssertFalse(snap.loading)

        clock.set(4)
        state.recordNotification(pid: pid, busy: false)
        snap = state.snapshot(pid: pid)
        XCTAssertEqual(snap.lastActivityAt, 4, "each notification advances the activity timestamp")
    }

    func testBusyNotificationSetsLoadingWithinWindowOnly() {
        let clock = FakeClock(0)
        let state = makeState(clock, loadingWindow: 0.5)
        state.attach(pid: pid)

        clock.set(2.0)
        state.recordNotification(pid: pid, busy: true)

        clock.set(2.3) // within the 0.5 s loading window
        XCTAssertTrue(state.snapshot(pid: pid).loading)

        clock.set(2.6) // past the loading window
        XCTAssertFalse(state.snapshot(pid: pid).loading)
    }

    func testNotificationForUntrackedPidCreatesEntry() {
        // A notification can arrive fractionally before attach runs; it must not be lost.
        let clock = FakeClock(9)
        let state = makeState(clock)
        state.recordNotification(pid: pid, busy: false)
        let snap = state.snapshot(pid: pid)
        XCTAssertTrue(snap.dirty)
        XCTAssertEqual(snap.lastActivityAt, 9)
    }

    // MARK: - Degradation (registration failure)

    func testDegradedStaysDirtyEvenAfterClear() {
        let clock = FakeClock()
        let state = makeState(clock)
        state.attach(pid: pid)
        state.markDegraded(pid: pid)
        state.clearDirty(pid: pid) // must not clear a degraded app
        let snap = state.snapshot(pid: pid)
        XCTAssertTrue(snap.dirty, "a degraded app always rebuilds (always dirty)")
        XCTAssertTrue(snap.degraded)
    }

    func testDegradeWithoutPriorAttach() {
        let clock = FakeClock(3)
        let state = makeState(clock)
        state.markDegraded(pid: pid) // registration failed before attach
        let snap = state.snapshot(pid: pid)
        XCTAssertTrue(snap.dirty)
        XCTAssertTrue(snap.degraded)
    }

    // MARK: - Coordinator plumbing (no live AX)

    func testCoordinatorMarkDirtyRoutesToState() {
        // The AX thread never spins up for pure state routing; observe() is not called.
        let clock = FakeClock(7)
        let state = makeState(clock)
        let coordinator = AXObserverCoordinator(state: state)
        coordinator.state.markDirty(pid: pid)
        XCTAssertTrue(coordinator.state.snapshot(pid: pid).dirty)
    }
}
