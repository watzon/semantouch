import Foundation
import CoreGraphics
import ScreenCaptureKit
import ComputerUseCore

// WindowCapture — capture ONE window's pixels via ScreenCaptureKit's
// desktop-independent single-window filter (docs/PROTOCOL.md §8). This is the
// covered-window guarantee: `SCContentFilter(desktopIndependentWindow:)` renders
// the target alone, so a window behind another window still yields clean,
// target-only pixels. It NEVER falls back to display capture and cropping —
// availability failures surface as typed `uncapturable_window` errors (§6).
// Capture is bounded by a 5 s deadline (M1); expiry is a typed `timeout`, never
// reclassified as uncapturable, so state/action paths can degrade to tree +
// warning while screenshot-only surfaces the timeout.

public enum WindowCapture {
    /// Bound on `SCScreenshotManager.captureImage` (milliseconds).
    static let captureDeadlineMs = 5_000
    /// Wire `timeout.operation` for a window capture deadline.
    static let captureOperation = "capture_window"

    /// Capture `scWindow` at native backing resolution.
    ///
    /// The `SCStreamConfiguration` is sized to the window's backing pixels
    /// (`framePoints × scale`, via `CoordinateMapper.backingPixelSize`) with the
    /// cursor hidden; the fit-to-1568 downscale and JPEG encode happen later in
    /// `ScreenshotEncoder`. Zero-size frames are rejected up front; capture faults
    /// are classified (`minimized` / `offscreen`→minimized / `stale` / `protected`
    /// / `unsupported_surface`) into `uncapturable_window`. A 5 s deadline wraps
    /// the ScreenCaptureKit call; expiry throws `timeout` (not uncapturable), and
    /// caller cancellation remains cancellation.
    ///
    /// - Parameters:
    ///   - scWindow: the correlated live `SCWindow` (from `WindowCatalogSnapshot`).
    ///   - framePoints: the window frame in global points (G).
    ///   - scale: the display backing scale (points → backing pixels).
    ///   - app: caller's app query, echoed into error payloads.
    ///   - windowNumber: WindowServer id, echoed into error payloads.
    /// - Returns: the captured `CGImage` at backing resolution.
    public static func captureImage(
        scWindow: SCWindow,
        framePoints: Rect,
        scale: Double,
        app: String,
        windowNumber: Int
    ) async throws -> CGImage {
        // Reject degenerate geometry before touching ScreenCaptureKit.
        let zeroSize = framePoints.width <= 0 || framePoints.height <= 0
        if zeroSize {
            throw CUError.uncapturableWindow(app: app, windowId: windowNumber, reason: .unsupportedSurface)
        }

        let pixelSize = CoordinateMapper.backingPixelSize(framePoints: framePoints, scale: scale)
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            throw CUError.uncapturableWindow(app: app, windowId: windowNumber, reason: .unsupportedSurface)
        }

        let configuration = SCStreamConfiguration()
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        configuration.showsCursor = false

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)

        do {
            // Bound the SCK call. Timeout and cancellation must NOT fall into the
            // uncapturable classifier below — only genuine capture faults do.
            return try await withDeadline(
                deadlineMs: captureDeadlineMs,
                operation: captureOperation
            ) {
                try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CUError {
            // Typed timeout (or any other CUError) propagates unchanged.
            throw error
        } catch {
            // Classify without ever falling back to a display screenshot. A fresh
            // shareable-content query tells us whether the window vanished.
            let stillPresent = (try? await windowStillPresent(windowNumber)) ?? true
            let reason = classifyUncapturable(
                frameIsZeroSize: false,
                stillPresent: stillPresent,
                isOnscreen: scWindow.isOnScreen,
                isScreenCaptureKitError: error is SCStreamError
            )
            throw CUError.uncapturableWindow(app: app, windowId: windowNumber, reason: reason)
        }
    }

    // MARK: - Helpers

    /// One child's result in the deadline race. Children never throw into the
    /// group: cancellation and failure are values, so a cancelled loser cannot
    /// overwrite the winner when the group drains.
    private enum DeadlineOutcome<T> {
        case value(T)
        case error(Error)
        case timeout
        case cancelled
    }

    /// Race `work` against a wall-clock deadline using structured concurrency
    /// (no detached tasks). The first decisive finisher wins; the loser is cancelled.
    ///
    /// - On success before the deadline: returns `work`'s value and cancels the
    ///   timer child (no second completion).
    /// - On deadline: throws `CUError.timeout(operation:deadlineMs:)` with the
    ///   supplied payload.
    /// - On parent/caller cancellation: surfaces `CancellationError`. Cancellation
    ///   always wins over a not-yet-fired deadline because the timer never reaches
    ///   its timeout outcome once cancelled.
    ///
    /// Internal and generic so permission-free unit tests can inject async
    /// operations without touching ScreenCaptureKit.
    static func withDeadline<T>(
        deadlineMs: Int,
        operation: String,
        work: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: DeadlineOutcome<T>.self) { group in
            group.addTask {
                do {
                    return .value(try await work())
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .error(error)
                }
            }
            group.addTask {
                // Task.sleep is cancellation-aware: a parent cancel turns this into
                // `.cancelled` rather than a timeout, so cancel beats deadline.
                do {
                    let nanos = UInt64(max(deadlineMs, 0)) * 1_000_000
                    try await Task.sleep(nanoseconds: nanos)
                    return .timeout
                } catch {
                    return .cancelled
                }
            }

            // First decisive outcome wins. `.cancelled` is the non-decisive
            // sibling finishing after cancelAll (or a parent cancel) — keep
            // waiting for the other child unless the group is empty. A parent
            // cancel always wins over value/timeout/error so a late SCK success
            // cannot mask cancellation.
            while let outcome = try await group.next() {
                try Task.checkCancellation()
                switch outcome {
                case .value(let value):
                    group.cancelAll()
                    try Task.checkCancellation()
                    return value
                case .timeout:
                    group.cancelAll()
                    try Task.checkCancellation()
                    throw CUError.timeout(operation: operation, deadlineMs: deadlineMs)
                case .error(let error):
                    group.cancelAll()
                    try Task.checkCancellation()
                    throw error
                case .cancelled:
                    continue
                }
            }

            // Both children finished as cancelled → parent/caller cancellation.
            try Task.checkCancellation()
            throw CancellationError()
        }
    }

    /// Whether a WindowServer id is still present in a fresh shareable-content list.
    static func windowStillPresent(_ windowNumber: Int) async throws -> Bool {
        let windows = try await WindowCatalog.shareableWindows()
        return windows.contains { Int($0.windowID) == windowNumber }
    }

    /// Map a capture fault to an `uncapturable_window` reason (§6). Pure and
    /// unit-testable; the live call site supplies the four inputs.
    ///
    /// Order matters: a degenerate frame is an unsupported surface; a vanished
    /// window is stale; a present-but-not-on-screen window is minimized (or on
    /// another Space — indistinguishable via public API, reported as `minimized`);
    /// a present, on-screen window that ScreenCaptureKit refuses is treated as
    /// protected content; anything else is an unsupported surface.
    static func classifyUncapturable(
        frameIsZeroSize: Bool,
        stillPresent: Bool,
        isOnscreen: Bool,
        isScreenCaptureKitError: Bool
    ) -> UncapturableReason {
        if frameIsZeroSize { return .unsupportedSurface }
        if !stillPresent { return .stale }
        if !isOnscreen { return .minimized }
        if isScreenCaptureKitError { return .protected }
        return .unsupportedSurface
    }
}
