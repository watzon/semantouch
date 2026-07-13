import Foundation
import ApplicationServices
import ComputerUseCore
import AccessibilityEngine
import MCPServer

/// The read-only `wait_for` tool (docs/PROTOCOL.md §18.7): resolve the session's bound window,
/// then poll its observable state (title / document URL / element existence) until the
/// conditions hold or the deadline expires. An expired deadline is a **normal**
/// `satisfied: false` result, never a `timeout` error. It never advances the revision, mints or
/// retires element ids, or synthesizes input.
///
/// Processing order (§18.7): read-side app policy gate (§13.5) → session existence
/// (unknown/ended → `stale_revision`, `current: null`) → window re-resolution by the session's
/// bound WindowServer id (gone → `window_not_found`) → poll. Polling walks the live AX hierarchy
/// through `LiveWaitForProbe` (a bounded raw walk that NEVER touches the session element table).
enum WaitForService {
    /// Poll interval between snapshots (§18.7: "roughly every 150 ms").
    static let pollInterval: TimeInterval = 0.15

    /// A decoded `wait_for` request.
    struct Request {
        let app: String
        let sessionId: String
        let conditions: [WaitFor.Condition]
        let mode: WaitFor.Mode
        let timeoutMs: Int
    }

    // MARK: - Decode (→ -32602 on malformed conditions)

    /// Decode `wait_for` arguments. The JSON Schema layer already validated the envelope
    /// (required keys, `mode` enum, `timeoutMs` range, `conditions` count); here we decode the
    /// discriminated `Condition` union the schema cannot express — an unknown `kind` or a missing
    /// per-kind field is a `ToolInvalidArguments` (→ JSON-RPC `-32602`, §18.7).
    static func decodeRequest(_ arguments: JSONValue) throws -> Request {
        guard let app = arguments["app"]?.stringValue else {
            throw ToolInvalidArguments("wait_for requires a string \"app\"")
        }
        guard let sessionId = arguments["sessionId"]?.stringValue else {
            throw ToolInvalidArguments("wait_for requires a string \"sessionId\"")
        }
        guard let rawConditions = arguments["conditions"]?.arrayValue, !rawConditions.isEmpty else {
            throw ToolInvalidArguments("wait_for requires a non-empty \"conditions\" array")
        }
        guard rawConditions.count <= 4 else {
            throw ToolInvalidArguments("wait_for allows at most 4 conditions")
        }
        let conditions = try rawConditions.map(decodeCondition)

        let mode: WaitFor.Mode
        if let rawMode = arguments["mode"]?.stringValue {
            guard let parsed = WaitFor.Mode(rawValue: rawMode) else {
                throw ToolInvalidArguments("wait_for \"mode\" must be \"all\" or \"any\"")
            }
            mode = parsed
        } else {
            mode = .all
        }

        // Clamp defensively to the frozen range; the schema already enforces it.
        let timeoutMs = min(max(arguments["timeoutMs"]?.intValue ?? 5000, 100), 30000)
        return Request(app: app, sessionId: sessionId, conditions: conditions, mode: mode, timeoutMs: timeoutMs)
    }

    /// Decode one condition object (§18.7). Unknown `kind` / missing field → `-32602`.
    static func decodeCondition(_ value: JSONValue) throws -> WaitFor.Condition {
        guard let kind = value["kind"]?.stringValue else {
            throw ToolInvalidArguments("each wait_for condition requires a string \"kind\"")
        }
        switch kind {
        case "title_changed":
            return .titleChanged(from: try requireString(value, "from", kind: kind))
        case "title_contains":
            return .titleContains(value: try requireString(value, "value", kind: kind))
        case "url_changed":
            return .urlChanged(from: try requireString(value, "from", kind: kind))
        case "url_contains":
            return .urlContains(value: try requireString(value, "value", kind: kind))
        case "element_exists":
            return .elementExists(try decodeMatcher(value))
        case "element_gone":
            return .elementGone(try decodeMatcher(value))
        default:
            throw ToolInvalidArguments("unknown wait_for condition kind \"\(kind)\"")
        }
    }

    private static func requireString(_ value: JSONValue, _ key: String, kind: String) throws -> String {
        guard let string = value[key]?.stringValue else {
            throw ToolInvalidArguments("wait_for condition \"\(kind)\" requires a string \"\(key)\"")
        }
        return string
    }

    /// Decode an `element_exists`/`element_gone` matcher; at least one field is required (§18.7).
    private static func decodeMatcher(_ value: JSONValue) throws -> WaitFor.ElementMatcher {
        let role = value["role"]?.stringValue
        let titleContains = value["titleContains"]?.stringValue
        let valueContains = value["valueContains"]?.stringValue
        guard role != nil || titleContains != nil || valueContains != nil else {
            throw ToolInvalidArguments("wait_for element condition requires at least one of \"role\", \"titleContains\", \"valueContains\"")
        }
        return WaitFor.ElementMatcher(role: role, titleContains: titleContains, valueContains: valueContains)
    }

    // MARK: - Run (poll loop)

    /// Run the request to a `WaitForResult`. Throws a typed `CUError` for the pre-poll gates
    /// (policy / session / window); an expired deadline is a normal `satisfied: false` result.
    static func run(_ request: Request, context: ServiceContext) throws -> WaitForResult {
        // 1. Read-side app policy gate (§13.5): resolve the app and consult the denylist.
        let record: AppRecord
        switch context.appResolver.resolve(request.app) {
        case let .success(resolved): record = resolved
        case let .failure(error): throw error
        }
        if let reason = context.policyEngine.readDenialReason(
            bundleId: record.bundleId,
            displayName: record.displayName,
            path: record.path
        ) {
            throw CUError.policyDenied(reason: reason, app: request.app, tool: "wait_for")
        }

        // 2. Session existence (§18.7): an unknown/ended session → stale_revision with the
        //    read-side sentinel (provided: 0, current: null), matching a fallback action.
        guard context.sessionManager.currentRevision(forSession: request.sessionId) != nil,
              let session = context.sessionManager.session(id: request.sessionId),
              let pid = session.pid else {
            throw CUError.staleRevision(sessionId: request.sessionId, provided: 0, current: nil)
        }

        // 3. Window re-resolution by the session's bound WindowServer id (§18.7). The window
        //    identity is stable for the duration of the wait, so it is resolved once and the same
        //    element is re-walked each poll. No prior get_app_state (no bound window), or a window
        //    that has since closed, → window_not_found.
        guard let boundWindowId = context.windowGeometry(forSession: request.sessionId)?.windowId else {
            throw CUError.windowNotFound(app: request.app, windowId: nil)
        }
        let client = context.axClient
        let appElement = client.applicationElement(pid: pid)
        let resolution = try WindowResolution.resolve(
            appElement: appElement,
            pid: pid,
            app: request.app,
            explicitWindowId: boundWindowId,
            client: client
        )
        let windowElement = resolution.selection.axWindow

        // 4. Poll (§18.7): evaluate at least once, then ~150 ms between polls with a cancellation
        //    checkpoint (§17) at each boundary, until the conditions hold or the deadline expires.
        let start = SettleDetector.monotonicNow()
        let deadline = start + Double(request.timeoutMs) / 1000.0
        while true {
            try CancellationToken.checkpoint()
            let probe = LiveWaitForProbe(windowElement: windowElement, client: client)
            let evaluation = WaitFor.evaluate(conditions: request.conditions, mode: request.mode, probe: probe)
            let now = SettleDetector.monotonicNow()
            if evaluation.satisfied || now >= deadline {
                return result(request: request, evaluation: evaluation, elapsed: now - start)
            }
            // Sleep the poll interval but never overshoot the deadline meaningfully.
            Thread.sleep(forTimeInterval: min(pollInterval, max(0, deadline - now)))
        }
    }

    /// Assemble the wire result from the final evaluation (§18.7). `conditions` echoes each kind
    /// and its outcome in request order; `observed` carries the best-effort title/URL.
    private static func result(request: Request, evaluation: WaitFor.Evaluation, elapsed: TimeInterval) -> WaitForResult {
        let conditionResults = zip(request.conditions, evaluation.conditionResults).map {
            WaitForResult.ConditionResult(kind: $0.0.discriminant, satisfied: $0.1)
        }
        return WaitForResult(
            satisfied: evaluation.satisfied,
            elapsedMs: Int(max(0, (elapsed * 1000).rounded())),
            conditions: conditionResults,
            observed: WaitForResult.Observed(windowTitle: evaluation.observedTitle, url: evaluation.observedURL),
            refreshRecommended: true
        )
    }
}
