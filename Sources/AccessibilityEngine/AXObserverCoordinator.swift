import Foundation
import ApplicationServices
import CoreGraphics
import ComputerUseCore

// Event-driven invalidation (docs/PROTOCOL.md §15.3). The coordinator hosts
// one AXObserver per observed application on a single dedicated CFRunLoop thread and
// converts AX notifications into cheap, lock-guarded "dirty + activity timestamp"
// updates — never any tree work on the observer thread. `get_app_state` consults the
// resulting activity state through `SettleDetector` to decide how long to wait before
// re-walking the tree.
//
// The AX plumbing (`AXObserverCoordinator`) is impure and never exercised by the
// permission-free tests; the state machine it feeds (`ObserverActivityState`) is pure
// and fully tested via injected notifications and a fake clock.

/// A snapshot of one application's observed activity, read by the settle detector.
public struct ActivitySnapshot: Equatable, Sendable {
    /// Whether the window needs a rebuild (an action or a notification dirtied it, or
    /// observation is degraded so we always rebuild).
    public let dirty: Bool
    /// Monotonic timestamp of the most recent observed activity.
    public let lastActivityAt: TimeInterval
    /// Whether a busy/progress indicator was active within the loading window.
    public let loading: Bool
    /// Whether observer registration failed for this app, so it is treated as always
    /// dirty (full rebuilds) — the graceful-degradation path (never a crash).
    public let degraded: Bool

    public init(dirty: Bool, lastActivityAt: TimeInterval, loading: Bool, degraded: Bool) {
        self.dirty = dirty
        self.lastActivityAt = lastActivityAt
        self.loading = loading
        self.degraded = degraded
    }
}

/// Pure, thread-safe activity tracker keyed by pid. AX notifications and action
/// dirtying both funnel here; the settle detector reads `snapshot(pid:)`. The clock is
/// injectable so timing is deterministic under test.
public final class ObserverActivityState: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    /// How long after a busy/progress signal the app is still considered "loading".
    private let loadingWindow: TimeInterval

    private struct Entry {
        var dirty: Bool
        var lastActivityAt: TimeInterval
        var loadingUntil: TimeInterval
        var degraded: Bool
    }
    private var entries: [pid_t: Entry] = [:]

    public init(
        clock: @escaping @Sendable () -> TimeInterval = { SettleDetector.monotonicNow() },
        loadingWindow: TimeInterval = 0.5
    ) {
        self.clock = clock
        self.loadingWindow = loadingWindow
    }

    /// Begin tracking `pid`. The entry starts dirty (the first snapshot must build) and
    /// records "activity now" so a settle wait observes the natural quiet window.
    public func attach(pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        entries[pid] = Entry(dirty: true, lastActivityAt: now, loadingUntil: 0, degraded: false)
    }

    /// Stop tracking `pid` (session end or app death).
    public func detach(pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: pid)
    }

    /// Mark `pid` dirty and stamp activity now — used after a mutation so the next
    /// `get_app_state` settles before rebuilding.
    public func markDirty(pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        var entry = entries[pid] ?? Entry(dirty: false, lastActivityAt: 0, loadingUntil: 0, degraded: false)
        entry.dirty = true
        entry.lastActivityAt = clock()
        entries[pid] = entry
    }

    /// Record that observer registration failed for `pid`: degrade to always-dirty
    /// (full rebuilds) rather than trusting stale incremental state.
    public func markDegraded(pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        var entry = entries[pid] ?? Entry(dirty: true, lastActivityAt: clock(), loadingUntil: 0, degraded: false)
        entry.degraded = true
        entry.dirty = true
        entries[pid] = entry
    }

    /// Record an AX notification for `pid`: dirty + activity now, and extend the
    /// loading window when the source was a busy/progress indicator. This is the only
    /// work done per notification (no tree walking).
    public func recordNotification(pid: pid_t, busy: Bool) {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        var entry = entries[pid] ?? Entry(dirty: false, lastActivityAt: now, loadingUntil: 0, degraded: false)
        entry.dirty = true
        entry.lastActivityAt = now
        if busy {
            entry.loadingUntil = now + loadingWindow
        }
        entries[pid] = entry
    }

    /// Clear the dirty flag after a settled rebuild. A degraded app stays dirty.
    public func clearDirty(pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[pid], !entry.degraded else { return }
        entry.dirty = false
        entries[pid] = entry
    }

    /// The current activity snapshot for `pid`. An untracked pid reports quiet + clean.
    public func snapshot(pid: pid_t) -> ActivitySnapshot {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[pid] else {
            return ActivitySnapshot(dirty: false, lastActivityAt: 0, loading: false, degraded: false)
        }
        let now = clock()
        return ActivitySnapshot(
            dirty: entry.dirty || entry.degraded,
            lastActivityAt: entry.lastActivityAt,
            loading: now < entry.loadingUntil,
            degraded: entry.degraded
        )
    }

    /// Whether `pid` is currently being tracked.
    public func isTracking(pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[pid] != nil
    }
}

/// The minimal AX notification set the coordinator subscribes to: element
/// lifecycle, value/title changes, layout/geometry, focus, and window/sheet lifecycle.
/// Written as literal notification names (stable AX strings) so the code does not
/// depend on which `kAX…Notification` constants a given SDK re-exports to Swift.
enum AXNotificationName {
    static let all: [String] = [
        "AXUIElementDestroyed",
        "AXCreated",
        "AXValueChanged",
        "AXTitleChanged",
        "AXLayoutChanged",
        "AXResized",
        "AXMoved",
        "AXFocusedUIElementChanged",
        "AXFocusedWindowChanged",
        "AXMainWindowChanged",
        "AXWindowCreated",
        "AXWindowMoved",
        "AXWindowMiniaturized",
        "AXWindowDeminiaturized",
        "AXSelectedTextChanged",
        "AXRowCountChanged",
    ]
    static let valueChanged = "AXValueChanged"
}

/// Hosts AXObserver instances on a dedicated CFRunLoop thread and forwards
/// notifications into an `ObserverActivityState`. Public Apple APIs only.
///
/// Lifecycle: `observe(pid:)` on the first `get_app_state` for a session; `stopObserving`
/// on `end_app_session`; `shutdown()` on process teardown. Registration failure degrades
/// the app to always-dirty (a logged warning to stderr) and never throws or crashes.
public final class AXObserverCoordinator: @unchecked Sendable {
    /// The activity state fed by observed notifications and by action dirtying.
    public let state: ObserverActivityState

    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var stopped = false
    private let ready = DispatchSemaphore(value: 0)

    /// The live AXObserver per pid, written only on the runloop thread.
    private var observers: [pid_t: AXObserver] = [:]
    /// Pids `observe(pid:)` has claimed (reserved *before* enqueueing registration). This
    /// closes the check-then-enqueue window: two back-to-back `observe(pid:)` calls for one
    /// pid, or an `observe` racing an in-flight `registerObserver`, cannot both pass the
    /// guard and double-register (which would leak an AXObserver whose runloop source is
    /// never removed → dangling scheduled source → UAF). It is also the single idempotency
    /// gate and the cancel signal `registerObserver` re-checks after a `stopObserving`.
    private var observed: Set<pid_t> = []

    public init(state: ObserverActivityState = ObserverActivityState()) {
        self.state = state
    }

    // MARK: - Public API

    /// Begin observing `pid`. Idempotent per pid. Safe to call without the Accessibility
    /// grant — it degrades to always-dirty rather than failing.
    public func observe(pid: pid_t) {
        lock.lock()
        if observed.contains(pid) {
            lock.unlock()
            return
        }
        observed.insert(pid) // claim before enqueueing so no concurrent observe double-registers
        lock.unlock()

        // Seed the activity entry synchronously on the caller thread, up front, separate
        // from the async AXObserver registration. This makes the first snapshot's
        // dirty/attach ordering deterministic: attach happens before `observe` returns, so
        // the first `get_app_state`'s later `clearDirty(pid:)` reliably lands AFTER it —
        // otherwise the registration's attach could re-dirty a just-cleared session and
        // force a spurious settle wait on the second snapshot.
        state.attach(pid: pid)

        ensureThread()
        performOnRunLoop { [weak self] in
            self?.registerObserver(pid: pid)
        }
    }

    /// Stop observing `pid` and release its observer + activity entry.
    public func stopObserving(pid: pid_t) {
        // Detach and unregister run together on the runloop thread (where the observer
        // callback also runs), so a notification callback cannot race between them and
        // resurrect a just-detached activity entry, and a pid's lifecycle transitions are
        // totally ordered on one thread.
        performOnRunLoop { [weak self] in
            self?.unregisterObserver(pid: pid)
        }
    }

    /// Tear down the runloop thread and all observers.
    public func shutdown() {
        lock.lock()
        stopped = true
        let pids = Array(observed) // includes pids registered OR still pending registration
        let loop = runLoop
        lock.unlock()

        performOnRunLoop { [weak self] in
            for pid in pids { self?.unregisterObserver(pid: pid) }
        }
        if let loop { CFRunLoopWakeUp(loop) }
    }

    // MARK: - Run loop thread

    private func ensureThread() {
        lock.lock()
        if thread != nil {
            lock.unlock()
            return
        }
        let t = Thread { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.runLoop = CFRunLoopGetCurrent()
            self.lock.unlock()
            self.ready.signal()

            // Keep the runloop alive even with no observer sources yet: a far-future
            // repeating timer is a source, so `CFRunLoopRunInMode` blocks instead of
            // returning immediately. Short slices let `stopped` break the loop promptly.
            let timer = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + Double.greatestFiniteMagnitude,
                0, 0, 0
            ) { _ in }
            if let timer {
                CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
            }
            while !self.isStopped {
                _ = CFRunLoopRunInMode(.defaultMode, 0.25, true)
            }
        }
        t.name = "dev.watzon.semantouch.ax-observer"
        t.stackSize = 512 * 1024
        thread = t
        lock.unlock()
        t.start()
        ready.wait()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Enqueue `block` on the observer runloop and wake it. If the thread is not up,
    /// runs inline as a best-effort fallback.
    private func performOnRunLoop(_ block: @escaping () -> Void) {
        lock.lock()
        let loop = runLoop
        lock.unlock()
        guard let loop else {
            block()
            return
        }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    // MARK: - Registration (on the runloop thread)

    private func registerObserver(pid: pid_t) {
        // A `stopObserving`/`shutdown` may have cancelled this pid before the runloop
        // reached us (both hop through the same runloop thread, FIFO). If it is no longer
        // claimed, do not create an observer — that would leak one for a stopped session.
        lock.lock()
        let wanted = observed.contains(pid)
        lock.unlock()
        guard wanted else { return }

        var observer: AXObserver?
        let err = AXObserverCreate(pid, axObserverCallback, &observer)
        guard err == .success, let observer else {
            FileHandle.standardError.write(Data(
                "semantouch: AXObserverCreate failed for pid \(pid) (\(err.rawValue)); degrading to full rebuilds.\n".utf8
            ))
            // The activity entry already exists (attached in observe); degrade it. Leave the
            // pid claimed so we do not retry-storm a genuinely unregisterable app.
            state.markDegraded(pid: pid)
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in AXNotificationName.all {
            // Per-notification failures are non-fatal: an app that does not post a given
            // notification simply will not accelerate settle for that event.
            _ = AXObserverAddNotification(observer, appElement, name as CFString, refcon)
        }

        // Publish only if still claimed. If a `stopObserving` landed while we were creating
        // (it cleared `observed` and detached), do NOT schedule the fresh source — let the
        // observer release at scope end so we never leave a live source for an untracked pid.
        lock.lock()
        let stillWanted = observed.contains(pid)
        if stillWanted { observers[pid] = observer }
        lock.unlock()
        guard stillWanted else { return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func unregisterObserver(pid: pid_t) {
        lock.lock()
        observed.remove(pid) // cancels a still-pending registration and clears the idempotency claim
        let observer = observers.removeValue(forKey: pid)
        lock.unlock()
        // Detach here (runloop thread) so it is ordered with the observer callback and a
        // late notification cannot resurrect the activity entry for a stopped pid.
        state.detach(pid: pid)
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}

/// The C observer callback: stamp activity for the notification's owning process, with
/// a cheap busy/progress check on value changes. No tree work.
private let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let coordinator = Unmanaged<AXObserverCoordinator>.fromOpaque(refcon).takeUnretainedValue()

    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)

    var busy = false
    if (notification as String) == AXNotificationName.valueChanged {
        // Bound this one cross-process read. Without a timeout an unresponsive target could
        // stall this shared observer thread for the ~6 s default AX messaging timeout,
        // blocking notification delivery and (un)registration for EVERY observed app. A
        // short per-read cap keeps busy-detection cheap for a responsive app and treats a
        // timeout/failure as not-busy — the callback still only does "stamp dirty + activity".
        AXUIElementSetMessagingTimeout(element, 0.1)
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &roleValue) == .success,
           let role = roleValue as? String {
            busy = role == "AXProgressIndicator" || role == "AXBusyIndicator"
        }
    }
    coordinator.state.recordNotification(pid: pid, busy: busy)
}
