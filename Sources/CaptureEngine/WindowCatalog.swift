import Foundation
import CoreGraphics
import ScreenCaptureKit
import ComputerUseCore

// WindowCatalog — enumerate on/off-screen windows via CGWindowListCopyWindowInfo
// (scalar signals) and via SCShareableContent (capturable SCWindow handles), and
// merge them into a unified `WindowInfo` record while keeping the SCWindow lookup
// (docs/PROTOCOL.md §§10.2–10.3). Public Apple APIs only — no `_AXUIElementGetWindow`,
// no SkyLight, no CGS*.
//
// Coordinate note: `kCGWindowBounds` is a GLOBAL, TOP-LEFT-origin rect in points
// (space **G**, PROTOCOL §9), the same space AX `AXPosition`/`AXSize` report, which
// is why AX↔SCWindow frame correlation (WindowCorrelation) can compare them directly.

/// A window as the catalog sees it: the CGWindowList scalar signals unified with
/// whether a capturable `SCWindow` exists for the same WindowServer id.
///
/// This is a pure value type on purpose — it carries no `SCWindow` reference — so
/// correlation scoring (WindowCorrelation) is fully unit-testable from synthetic
/// fixtures without Screen Recording permission. The live `SCWindow` handle needed
/// for capture is kept separately in `WindowCatalogSnapshot`, keyed by
/// `windowNumber`.
public struct WindowInfo: Equatable, Sendable {
    /// WindowServer window id (`kCGWindowNumber`, == `SCWindow.windowID`).
    public var windowNumber: Int
    /// Owning process id (`kCGWindowOwnerPID`).
    public var ownerPID: Int32
    /// Global window bounds in points (G, top-left origin) from `kCGWindowBounds`.
    public var bounds: Rect
    /// Window title (`kCGWindowName`); often `nil`/empty without Screen Recording.
    public var title: String?
    /// Window layer (`kCGWindowLayer`); `0` is the normal application-window layer.
    public var layer: Int
    /// On-screen flag (`kCGWindowIsOnscreen`). A covered-but-present window is still
    /// on-screen; minimized / other-Space windows are not.
    public var isOnscreen: Bool
    /// Window alpha (`kCGWindowAlpha`), 0…1.
    public var alpha: Double
    /// Whether a capturable `SCWindow` with the same `windowNumber` was found in
    /// `SCShareableContent`. Capture (WindowCapture) requires this to be `true`.
    public var hasShareableWindow: Bool

    public init(
        windowNumber: Int,
        ownerPID: Int32,
        bounds: Rect,
        title: String? = nil,
        layer: Int = 0,
        isOnscreen: Bool = true,
        alpha: Double = 1.0,
        hasShareableWindow: Bool = false
    ) {
        self.windowNumber = windowNumber
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.title = title
        self.layer = layer
        self.isOnscreen = isOnscreen
        self.alpha = alpha
        self.hasShareableWindow = hasShareableWindow
    }

    /// A normal, visible, non-degenerate application window: layer 0, on-screen,
    /// opaque enough to matter, with positive area. Used by window-selection
    /// rule 3 ("largest normal visible window", §10.2).
    public var isNormalVisible: Bool {
        layer == 0 && isOnscreen && alpha > 0 && bounds.width > 0 && bounds.height > 0
    }

    /// Bounds area in square points (window-selection tiebreak).
    public var area: Double { max(0, bounds.width) * max(0, bounds.height) }

    /// Project to an error-payload `WindowRef` on the ScreenCaptureKit side (§6).
    /// Qualified: bare `WindowRef` collides with a Quickdraw typedef reachable
    /// through ScreenCaptureKit → ApplicationServices.
    public var screenCaptureKitRef: ComputerUseCore.WindowRef {
        ComputerUseCore.WindowRef(
            windowId: windowNumber,
            title: title,
            framePoints: bounds,
            pid: Int(ownerPID),
            source: .screencapturekit
        )
    }
}

/// A point-in-time merge of the CGWindowList catalog and the ScreenCaptureKit
/// window list. Holds the unified `WindowInfo` records plus the live `SCWindow`
/// handles (kept out of `WindowInfo` so scoring stays permission-free).
public struct WindowCatalogSnapshot {
    /// Unified records, in CGWindowList front-to-back order.
    public let windows: [WindowInfo]
    private let shareableByNumber: [Int: SCWindow]

    public init(windows: [WindowInfo], shareableByNumber: [Int: SCWindow]) {
        self.windows = windows
        self.shareableByNumber = shareableByNumber
    }

    /// All unified records owned by `pid`.
    public func windows(forPID pid: Int32) -> [WindowInfo] {
        windows.filter { $0.ownerPID == pid }
    }

    /// The unified record for a WindowServer id, if present.
    public func window(number: Int) -> WindowInfo? {
        windows.first { $0.windowNumber == number }
    }

    /// The live `SCWindow` handle for a WindowServer id — the SCWindow lookup used
    /// by WindowCapture after correlation. `nil` when the window has no capturable
    /// counterpart.
    public func shareableWindow(number: Int) -> SCWindow? {
        shareableByNumber[number]
    }

    /// Count of capturable normal windows for `pid` (feeds `AppSummary.windows`).
    public func capturableWindowCount(forPID pid: Int32) -> Int {
        windows.filter { $0.ownerPID == pid && $0.isNormalVisible && $0.hasShareableWindow }.count
    }
}

/// Enumeration entry points. A namespace: everything is `static`.
public enum WindowCatalog {
    /// Enumerate windows from `CGWindowListCopyWindowInfo`. `includeOffscreen`
    /// selects `.optionAll` (on- and off-screen) vs. `.optionOnScreenOnly`.
    /// Records come back with `hasShareableWindow == false`; `snapshot()` fills it.
    public static func cgWindows(includeOffscreen: Bool = true) -> [WindowInfo] {
        let options: CGWindowListOption = includeOffscreen ? [.optionAll] : [.optionOnScreenOnly]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { parseCGWindow($0) }
    }

    /// Enumerate capturable windows via ScreenCaptureKit. `onScreenWindowsOnly` is
    /// **false** so off-screen/covered windows are included. This is an
    /// async, permission-gated call (Screen Recording).
    public static func shareableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return content.windows
    }

    /// Enumerate both sources and merge them by WindowServer id into a unified
    /// snapshot (records + SCWindow lookup).
    public static func snapshot(includeOffscreen: Bool = true) async throws -> WindowCatalogSnapshot {
        let cg = cgWindows(includeOffscreen: includeOffscreen)
        let sc = try await shareableWindows()

        var shareableByNumber: [Int: SCWindow] = [:]
        for window in sc {
            shareableByNumber[Int(window.windowID)] = window
        }

        let unified = cg.map { info -> WindowInfo in
            var merged = info
            merged.hasShareableWindow = shareableByNumber[info.windowNumber] != nil
            return merged
        }
        return WindowCatalogSnapshot(windows: unified, shareableByNumber: shareableByNumber)
    }

    // MARK: - Pure parsing seam (unit-testable without permissions)

    /// Parse one `CGWindowListCopyWindowInfo` entry into a `WindowInfo`. Returns
    /// `nil` when the required id/pid keys are missing. Isolated as a pure function
    /// so parsing is testable with synthetic dictionaries.
    static func parseCGWindow(_ dict: [String: Any]) -> WindowInfo? {
        guard
            let number = (dict[kCGWindowNumber as String] as? NSNumber)?.intValue,
            let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        else {
            return nil
        }

        let bounds: Rect
        if
            let boundsAny = dict[kCGWindowBounds as String],
            let boundsDict = boundsAny as? NSDictionary,
            let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        {
            bounds = Rect(cgBounds)
        } else {
            bounds = Rect(x: 0, y: 0, width: 0, height: 0)
        }

        let title = dict[kCGWindowName as String] as? String
        let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let isOnscreen = (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        let alpha = (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0

        return WindowInfo(
            windowNumber: number,
            ownerPID: pid,
            bounds: bounds,
            title: title,
            layer: layer,
            isOnscreen: isOnscreen,
            alpha: alpha,
            hasShareableWindow: false
        )
    }
}
