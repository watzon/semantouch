import Foundation
import ComputerUseCore
import AccessibilityEngine
import ActionEngine

/// Binds an `ActionExecutor` to this helper's live state (§13.2): it resolves the
/// target app for the mutation policy gate, reports a session's current revision, and
/// resolves an element id to a live `AXActionElement` through the session's stable
/// element table.
struct ServiceActionEnvironment: FallbackEnvironment {
    let context: ServiceContext
    let resolver: AppResolver

    /// Resolve `app` and return its mutation policy denial reason (§13.5), or `nil`
    /// when it may be mutated. Resolution failures propagate as typed `CUError`s.
    func policyCheck(app: String) throws -> PolicyDenyReason? {
        let record: AppRecord
        switch resolver.resolve(app) {
        case let .success(resolved): record = resolved
        case let .failure(error): throw error
        }
        return context.policyEngine.mutationDenialReason(
            bundleId: record.bundleId,
            displayName: record.displayName,
            path: record.path
        )
    }

    /// The session's current revision, or `nil` when the session is unknown/ended. Read
    /// through the locked accessor so it shares the SessionManager lock with
    /// `bumpRevision` (no bare `session.revision` dereference outside the lock).
    func currentRevision(sessionId: String) -> Int? {
        context.sessionManager.currentRevision(forSession: sessionId)
    }

    /// Whether the live session `sessionId` is owned by the same process the gated
    /// `app` resolves to (§13.5 confused-deputy guard). Binds on **pid** — the
    /// strongest, spelling-independent identity (a bundle id, display name, and
    /// `pid:<n>` for one running app all resolve to the same pid). A session with no
    /// pid, or a pid that differs from the resolved app's, is not owned by `app`.
    func sessionOwnedByApp(sessionId: String, app: String) throws -> Bool {
        guard let session = context.sessionManager.session(id: sessionId),
              let sessionPid = session.pid else {
            return false
        }
        let record: AppRecord
        switch resolver.resolve(app) {
        case let .success(resolved): record = resolved
        case let .failure(error): throw error
        }
        return record.pid == sessionPid
    }

    /// Resolve `elementId` in the session's current element table to a live element,
    /// or throw `stale_element`.
    func resolveElement(sessionId: String, elementId: String, revision: Int) throws -> ActionElement {
        let table = context.elementTable(forSession: sessionId)
        let handle = try table.resolve(elementId, sessionId: sessionId, revision: revision)
        guard let axHandle = handle as? AXElementHandle else {
            // The Phase-2 pipeline always stores AX-backed handles; anything else is a bug.
            throw CUError.internalError(detail: "resolved element handle is not AX-backed")
        }
        return AXActionElement(handle: axHandle, client: context.axClient)
    }

    // MARK: - FallbackEnvironment (Phase 4, §16)

    /// The target session's owning pid (the app the fallback input is meant for).
    func targetPID(sessionId: String) -> pid_t? {
        context.sessionManager.session(id: sessionId)?.pid
    }

    /// The session's last-captured window geometry (coordinate-mapping source).
    func windowGeometry(sessionId: String) -> WindowGeometry? {
        context.windowGeometry(forSession: sessionId)
    }

    /// The target window's CURRENT on-screen frame (coordinate-safety staleness source, §16.3),
    /// delegated to the context so the live `CGWindowListCopyWindowInfo` lookup stays
    /// injectable for contract tests.
    func currentWindowFrame(sessionId: String) -> Rect? {
        context.currentWindowFrame(forSession: sessionId)
    }

    var workspace: WorkspaceControlling { context.workspace }
    var synthesizer: InputSynthesizer { context.synthesizer }
    var interruption: InterruptionMonitoring { context.interruption }
}
