import Foundation

/// The frozen set of tool-level error codes (§6). Every code the protocol defines
/// has exactly one case here. `rawValue` is the on-the-wire string.
public enum CUErrorCode: String, Codable, Equatable, Sendable, CaseIterable {
    case permissionDenied = "permission_denied"
    case appNotFound = "app_not_found"
    case ambiguousApp = "ambiguous_app"
    case windowNotFound = "window_not_found"
    case ambiguousWindow = "ambiguous_window"
    case uncorrelatedWindow = "uncorrelated_window"
    case uncapturableWindow = "uncapturable_window"
    case staleRevision = "stale_revision"
    case staleElement = "stale_element"
    case unsupportedAction = "unsupported_action"
    case focusRequired = "focus_required"
    case userInterrupted = "user_interrupted"
    case policyDenied = "policy_denied"
    case timeout = "timeout"
    case cancelled = "cancelled"
    case internalError = "internal_error"
}

/// A tool-level failure (§6). Delivered inside a successful `tools/call` result as
/// `{ "content": [{ "type": "text", "text": <JSON> }], "isError": true }`, where
/// `<JSON>` is this value encoded to the exact wire shape `{ code, message, data? }`.
///
/// Each case carries exactly the structured `data` payload the protocol requires
/// for that code. `message` is derived deterministically from the case so the wire
/// output is stable. Cases whose `data` is entirely optional (`user_interrupted`,
/// `internal_error`) omit the `data` object when they carry nothing.
public enum CUError: Error, Equatable, Sendable {
    case permissionDenied(permission: Permission, helperPath: String, remediation: [String])
    case appNotFound(query: String)
    case ambiguousApp(query: String, candidates: [AppSummary])
    case windowNotFound(app: String, windowId: Int?)
    case ambiguousWindow(app: String, candidates: [WindowRef])
    case uncorrelatedWindow(app: String, ax: WindowRef?, sc: WindowRef?, signalsTried: [String])
    case uncapturableWindow(app: String, windowId: Int, reason: UncapturableReason)
    /// `current` is the session's current revision, or `nil` (wire `null`) when the
    /// session is unknown or ended (v1.1 §13.2).
    case staleRevision(sessionId: String, provided: Int, current: Int?)
    case staleElement(sessionId: String, elementId: String, revision: Int)
    /// `reason` (v1.1 §13.3) is an optional human-readable explanation of why no
    /// mechanism applied; omitted from the wire when `nil`.
    case unsupportedAction(elementId: String, action: String?, supported: [String], reason: String?)
    /// Phase 4 (§16): a fallback action under `background-only` needs the target to be
    /// frontmost to deliver input safely, but it is not. `frontmostApp` is the app that
    /// currently holds the foreground (the one the input would otherwise hit). The
    /// caller must retry with `allow-brief-focus` or `foreground-takeover`.
    case focusRequired(app: String?, frontmostApp: String?)
    case userInterrupted(at: String?)
    case policyDenied(reason: PolicyDenyReason, app: String?, tool: String?)
    case timeout(operation: String, deadlineMs: Int)
    /// Phase 1 / v1.4 (§17): the client cancelled the in-flight request (`notifications/
    /// cancelled`), or the process is shutting down (stdin EOF / SIGTERM). The optional
    /// `reason` echoes the notification's `reason` when supplied; omitted from the wire
    /// when `nil`.
    case cancelled(reason: String?)
    case internalError(detail: String?)
}

// MARK: - Code + message

public extension CUError {
    /// The wire error code for this case.
    var code: CUErrorCode {
        switch self {
        case .permissionDenied: return .permissionDenied
        case .appNotFound: return .appNotFound
        case .ambiguousApp: return .ambiguousApp
        case .windowNotFound: return .windowNotFound
        case .ambiguousWindow: return .ambiguousWindow
        case .uncorrelatedWindow: return .uncorrelatedWindow
        case .uncapturableWindow: return .uncapturableWindow
        case .staleRevision: return .staleRevision
        case .staleElement: return .staleElement
        case .unsupportedAction: return .unsupportedAction
        case .focusRequired: return .focusRequired
        case .userInterrupted: return .userInterrupted
        case .policyDenied: return .policyDenied
        case .timeout: return .timeout
        case .cancelled: return .cancelled
        case .internalError: return .internalError
        }
    }

    /// A deterministic, human-readable message derived from the case payload.
    var message: String {
        switch self {
        case let .permissionDenied(permission, _, _):
            return "The \(permission.rawValue) permission is required but not granted."
        case let .appNotFound(query):
            return "No application matched \"\(query)\"."
        case let .ambiguousApp(query, candidates):
            return "\"\(query)\" matched \(candidates.count) applications; disambiguate with a bundle id or path."
        case let .windowNotFound(app, windowId):
            if let windowId {
                return "Window \(windowId) was not found for \"\(app)\". windowId is a WindowServer id from get_app_state.window.id, not the list_apps window count or an ordinal; omit windowId or pass 0 to auto-select."
            }
            return "\"\(app)\" exposes no capturable window."
        case let .ambiguousWindow(app, candidates):
            return "\(candidates.count) windows equally satisfy the selection for \"\(app)\"."
        case let .uncorrelatedWindow(app, _, _, _):
            return "Could not correlate the AX and ScreenCaptureKit windows for \"\(app)\"."
        case let .uncapturableWindow(app, windowId, reason):
            return "Window \(windowId) of \"\(app)\" is not capturable (\(reason.rawValue))."
        case let .staleRevision(_, provided, current):
            guard let current else {
                return "Revision \(provided) is stale; the session is unknown or has ended. Refresh with get_app_state."
            }
            return "Revision \(provided) is stale; the current session revision is \(current). Refresh with get_app_state."
        case let .staleElement(_, elementId, revision):
            return "Element \(elementId) does not resolve in revision \(revision). Refresh with get_app_state."
        case let .unsupportedAction(elementId, action, _, reason):
            if let reason {
                return reason
            }
            if let action {
                return "Element \(elementId) does not expose the action \"\(action)\"."
            }
            return "Element \(elementId) does not expose the requested action or attribute."
        case let .focusRequired(_, frontmostApp):
            let front = frontmostApp.map { " (frontmost app is \"\($0)\")" } ?? ""
            return "Delivering this input under background-only requires the target to be frontmost, but it is not\(front). Retry with interference \"allow-brief-focus\" or \"foreground-takeover\"."
        case .userInterrupted:
            return "The action was interrupted by user input."
        case let .policyDenied(reason, _, _):
            return "The request was denied by policy (\(reason.rawValue))."
        case let .timeout(operation, deadlineMs):
            return "Operation \"\(operation)\" exceeded its deadline of \(deadlineMs) ms."
        case let .cancelled(reason):
            if let reason {
                return "The request was cancelled (\(reason))."
            }
            return "The request was cancelled before it completed."
        case let .internalError(detail):
            if let detail {
                return "Internal error: \(detail)"
            }
            return "An internal error occurred."
        }
    }

    /// Encode this error to its canonical wire JSON string `{ code, message, data? }`.
    func jsonString() throws -> String {
        try CanonicalJSON.encodeToString(self)
    }
}

extension CUError: LocalizedError {
    public var errorDescription: String? { message }
}

// MARK: - Codable (exact wire shape)

extension CUError: Codable {
    private enum TopKeys: String, CodingKey {
        case code, message, data
    }

    /// Union of every field name any error's `data` object can contain. Each case
    /// only writes the subset the protocol specifies for it.
    private enum DataKeys: String, CodingKey {
        case permission, helperPath, remediation
        case query, candidates
        case app, windowId, frontmostApp
        case ax, sc, signalsTried
        case reason
        case sessionId, provided, current
        case elementId, revision
        case action, supported
        case at
        case tool
        case operation, deadlineMs
        case detail
    }

    public func encode(to encoder: Encoder) throws {
        var top = encoder.container(keyedBy: TopKeys.self)
        try top.encode(code, forKey: .code)
        try top.encode(message, forKey: .message)

        switch self {
        case let .permissionDenied(permission, helperPath, remediation):
            var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            try data.encode(permission, forKey: .permission)
            try data.encode(helperPath, forKey: .helperPath)
            try data.encode(remediation, forKey: .remediation)

        case let .appNotFound(query):
            var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            try data.encode(query, forKey: .query)

        case let .ambiguousApp(query, candidates):
            var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            try data.encode(query, forKey: .query)
            try data.encode(candidates, forKey: .candidates)

        case let .windowNotFound(app, windowId):
            var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            try data.encode(app, forKey: .app)
            try data.encodeIfPresent(windowId, forKey: .windowId)

        case let .ambiguousWindow(app, candidates):
            var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            try data.encode(app, forKey: .app)
            try data.encode(candidates, forKey: .candidates)

        case let .uncorrelatedWindow(app, ax, sc, signalsTried):
            var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            try data.encode(app, forKey: .app)
            try data.encodeIfPresent(ax, forKey: .ax)
            try data.encodeIfPresent(sc, forKey: .sc)
            try data.encode(signalsTried, forKey: .signalsTried)

        case let .uncapturableWindow(app, windowId, reason):
            var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            try data.encode(app, forKey: .app)
            try data.encode(windowId, forKey: .windowId)
            try data.encode(reason, forKey: .reason)

        case let .staleRevision(sessionId, provided, current):
            var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            try data.encode(sessionId, forKey: .sessionId)
            try data.encode(provided, forKey: .provided)
            // `current` is always emitted; `null` when the session is unknown/ended.
            if let current {
                try data.encode(current, forKey: .current)
            } else {
                try data.encodeNil(forKey: .current)
            }

        case let .staleElement(sessionId, elementId, revision):
            var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            try data.encode(sessionId, forKey: .sessionId)
            try data.encode(elementId, forKey: .elementId)
            try data.encode(revision, forKey: .revision)

        case let .unsupportedAction(elementId, action, supported, reason):
            var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            try data.encode(elementId, forKey: .elementId)
            try data.encodeIfPresent(action, forKey: .action)
            try data.encode(supported, forKey: .supported)
            try data.encodeIfPresent(reason, forKey: .reason)

        case let .focusRequired(app, frontmostApp):
            // Emit a `data` object only when at least one field is present, so an
            // entirely-empty payload omits `data` (consistent with the optional-only cases).
            if app != nil || frontmostApp != nil {
                var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
                try data.encodeIfPresent(app, forKey: .app)
                try data.encodeIfPresent(frontmostApp, forKey: .frontmostApp)
            }

        case let .userInterrupted(at):
            if let at {
                var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
                try data.encode(at, forKey: .at)
            }

        case let .policyDenied(reason, app, tool):
            var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            try data.encode(reason, forKey: .reason)
            try data.encodeIfPresent(app, forKey: .app)
            try data.encodeIfPresent(tool, forKey: .tool)

        case let .timeout(operation, deadlineMs):
            var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            try data.encode(operation, forKey: .operation)
            try data.encode(deadlineMs, forKey: .deadlineMs)

        case let .cancelled(reason):
            // Emit a `data` object only when a reason is present, so a bare cancellation
            // omits `data` (consistent with the other optional-only cases).
            if let reason {
                var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
                try data.encode(reason, forKey: .reason)
            }

        case let .internalError(detail):
            if let detail {
                var data = top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
                try data.encode(detail, forKey: .detail)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let top = try decoder.container(keyedBy: TopKeys.self)
        let code = try top.decode(CUErrorCode.self, forKey: .code)
        // `message` is regenerated from the payload, so it is not read back.
        let data = try? top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)

        func requireData() throws -> KeyedDecodingContainer<DataKeys> {
            try top.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
        }

        switch code {
        case .permissionDenied:
            let d = try requireData()
            self = .permissionDenied(
                permission: try d.decode(Permission.self, forKey: .permission),
                helperPath: try d.decode(String.self, forKey: .helperPath),
                remediation: try d.decode([String].self, forKey: .remediation)
            )
        case .appNotFound:
            let d = try requireData()
            self = .appNotFound(query: try d.decode(String.self, forKey: .query))
        case .ambiguousApp:
            let d = try requireData()
            self = .ambiguousApp(
                query: try d.decode(String.self, forKey: .query),
                candidates: try d.decode([AppSummary].self, forKey: .candidates)
            )
        case .windowNotFound:
            let d = try requireData()
            self = .windowNotFound(
                app: try d.decode(String.self, forKey: .app),
                windowId: try d.decodeIfPresent(Int.self, forKey: .windowId)
            )
        case .ambiguousWindow:
            let d = try requireData()
            self = .ambiguousWindow(
                app: try d.decode(String.self, forKey: .app),
                candidates: try d.decode([WindowRef].self, forKey: .candidates)
            )
        case .uncorrelatedWindow:
            let d = try requireData()
            self = .uncorrelatedWindow(
                app: try d.decode(String.self, forKey: .app),
                ax: try d.decodeIfPresent(WindowRef.self, forKey: .ax),
                sc: try d.decodeIfPresent(WindowRef.self, forKey: .sc),
                signalsTried: try d.decode([String].self, forKey: .signalsTried)
            )
        case .uncapturableWindow:
            let d = try requireData()
            self = .uncapturableWindow(
                app: try d.decode(String.self, forKey: .app),
                windowId: try d.decode(Int.self, forKey: .windowId),
                reason: try d.decode(UncapturableReason.self, forKey: .reason)
            )
        case .staleRevision:
            let d = try requireData()
            self = .staleRevision(
                sessionId: try d.decode(String.self, forKey: .sessionId),
                provided: try d.decode(Int.self, forKey: .provided),
                current: try d.decodeIfPresent(Int.self, forKey: .current)
            )
        case .staleElement:
            let d = try requireData()
            self = .staleElement(
                sessionId: try d.decode(String.self, forKey: .sessionId),
                elementId: try d.decode(String.self, forKey: .elementId),
                revision: try d.decode(Int.self, forKey: .revision)
            )
        case .unsupportedAction:
            let d = try requireData()
            self = .unsupportedAction(
                elementId: try d.decode(String.self, forKey: .elementId),
                action: try d.decodeIfPresent(String.self, forKey: .action),
                supported: try d.decode([String].self, forKey: .supported),
                reason: try d.decodeIfPresent(String.self, forKey: .reason)
            )
        case .focusRequired:
            self = .focusRequired(
                app: try data?.decodeIfPresent(String.self, forKey: .app) ?? nil,
                frontmostApp: try data?.decodeIfPresent(String.self, forKey: .frontmostApp) ?? nil
            )
        case .userInterrupted:
            self = .userInterrupted(at: try data?.decodeIfPresent(String.self, forKey: .at) ?? nil)
        case .policyDenied:
            let d = try requireData()
            self = .policyDenied(
                reason: try d.decode(PolicyDenyReason.self, forKey: .reason),
                app: try d.decodeIfPresent(String.self, forKey: .app),
                tool: try d.decodeIfPresent(String.self, forKey: .tool)
            )
        case .timeout:
            let d = try requireData()
            self = .timeout(
                operation: try d.decode(String.self, forKey: .operation),
                deadlineMs: try d.decode(Int.self, forKey: .deadlineMs)
            )
        case .cancelled:
            self = .cancelled(reason: try data?.decodeIfPresent(String.self, forKey: .reason) ?? nil)
        case .internalError:
            self = .internalError(detail: try data?.decodeIfPresent(String.self, forKey: .detail) ?? nil)
        }
    }
}
