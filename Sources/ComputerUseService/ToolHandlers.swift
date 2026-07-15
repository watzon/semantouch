import Foundation
import CoreGraphics
import ComputerUseCore
import CaptureEngine
import AccessibilityEngine
import ActionEngine
import CursorOverlay
import MCPServer

/// Wires the engines into `ToolHandler`s and builds the enabled-tool `ToolRegistry`
/// the MCP server serves (§4, §5). Phase 1 read-only tools plus the Phase 2 semantic
/// actions (§13). Still-disabled tools (Phase 4) keep the placeholder handler and
/// short-circuit to `policy_denied`/`tool_disabled` before dispatch.
public enum ToolHandlers {
    /// The standard registry: real handlers for every enabled tool.
    public static func registry(context: ServiceContext) -> ToolRegistry {
        ToolRegistry.standard(handlers: handlers(context: context))
    }

    /// The handler map, keyed by tool name.
    public static func handlers(context: ServiceContext) -> [String: ToolHandler] {
        [
            // Phase 1 — read-only + explicit lifecycle launch.
            "doctor": doctorHandler(),
            "list_apps": listAppsHandler(),
            "launch_app": launchAppHandler(context: context),
            "get_app_state": getAppStateHandler(context: context),
            // Full-text read of one revision-checked element (never advances revision).
            "read_text": readTextHandler(context: context),
            // v1.5 — read-only capture-only tool (§18.9).
            "screenshot": screenshotHandler(context: context),
            "end_app_session": endSessionHandler(context: context),
            // Phase 2 — semantic actions (§13); click/scroll also carry a Phase 4
            // coordinate fallback path (§16), dispatched on the presence of `at`.
            "click": clickHandler(context: context),
            "perform_action": actionHandler(context: context) { args in
                guard let name = args["action"]?.stringValue else {
                    throw ToolInvalidArguments("perform_action requires a string \"action\"")
                }
                return .performAction(name: name)
            },
            "set_value": actionHandler(context: context) { args in
                // §18.5: optional `commit` runs the semantic commit path (pre-focus, write, then
                // AXConfirm when advertised). Default false → byte-identical to v1.1.
                .setValue(try actionValue(from: args), commit: args["commit"]?.boolValue ?? false)
            },
            "select_text": actionHandler(context: context) { args in
                guard let start = args["start"]?.intValue, let length = args["length"]?.intValue else {
                    throw ToolInvalidArguments("select_text requires integer \"start\" and \"length\"")
                }
                return .selectText(start: start, length: length)
            },
            "scroll": scrollHandler(context: context),
            // Phase 4 — native fallback input (§16).
            "press_key": pressKeyHandler(context: context),
            "type_text": typeTextHandler(context: context),
            "drag": dragHandler(context: context),
            // v1.5 — read-only outcome verification (§18.7).
            "wait_for": waitForHandler(context: context),
        ]
    }

    // MARK: - Individual handlers

    static func doctorHandler() -> ToolHandler {
        { arguments in
            let requestOnboarding = arguments["requestOnboarding"]?.boolValue ?? false
            let result = DoctorService.run(requestOnboarding: requestOnboarding)
            return .text(try CanonicalJSON.encodeToString(result))
        }
    }

    static func listAppsHandler() -> ToolHandler {
        { _ in
            let apps = AppLister.listApps()
            return .text(try CanonicalJSON.encodeToString(ListAppsResult(apps: apps)))
        }
    }

    /// `launch_app`: explicit, policy-gated launch / hidden-window recovery. Never
    /// implied by ordinary app resolution. No SnapshotOptions cascade — lifecycle only.
    static func launchAppHandler(context: ServiceContext) -> ToolHandler {
        { arguments in
            let request = try decode(LaunchAppRequest.self, from: arguments)
            let result = try await AppLauncher.launch(request, context: context)
            return .text(try CanonicalJSON.encodeToString(result))
        }
    }

    static func getAppStateHandler(context: ServiceContext) -> ToolHandler {
        { arguments in
            let request = try decode(GetAppStateRequest.self, from: arguments)
            let output = try await AppStateBuilder(context: context, resolver: context.appResolver).build(request)
            // Record the target window's geometry so the overlay
            // follows window moves. Best-effort and decorative — never affects the result.
            context.cursorController.noteWindowFrame(
                sessionId: output.state.sessionId,
                output.state.window.framePoints
            )
            let text = try CanonicalJSON.encodeToString(output.state)
            var blocks: [ToolContent] = [.text(text)]
            if let base64 = output.imageBase64 {
                blocks.append(.image(base64: base64, mimeType: CaptureEngine.mcpMimeType))
            }
            return ToolResult(content: blocks)
        }
    }

    /// `screenshot` (§18.9): capture the resolved window as JPEG without a tree walk. The
    /// envelope mirrors `get_app_state` — a JSON text block plus a second image content block —
    /// but the image is ALWAYS present on success (it is the product). Best-effort overlay
    /// tracking follows the delivered window, exactly as get_app_state's handler does.
    static func screenshotHandler(context: ServiceContext) -> ToolHandler {
        { arguments in
            let request = try decode(ScreenshotRequest.self, from: arguments)
            let output = try await ScreenshotService(context: context, resolver: context.appResolver).capture(request)
            // Record the target window's geometry so the overlay follows
            // window moves. Best-effort and decorative — never affects the result.
            context.cursorController.noteWindowFrame(
                sessionId: output.result.sessionId,
                output.result.window.framePoints
            )
            let text = try CanonicalJSON.encodeToString(output.result)
            return ToolResult(content: [
                .text(text),
                .image(base64: output.imageBase64, mimeType: CaptureEngine.mcpMimeType),
            ])
        }
    }

    /// `read_text`: revision-checked full-text AXValue read. Never advances revision.
    static func readTextHandler(context: ServiceContext) -> ToolHandler {
        { arguments in
            let request = try decode(ReadTextRequest.self, from: arguments)
            let result = try ReadTextService.run(request, context: context)
            return .text(try CanonicalJSON.encodeToString(result))
        }
    }

    static func endSessionHandler(context: ServiceContext) -> ToolHandler {
        { arguments in
            guard let sessionId = arguments["sessionId"]?.stringValue else {
                throw ToolInvalidArguments("end_app_session requires a string \"sessionId\"")
            }
            // Capture the pid before ending so the observer can be detached (§15.3).
            let pid = context.sessionManager.session(id: sessionId)?.pid
            let ended = context.sessionManager.endSession(id: sessionId)
            if ended {
                // §18.1: reset (to false) the web-AX attributes THIS server flipped for the
                // session, before dropping its bookkeeping. Best-effort; never a pre-existing true.
                context.resetWebContentAccessibility(forSession: sessionId)
                context.releaseElementTable(forSession: sessionId)
                context.releaseSnapshot(forSession: sessionId)
                context.releaseWindowGeometry(forSession: sessionId)
                context.actionExecutor.releaseLane(sessionId: sessionId)
                if let pid { context.observerCoordinator.stopObserving(pid: pid) }
            }
            // A session ending hides its overlay immediately (idempotent
            // for an unknown session).
            context.cursorController.endSession(sessionId: sessionId)
            let payload = EndSessionResult(sessionId: sessionId, ended: ended)
            return .text(try CanonicalJSON.encodeToString(payload))
        }
    }

    // MARK: - Phase 2 action handlers (§13)

    /// Build a handler for an element-targeted action: decode the `ElementTarget`,
    /// build the `SemanticAction` from the remaining arguments, run it through the
    /// per-session serial executor, and return the `ActionResult` JSON (§13.2, §13.4).
    /// The policy gate, session/revision validation, and element resolution all live
    /// inside `ActionExecutor.execute`; a `CUError` it throws becomes a tool-level
    /// error, a `ToolInvalidArguments` from `makeAction` becomes `-32602`.
    static func actionHandler(
        context: ServiceContext,
        _ makeAction: @escaping (JSONValue) throws -> SemanticAction
    ) -> ToolHandler {
        { arguments in try await runSemantic(context: context, arguments: arguments, makeAction: makeAction) }
    }

    /// Run one semantic (Phase 2) element-targeted action to completion.
    /// On a committed mutation, cascade the caller's `SnapshotOptions` into a post-action
    /// refresh and attach the resulting `AppState` (plus a separate image block when produced).
    static func runSemantic(
        context: ServiceContext,
        arguments: JSONValue,
        makeAction: (JSONValue) throws -> SemanticAction
    ) async throws -> ToolResult {
        let target = try decode(ElementTarget.self, from: arguments)
        let options = try decode(SnapshotOptions.self, from: arguments)
        let action = try makeAction(arguments)
        // Reflect the action in the overlay if this session's window is
        // known. Semantic actions still move the system pointer 0px — this is a purely drawn
        // cursor. Best-effort: it never gates or delays the action below. The drawn cursor
        // anchors at the TARGET ELEMENT's frame centre (window points) when the element and
        // its frame resolve — an independent pointer visibly doing the work — else the
        // controller keeps its last position (never yanking to the window centre).
        if let geometry = context.windowGeometry(forSession: target.sessionId) {
            var anchor: Point?
            if let handle = try? context.elementTable(forSession: target.sessionId)
                .resolve(target.elementId, sessionId: target.sessionId, revision: target.revision),
               let axHandle = handle as? AXElementHandle,
               let frameGlobal = context.axClient.frame(of: axHandle.element) {
                anchor = CursorReflection.elementAnchor(
                    frameGlobal: Rect(frameGlobal),
                    windowFrame: geometry.framePoints
                )
            }
            context.cursorController.reflect(
                sessionId: target.sessionId,
                windowFrame: geometry.framePoints,
                action: CursorReflection.kind(for: action),
                at: anchor,
                pointerKind: CursorReflection.armsFirstShow(for: action)
            )
        }
        let result: ActionResult
        do {
            result = try context.actionExecutor.execute(
                action,
                target: target,
                environment: context.actionEnvironment()
            )
        } catch {
            // A rejected action (typed CUError) still returns the overlay to idle so it does
            // not stay stuck in the press state (best-effort; never affects the thrown error).
            // Rejected paths never refresh or attach state.
            context.cursorController.finish(sessionId: target.sessionId, interrupted: false)
            throw error
        }
        context.cursorController.finish(sessionId: target.sessionId, interrupted: result.status == .interrupted)
        // Phase 3 (§15.3): a completed mutation dirties the session so the next
        // get_app_state settles before rebuilding. Then attach a one-round-trip refresh.
        if result.status == .completed {
            context.markSessionDirty(sessionId: target.sessionId)
            return try await attachPostActionState(
                context: context,
                result: result,
                app: target.app,
                options: options
            )
        }
        return try encodeActionResult(result)
    }


    // MARK: - Phase 4 fallback handlers (§16)

    /// `click`: coordinate fallback (§16) when `at` is present, else the Phase 2 semantic
    /// path (§13) for ordinary left clicks. Right/middle element clicks are delivered
    /// through the element's verified current frame under the existing interference /
    /// focus / target gates — never a bare invented coordinate. `clickCount` is 1...3
    /// (default 1); left multi-clicks repeat AXPress, coordinate multi-clicks set
    /// CoreGraphics click-state 1...N.
    static func clickHandler(context: ServiceContext) -> ToolHandler {
        { arguments in
            let button = decodeButton(arguments)
            let clickCount = decodeClickCount(arguments)
            if arguments["at"] != nil {
                let target = try decodeFallbackTarget(arguments)
                let action = FallbackAction.coordinateClick(
                    at: try decodePoint(arguments["at"], field: "at"),
                    space: try decodeSpace(arguments),
                    button: button,
                    modifiers: modifierFlags(from: arguments["modifiers"]),
                    clickCount: clickCount
                )
                return try await runFallback(context: context, arguments: arguments, action: action, target: target)
            }

            // Element form. Ordinary left → AXPress (with multi-click). Right/middle need
            // pointer semantics via the element's verified frame centre.
            if SemanticActions.usesAXPress(button: button) {
                return try await runSemantic(context: context, arguments: arguments) { _ in
                    clickCount <= 1 ? .click : .clickRepeated(count: clickCount)
                }
            }
            return try await runElementPointerClick(
                context: context,
                arguments: arguments,
                button: button,
                clickCount: clickCount
            )
        }
    }

    /// `scroll`: coordinate fallback (§16) when `at` is present, else the Phase 2 semantic
    /// scroll (§13). `direction` is required in both forms. `count` is a positive number
    /// (integers remain valid); fractional page amounts pass through.
    static func scrollHandler(context: ServiceContext) -> ToolHandler {
        { arguments in
            guard let raw = arguments["direction"]?.stringValue, let direction = ScrollDirection(rawValue: raw) else {
                throw ToolInvalidArguments("scroll requires \"direction\" ∈ up|down|left|right")
            }
            let by = arguments["by"]?.stringValue.flatMap(ScrollGranularity.init(rawValue:)) ?? .line
            let count = try decodeScrollCount(arguments)
            if arguments["at"] != nil {
                let target = try decodeFallbackTarget(arguments)
                let action = FallbackAction.coordinateScroll(
                    at: try decodePoint(arguments["at"], field: "at"),
                    space: try decodeSpace(arguments),
                    direction: direction,
                    by: by,
                    count: count
                )
                return try await runFallback(context: context, arguments: arguments, action: action, target: target)
            }
            return try await runSemantic(context: context, arguments: arguments) { _ in
                .scroll(direction: direction, by: by, count: count)
            }
        }
    }

    static func pressKeyHandler(context: ServiceContext) -> ToolHandler {
        { arguments in
            // §18.6: press_key MAY carry the element-targeting pair (validated in-lane).
            let target = try decodeFallbackTarget(arguments, elementPair: true)
            guard let combo = arguments["combo"]?.stringValue else {
                throw ToolInvalidArguments("press_key requires a string \"combo\"")
            }
            let chords: [KeyChord]
            do {
                chords = try KeyChord.parse(combo)
            } catch let error as KeyChordError {
                throw ToolInvalidArguments("invalid combo: \(error.message)")
            }
            return try await runFallback(
                context: context,
                arguments: arguments,
                action: .pressKey(chords: chords),
                target: target
            )
        }
    }

    static func typeTextHandler(context: ServiceContext) -> ToolHandler {
        { arguments in
            // §18.6: type_text MAY carry the element-targeting pair (validated in-lane).
            let target = try decodeFallbackTarget(arguments, elementPair: true)
            guard let text = arguments["text"]?.stringValue else {
                throw ToolInvalidArguments("type_text requires a string \"text\"")
            }
            return try await runFallback(
                context: context,
                arguments: arguments,
                action: .typeText(text),
                target: target
            )
        }
    }

    static func dragHandler(context: ServiceContext) -> ToolHandler {
        { arguments in
            let target = try decodeFallbackTarget(arguments)
            let action = FallbackAction.drag(
                from: try decodePoint(arguments["from"], field: "from"),
                to: try decodePoint(arguments["to"], field: "to"),
                space: try decodeSpace(arguments),
                button: decodeButton(arguments),
                modifiers: modifierFlags(from: arguments["modifiers"])
            )
            return try await runFallback(context: context, arguments: arguments, action: action, target: target)
        }
    }

    /// Element right/middle (or other pointer-semantic) click: resolve the live element
    /// frame after revision checks, then deliver a coordinate click at its centre through
    /// the existing fallback interference / focus / target-verification gates. Never invents
    /// a bare coordinate — if the frame cannot be read or sits outside the target window,
    /// delivery is refused.
    static func runElementPointerClick(
        context: ServiceContext,
        arguments: JSONValue,
        button: PointerButton,
        clickCount: Int
    ) async throws -> ToolResult {
        let elementTarget = try decode(ElementTarget.self, from: arguments)
        let interference = arguments["interference"]?.stringValue
            .flatMap(InterferencePolicy.init(rawValue:)) ?? .backgroundOnly
        let modifiers = modifierFlags(from: arguments["modifiers"])

        // Resolve the live element under the same revision contract as Phase 2.
        let env = context.actionEnvironment()
        guard let current = env.currentRevision(sessionId: elementTarget.sessionId) else {
            throw CUError.staleRevision(sessionId: elementTarget.sessionId, provided: elementTarget.revision, current: nil)
        }
        guard try env.sessionOwnedByApp(sessionId: elementTarget.sessionId, app: elementTarget.app) else {
            throw CUError.policyDenied(reason: .appDenied, app: elementTarget.app, tool: "click")
        }
        guard current == elementTarget.revision else {
            throw CUError.staleRevision(sessionId: elementTarget.sessionId, provided: elementTarget.revision, current: current)
        }
        let element = try env.resolveElement(
            sessionId: elementTarget.sessionId,
            elementId: elementTarget.elementId,
            revision: elementTarget.revision
        )

        // Read the verified current frame via the live AX handle (not a cached tree node).
        guard let geometry = context.windowGeometry(forSession: elementTarget.sessionId) else {
            throw CUError.windowNotFound(app: elementTarget.app, windowId: nil)
        }
        guard let axElement = element as? AXActionElement else {
            throw CUError.unsupportedAction(
                elementId: elementTarget.elementId,
                action: button.rawValue + "-click",
                supported: element.actionNames(),
                reason: "Element pointer click requires a live AX-backed frame; the resolved element is not AX-backed."
            )
        }
        // Access the frame through the same AXClient the handle was built with.
        // AXActionElement does not expose the raw element publicly, so re-resolve the
        // handle from the session table (already revision-checked above).
        let handle = try context.elementTable(forSession: elementTarget.sessionId)
            .resolve(elementTarget.elementId, sessionId: elementTarget.sessionId, revision: elementTarget.revision)
        guard let axHandle = handle as? AXElementHandle,
              let frameGlobal = context.axClient.frame(of: axHandle.element),
              frameGlobal.width >= 0, frameGlobal.height >= 0 else {
            throw CUError.unsupportedAction(
                elementId: elementTarget.elementId,
                action: button.rawValue + "-click",
                supported: element.actionNames(),
                reason: "Element pointer click requires a readable current frame; none was available."
            )
        }
        let centerWindow = Point(
            x: Double(frameGlobal.midX) - geometry.framePoints.x,
            y: Double(frameGlobal.midY) - geometry.framePoints.y
        )
        let fallbackTarget = FallbackTarget(
            app: elementTarget.app,
            sessionId: elementTarget.sessionId,
            interference: interference
        )
        let action = FallbackAction.coordinateClick(
            at: centerWindow,
            space: .window,
            button: button,
            modifiers: modifiers,
            clickCount: clickCount
        )
        // Silence unused binding (element already validated live above).
        _ = axElement
        return try await runFallback(context: context, arguments: arguments, action: action, target: fallbackTarget)
    }


    // MARK: - v1.5 read-only verification (§18.7)

    /// `wait_for`: decode the conditions (an unknown/malformed condition is a `-32602`), then run
    /// the read-only poll loop to a `WaitForResult`. A `CUError` from the pre-poll gates
    /// (policy / session / window) becomes a tool-level error; an expired deadline is a normal
    /// `satisfied: false` result. Read-only, so it never touches the cursor overlay or dirties
    /// the session.
    static func waitForHandler(context: ServiceContext) -> ToolHandler {
        { arguments in
            let request = try WaitForService.decodeRequest(arguments)
            let result = try WaitForService.run(request, context: context)
            return .text(try CanonicalJSON.encodeToString(result))
        }
    }

    /// Run one Phase 4 fallback action to completion through the executor's fallback path.
    /// Completed and interrupted deliveries mark the session dirty and attach a post-action
    /// refresh; rejected actions never refresh.
    static func runFallback(
        context: ServiceContext,
        arguments: JSONValue,
        action: FallbackAction,
        target: FallbackTarget
    ) async throws -> ToolResult {
        let options = try decode(SnapshotOptions.self, from: arguments)
        // Reflect the fallback action's target point in the overlay
        // (best-effort; the drawn cursor is decorative and does not move the system pointer).
        if let geometry = context.windowGeometry(forSession: target.sessionId) {
            let reflection = CursorReflection.forFallback(action, geometry: geometry)
            context.cursorController.reflect(
                sessionId: target.sessionId,
                windowFrame: geometry.framePoints,
                action: reflection.kind,
                at: reflection.point,
                pointerKind: reflection.arms
            )
        }
        let result: ActionResult
        do {
            result = try context.actionExecutor.executeFallback(
                action,
                target: target,
                environment: context.fallbackEnvironment()
            )
        } catch {
            // A rejected fallback (policy_denied / focus_required / …) returns the overlay to
            // idle rather than leaving it stuck (best-effort; never affects the thrown error).
            // Rejected paths never refresh or attach state.
            context.cursorController.finish(sessionId: target.sessionId, interrupted: false)
            throw error
        }
        context.cursorController.finish(sessionId: target.sessionId, interrupted: result.status == .interrupted)
        // A delivered fallback action changes app state; dirty the session so the next
        // get_app_state settles (§15.3). An INTERRUPTED action may already have applied
        // partial input before the user (or a foreground steal) cut it short, so it must dirty
        // the session too — signalling the settle pipeline and marking state stale per
        // SECURITY.md §6. Only a `rejected` action (nothing delivered) leaves state untouched.
        if result.status == .completed || result.status == .interrupted {
            context.markSessionDirty(sessionId: target.sessionId)
            return try await attachPostActionState(
                context: context,
                result: result,
                app: target.app,
                options: options
            )
        }
        return try encodeActionResult(result)
    }

    // MARK: - Post-action state attachment

    /// Deterministic warning when a committed mutation's post-action refresh fails for a
    /// non-cancellation reason. The mutation itself still stands; `refreshRecommended` stays true.
    static let postActionRefreshFailedWarning =
        "Post-action state refresh failed; call get_app_state to observe the result."

    /// After a committed mutation, cascade the caller's `SnapshotOptions` into
    /// `AppStateBuilder`, attach `result.state`, clear `refreshRecommended` on success, and
    /// emit a separate image content block when a screenshot was produced.
    ///
    /// Cancellation during refresh propagates. A non-cancellation refresh failure returns the
    /// committed `ActionResult` with `state` omitted, `refreshRecommended` preserved, and an
    /// additive warning — never converting a successful mutation into an error.
    static func attachPostActionState(
        context: ServiceContext,
        result: ActionResult,
        app: String,
        options: SnapshotOptions
    ) async throws -> ToolResult {
        let request = options.asGetAppStateRequest(app: app)
        do {
            let output = try await AppStateBuilder(context: context, resolver: context.appResolver).build(request)
            // Record the refreshed window geometry so the overlay follows moves.
            // Best-effort and decorative — never affects the result.
            context.cursorController.noteWindowFrame(
                sessionId: output.state.sessionId,
                output.state.window.framePoints
            )
            var attached = result
            attached.state = output.state
            attached.refreshRecommended = false
            return try encodeActionResult(attached, imageBase64: output.imageBase64)
        } catch {
            if isCancellation(error) { throw error }
            var degraded = result
            degraded.state = nil
            // Preserve refreshRecommended from the committed result (true for mutations).
            degraded.warning = appendWarning(result.warning, Self.postActionRefreshFailedWarning)
            return try encodeActionResult(degraded)
        }
    }

    /// Encode an `ActionResult` as the primary text block, optionally followed by a separate
    /// image content block (screenshot bytes never embed inside the JSON).
    static func encodeActionResult(_ result: ActionResult, imageBase64: String? = nil) throws -> ToolResult {
        let text = try CanonicalJSON.encodeToString(result)
        var blocks: [ToolContent] = [.text(text)]
        if let imageBase64 {
            blocks.append(.image(base64: imageBase64, mimeType: CaptureEngine.mcpMimeType))
        }
        return ToolResult(content: blocks)
    }

    /// Append an additive warning without overwriting any existing one.
    static func appendWarning(_ existing: String?, _ addition: String) -> String {
        if let existing, !existing.isEmpty {
            return existing + " " + addition
        }
        return addition
    }

    /// Whether an error represents client/process cancellation (must propagate, not degrade).
    static func isCancellation(_ error: Error) -> Bool {
        if case CUError.cancelled = error { return true }
        if error is CancellationError { return true }
        if let token = CancellationToken.current, token.isCancelled { return true }
        return false
    }


    // MARK: - Fallback argument decoding

    /// Decode the shared `{ app, sessionId, interference? }` fallback target. `interference`
    /// defaults to `background-only` and is never silently escalated (§16).
    ///
    /// When `elementPair` is true (`press_key`/`type_text`, §18.6) the optional
    /// `revision`+`elementId` pair is decoded too — valid **only together** (one without the
    /// other is a JSON-RPC `-32602`, matching how a malformed combo is rejected at decode).
    static func decodeFallbackTarget(_ arguments: JSONValue, elementPair: Bool = false) throws -> FallbackTarget {
        guard let app = arguments["app"]?.stringValue else {
            throw ToolInvalidArguments("missing string \"app\"")
        }
        guard let sessionId = arguments["sessionId"]?.stringValue else {
            throw ToolInvalidArguments("missing string \"sessionId\"")
        }
        let interference = arguments["interference"]?.stringValue
            .flatMap(InterferencePolicy.init(rawValue:)) ?? .backgroundOnly
        var revision: Int?
        var elementId: String?
        if elementPair {
            // The schema already validated types/pattern when present; here we only enforce the
            // both-or-neither pairing (§18.6). A present key therefore carries a valid value.
            let hasRevision = arguments["revision"] != nil
            let hasElementId = arguments["elementId"] != nil
            guard hasRevision == hasElementId else {
                throw ToolInvalidArguments("\"revision\" and \"elementId\" must be provided together (both or neither)")
            }
            revision = arguments["revision"]?.intValue
            elementId = arguments["elementId"]?.stringValue
        }
        return FallbackTarget(
            app: app,
            sessionId: sessionId,
            interference: interference,
            revision: revision,
            elementId: elementId
        )
    }

    /// Decode a `{ x, y }` point.
    static func decodePoint(_ value: JSONValue?, field: String) throws -> Point {
        guard let value, let x = value["x"]?.doubleValue, let y = value["y"]?.doubleValue else {
            throw ToolInvalidArguments("\"\(field)\" must be an object with numeric x and y")
        }
        return Point(x: x, y: y)
    }

    /// Decode the coordinate `space` (default `window`).
    static func decodeSpace(_ arguments: JSONValue) throws -> CoordinateSpace {
        guard let raw = arguments["space"]?.stringValue else { return .window }
        guard let space = CoordinateSpace(rawValue: raw) else {
            throw ToolInvalidArguments("\"space\" must be \"window\" or \"screenshot\"")
        }
        return space
    }

    /// Decode the pointer `button` (default `left`).
    static func decodeButton(_ arguments: JSONValue) -> PointerButton {
        arguments["button"]?.stringValue.flatMap(PointerButton.init(rawValue:)) ?? .left
    }

    /// Decode `clickCount` (default 1). Schema already clamps to integer 1...3; defensive
    /// clamp keeps a pre-validated call site honest if the schema is bypassed in tests.
    static func decodeClickCount(_ arguments: JSONValue) -> Int {
        let raw = arguments["clickCount"]?.intValue ?? 1
        return max(1, min(3, raw))
    }

    /// Decode `scroll.count` as a positive Double (default 1). Integers remain valid via
    /// `doubleValue`; rejects non-positive values (schema allows 0 as inclusive minimum
    /// because the validator has no exclusive bound).
    static func decodeScrollCount(_ arguments: JSONValue) throws -> Double {
        let raw = arguments["count"]?.doubleValue ?? 1
        guard raw > 0 else {
            throw ToolInvalidArguments("\"count\" must be a number > 0")
        }
        return raw
    }

    /// Decode a `modifiers` array into CGEvent flags (unknown tokens are ignored; the
    /// schema enum already constrains the set).
    static func modifierFlags(from value: JSONValue?) -> CGEventFlags {
        guard let array = value?.arrayValue else { return [] }
        var flags: CGEventFlags = []
        for entry in array {
            if let token = entry.stringValue, let flag = Keymap.modifier(for: token) {
                flags.insert(flag)
            }
        }
        return flags
    }

    /// Decode `set_value`'s `value` (string | number | boolean) into an `ActionValue`.
    static func actionValue(from arguments: JSONValue) throws -> ActionValue {
        guard let value = arguments["value"] else {
            throw ToolInvalidArguments("set_value requires a \"value\"")
        }
        switch value {
        case let .string(string): return .string(string)
        case let .bool(flag): return .boolean(flag)
        case let .int(int): return .number(Double(int))
        case let .double(double): return .number(double)
        default: throw ToolInvalidArguments("\"value\" must be a string, number, or boolean")
        }
    }

    // MARK: - Argument decoding

    /// Decode tool arguments (already schema-validated) into a DTO. A decode fault
    /// surfaces as `-32602` (Invalid params) via `ToolInvalidArguments`.
    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        do {
            return try CanonicalJSON.decode(T.self, from: value.serialized())
        } catch {
            throw ToolInvalidArguments("could not decode arguments: \(error)")
        }
    }
}

/// Maps an action to the overlay's `CursorActionKind` and (for coordinate actions) a
/// target point in WINDOW points. Purely decorative — nothing here influences the action
/// result; it only decides what the drawn cursor shows.
enum CursorReflection {
    /// The overlay state for a Phase 2 semantic (element-targeted) action. These carry no
    /// coordinate, so the drawn cursor rests at the window centre (`at: nil` in the plan).
    static func kind(for action: SemanticAction) -> CursorActionKind {
        switch action {
        case .click, .clickRepeated, .performAction, .setValue: return .press
        case .selectText: return .move
        case .scroll: return .move
        }
    }

    /// The drawn-cursor anchor for a semantic action: the target element's frame centre
    /// converted from GLOBAL points to WINDOW points (origin at the window's top-left).
    /// Pure; `nil` for a degenerate element frame (the controller then keeps its last
    /// position rather than jumping to the window centre).
    static func elementAnchor(frameGlobal: Rect, windowFrame: Rect) -> Point? {
        guard frameGlobal.width >= 0, frameGlobal.height >= 0 else { return nil }
        return Point(
            x: frameGlobal.x + frameGlobal.width / 2 - windowFrame.x,
            y: frameGlobal.y + frameGlobal.height / 2 - windowFrame.y
        )
    }

    /// Whether a Phase 2 semantic action is POINTER-KIND and so may arm the overlay's
    /// first-show (task step 1). Only `click` and `scroll` are pointer actions; the other
    /// semantics (`perform_action`/`set_value`/`select_text`) reflect once a pointer action
    /// has already shown the overlay, but never bring it on screen themselves.
    static func armsFirstShow(for action: SemanticAction) -> Bool {
        switch action {
        case .click, .clickRepeated, .scroll: return true
        case .performAction, .setValue, .selectText: return false
        }
    }

    /// The overlay state, target point, and first-show arming for a Phase 4 fallback action.
    /// Keyboard actions have no location (progress at centre) and never arm first-show;
    /// coordinate actions map their point to window points and are pointer-kind (they arm).
    static func forFallback(_ action: FallbackAction, geometry: WindowGeometry) -> (kind: CursorActionKind, point: Point?, arms: Bool) {
        switch action {
        case .pressKey, .typeText:
            return (.progress, nil, false)
        case let .coordinateClick(at, space, _, _, _):
            return (.press, windowPoint(at, space: space, geometry: geometry), true)
        case let .drag(_, to, space, _, _):
            // Track the drag's END point (where the cursor lands).
            return (.drag, windowPoint(to, space: space, geometry: geometry), true)
        case let .coordinateScroll(at, space, _, _, _):
            return (.move, windowPoint(at, space: space, geometry: geometry), true)
        }
    }

    /// Convert a coordinate-action point in its `space` to WINDOW points (origin at the
    /// window's top-left) for the overlay plan. `window` points pass through; `screenshot`
    /// pixels are divided by the delivered pixels-per-point ratio (§9). Returns `nil` when
    /// a screenshot-space point cannot be mapped (no delivered pixels).
    private static func windowPoint(_ point: Point, space: CoordinateSpace, geometry: WindowGeometry) -> Point? {
        switch space {
        case .window:
            return point
        case .screenshot:
            guard let pixels = geometry.screenshotPixels,
                  geometry.framePoints.width > 0, geometry.framePoints.height > 0,
                  pixels.width > 0, pixels.height > 0 else { return nil }
            let kx = Double(pixels.width) / geometry.framePoints.width
            let ky = Double(pixels.height) / geometry.framePoints.height
            return Point(x: point.x / kx, y: point.y / ky)
        }
    }
}
