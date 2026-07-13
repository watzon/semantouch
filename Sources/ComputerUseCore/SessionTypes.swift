import Foundation

/// A live automation session for one resolved application (§3).
///
/// Sessions are created lazily by `get_app_state` and destroyed by
/// `end_app_session` or process exit. Element ids and the revision are scoped to a
/// single session and are meaningless across sessions. Mutable counters
/// (`revision`, element id) are only advanced by the owning `SessionManager` under
/// its lock, so callers observe consistent values.
public final class AppSession {
    /// Session id, `s<N>` (§3).
    public let sessionId: String
    /// The `AppSummary.id` of the resolved app (bundle id, path, or `pid:<pid>`).
    public let appId: String
    /// Owning process id, when the app is running.
    public let pid: Int32?
    /// When the session was created.
    public let createdAt: Date

    /// Current revision (§3). Phase 1 keeps this at 1.
    public internal(set) var revision: Int
    /// Next element-id counter for this session; `e<N>` ids are minted from it.
    internal var nextElementCounter: Int

    internal init(sessionId: String, appId: String, pid: Int32?, createdAt: Date = Date()) {
        self.sessionId = sessionId
        self.appId = appId
        self.pid = pid
        self.createdAt = createdAt
        self.revision = 1
        self.nextElementCounter = 1
    }
}

/// Thread-safe registry of `AppSession`s (§3).
///
/// - Session ids (`s<N>`) come from a per-process monotonic counter starting at 1.
/// - Element ids (`e<N>`) come from a per-session monotonic counter starting at 1.
/// - Neither is reused within its scope.
///
/// All state is guarded by a single lock; the class is safe to share.
public final class SessionManager: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: AppSession] = [:]
    private var sessionIdByAppId: [String: String] = [:]
    private var nextSessionCounter = 1

    public init() {}

    /// Return the existing session for `appId`, or create one. A given `appId` maps
    /// to at most one live session at a time.
    @discardableResult
    public func ensureSession(appId: String, pid: Int32? = nil) -> AppSession {
        lock.lock()
        defer { lock.unlock() }
        if let existingId = sessionIdByAppId[appId], let existing = sessions[existingId] {
            return existing
        }
        let session = AppSession(sessionId: "s\(nextSessionCounter)", appId: appId, pid: pid)
        nextSessionCounter += 1
        sessions[session.sessionId] = session
        sessionIdByAppId[appId] = session.sessionId
        return session
    }

    /// Look up a session by its id.
    public func session(id: String) -> AppSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    /// Look up the live session for an `appId`, if any.
    public func session(forAppId appId: String) -> AppSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = sessionIdByAppId[appId] else { return nil }
        return sessions[id]
    }

    /// Mint the next element id for a session. Returns `nil` for an unknown session.
    public func nextElementId(forSession sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionId] else { return nil }
        let value = session.nextElementCounter
        session.nextElementCounter += 1
        return "e\(value)"
    }

    /// The session's current revision read **under the lock**, or `nil` for an unknown
    /// session. Every read of the field must go through here (never a bare
    /// `session.revision` dereference) so reads and `bumpRevision` writes share the same
    /// lock and the type's stated thread-safety actually holds (SessionTypes doc, §3).
    public func currentRevision(forSession sessionId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sessionId]?.revision
    }

    /// Advance and return the revision for a session (Phase 3+). Returns `nil` for
    /// an unknown session.
    @discardableResult
    public func bumpRevision(forSession sessionId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionId] else { return nil }
        session.revision += 1
        return session.revision
    }

    /// End a session and release its element/observer scope. Returns `false` for an
    /// unknown session (not an error per §4.1).
    @discardableResult
    public func endSession(id sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions.removeValue(forKey: sessionId) else { return false }
        if sessionIdByAppId[session.appId] == sessionId {
            sessionIdByAppId.removeValue(forKey: session.appId)
        }
        return true
    }

    /// Snapshot of the live session ids (diagnostics).
    public var activeSessionIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.keys.sorted()
    }
}
