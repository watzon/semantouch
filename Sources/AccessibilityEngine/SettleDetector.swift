import Foundation
import ComputerUseCore

/// Bounded adaptive settle detection (docs/PROTOCOL.md §15.3). After an action marks
/// a window dirty, `get_app_state` waits for the UI to go
/// quiet before it walks the tree — long enough that a state change is captured, short
/// enough that the agent is not needlessly slowed. The policy is a pure state machine
/// (`decide`) over a monotonic clock plus the observer's activity signal, so it is
/// exercised deterministically with a fake clock — no Accessibility permission.
public enum SettleDetector {
    /// Adaptive wait parameters frozen in PROTOCOL.md §15.3. One
    /// tunable struct so every timing lives in a single place.
    public struct Timings: Equatable, Sendable {
        /// Minimum time to wait after the action before settling can be declared, even
        /// if the UI is already quiet — absorbs the gap before the first notification.
        public var minDelay: TimeInterval
        /// Required window of no observed activity to declare the UI settled.
        public var quiet: TimeInterval
        /// Hard deadline for an ordinary interaction.
        public var normalDeadline: TimeInterval
        /// Hard deadline while a busy/progress indicator is (recently) active.
        public var loadingDeadline: TimeInterval

        public init(
            minDelay: TimeInterval = 0.075,
            quiet: TimeInterval = 0.150,
            normalDeadline: TimeInterval = 1.0,
            loadingDeadline: TimeInterval = 5.0
        ) {
            self.minDelay = minDelay
            self.quiet = quiet
            self.normalDeadline = normalDeadline
            self.loadingDeadline = loadingDeadline
        }

        /// Frozen defaults: min-delay 75 ms, quiet 150 ms, normal deadline 1 s, loading
        /// deadline 5 s (docs/PROTOCOL.md §15.3).
        public static let `default` = Timings()
    }

    /// The result of a settle wait.
    public enum Outcome: Equatable, Sendable {
        /// The UI went quiet within the deadline.
        case settled
        /// The deadline expired while activity was still ongoing; state is returned
        /// anyway with a `possibly_unsettled` warning (§15.3).
        case possiblyUnsettled
    }

    /// One step of the settle decision.
    public enum Decision: Equatable, Sendable {
        case keepWaiting
        case finished(Outcome)
    }

    /// Pure settle policy. All times are seconds on the same monotonic clock.
    ///
    /// - `startedAt`: when the wait began.
    /// - `now`: current time.
    /// - `lastActivityAt`: timestamp of the most recent observed AX activity (a value
    ///   at or before `startedAt` means "quiet since before the wait").
    /// - `loading`: whether a busy/progress indicator was recently active — extends the
    ///   deadline from `normalDeadline` to `loadingDeadline`.
    ///
    /// Order of checks: the hard deadline wins; then the minimum delay must
    /// elapse; then a quiet window settles it; otherwise keep waiting.
    public static func decide(
        startedAt: TimeInterval,
        now: TimeInterval,
        lastActivityAt: TimeInterval,
        loading: Bool,
        timings: Timings = .default
    ) -> Decision {
        let elapsed = now - startedAt
        let deadline = loading ? timings.loadingDeadline : timings.normalDeadline
        if elapsed >= deadline {
            return .finished(.possiblyUnsettled)
        }
        if elapsed < timings.minDelay {
            return .keepWaiting
        }
        let quietFor = now - lastActivityAt
        if quietFor >= timings.quiet {
            return .finished(.settled)
        }
        return .keepWaiting
    }

    /// Drive `decide` to completion. `clock` returns the current monotonic time;
    /// `sleep` advances it (real code sleeps the thread; tests advance a fake clock);
    /// `activity` reports the latest `(lastActivityAt, loading)` each poll. `isCancelled`
    /// is polled between sleep slices so a cancellation (§17.2) breaks the up-to-5 s wait
    /// promptly instead of paying the full deadline; it defaults to never-cancelled, so
    /// the frozen timings and existing behavior are unchanged. Injectable so the loop is
    /// unit-tested without a live observer.
    public static func waitForSettle(
        timings: Timings = .default,
        pollInterval: TimeInterval = 0.02,
        clock: () -> TimeInterval,
        sleep: (TimeInterval) -> Void,
        activity: () -> (lastActivityAt: TimeInterval, loading: Bool),
        isCancelled: () -> Bool = { false }
    ) -> Outcome {
        let start = clock()
        while true {
            // Break the wait promptly on cancellation. The caller's post-settle checkpoint
            // (§17.2) turns this into a typed `cancelled`, so return the benign `.settled` —
            // no `possibly_unsettled` warning is attached to a request about to be cancelled.
            if isCancelled() { return .settled }
            let current = activity()
            switch decide(
                startedAt: start,
                now: clock(),
                lastActivityAt: current.lastActivityAt,
                loading: current.loading,
                timings: timings
            ) {
            case let .finished(outcome):
                return outcome
            case .keepWaiting:
                sleep(pollInterval)
            }
        }
    }

    /// A monotonic clock reading in seconds, safe to diff for elapsed time.
    public static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
