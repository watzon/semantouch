import Foundation
import ApplicationServices
import CoreGraphics
import ComputerUseCore
import AccessibilityEngine
import CaptureEngine
import ActionEngine

/// The full `get_app_state` pipeline (§4.1): resolve app+window, build and render
/// the accessibility tree, optionally capture a single-window screenshot, and
/// assemble the `AppState` payload.
///
/// Read-only. It preflights the Accessibility grant (a missing grant is a clean
/// `permission_denied`, never an ambiguous AX fault) and never triggers a Screen
/// Recording prompt: capture is attempted only when the grant is already present.
public struct AppStateBuilder {
    /// The assembled state plus the base64 JPEG for the MCP image block (when a
    /// screenshot was delivered). `imageBase64 == nil` ⇒ no image block.
    public struct Output: Sendable {
        public let state: AppState
        public let imageBase64: String?
    }

    let context: ServiceContext
    let resolver: AppResolver

    public init(context: ServiceContext, resolver: AppResolver = .system()) {
        self.context = context
        self.resolver = resolver
    }

    /// Run the pipeline for a decoded request. Throws a typed `CUError` (§6).
    public func build(_ request: GetAppStateRequest) async throws -> Output {
        // Boundary trace: get_app_state total, → AX tree
        // complete, → screenshot complete, plus node/byte counts. Off unless SEMANTOUCH_TRACE=1;
        // `end()` runs even on an early throw so a cancelled/failed build still records total.
        let trace = Tracer.shared.span("get_app_state")
        defer { trace?.end() }

        // Cancellation checkpoint (§17): a client `notifications/cancelled` (or process
        // shutdown) cancels the ambient token; bail before doing any work.
        try CancellationToken.checkpoint()

        // 1. Resolve the application (§10.1).
        let record: AppRecord
        switch resolver.resolve(request.app) {
        case let .success(resolved): record = resolved
        case let .failure(error): throw error
        }
        // Read and mutation tools share the operator-configured app denylist.
        if let reason = context.policyEngine.readDenialReason(
            bundleId: record.bundleId,
            displayName: record.displayName,
            path: record.path
        ) {
            throw CUError.policyDenied(reason: reason, app: request.app, tool: "get_app_state")
        }

        guard let pid = record.pid else {
            // Installed but not running exposes no window to observe.
            throw CUError.windowNotFound(app: request.app, windowId: nil)
        }

        // 2. Preflight Accessibility so a missing grant is a clean error.
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

        // 3. Session (lazy, §3). Phase 2 (§13.1): the first snapshot of a new session
        //    reports revision 1; every subsequent snapshot of that session advances
        //    the revision (2, 3, …), which retires the prior snapshot's element ids.
        //    Both session-visible mutations — the revision bump and the element-table
        //    swap — are COMMITTED only after the final post-capture cancellation
        //    checkpoint (§17.2) passes: the bump is deferred and the element table is
        //    checkpointed/rolled-back, so a get_app_state that throws anywhere (the
        //    fallible window-resolution path, or a cancel caught at/after capture) leaves
        //    BOTH the revision counter and the element table untouched (§13.1).
        let appId = record.toSummary().id
        let sessionExisted = context.sessionManager.session(forAppId: appId) != nil
        let session = context.sessionManager.ensureSession(appId: appId, pid: pid)
        // §18.2: an unhonorable `scopeElementId` DEGRADES to a full unscoped snapshot with a
        // `scope_ignored` warning — it never errors. Live OMP finding (two rounds): an agent
        // fed `stale_revision`/`stale_element` for a premature scoped request looped on the
        // error indefinitely (the message's "refresh with get_app_state" is exactly what it
        // believed it was doing, and in-schema descriptions demonstrably went unread), while
        // a successful full snapshot with fresh ids self-corrects on the next call. The
        // no-session case short-circuits here; resolve failures against a live table degrade
        // identically below.
        var scopeIgnoredReason: String?
        if request.scopeElementId != nil, !sessionExisted {
            scopeIgnoredReason = "this session has no prior snapshot to scope into"
        }
        let table = context.elementTable(forSession: session.sessionId)
        let client = context.axClient
        let appElement = client.applicationElement(pid: pid)

        // §18.1: Web-content accessibility enablement. AFTER the Accessibility preflight and
        // BEFORE window resolution, best-effort announce as an assistive client so Chromium/
        // Electron apps expose their web-content AX subtree. Once per session (re-attempted on
        // the next snapshot if a write faulted); the operator disables it with
        // `SEMANTOUCH_WEB_AX=off`. Only attributes THIS server flips are recorded (for reset on
        // end_app_session/shutdown, never a pre-existing `true`). Failures log to stderr only —
        // MCP stdout is protocol-only (§1).
        var webContentJustEnabled = false
        if context.webAXEnabled, !context.webAXEnablementAttempted(forSession: session.sessionId) {
            let seam = LiveWebAXAppElement(element: appElement, client: client)
            let result = WebContentAccessibility.enable(seam)
            if result.didEnableAny {
                context.recordWebAXFlipped(result.newlyEnabled, pid: pid, forSession: session.sessionId)
                webContentJustEnabled = true
            }
            if result.faulted {
                Self.logStderr("semantouch: web-content AX enable faulted for pid \(pid); will retry next snapshot")
            } else {
                context.markWebAXEnablementAttempted(forSession: session.sessionId)
            }
        }

        // Phase 3 (§15.3): attach an AX observer on first use (idempotent; degrades to
        // always-dirty on failure), then, when the session is dirty from a prior
        // mutation or observed activity, wait — bounded — for the UI to settle before
        // walking the tree. The first snapshot of a new session never waits — except when
        // web content was just enabled (§18.1): the target builds the web tree
        // asynchronously, so this snapshot settles with the loading deadline regardless.
        context.observerCoordinator.observe(pid: pid)
        let activity = context.observerCoordinator.state.snapshot(pid: pid)
        // A degraded observer (registration failed → always-dirty) is the §15.1 "observer
        // gap": incremental correlation cannot be trusted, so flag the session's lineage
        // broken. The next diff decision below then returns a full tree with `diff_reset`
        // instead of an ordinary diff. Only fires for an already-existing session (a first
        // snapshot is full anyway) and never for a healthy observer (fixture path).
        if sessionExisted, activity.degraded {
            context.markLineageBroken(forSession: session.sessionId)
        }
        var settleWarning: StateWarning?
        if (sessionExisted && activity.dirty) || webContentJustEnabled {
            let outcome = Self.waitForSettle(
                context: context,
                pid: pid,
                token: CancellationToken.current,
                forceLoading: webContentJustEnabled
            )
            if outcome == .possiblyUnsettled {
                settleWarning = StateWarning(
                    .possiblyUnsettled,
                    message: "The UI was still changing when the settle deadline expired; the returned state may not be final."
                )
            }
        }

        // Cancellation checkpoint (§17): after a (possibly multi-second) settle wait and
        // before the AX tree walk / capture, so a cancel that arrived during settle stops
        // the work here rather than paying for the tree build + screenshot.
        try CancellationToken.checkpoint()

        // §18.2: Resolve a scoped snapshot's element against the session's CURRENT table.
        // Resolution failure DEGRADES to unscoped (`scope_ignored` warning, never an error) —
        // the returned full tree carries the fresh ids the caller needs to scope correctly
        // on its next call.
        var scopeRoot: AXUIElement?
        if let scopeElementId = request.scopeElementId, scopeIgnoredReason == nil {
            let currentRev = context.sessionManager.currentRevision(forSession: session.sessionId) ?? 1
            if let handle = try? table.resolve(scopeElementId, sessionId: session.sessionId, revision: currentRev),
               let axHandle = handle as? AXElementHandle {
                scopeRoot = axHandle.element
            } else {
                scopeIgnoredReason = "element \(scopeElementId) does not resolve in the current snapshot (revision \(currentRev))"
            }
        }

        // 4. Window selection + correlation (§10.2–10.3). Fallible — must run before
        //    the revision advances so a failed snapshot leaves the session unchanged.
        let resolution = try WindowResolution.resolve(
            appElement: appElement,
            pid: pid,
            app: request.app,
            explicitWindowId: request.windowId,
            client: client
        )
        let selection = resolution.selection

        // §18.2: a scoped element must belong to the resolved window (best-effort: verified
        // via the element's `AXWindow` when readable). A scoped element in a different
        // window likewise degrades to unscoped — this also keeps `scopeElementId` composing
        // with `windowId` without a new failure mode.
        if let scopeElementId = request.scopeElementId, let resolvedRoot = scopeRoot,
           let elementWindow = client.copyElement(resolvedRoot, "AXWindow"),
           !CFEqual(elementWindow, selection.axWindow) {
            scopeRoot = nil
            scopeIgnoredReason = "element \(scopeElementId) belongs to a different window than the resolved one"
        }

        // §18.2: everything downstream keys off whether the scope was HONORED — a degraded
        // scoped request behaves exactly like an unscoped snapshot (id stability, diffing,
        // diff-base storage, no scope echo), differing only by the advisory warning.
        let scopeHonored = scopeRoot != nil

        var warnings: [StateWarning] = []
        if let settleWarning {
            warnings.append(settleWarning)
        }
        // §18.2: the degraded-scope advisory. The full unscoped tree below is authoritative;
        // the caller re-scopes with an id copied from it.
        if let scopeElementId = request.scopeElementId, let reason = scopeIgnoredReason {
            warnings.append(StateWarning(
                .scopeIgnored,
                message: "scopeElementId \(scopeElementId) was ignored (\(reason)); a full unscoped snapshot was returned instead. Copy element ids from THIS tree, and scope only to ids from this session's current snapshot."
            ))
        }
        // §18.1: advisory that web-content AX was just enabled — the async web tree may not
        // be present yet, so the client should request another snapshot if it is missing.
        // Attached to the enabling snapshot only (clients ignore unknown warning codes).
        if webContentJustEnabled {
            warnings.append(StateWarning(
                .webContentEnabled,
                message: "Web-content accessibility was just enabled for this app; if expected web content is missing from this tree, request another snapshot."
            ))
        }
        if selection.confidence == .low {
            warnings.append(StateWarning(
                .lowCorrelationConfidence,
                message: "AX↔window correlation relied on weak signals; the captured window may not be the intended one."
            ))
        }

        // 5. Build + render the tree. `build` rebuilds the element table (retires the prior
        //    snapshot's ids, mints this snapshot's) inside its beginPass/endPass; it does not
        //    throw. The element table's pre-build id space is checkpointed here so a cancel
        //    caught after the build (on the capture path or at the post-capture checkpoint)
        //    rolls it back, and the revision bump is DEFERRED to after that checkpoint — so a
        //    cancelled build leaves BOTH the revision counter and the element table untouched
        //    (§13.1, §17.2). Take the checkpoint before `forceFullTree`'s `table.reset()` and
        //    the build pass, so a rollback restores the exact pre-build mappings.
        let tableCheckpoint = table.checkpoint()
        let focused = client.focusedUIElement(of: appElement)
        // `forceFullTree` (§15.1) means "rebuild ids too": retire the session's whole id
        // space before the build pass so every element is re-minted fresh and the prior
        // snapshot's ids are retired (the monotonic counter still never rewinds). This is
        // what distinguishes it from `disableDiff`, which forces a full tree but keeps ids
        // stable. Diffing is already suppressed for both (`suppressesDiff`), so a reset
        // here only changes the id space, never the full-vs-diff decision.
        // An HONORED scoped snapshot (§18.2) likewise retires ALL prior ids: the new table
        // covers exactly the scoped subtree, so an out-of-scope id must be re-acquired
        // unscoped. A degraded scope keeps normal unscoped id stability.
        if request.forceFullTree || scopeHonored {
            table.reset()
        }
        // §18.2: a scoped snapshot roots the walk at the resolved element instead of the
        // window; the window frame stays the same so frames remain window points (§9).
        let buildRoot = scopeRoot ?? selection.axWindow
        let builder = AXTreeBuilder(client: client)
        let buildResult = builder.build(
            windowElement: buildRoot,
            windowFrameGlobal: selection.frameGlobal,
            focusedElement: focused,
            table: table
        )
        // Revision this snapshot will report — computed but NOT yet committed. The actual
        // `bumpRevision` is deferred to after the post-capture checkpoint (§17.2) so a cancelled
        // build leaves the session's revision untouched (§13.1). Execution is strictly serial per
        // session (§17.1), so the value committed by `bumpRevision` below equals this.
        let priorRevision = context.sessionManager.currentRevision(forSession: session.sessionId) ?? 1
        let currentRevision = sessionExisted ? priorRevision + 1 : priorRevision
        // §18.2: `maxNodes` overrides the §7.5 default node budget for this snapshot, clamped
        // to the frozen 1...2000 ceiling; omitted → default (600). The byte cap is unchanged.
        let renderOptions = AXTreeRenderer.Options(maxNodes: AccessibilityEngine.nodeBudget(requested: request.maxNodes))
        let rendered = AXTreeRenderer.render(buildResult.root, options: renderOptions)
        // Boundary trace: AX tree extraction + render complete.
        trace?.mark("ax_tree")
        // Either the renderer cut nodes for the node/byte budget (§7.5) OR the
        // builder dropped subtrees at the depth cap / node ceiling. The latter can
        // leave a tree that fits the render budget yet is incomplete, so OR both
        // signals — otherwise the client is told a silently-pruned tree is full.
        let treeTruncated = rendered.truncated || buildResult.truncatedDuringBuild
        if treeTruncated {
            warnings.append(StateWarning(
                .truncatedTree,
                message: "The accessibility tree exceeded the node, byte, or depth budget and was truncated."
            ))
        }

        // Phase 3 (§15): emit a diff when an intact-lineage base snapshot exists for the
        // same window, neither base nor current text is truncated (the client received
        // the base completely), and the caller did not suppress diffing. Otherwise a
        // full tree — with a `diff_reset` warning when a usable base existed but the
        // window changed or lineage broke (never for a first snapshot or an explicit
        // forceFullTree/disableDiff).
        // §18.2: a scoped snapshot never participates in diffing — always full, never a diff
        // base — so it is excluded from the diff decision below (and from the base store in the
        // commit block). It instead marks lineage broken so the next unscoped snapshot returns
        // a full tree (with `diff_reset` when a base had existed).
        let previous = context.snapshot(forSession: session.sessionId)
        let lineageBroken = context.isLineageBroken(forSession: session.sessionId)
        let sameWindow = previous?.windowId == selection.windowNumber
        let baseIsClean = previous.map { !$0.truncated } ?? false
        var isFull = true
        var baseRevision: Int?
        var treeText = rendered.text
        if let previous, !scopeHonored, !request.suppressesDiff, !treeTruncated, baseIsClean, sameWindow, !lineageBroken {
            let diff = AXTreeDiff.compute(
                previous: previous.root,
                current: buildResult.root,
                baseRevision: previous.revision,
                revision: currentRevision
            )
            if diff.reusedIdConflict {
                // A matched (id-reused) element changed its diff-identity (raw title) or
                // child position, so the diff cannot be rendered without listing the same
                // live id in both `+` and `-` (§15.2/§15.3 disjointness). Correctness beats
                // a smaller payload: keep the full tree and flag `diff_reset` so
                // the client re-reads all ids.
                warnings.append(StateWarning(
                    .diffReset,
                    message: "Incremental lineage could not be represented as a diff (a reused element id changed identity or position); a full tree was returned. Treat element ids as fresh."
                ))
            } else {
                treeText = AXTreeDiff.render(diff)
                isFull = false
                baseRevision = previous.revision
            }
        } else if previous != nil, !scopeHonored, !request.suppressesDiff, (!sameWindow || lineageBroken) {
            warnings.append(StateWarning(
                .diffReset,
                message: "Incremental lineage could not be guaranteed (window changed or observer gap); a full tree was returned. Treat element ids as fresh."
            ))
        }

        // NB: recording this snapshot as the next diff base and clearing the transient
        // dirty/lineage flags are session-visible mutations, so they are DEFERRED to the
        // commit block after the post-capture checkpoint (§17.2) — a cancelled build must not
        // advance the diff base or clear the dirty flag it never delivered a snapshot for.

        // 6. Screenshot (§4.1, §8). Prompt-free: capture only when SR is granted.
        let scale = Self.backingScale(forGlobalRect: selection.frameGlobal)
        var screenshotMeta: AppState.ScreenshotMeta?
        var screenshotPixels: Size?
        var imageBase64: String?

        do {
            switch request.includeScreenshot {
            case .never:
                warnings.append(StateWarning(.screenshotOmitted, message: "includeScreenshot was \"never\"."))
            case .auto, .always:
                if CGPreflightScreenCaptureAccess() {
                    // Cancellation checkpoint (§17): stop before starting the ScreenCaptureKit
                    // capture if the request was already cancelled.
                    try CancellationToken.checkpoint()
                    do {
                        let shot = try await Self.capture(
                            windowNumber: selection.windowNumber,
                            frameGlobal: selection.frameGlobal,
                            scale: scale,
                            app: request.app
                        )
                        screenshotMeta = shot.meta
                        screenshotPixels = shot.pixels
                        imageBase64 = shot.base64
                    } catch {
                        // A cancellation mid-capture (the async SCK call is torn down by
                        // Task.cancel, or the ambient token fired) must surface as the typed
                        // `cancelled` error, NOT be swallowed into a screenshot warning that
                        // returns a spuriously-successful partial state (§17).
                        if let cancelled = Self.cancellationError(error) { throw cancelled }
                        warnings.append(StateWarning(
                            .screenshotUnavailable,
                            message: Self.uncapturableMessage(error)
                        ))
                    }
                } else if request.includeScreenshot == .always {
                    warnings.append(StateWarning(
                        .screenshotUnavailable,
                        message: "Screen Recording is not granted, so the requested screenshot could not be captured."
                    ))
                } else {
                    warnings.append(StateWarning(
                        .screenshotOmitted,
                        message: "Screen Recording is not granted; the accessibility tree is returned without a screenshot."
                    ))
                }
            }

            // Boundary trace: screenshot capture + encode complete (or skipped/failed).
            trace?.mark("screenshot")

            // Cancellation checkpoint (§17.2, POST-capture). Two gaps close here:
            //   (1) the capture SUCCESS branch has no cancellation check, and
            //       `SCScreenshotManager.captureImage` neither honors `Task` cancellation nor
            //       consults `Task.isCancelled`, so a cancel that lands while a valid image is
            //       assembled would otherwise return a spuriously-successful screenshot-bearing
            //       state instead of `cancelled`;
            //   (2) the no-screenshot branches (`never`, and SR-denied `auto`/`always`) skip the
            //       pre-capture checkpoint entirely, so tree build / render / diff on those paths
            //       had no post-settle cancellation check — this checkpoint sits after all five
            //       branches and after build/render/diff, covering every path.
            try CancellationToken.checkpoint()
        } catch {
            // A cancellation (or any fault) after the tree was built rolls back the element-table
            // id-space mutations so the session's element table is left exactly as it was
            // (§13.1, §17.2); the deferred revision bump / snapshot store / dirty+lineage clear
            // below are then simply never committed.
            table.rollback(to: tableCheckpoint)
            throw error
        }

        // COMMIT the deferred session-visible mutations — reached only once cancellation can no
        // longer intervene, preserving the invariant that a cancelled/failed build leaves BOTH
        // the revision counter and the element table untouched (§13.1, §17.2). Bump the revision
        // (existing session only; a new session already reads revision 1), then record this
        // snapshot as the next diff base and clear the transient dirty/lineage flags.
        if sessionExisted {
            _ = context.sessionManager.bumpRevision(forSession: session.sessionId)
        }
        if scopeHonored {
            // §18.2: an honored scoped snapshot is never stored as a diff base, and it marks
            // lineage broken so the NEXT unscoped snapshot is a full tree (with `diff_reset`
            // when a base had existed). The revision still advanced above. A degraded scope
            // stores its (full, unscoped) tree as a normal diff base below.
            context.markLineageBroken(forSession: session.sessionId)
        } else {
            context.storeSnapshot(
                forSession: session.sessionId,
                ServiceContext.TreeSnapshot(
                    revision: currentRevision,
                    windowId: selection.windowNumber,
                    root: buildResult.root,
                    truncated: treeTruncated
                )
            )
            context.clearLineageBroken(forSession: session.sessionId)
        }
        context.observerCoordinator.state.clearDirty(pid: pid)

        // Phase 4 (§16): record this window's geometry as the coordinate-mapping source for
        // subsequent fallback actions (coordinate click/drag/scroll). `screenshotPixels` is
        // present only when a screenshot was delivered — required to map screenshot-space
        // points.
        context.storeWindowGeometry(
            WindowGeometry(
                windowId: selection.windowNumber,
                framePoints: selection.frameGlobal,
                screenshotPixels: screenshotPixels,
                scale: scale
            ),
            forSession: session.sessionId
        )

        // 7. Assemble.
        let summary = AppSummary(
            id: record.toSummary().id,
            displayName: record.displayName,
            path: record.path,
            pid: Int(pid),
            isRunning: true,
            windows: Self.windowCount(forPID: pid),
            lastUsedAt: nil
        )
        let window = AppState.WindowInfo(
            id: selection.windowNumber,
            title: selection.title,
            framePoints: selection.frameGlobal,
            screenshotPixels: screenshotPixels,
            scale: scale,
            document: buildResult.document // §18.4: principal web area's url/title (omitted when absent)
        )
        // `nodeCount` always reflects the current tree's emitted element lines (§4.1);
        // `text` is the diff body when `isFull` is false (§15), the full tree otherwise.
        let tree = AppState.TreeInfo(
            text: treeText,
            nodeCount: rendered.nodeCount,
            truncated: treeTruncated
        )
        let state = AppState(
            sessionId: session.sessionId,
            app: summary,
            window: window,
            revision: currentRevision,
            full: isFull,
            baseRevision: baseRevision,
            tree: tree,
            screenshot: screenshotMeta,
            focusedElementId: buildResult.focusedElementId,
            warnings: warnings,
            windows: resolution.windows, // §18.3: best-effort window enumeration (omitted when nil)
            scope: scopeHonored ? request.scopeElementId.map { AppState.Scope(elementId: $0) } : nil // §18.2: echo only when the scope was honored
        )
        // Boundary trace counts: emitted node count and
        // the full-tree-vs-diff byte sizes. `tree_bytes` is the delivered `tree.text`
        // (diff body when `full` is false); `diff_bytes` is recorded only for a diff.
        trace?.count("nodes", rendered.nodeCount)
        trace?.count("tree_bytes", treeText.utf8.count)
        if !isFull {
            trace?.count("diff_bytes", treeText.utf8.count)
        }
        return Output(state: state, imageBase64: imageBase64)
    }

    /// Map an error thrown during capture to a typed `cancelled` when a cancellation caused
    /// it — either the ambient token fired, the surrounding `Task` was cancelled, or the
    /// error itself is a `CancellationError`. Returns `nil` for a genuine capture fault.
    static func cancellationError(_ error: Error) -> CUError? {
        if case let CUError.cancelled(reason) = error { return .cancelled(reason: reason) }
        if error is CancellationError { return .cancelled(reason: nil) }
        if let token = CancellationToken.current, token.isCancelled {
            return .cancelled(reason: token.reason)
        }
        if Task.isCancelled { return .cancelled(reason: nil) }
        return nil
    }

    /// Write one diagnostic line to stderr (§1: MCP stdout is protocol-only). Used for the
    /// best-effort web-AX enablement faults (§18.1), which never reach the wire.
    static func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    // MARK: - Settle

    /// Wait — bounded — for the target app's UI to go quiet before the tree walk
    /// (§15.3). Runs on the `get_app_state` background thread, so a real `Thread.sleep`
    /// is safe. The pure policy lives in `SettleDetector`; here we feed it the live
    /// clock and the observer's activity snapshot.
    static func waitForSettle(
        context: ServiceContext,
        pid: pid_t,
        token: CancellationToken? = nil,
        forceLoading: Bool = false
    ) -> SettleDetector.Outcome {
        SettleDetector.waitForSettle(
            timings: context.settleTimings,
            clock: { SettleDetector.monotonicNow() },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            activity: {
                let snapshot = context.observerCoordinator.state.snapshot(pid: pid)
                // §18.1: a snapshot that just enabled web content settles with the loading
                // deadline (the app builds the web tree asynchronously) even on a session's
                // first snapshot, so force the loading branch here.
                return (snapshot.lastActivityAt, forceLoading || snapshot.loading)
            },
            isCancelled: {
                // A client cancel (or shutdown) that lands during the settle wait breaks it
                // early instead of paying up to the 5 s loading deadline; the post-settle
                // checkpoint below then surfaces the typed `cancelled` (§17.2).
                if let token, token.isCancelled { return true }
                return Task.isCancelled
            }
        )
    }

    // MARK: - Capture

    /// The output of `capture`: screenshot metadata, the decoded pixel size, and the base64
    /// JPEG for the §5 image block. Internal so the `screenshot` tool's `ScreenshotService`
    /// reuses the exact SCK/encoder pipeline (§18.9) rather than duplicating it.
    struct CaptureResult {
        let meta: AppState.ScreenshotMeta
        let pixels: Size
        let base64: String
    }

    /// Capture and JPEG-encode one window (§8). Throws `uncapturable_window` / capture faults.
    /// In `get_app_state` these degrade to a `screenshot_unavailable` warning; in `screenshot`
    /// (§18.9) the image is the product, so its caller surfaces the fault directly. Internal so
    /// both tools share this single SCK + encoder pipeline.
    static func capture(
        windowNumber: Int,
        frameGlobal: Rect,
        scale: Double,
        app: String
    ) async throws -> CaptureResult {
        let snapshot = try await WindowCatalog.snapshot()
        guard let scWindow = snapshot.shareableWindow(number: windowNumber) else {
            throw CUError.uncapturableWindow(app: app, windowId: windowNumber, reason: .stale)
        }
        let image = try await WindowCapture.captureImage(
            scWindow: scWindow,
            framePoints: frameGlobal,
            scale: scale,
            app: app,
            windowNumber: windowNumber
        )
        let encoded = try ScreenshotEncoder.encodeJPEG(image)
        return CaptureResult(
            meta: AppState.ScreenshotMeta(
                mimeType: CaptureEngine.mcpMimeType,
                width: encoded.width,
                height: encoded.height,
                byteLength: encoded.byteCount
            ),
            pixels: Size(width: encoded.width, height: encoded.height),
            base64: encoded.data.base64EncodedString()
        )
    }

    private static func uncapturableMessage(_ error: Error) -> String {
        if case let CUError.uncapturableWindow(_, _, reason) = error {
            return "The target window could not be captured (\(reason.rawValue)); the accessibility tree is still returned."
        }
        return "The target window could not be captured; the accessibility tree is still returned."
    }

    // MARK: - Display metrics

    /// Count of normal, visible windows owned by `pid` (feeds `AppSummary.windows`).
    static func windowCount(forPID pid: Int32) -> Int {
        WindowCatalog.cgWindows(includeOffscreen: false)
            .filter { $0.ownerPID == pid && $0.isNormalVisible }
            .count
    }

    /// Best-effort display backing scale for a window at `rect` (global points,
    /// top-left).
    ///
    /// Uses **only thread-safe CoreGraphics** APIs. The whole `get_app_state`
    /// pipeline runs on a cooperative-pool background thread (the mcp main thread is
    /// parked on a semaphore with no run loop, so a MainActor/`DispatchQueue.main`
    /// hop would hang), and AppKit's `NSScreen` is main-thread-only — touching it
    /// here aborts under Main Thread Checker and can read a stale/empty screen list.
    /// `CGGetDisplaysWithPoint` + `CGDisplayCopyDisplayMode` are safe from any
    /// thread, and `pixelWidth / width` of the mode is the true backing scale
    /// (1.0 on a non-Retina display, 2.0 on Retina) — no hardcoded guess.
    static func backingScale(forGlobalRect rect: Rect) -> Double {
        let center = CGPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)

        // Display whose bounds contain the window's center (CG global display space
        // is top-left origin, matching `rect`); fall back to the main display.
        var displayID = CGMainDisplayID()
        var matching: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(center, 1, &matching, &count) == .success, count > 0 {
            displayID = matching
        }

        return scale(ofDisplay: displayID)
            ?? scale(ofDisplay: CGMainDisplayID())
            ?? 2.0 // only when no display mode is readable at all (e.g. headless)
    }

    /// Backing scale of a display = `pixelWidth / width` of its current mode; `nil`
    /// when the mode is unreadable or reports a zero point width.
    private static func scale(ofDisplay displayID: CGDirectDisplayID) -> Double? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        let pointWidth = mode.width
        guard pointWidth > 0 else { return nil }
        return Double(mode.pixelWidth) / Double(pointWidth)
    }
}
