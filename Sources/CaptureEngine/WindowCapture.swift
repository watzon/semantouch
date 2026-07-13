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

public enum WindowCapture {
    /// Capture `scWindow` at native backing resolution.
    ///
    /// The `SCStreamConfiguration` is sized to the window's backing pixels
    /// (`framePoints × scale`, via `CoordinateMapper.backingPixelSize`) with the
    /// cursor hidden; the fit-to-1568 downscale and JPEG encode happen later in
    /// `ScreenshotEncoder`. Zero-size frames are rejected up front; capture faults
    /// are classified (`minimized` / `offscreen`→minimized / `stale` / `protected`
    /// / `unsupported_surface`) into `uncapturable_window`.
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
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
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
