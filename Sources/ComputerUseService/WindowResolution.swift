import Foundation
import ApplicationServices
import CoreGraphics
import ComputerUseCore
import AccessibilityEngine
import CaptureEngine

/// Selects the target window for `get_app_state` and correlates it to its
/// WindowServer id using **public signals only** (§10.2–10.3).
///
/// The Accessibility side supplies candidate windows (`AXWindows`, `AXFocusedWindow`,
/// `AXMainWindow`) with global-point frames; the `CGWindowListCopyWindowInfo`
/// catalog (permission-free) supplies the WindowServer ids. Correlation reuses the
/// tested `WindowCorrelation` engine. Every ambiguous or unmatchable case returns a
/// typed error rather than guessing.
enum WindowResolution {
    /// The chosen window: its live AX element, global-point frame, resolved title,
    /// WindowServer id, and correlation confidence.
    struct Selection {
        let axWindow: AXUIElement
        let frameGlobal: Rect
        let title: String?
        let windowNumber: Int
        let confidence: CorrelationConfidence
    }

    /// The window selection plus the best-effort `AppState.windows` enumeration (§18.3),
    /// gathered from the same single `AXWindows` read — no second AX pass. `windows` is nil
    /// when the app exposes no AX windows at all.
    struct Resolution {
        let selection: Selection
        let windows: [AppState.WindowSummary]?
    }

    /// One AX window candidate.
    private struct AXWindowCandidate {
        let element: AXUIElement
        let frame: Rect
        let title: String?
        let subrole: String?
        var isStandard: Bool { subrole == nil || subrole == "AXStandardWindow" }
        var area: Double { max(0, frame.width) * max(0, frame.height) }
    }

    /// Resolve the target window.
    ///
    /// - Parameters:
    ///   - appElement: the application AX element (`AXUIElementCreateApplication`).
    ///   - pid: the owning process id.
    ///   - app: the caller's `app` query, echoed into error payloads.
    ///   - explicitWindowId: an explicit WindowServer id (§10.2 rule 1), if given.
    ///   - client: the AX extraction client.
    static func resolve(
        appElement: AXUIElement,
        pid: Int32,
        app: String,
        explicitWindowId: Int?,
        client: AXClient
    ) throws -> Resolution {
        let axWindows = gatherAXWindows(appElement: appElement, client: client)
        let cgWindows = WindowCatalog.cgWindows(includeOffscreen: true).filter { $0.ownerPID == pid }

        let selection: Selection
        if let explicitWindowId {
            selection = try resolveExplicit(
                windowId: explicitWindowId,
                app: app,
                axWindows: axWindows,
                cgWindows: cgWindows
            )
        } else {
            // Rules 2–4: choose an AX window, then correlate it for the WindowServer id.
            guard !axWindows.isEmpty else {
                throw CUError.windowNotFound(app: app, windowId: nil)
            }

            let chosen = try chooseAXWindow(
                app: app,
                appElement: appElement,
                axWindows: axWindows,
                cgWindows: cgWindows,
                client: client
            )

            let descriptor = AXWindowDescriptor(pid: pid, frame: chosen.frame, title: chosen.title)
            switch WindowCorrelation.correlate(ax: descriptor, candidates: cgWindows, app: app) {
            case let .success(match):
                selection = Selection(
                    axWindow: chosen.element,
                    frameGlobal: chosen.frame,
                    title: chosen.title,
                    windowNumber: match.window.windowNumber,
                    confidence: match.confidence
                )
            case let .failure(error):
                throw error
            }
        }

        // §18.3: enumerate every AX window from the same read, correlating each to a
        // WindowServer id. The selected window always appears (with its resolved id).
        let windows = enumerateWindows(
            appElement: appElement,
            axWindows: axWindows,
            cgWindows: cgWindows,
            selected: selection,
            client: client
        )
        return Resolution(selection: selection, windows: windows)
    }

    // MARK: - Window enumeration (§18.3)

    /// Build the best-effort `AppState.windows` list from the already-gathered candidates.
    /// Each entry: WindowServer `id` (frame/title correlation, nil when not uniquely
    /// matchable), `focused`/`main` by CFEqual to `AXFocusedWindow`/`AXMainWindow`, and
    /// `onScreen` when the frame correlates to a normal, visible CG window. Nil when the app
    /// exposes no AX windows (total failure omits the array).
    private static func enumerateWindows(
        appElement: AXUIElement,
        axWindows: [AXWindowCandidate],
        cgWindows: [WindowInfo],
        selected: Selection,
        client: AXClient
    ) -> [AppState.WindowSummary]? {
        guard !axWindows.isEmpty else { return nil }
        let focused = client.focusedWindow(of: appElement)
        let main = client.mainWindow(of: appElement)
        let tolerance = WindowCorrelation.defaultFrameTolerance
        return axWindows.map { candidate in
            // The selected window keeps the id the robust correlation engine resolved.
            let id: Int? = CFEqual(candidate.element, selected.axWindow)
                ? selected.windowNumber
                : correlateWindowNumber(candidate, cgWindows: cgWindows, tolerance: tolerance)
            let onScreen = cgWindows.contains {
                $0.isNormalVisible && WindowCorrelation.framesEqual(candidate.frame, $0.bounds, tolerance: tolerance)
            }
            return AppState.WindowSummary(
                id: id,
                title: candidate.title,
                framePoints: candidate.frame,
                focused: focused.map { CFEqual($0, candidate.element) } ?? false,
                main: main.map { CFEqual($0, candidate.element) } ?? false,
                onScreen: onScreen
            )
        }
    }

    /// Best-effort WindowServer id for an AX window: the unique CG window matching its frame,
    /// disambiguated by title when several share the frame. Nil when no unique match exists
    /// (an entry without an id is not re-targetable via `windowId`, §18.3).
    private static func correlateWindowNumber(
        _ candidate: AXWindowCandidate,
        cgWindows: [WindowInfo],
        tolerance: Double
    ) -> Int? {
        let frameMatches = cgWindows.filter {
            WindowCorrelation.framesEqual(candidate.frame, $0.bounds, tolerance: tolerance)
        }
        if frameMatches.count == 1 { return frameMatches[0].windowNumber }
        if frameMatches.count > 1, let title = normalized(candidate.title) {
            let titled = frameMatches.filter { normalized($0.title) == title }
            if titled.count == 1 { return titled[0].windowNumber }
        }
        return nil
    }

    // MARK: - Explicit window id (rule 1)

    private static func resolveExplicit(
        windowId: Int,
        app: String,
        axWindows: [AXWindowCandidate],
        cgWindows: [WindowInfo]
    ) throws -> Selection {
        // Must be one of the app's windows.
        guard let cgRecord = cgWindows.first(where: { $0.windowNumber == windowId }) else {
            throw CUError.windowNotFound(app: app, windowId: windowId)
        }

        // Correlate to exactly one AX window by frame (public signal).
        let tolerance = WindowCorrelation.defaultFrameTolerance
        let frameMatches = axWindows.filter {
            WindowCorrelation.framesEqual($0.frame, cgRecord.bounds, tolerance: tolerance)
        }

        switch frameMatches.count {
        case 1:
            let chosen = frameMatches[0]
            return Selection(
                axWindow: chosen.element,
                frameGlobal: chosen.frame,
                title: chosen.title,
                windowNumber: windowId,
                confidence: .high
            )
        case 0:
            throw CUError.uncorrelatedWindow(
                app: app,
                ax: nil,
                sc: cgRecord.screenCaptureKitRef,
                signalsTried: [CorrelationSignal.pid, CorrelationSignal.frame]
            )
        default:
            // Several AX windows share the frame: title must single one out.
            if let cgTitle = normalized(cgRecord.title) {
                let titled = frameMatches.filter { normalized($0.title) == cgTitle }
                if titled.count == 1 {
                    let chosen = titled[0]
                    return Selection(
                        axWindow: chosen.element,
                        frameGlobal: chosen.frame,
                        title: chosen.title,
                        windowNumber: windowId,
                        confidence: .medium
                    )
                }
            }
            throw CUError.ambiguousWindow(
                app: app,
                candidates: frameMatches.map {
                    ComputerUseCore.WindowRef(
                        windowId: nil, title: $0.title, framePoints: $0.frame,
                        pid: Int(cgRecord.ownerPID), source: .ax
                    )
                }
            )
        }
    }

    // MARK: - AX window selection (rules 2–4)

    private static func chooseAXWindow(
        app: String,
        appElement: AXUIElement,
        axWindows: [AXWindowCandidate],
        cgWindows: [WindowInfo],
        client: AXClient
    ) throws -> AXWindowCandidate {
        // Rule 2: AX focused window, else AX main window.
        if let focused = client.focusedWindow(of: appElement),
           let match = axWindows.first(where: { CFEqual($0.element, focused) }) {
            return match
        }
        if let main = client.mainWindow(of: appElement),
           let match = axWindows.first(where: { CFEqual($0.element, main) }) {
            return match
        }

        let tolerance = WindowCorrelation.defaultFrameTolerance

        // AX exposes no on-screen/minimized state, so the CG catalog supplies it: an
        // AX candidate is "on-screen, not minimized" (§10.2 rule 3) only when it
        // correlates by frame to a normal, visible (layer 0, on-screen, opaque) CG
        // window. A minimized window still lists in AXWindows with its pre-minimize
        // frame, so without this it could win the area sort and then fail at capture.
        func onScreenCGWindow(for candidate: AXWindowCandidate) -> WindowInfo? {
            cgWindows.first {
                $0.isNormalVisible
                    && WindowCorrelation.framesEqual(candidate.frame, $0.bounds, tolerance: tolerance)
            }
        }

        // Rule 3: largest normal *visible* window; ties with no tiebreak → ambiguous.
        let standard = axWindows
            .filter { $0.isStandard && $0.area > 0 && onScreenCGWindow(for: $0) != nil }
            .sorted { $0.area > $1.area }
        if let largest = standard.first {
            if standard.count > 1, standard[1].area == largest.area {
                throw CUError.ambiguousWindow(
                    app: app,
                    candidates: standard.filter { $0.area == largest.area }.map {
                        ComputerUseCore.WindowRef(
                            windowId: onScreenCGWindow(for: $0)?.windowNumber,
                            title: $0.title, framePoints: $0.frame,
                            pid: nil, source: .ax
                        )
                    }
                )
            }
            return largest
        }

        // Rule 4: most recently active capturable window, taken from the CG catalog's
        // front-to-back on-screen ordering (the permission-free proxy for
        // SCShareableContent on-screen ordering, §10.2). Walk front to back; the first
        // on-screen normal CG window that correlates to exactly one AX window wins.
        // If a front window correlates to several AX windows that title cannot
        // separate, that is a genuine ambiguity of equally-front candidates →
        // `ambiguous_window`. Never pick by AX-array order.
        for cg in cgWindows where cg.isNormalVisible {
            let frameMatches = axWindows.filter {
                WindowCorrelation.framesEqual($0.frame, cg.bounds, tolerance: tolerance)
            }
            switch frameMatches.count {
            case 0:
                continue
            case 1:
                return frameMatches[0]
            default:
                if let cgTitle = normalized(cg.title) {
                    let titled = frameMatches.filter { normalized($0.title) == cgTitle }
                    if titled.count == 1 { return titled[0] }
                }
                throw CUError.ambiguousWindow(
                    app: app,
                    candidates: frameMatches.map {
                        ComputerUseCore.WindowRef(
                            windowId: cg.windowNumber, title: $0.title,
                            framePoints: $0.frame, pid: Int(cg.ownerPID), source: .ax
                        )
                    }
                )
            }
        }

        // Rule 5: no safe deterministic choice exists.
        throw CUError.windowNotFound(app: app, windowId: nil)
    }

    // MARK: - AX gathering

    private static func gatherAXWindows(appElement: AXUIElement, client: AXClient) -> [AXWindowCandidate] {
        client.windows(of: appElement).compactMap { element in
            guard let cg = client.frame(of: element) else { return nil }
            return AXWindowCandidate(
                element: element,
                frame: Rect(cg),
                title: nonEmpty(client.copyString(element, "AXTitle")),
                subrole: client.subrole(of: element)
            )
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private static func normalized(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
