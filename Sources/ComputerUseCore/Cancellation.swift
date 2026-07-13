import Foundation

// Cooperative cancellation for an in-flight request (PROTOCOL v1.4 §17).
//
// The MCP server is strictly serial in *execution* (one request handler at a time),
// but its read loop runs concurrently, so a client `notifications/cancelled` for the
// in-flight request is observed while that request is still running. The server routes
// the cancellation to this token; long-running work (the get_app_state capture + tree
// build) reads the ambient token from `CancellationToken.current` and calls
// `throwIfCancelled()` at loop/await boundaries, turning a cancellation into a typed
// `CUError.cancelled`. The server additionally ties `onCancel` to `Task.cancel()` as a
// best-effort nudge; because ScreenCaptureKit does not document honoring `Task`
// cancellation, an already-started capture may run to completion, but the ambient/checkpoint
// token then turns that completed capture into `cancelled` at the next boundary rather than
// letting it surface as a partial success.

/// A one-way cancellation latch. Once `cancel(reason:)` fires, the token stays cancelled
/// and any registered `onCancel` handler runs exactly once. Safe to share across threads.
public final class CancellationToken: @unchecked Sendable {
    /// The ambient token for the operation currently executing, propagated to child async
    /// work via a task-local. `nil` when no cancellable request is in flight (e.g. the
    /// synchronous `MCPServer.process` path, or any non-request context).
    @TaskLocal public static var current: CancellationToken?

    private let lock = NSLock()
    private var cancelledFlag = false
    private var reasonValue: String?
    private var handler: (() -> Void)?

    public init() {}

    /// Whether the token has been cancelled.
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }

    /// The reason supplied to `cancel`, if any.
    public var reason: String? {
        lock.lock(); defer { lock.unlock() }
        return reasonValue
    }

    /// Latch the token cancelled and run any registered handler exactly once. A second
    /// `cancel` is a no-op (the first reason and the one-shot handler win).
    public func cancel(reason: String? = nil) {
        lock.lock()
        if cancelledFlag {
            lock.unlock()
            return
        }
        cancelledFlag = true
        reasonValue = reason
        let toRun = handler
        handler = nil
        lock.unlock()
        toRun?()
    }

    /// Register a handler fired once when the token is cancelled. If the token is already
    /// cancelled, the handler runs immediately (so registration never misses a cancel that
    /// arrived first).
    public func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelledFlag {
            lock.unlock()
            handler()
            return
        }
        self.handler = handler
        lock.unlock()
    }

    /// Throw `CUError.cancelled` when this token is cancelled; otherwise return normally.
    public func throwIfCancelled() throws {
        lock.lock()
        let cancelled = cancelledFlag
        let reason = reasonValue
        lock.unlock()
        if cancelled {
            throw CUError.cancelled(reason: reason)
        }
    }

    /// Throw `CUError.cancelled` when the ambient `current` token OR the surrounding `Task`
    /// is cancelled. Long-running code calls this at await/loop boundaries.
    public static func checkpoint() throws {
        if let token = CancellationToken.current {
            try token.throwIfCancelled()
        }
        if Task.isCancelled {
            throw CUError.cancelled(reason: nil)
        }
    }
}
