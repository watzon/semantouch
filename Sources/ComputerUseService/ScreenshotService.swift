import Foundation
import ApplicationServices
import CoreGraphics
import ComputerUseCore
import AccessibilityEngine
import CaptureEngine
import ActionEngine

/// The `screenshot` pipeline (§18.9): resolve app + window, capture the single resolved window
/// as a JPEG, and assemble the `ScreenshotResult` — WITHOUT building an accessibility tree,
/// waiting to settle, advancing the revision, or minting/retiring element ids.
///
/// A cheap "just look" primitive: `get_app_state` couples pixels to a full snapshot (settle
/// wait, tree walk, revision advance, id retirement), which is the wrong cost when the caller
/// only needs to see the window. This tool changes nothing else — the current snapshot's ids
/// remain valid across any number of `screenshot` calls (§18.9).
///
/// Processing order (§18.9): read-side app policy gate (§13.5) → app resolution (§10.1) →
/// Accessibility preflight (window resolution reads AX) → window resolution (§10.2–10.3) →
/// Screen Recording gate → capture (§8) → assemble. Unlike `get_app_state`'s §8 soft
/// degradation, a missing Screen Recording grant is a HARD `permission_denied` here — the image
/// is the product. Cancellation is cooperative per §17.
public struct ScreenshotService {
    /// The assembled result plus the base64 JPEG for the §5 image block. Unlike
    /// `get_app_state`'s optional screenshot, the image is always present on success here.
    public struct Output: Sendable {
        public let result: ScreenshotResult
        public let imageBase64: String
    }

    let context: ServiceContext
    let resolver: AppResolver

    public init(context: ServiceContext, resolver: AppResolver = .system()) {
        self.context = context
        self.resolver = resolver
    }

    /// Run the pipeline for a decoded request. Throws a typed `CUError` (§6).
    public func capture(_ request: ScreenshotRequest) async throws -> Output {
        // Boundary trace: screenshot total, → capture
        // complete, plus the encoded JPEG byte size. Off unless SEMANTOUCH_TRACE=1.
        let trace = Tracer.shared.span("screenshot")
        defer { trace?.end() }

        // Cancellation checkpoint (§17): a client `notifications/cancelled` (or process
        // shutdown) cancels the ambient token; bail before doing any work.
        try CancellationToken.checkpoint()

        // 1. Resolve the application (§10.1), then apply the read-side app denylist (§13.5) —
        //    the same resolve→policy pattern get_app_state uses. Read and mutation tools share
        //    the operator-configured denylist.
        let record: AppRecord
        switch resolver.resolve(request.app) {
        case let .success(resolved): record = resolved
        case let .failure(error): throw error
        }
        if let reason = context.policyEngine.readDenialReason(
            bundleId: record.bundleId,
            displayName: record.displayName,
            path: record.path
        ) {
            throw CUError.policyDenied(reason: reason, app: request.app, tool: "screenshot")
        }

        guard let pid = record.pid else {
            // Installed but not running exposes no window to capture.
            throw CUError.windowNotFound(app: request.app, windowId: nil)
        }

        // 2. Preflight Accessibility so a missing grant is a clean error (window resolution
        //    reads AX). Same error as get_app_state (§10.1, §13.5).
        guard AXIsProcessTrusted() else {
            let path = DoctorService.helperPath()
            throw CUError.permissionDenied(
                permission: .accessibility,
                helperPath: path,
                remediation: [
                    "Grant Accessibility: open System Settings › Privacy & Security › Accessibility and enable \"\(path)\".",
                    "Restart \"\(path)\" so the new grant takes effect.",
                ]
            )
        }

        // 3. Session (lazy, §3): create one if absent, exactly as get_app_state would — but the
        //    revision, element table, diff base, lineage, settle, and web-AX enablement are ALL
        //    left untouched (§18.9). A session's current ids stay valid across screenshot calls.
        let appId = record.toSummary().id
        let session = context.sessionManager.ensureSession(appId: appId, pid: pid)
        let client = context.axClient
        let appElement = client.applicationElement(pid: pid)

        // Cancellation checkpoint (§17) before the (fallible) window resolution.
        try CancellationToken.checkpoint()

        // 4. Window selection + correlation (§10.2–10.3). Only `.selection` is needed here (no
        //    tree, so no window enumeration is surfaced).
        let resolution = try WindowResolution.resolve(
            appElement: appElement,
            pid: pid,
            app: request.app,
            explicitWindowId: request.windowId,
            client: client
        )
        let selection = resolution.selection

        var warnings: [StateWarning] = []
        // A low-confidence AX↔window correlation: the same advisory get_app_state appends.
        if selection.confidence == .low {
            warnings.append(StateWarning(
                .lowCorrelationConfidence,
                message: "AX↔window correlation relied on weak signals; the captured window may not be the intended one."
            ))
        }

        // 5. Screen Recording gate (§18.9). Unlike get_app_state's §8 soft degradation, a missing
        //    grant is a HARD permission_denied — the image is the product. Mirrors the
        //    Accessibility remediation but for Screen Recording.
        guard CGPreflightScreenCaptureAccess() else {
            let path = DoctorService.helperPath()
            throw CUError.permissionDenied(
                permission: .screenRecording,
                helperPath: path,
                remediation: [
                    "Grant Screen Recording: open System Settings › Privacy & Security › Screen Recording and enable \"\(path)\".",
                    "Restart \"\(path)\" so the new grant takes effect.",
                ]
            )
        }

        // 6. Capture the single resolved window as JPEG (§8), reusing the exact SCK + encoder
        //    pipeline get_app_state uses. Cancellation-cooperative (§17): checkpoint before, and
        //    map a mid-capture cancel to the typed `cancelled` error (never a partial success).
        let scale = AppStateBuilder.backingScale(forGlobalRect: selection.frameGlobal)
        try CancellationToken.checkpoint()
        let shot: AppStateBuilder.CaptureResult
        do {
            shot = try await AppStateBuilder.capture(
                windowNumber: selection.windowNumber,
                frameGlobal: selection.frameGlobal,
                scale: scale,
                app: request.app
            )
        } catch {
            // A cancellation mid-capture (the async SCK call is torn down by Task.cancel, or the
            // ambient token fired) must surface as the typed `cancelled`, not the raw capture
            // fault (§17). A genuine capture fault (e.g. uncapturable_window) propagates as-is.
            if let cancelled = AppStateBuilder.cancellationError(error) { throw cancelled }
            throw error
        }
        trace?.mark("capture")

        // Post-capture cancellation checkpoint (§17.2): SCScreenshotManager.captureImage honors
        // neither Task cancellation nor Task.isCancelled, so a cancel that lands while a valid
        // image is assembled would otherwise return a spuriously-successful screenshot. This
        // checkpoint turns that into `cancelled`.
        try CancellationToken.checkpoint()

        // 7. Coordinate-mapping geometry (§16.5): refresh the session's stored window frame,
        //    screenshotPixels, and scale so `space: "screenshot"` coordinates always refer to the
        //    most recently delivered image regardless of which tool delivered it (§18.9).
        context.storeWindowGeometry(
            WindowGeometry(
                windowId: selection.windowNumber,
                framePoints: selection.frameGlobal,
                screenshotPixels: shot.pixels,
                scale: scale
            ),
            forSession: session.sessionId
        )

        // 8. Assemble. `window.screenshotPixels`/`scale` are always present here; `document` is
        //    never populated (no tree walk). The revision, element table, diff base, and lineage
        //    remain untouched (§18.9).
        let window = AppState.WindowInfo(
            id: selection.windowNumber,
            title: selection.title,
            framePoints: selection.frameGlobal,
            screenshotPixels: shot.pixels,
            scale: scale
        )
        let result = ScreenshotResult(
            sessionId: session.sessionId,
            window: window,
            screenshot: shot.meta,
            warnings: warnings
        )
        trace?.count("screenshot_bytes", shot.meta.byteLength)
        return Output(result: result, imageBase64: shot.base64)
    }
}
