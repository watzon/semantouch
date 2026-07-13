import Foundation
import ComputerUseCore

// CaptureEngine — window enumeration, AX↔SCWindow correlation, and capture.
//
// Implemented across the sibling files in this module:
//   - WindowCatalog:      SCShareableContent / CGWindowList enumeration + unified
//                         `WindowInfo`, keeping the SCWindow lookup (public signals).
//   - WindowCorrelation:  match an AX window to its SCWindow by pid/frame/title/
//                         layer/on-screen (§10.3); zero-wrong-match, signal log.
//   - WindowCapture:      SCContentFilter(desktopIndependentWindow:) +
//                         SCScreenshotManager; typed `uncapturable_window`, never
//                         falls back to display capture.
//   - CoordinateMapper:   G/W/S conversions (§9), kx/ky from delivered pixels.
//   - ScreenshotEncoder:  JPEG q0.75, long-edge 1568, 3 MB cap (§8); PNG for probes.
//
// This file holds only the shared screenshot-policy constants (§8), referenced by
// the encoder and by dependent modules.

/// Namespace + constants for the capture engine.
public enum CaptureEngine {
    /// Screenshot encoding policy (§8).
    public static let jpegQuality = 0.75
    public static let maxLongEdgePixels = 1568
    public static let maxEncodedBytes = 3 * 1024 * 1024

    /// MIME type used on the MCP path (always JPEG, §8).
    public static let mcpMimeType = "image/jpeg"
}
