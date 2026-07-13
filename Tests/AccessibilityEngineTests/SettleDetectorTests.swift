import XCTest
@testable import AccessibilityEngine

/// Bounded adaptive settle logic (docs/PROTOCOL.md §15.3). Pure decision function plus
/// the driver loop under a fake clock — no live observer, no Accessibility.
final class SettleDetectorTests: XCTestCase {
    private let timings = SettleDetector.Timings.default // 75ms / 150ms / 1s / 5s

    // MARK: - Pure decision (§15.3 order of checks)

    func testMinDelayKeepsWaitingEvenWhenQuiet() {
        // Quiet since before the wait, but the minimum post-action delay has not elapsed.
        let decision = SettleDetector.decide(
            startedAt: 0, now: 0.05, lastActivityAt: -1, loading: false, timings: timings
        )
        XCTAssertEqual(decision, .keepWaiting)
    }

    func testQuietWindowSettlesAfterMinDelay() {
        let decision = SettleDetector.decide(
            startedAt: 0, now: 0.20, lastActivityAt: 0.0, loading: false, timings: timings
        )
        // elapsed 0.20 ≥ minDelay; quietFor 0.20 ≥ 0.15 → settled.
        XCTAssertEqual(decision, .finished(.settled))
    }

    func testRecentActivityKeepsWaiting() {
        let decision = SettleDetector.decide(
            startedAt: 0, now: 0.20, lastActivityAt: 0.15, loading: false, timings: timings
        )
        // elapsed 0.20 ≥ minDelay, but quietFor 0.05 < 0.15 → keep waiting.
        XCTAssertEqual(decision, .keepWaiting)
    }

    func testNormalDeadlineExpiresToPossiblyUnsettled() {
        let decision = SettleDetector.decide(
            startedAt: 0, now: 1.0, lastActivityAt: 0.99, loading: false, timings: timings
        )
        XCTAssertEqual(decision, .finished(.possiblyUnsettled))
    }

    func testLoadingExtendsDeadlineBeyondNormal() {
        // Past the 1 s normal deadline but loading → not expired (loading deadline 5 s).
        let stillWaiting = SettleDetector.decide(
            startedAt: 0, now: 2.0, lastActivityAt: 2.0, loading: true, timings: timings
        )
        XCTAssertEqual(stillWaiting, .keepWaiting)

        // The same elapsed time without loading would already be expired.
        let expired = SettleDetector.decide(
            startedAt: 0, now: 2.0, lastActivityAt: 2.0, loading: false, timings: timings
        )
        XCTAssertEqual(expired, .finished(.possiblyUnsettled))

        // Loading eventually hits its own deadline.
        let loadingExpired = SettleDetector.decide(
            startedAt: 0, now: 5.0, lastActivityAt: 5.0, loading: true, timings: timings
        )
        XCTAssertEqual(loadingExpired, .finished(.possiblyUnsettled))
    }

    func testDeadlineWinsOverQuiet() {
        // Even if quiet, an expired deadline reports possiblyUnsettled (deadline first).
        let decision = SettleDetector.decide(
            startedAt: 0, now: 1.5, lastActivityAt: 0.0, loading: false, timings: timings
        )
        XCTAssertEqual(decision, .finished(.possiblyUnsettled))
    }

    // MARK: - Driver loop under a fake clock

    /// A fake clock whose `sleep` advances time, so the loop terminates deterministically.
    private final class FakeClock {
        var t: TimeInterval = 0
        func now() -> TimeInterval { t }
        func sleep(_ dt: TimeInterval) { t += dt }
    }

    func testWaitSettlesWhenAlreadyQuiet() {
        let clock = FakeClock()
        let outcome = SettleDetector.waitForSettle(
            timings: timings, pollInterval: 0.02,
            clock: clock.now, sleep: clock.sleep,
            activity: { (lastActivityAt: 0.0, loading: false) }
        )
        XCTAssertEqual(outcome, .settled)
        // Settles once both min-delay and the quiet window are satisfied (~0.15 s).
        XCTAssertGreaterThanOrEqual(clock.t, 0.15)
        XCTAssertLessThan(clock.t, 0.30)
    }

    func testWaitSettlesAfterActivityStops() {
        let clock = FakeClock()
        let busyUntil = 0.5
        let outcome = SettleDetector.waitForSettle(
            timings: timings, pollInterval: 0.02,
            clock: clock.now, sleep: clock.sleep,
            activity: { [clock] in
                // Activity keeps stamping "now" until it stops at busyUntil, then freezes.
                let last = min(clock.t, busyUntil)
                return (lastActivityAt: last, loading: false)
            }
        )
        XCTAssertEqual(outcome, .settled)
        // Quiet window begins at 0.5; settles ~0.15 s later, before the 1 s deadline.
        XCTAssertGreaterThanOrEqual(clock.t, 0.65)
        XCTAssertLessThan(clock.t, 1.0)
    }

    func testWaitTimesOutToPossiblyUnsettledUnderContinuousActivity() {
        let clock = FakeClock()
        let outcome = SettleDetector.waitForSettle(
            timings: timings, pollInterval: 0.02,
            clock: clock.now, sleep: clock.sleep,
            activity: { [clock] in (lastActivityAt: clock.t, loading: false) } // never quiet
        )
        XCTAssertEqual(outcome, .possiblyUnsettled)
        XCTAssertGreaterThanOrEqual(clock.t, 1.0) // hit the normal deadline
        XCTAssertLessThan(clock.t, 1.2)
    }

    func testWaitExtendsUnderLoadingThenTimesOut() {
        let clock = FakeClock()
        let outcome = SettleDetector.waitForSettle(
            timings: timings, pollInterval: 0.02,
            clock: clock.now, sleep: clock.sleep,
            activity: { [clock] in (lastActivityAt: clock.t, loading: true) } // busy the whole time
        )
        XCTAssertEqual(outcome, .possiblyUnsettled)
        XCTAssertGreaterThanOrEqual(clock.t, 5.0) // rode the loading deadline
        XCTAssertLessThan(clock.t, 5.2)
    }

    // MARK: - Cancellation shortcuts the wait (§17.2)

    func testCancellationShortcutsTheWait() {
        // The same never-quiet + loading configuration that rides the 5 s loading deadline above,
        // but a cancel flips true after a few polls — the loop must break promptly instead of
        // paying the full deadline. The caller's post-settle checkpoint (§17.2) turns this into a
        // typed `cancelled`, so the loop returns the benign `.settled`.
        let clock = FakeClock()
        var polls = 0
        let outcome = SettleDetector.waitForSettle(
            timings: timings, pollInterval: 0.02,
            clock: clock.now, sleep: clock.sleep,
            activity: { [clock] in (lastActivityAt: clock.t, loading: true) }, // never quiet, loading
            isCancelled: { polls += 1; return polls > 3 } // cancel arrives after a few slices
        )
        XCTAssertEqual(outcome, .settled)
        // Broke far earlier than even the 1 s normal deadline (≈0.06 s of fake time), proving the
        // up-to-5 s wait was shortcut by the cancel — not by any settle/deadline condition.
        XCTAssertLessThan(clock.t, 0.15)
    }

    func testAlreadyCancelledReturnsImmediatelyWithoutSleeping() {
        // Cancelled before the first poll: return at once, no sleep advanced.
        let clock = FakeClock()
        let outcome = SettleDetector.waitForSettle(
            timings: timings, pollInterval: 0.02,
            clock: clock.now, sleep: clock.sleep,
            activity: { [clock] in (lastActivityAt: clock.t, loading: true) },
            isCancelled: { true }
        )
        XCTAssertEqual(outcome, .settled)
        XCTAssertEqual(clock.t, 0.0, "an already-cancelled wait must not sleep at all")
    }
}
