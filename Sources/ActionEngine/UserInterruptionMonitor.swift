import Foundation
import CoreGraphics
import ComputerUseCore

// User-interruption monitor (docs/SECURITY.md §6). A
// PASSIVE, listen-only CGEvent tap observes physical key/mouse input on a dedicated
// runloop thread. Events carrying OUR tag (`FallbackTag`) are ignored; a genuine physical
// event during an armed fallback action sets an interrupted flag the executor polls
// between input units to cancel the remainder and return `status: interrupted`.
//
// The decision logic lives in the pure, thread-safe `InterruptionState` (fed by injected
// events under a fake clock in tests — no live tap). The impure `UserInterruptionMonitor`
// owns the tap; if tap creation fails it degrades to "no interruption detection" with a
// logged warning and a per-action `StateWarning`, never a crash.

// MARK: - Seam

/// The interruption surface the executor uses. `arm`/`disarm` bracket an action's input
/// delivery; `isInterrupted` is polled between units; `degraded` is true when detection is
/// unavailable (tap creation failed), which the executor surfaces as a warning.
public protocol InterruptionMonitoring: AnyObject {
    func arm()
    func disarm()
    var isInterrupted: Bool { get }
    var degraded: Bool { get }
}

// MARK: - Pure state machine

/// Pure, thread-safe interruption decision. Fed observed events (tagged ours vs. not) with
/// their `CGEventType` and a monotonic timestamp; sets `interrupted` on the first genuine
/// physical event during an armed window.
///
/// Discrimination rests on the reliable per-event/per-source **tag** (`FallbackTag`), NOT on
/// timing: genuine keyboard, button, scroll, and flag-change input ALWAYS interrupts,
/// immediately, so a dense synthetic delivery (a long `type_text`, a multi-chord `press_key`,
/// a drag) can never suppress the very cancellation it most needs. The only residual time
/// guard is narrow: an untagged **mouse-move** arriving right after one of our own synthetic
/// events is treated as a possible echo of our cursor warp and ignored — it never covers
/// a keyDown/flagsChanged/button/scroll event (docs/PROTOCOL.md §16.6).
///
/// The interruption signal is intentionally **process-global**: there is a single physical
/// user and one passive tap, so every concurrently-armed fallback delivery yields together on
/// genuine input — the safe over-yield direction, never an under-yield that would let input
/// keep flowing past a physical keypress. Today's runtime serializes fallback per request, so
/// concurrent arms do not actually occur.
public final class InterruptionState: InterruptionMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var armedCount = 0
    private var interrupted = false
    private var _degraded = false
    private var lastOurEventAt: TimeInterval = -.greatestFiniteMagnitude
    /// An untagged **mouse-move** within this window
    /// of our own last synthetic event is treated as a cursor-warp echo and ignored. It is
    /// deliberately scoped to mouse moves only — never keyboard/button/scroll input.
    private let debounce: TimeInterval

    public init(debounce: TimeInterval = 0.05) {
        self.debounce = debounce
    }

    /// Begin an armed window. The first arm (0 → 1) clears any stale interruption so each
    /// action starts fresh; nested arms (concurrent sessions) do not reset.
    public func arm() {
        lock.lock(); defer { lock.unlock() }
        if armedCount == 0 { interrupted = false }
        armedCount += 1
    }

    /// End an armed window. When the last armed window closes (count → 0) the flag is cleared,
    /// so a fully-drained cycle never leaves a sticky interruption for a later window (the
    /// symmetric guard to the 0 → 1 clear in `arm`).
    public func disarm() {
        lock.lock(); defer { lock.unlock() }
        armedCount = max(0, armedCount - 1)
        if armedCount == 0 { interrupted = false }
    }

    public var isInterrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return interrupted
    }

    public var degraded: Bool {
        lock.lock(); defer { lock.unlock() }
        return _degraded
    }

    /// Record that interruption detection is unavailable (tap creation failed).
    public func markDegraded() {
        lock.lock(); defer { lock.unlock() }
        _degraded = true
    }

    /// Feed one observed event. `isOurs` is true for events carrying our tag (never an
    /// interruption). An untagged event during an armed window sets the interrupted flag —
    /// **immediately** for keyboard/button/scroll/flag-change input. The only suppression is
    /// a narrow one: an untagged `.mouseMoved` within `debounce` of our own last synthetic
    /// event is treated as a cursor-warp echo and ignored.
    public func observe(isOurs: Bool, type: CGEventType, at: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if isOurs {
            lastOurEventAt = at
            return
        }
        guard armedCount > 0 else { return }
        // Scope the time-based echo guard to mouse MOVES only, so it can never suppress a
        // genuine keyDown/flagsChanged/mouseDown/scroll — the events that must always cancel.
        if type == .mouseMoved, at - lastOurEventAt < debounce { return }
        interrupted = true
    }

    /// Convenience overload defaulting to a keyboard event (never echo-suppressed). Used by
    /// the pure-state unit tests and any caller that only distinguishes ours vs. genuine.
    public func observe(isOurs: Bool, at: TimeInterval) {
        observe(isOurs: isOurs, type: .keyDown, at: at)
    }

    /// Reset for reuse (tests).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        armedCount = 0
        interrupted = false
        lastOurEventAt = -.greatestFiniteMagnitude
    }
}

// MARK: - Live tap (impure; never unit-tested)

/// Owns a passive CGEvent tap on a dedicated runloop thread and feeds an
/// `InterruptionState`. Degrades gracefully (logged warning + `state.markDegraded()`) if
/// the tap cannot be created. Public Apple APIs only.
public final class UserInterruptionMonitor: InterruptionMonitoring, @unchecked Sendable {
    /// The pure state this monitor feeds and forwards to.
    public let state: InterruptionState

    private let lock = NSLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var stopped = false
    private let ready = DispatchSemaphore(value: 0)

    public init(state: InterruptionState = InterruptionState()) {
        self.state = state
    }

    // Forward the seam to the pure state.
    public func arm() { state.arm() }
    public func disarm() { state.disarm() }
    public var isInterrupted: Bool { state.isInterrupted }
    public var degraded: Bool { state.degraded }

    /// Start the tap thread. Idempotent. Safe to call without permission — it degrades
    /// rather than failing.
    public func start() {
        lock.lock()
        if thread != nil { lock.unlock(); return }
        let t = Thread { [weak self] in self?.runThread() }
        t.name = "dev.watzon.semantouch.interruption-monitor"
        t.stackSize = 512 * 1024
        thread = t
        lock.unlock()
        t.start()
        ready.wait()
    }

    /// Stop the tap thread and release the tap.
    public func shutdown() {
        lock.lock()
        stopped = true
        let loop = runLoop
        lock.unlock()
        if let loop { CFRunLoopWakeUp(loop) }
    }

    private func runThread() {
        lock.lock()
        runLoop = CFRunLoopGetCurrent()
        lock.unlock()

        // Cover every physical key/mouse event that signals genuine user activity. Middle/side
        // buttons (`otherMouse*`) and the right/other button-up events are included so any
        // physical button press arms interruption even when the pointer never moves.
        var mask: CGEventMask = 0
        mask |= CGEventMask(1) << CGEventType.keyDown.rawValue
        mask |= CGEventMask(1) << CGEventType.keyUp.rawValue
        mask |= CGEventMask(1) << CGEventType.flagsChanged.rawValue
        mask |= CGEventMask(1) << CGEventType.leftMouseDown.rawValue
        mask |= CGEventMask(1) << CGEventType.leftMouseUp.rawValue
        mask |= CGEventMask(1) << CGEventType.leftMouseDragged.rawValue
        mask |= CGEventMask(1) << CGEventType.rightMouseDown.rawValue
        mask |= CGEventMask(1) << CGEventType.rightMouseUp.rawValue
        mask |= CGEventMask(1) << CGEventType.rightMouseDragged.rawValue
        mask |= CGEventMask(1) << CGEventType.otherMouseDown.rawValue
        mask |= CGEventMask(1) << CGEventType.otherMouseUp.rawValue
        mask |= CGEventMask(1) << CGEventType.otherMouseDragged.rawValue
        mask |= CGEventMask(1) << CGEventType.mouseMoved.rawValue
        mask |= CGEventMask(1) << CGEventType.scrollWheel.rawValue

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: interruptionTapCallback,
            userInfo: refcon
        )

        guard let created else {
            FileHandle.standardError.write(Data(
                "semantouch: CGEvent.tapCreate failed; user-interruption detection is unavailable (fallback actions will not auto-cancel on physical input).\n".utf8
            ))
            state.markDegraded()
            ready.signal()
            return
        }

        lock.lock(); tap = created; lock.unlock()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        ready.signal()

        while !isStopped {
            _ = CFRunLoopRunInMode(.defaultMode, 0.25, true)
        }

        // Teardown.
        CGEvent.tapEnable(tap: created, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Re-enable the tap after the system disables it (timeout / user input). Called from
    /// the tap callback on the monitor thread.
    fileprivate func reenable() {
        lock.lock(); let t = tap; lock.unlock()
        if let t { CGEvent.tapEnable(tap: t, enable: true) }
    }

    /// Handle one observed event (called from the tap callback).
    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable()
            return
        }
        let tag = event.getIntegerValueField(.eventSourceUserData)
        let isOurs = tag == FallbackTag.userData
        state.observe(isOurs: isOurs, type: type, at: ProcessInfo.processInfo.systemUptime)
    }
}

/// The C tap callback: forward the event to the monitor's `handle`, pass the event
/// through unchanged (listen-only).
private let interruptionTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    if let refcon {
        let monitor = Unmanaged<UserInterruptionMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
