import Foundation
import ApplicationServices
import ComputerUseCore
import AccessibilityEngine
import MCPServer

/// The read-only `read_text` tool: return the live `AXValue` **string** of one
/// revision-checked element, optionally truncated to a UTF-8 byte budget.
///
/// Processing order:
/// 1. read-side app policy gate (§13.5)
/// 2. session existence (unknown/ended → `stale_revision`, `current: null`)
/// 3. confused-deputy ownership guard (session pid must match resolved app)
/// 4. exact revision match
/// 5. stable element resolve (`stale_element` when unknown/dead)
/// 6. require a live AX-backed handle
/// 7. reject `AXSecureTextField` by role **or** subrole **before** any value read
/// 8. copy raw `AXValue` and require an actual `String` (no NSNumber coercion)
/// 9. apply the caller's limit on an extended-grapheme / UTF-8 boundary
///
/// Never advances the revision, never mutates the element table, never rebuilds a tree.
enum ReadTextService {
    /// Secure-field role/subrole token rejected before any value is copied.
    static let secureTextFieldRole = "AXSecureTextField"

    // MARK: - Run

    /// Execute `read_text` to a `ReadTextResult`. Throws a typed `CUError` for every gate
    /// and for non-string / secure-field failures.
    static func run(_ request: ReadTextRequest, context: ServiceContext) throws -> ReadTextResult {
        // 1. Read-side app policy gate (§13.5).
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
            throw CUError.policyDenied(reason: reason, app: request.app, tool: "read_text")
        }

        // 2. Session existence.
        guard let current = context.sessionManager.currentRevision(forSession: request.sessionId),
              let session = context.sessionManager.session(id: request.sessionId),
              session.pid != nil else {
            throw CUError.staleRevision(
                sessionId: request.sessionId,
                provided: request.revision,
                current: nil
            )
        }

        // 3. Confused-deputy ownership guard (session must belong to the gated app).
        guard try sessionOwnedByApp(
            sessionId: request.sessionId,
            app: request.app,
            context: context
        ) else {
            throw CUError.policyDenied(reason: .appDenied, app: request.app, tool: "read_text")
        }

        // 4. Exact revision match.
        guard current == request.revision else {
            throw CUError.staleRevision(
                sessionId: request.sessionId,
                provided: request.revision,
                current: current
            )
        }

        // 5. Stable element resolve (throws stale_element when unknown/dead).
        let handle = try context.elementTable(forSession: request.sessionId)
            .resolve(request.elementId, sessionId: request.sessionId, revision: request.revision)

        // 6. Require a live AX-backed handle.
        guard let axHandle = handle as? AXElementHandle else {
            throw CUError.internalError(detail: "resolved element handle is not AX-backed")
        }

        let client = context.axClient
        let element = axHandle.element

        // 7. Reject secure text fields by role or subrole BEFORE any value read.
        let role = client.role(of: element)
        let subrole = client.subrole(of: element)
        try rejectSecureField(role: role, subrole: subrole, elementId: request.elementId)

        // 8. Copy raw AXValue; require an actual String (no number/bool coercion).
        let text = try requireStringAXValue(
            of: element,
            client: client,
            elementId: request.elementId
        )

        // 9. Apply limit on Character / UTF-8 boundaries. No session mutation.
        return applyLimit(text, limit: request.limit)
    }

    // MARK: - Pure helpers (unit-tested)

    /// Whether `role` or `subrole` identifies a secure text field.
    static func isSecureTextField(role: String?, subrole: String?) -> Bool {
        role == secureTextFieldRole || subrole == secureTextFieldRole
    }

    /// Throw `unsupported_action` when the element is a secure text field.
    static func rejectSecureField(role: String?, subrole: String?, elementId: String) throws {
        guard isSecureTextField(role: role, subrole: subrole) else { return }
        throw CUError.unsupportedAction(
            elementId: elementId,
            action: nil,
            supported: [],
            reason: "Reading AXValue from a secure text field is not allowed."
        )
    }

    /// Live `AXValue` classification used by the pure value gate (and tests).
    enum LiveValue: Equatable {
        case string(String)
        case absent
        case nonString
    }

    /// Require a live string value; absent / non-string → `unsupported_action`.
    static func requireStringValue(_ value: LiveValue, elementId: String) throws -> String {
        switch value {
        case let .string(text):
            return text
        case .absent:
            throw CUError.unsupportedAction(
                elementId: elementId,
                action: nil,
                supported: [],
                reason: "Element has no AXValue string."
            )
        case .nonString:
            throw CUError.unsupportedAction(
                elementId: elementId,
                action: nil,
                supported: [],
                reason: "AXValue is not a string."
            )
        }
    }

    /// Apply `limit` to `text`. Truncation never splits a Swift `Character`
    /// (extended grapheme cluster) and never splits a multi-byte UTF-8 sequence
    /// (because whole Characters are accumulated).
    static func applyLimit(_ text: String, limit: ReadTextLimit) -> ReadTextResult {
        let totalBytes = text.utf8.count
        switch limit {
        case .max:
            return ReadTextResult(
                text: text,
                totalBytes: totalBytes,
                returnedBytes: totalBytes,
                truncated: false
            )
        case let .bytes(budget):
            if totalBytes <= budget {
                return ReadTextResult(
                    text: text,
                    totalBytes: totalBytes,
                    returnedBytes: totalBytes,
                    truncated: false
                )
            }
            var out = ""
            var used = 0
            for character in text {
                let piece = String(character)
                let cost = piece.utf8.count
                if used + cost > budget { break }
                out += piece
                used += cost
            }
            return ReadTextResult(
                text: out,
                totalBytes: totalBytes,
                returnedBytes: used,
                truncated: true
            )
        }
    }

    // MARK: - Private

    private static func sessionOwnedByApp(
        sessionId: String,
        app: String,
        context: ServiceContext
    ) throws -> Bool {
        guard let session = context.sessionManager.session(id: sessionId),
              let sessionPid = session.pid else {
            return false
        }
        let record: AppRecord
        switch context.appResolver.resolve(app) {
        case let .success(resolved): record = resolved
        case let .failure(error): throw error
        }
        return record.pid == sessionPid
    }

    /// Copy `AXValue` and require a real `String` (no NSNumber / CFBoolean coercion).
    private static func requireStringAXValue(
        of element: AXUIElement,
        client: AXClient,
        elementId: String
    ) throws -> String {
        let live: LiveValue
        do {
            guard let raw = try client.copyAttribute(element, "AXValue") else {
                live = .absent
                return try requireStringValue(live, elementId: elementId)
            }
            if let string = raw as? String {
                live = .string(string)
            } else {
                live = .nonString
            }
        } catch {
            // A genuine AX fault is not "absent"; surface as internal so the client
            // distinguishes unreadable hardware faults from a missing string value.
            throw CUError.internalError(detail: "failed to read AXValue: \(error)")
        }
        return try requireStringValue(live, elementId: elementId)
    }
}
