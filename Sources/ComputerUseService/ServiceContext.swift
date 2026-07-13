import Foundation
import ComputerUseCore
import AccessibilityEngine
import ActionEngine
import CaptureEngine
import CursorOverlay

/// Shared, process-lifetime state for the tool engines.
///
/// One `ServiceContext` is created per running helper (both the `mcp` server and the
/// CLI subcommands construct one). It owns the session registry, the per-session
/// stable element tables, a single `AXClient`, the mutation `PolicyEngine`, the
/// per-session `ActionExecutor`, the Phase-3 AX observer coordinator, and the
/// per-session tree-snapshot store used for diffs — so every tool observes a
/// consistent view. All access is serialized through the session manager's lock and
/// this class's own locks; the type is safe to share.
public final class ServiceContext: @unchecked Sendable {
    /// Session registry (§3): mints `s<N>` session ids and `e<N>` element ids.
    public let sessionManager: SessionManager

    /// The AX extraction client (impure; only touched by permission-gated paths).
    public let axClient: AXClient

    /// Application policy: an operator-configured denylist from
    /// `SEMANTOUCH_DENIED_APPS`, applied before reads and mutations.
    public let policyEngine: PolicyEngine

    /// Per-app-session serial executor for Phase 2 mutations (§13.6).
    public let actionExecutor: ActionExecutor

    /// App resolver used by the mutation policy gate. Injectable so contract tests can
    /// drive the gate deterministically without a live workspace.
    public let appResolver: AppResolver

    /// Phase-3 event-driven invalidation (§15.3): one AXObserver per observed app on a
    /// dedicated runloop thread, feeding an activity state the settle detector reads.
    public let observerCoordinator: AXObserverCoordinator

    /// Frozen settle timings (§15.3). Held here so a single tunable struct governs the
    /// whole helper.
    public let settleTimings: SettleDetector.Timings

    /// v1.5 (§18.1): whether web-content accessibility enablement is active. Default on;
    /// the operator disables the whole mechanism with `SEMANTOUCH_WEB_AX=off`.
    public let webAXEnabled: Bool

    /// Phase 4 (§16): the tagged CGEvent emitter for fallback input. Injectable so contract
    /// tests drive the pipeline with a recording fake (no real CGEvent is ever posted).
    public let synthesizer: InputSynthesizer

    /// Phase 4 (§16): foreground/focus control (record → activate → restore). Injectable so
    /// the interference decision is deterministic in tests (no live NSWorkspace).
    public let workspace: WorkspaceControlling

    /// The user-interruption monitor, armed around
    /// fallback delivery. Injectable; the live path is a `UserInterruptionMonitor` whose
    /// passive tap is started by `startInterruptionMonitor()`.
    public let interruption: InterruptionMonitoring

    /// The virtual cursor overlay controller. Best-effort and
    /// decorative — it NEVER fails or delays an action. Defaults to the fully-inert
    /// `disabled()` controller so CLI/tests/contract fixtures create no AppKit window; the
    /// `mcp` runtime injects the live `system()` controller (which itself no-ops when there
    /// is no active display).
    public let cursorController: CursorController

    /// Per-session stable element tables, keyed by session id. A session's table is
    /// created lazily on the first `get_app_state` and retired by `end_app_session`.
    private let tableLock = NSLock()
    private var tablesBySession: [String: StableElementTable] = [:]

    /// The last built tree snapshot per session, used to compute the next diff (§15).
    public struct TreeSnapshot: Sendable {
        public let revision: Int
        public let windowId: Int
        public let root: UINode
        /// Whether the rendered full text for this snapshot was truncated. A diff can
        /// only be built on a base the client received completely, so a truncated base
        /// forces the next snapshot to a full tree.
        public let truncated: Bool
        public init(revision: Int, windowId: Int, root: UINode, truncated: Bool) {
            self.revision = revision
            self.windowId = windowId
            self.root = root
            self.truncated = truncated
        }
    }
    private let snapshotLock = NSLock()
    private var snapshotsBySession: [String: TreeSnapshot] = [:]
    private var lineageBroken: Set<String> = []

    /// Per-session captured window geometry (§16): the mapping source for coordinate
    /// fallback actions. Set by `get_app_state`, cleared by `end_app_session`.
    private let geometryLock = NSLock()
    private var geometryBySession: [String: WindowGeometry] = [:]

    /// v1.5 (§18.1) web-AX bookkeeping. `webAXAttemptedSessions` are sessions whose enable
    /// attempt already ran without a fault (so it is not retried; a faulted write leaves the
    /// session absent so the next snapshot retries). `webAXFlippedBySession` records exactly
    /// the attributes THIS server flipped per session (with the owning pid), so
    /// `end_app_session`/shutdown reset only those — never a pre-existing `true`.
    private let webAXLock = NSLock()
    private var webAXAttemptedSessions: Set<String> = []
    private var webAXFlippedBySession: [String: (pid: pid_t, attributes: Set<String>)] = [:]

    public init(
        sessionManager: SessionManager = SessionManager(),
        axClient: AXClient = AXClient(),
        policyEngine: PolicyEngine = PolicyEngine.system(),
        actionExecutor: ActionExecutor = ActionExecutor(),
        appResolver: AppResolver = .system(),
        observerCoordinator: AXObserverCoordinator = AXObserverCoordinator(),
        settleTimings: SettleDetector.Timings = .default,
        synthesizer: InputSynthesizer = CGEventSynthesizer(),
        workspace: WorkspaceControlling = SystemWorkspace(),
        interruption: InterruptionMonitoring = UserInterruptionMonitor(),
        cursorController: CursorController = .disabled(),
        webAXEnabled: Bool = ServiceContext.webAXEnabledFromEnvironment()
    ) {
        self.sessionManager = sessionManager
        self.axClient = axClient
        self.policyEngine = policyEngine
        self.actionExecutor = actionExecutor
        self.appResolver = appResolver
        self.observerCoordinator = observerCoordinator
        self.settleTimings = settleTimings
        self.synthesizer = synthesizer
        self.workspace = workspace
        self.interruption = interruption
        self.cursorController = cursorController
        self.webAXEnabled = webAXEnabled
    }

    /// Whether web-content accessibility enablement is on for the process (§18.1). Enabled
    /// unless `SEMANTOUCH_WEB_AX=off` (case-insensitive), mirroring `SEMANTOUCH_CURSOR` parsing.
    public static func webAXEnabledFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        (environment["SEMANTOUCH_WEB_AX"] ?? "").lowercased() != "off"
    }

    /// Start the live user-interruption tap, if the injected monitor is the live one. A
    /// no-op for an injected fake/state. Called by the `mcp` runtime at startup.
    public func startInterruptionMonitor() {
        (interruption as? UserInterruptionMonitor)?.start()
    }

    /// Stop the live user-interruption tap, if any (process teardown).
    public func stopInterruptionMonitor() {
        (interruption as? UserInterruptionMonitor)?.shutdown()
    }

    // MARK: - Window geometry (coordinate fallback mapping)

    /// Store the session's captured window geometry as the coordinate-mapping source for
    /// fallback actions (§16).
    func storeWindowGeometry(_ geometry: WindowGeometry, forSession sessionId: String) {
        geometryLock.lock(); defer { geometryLock.unlock() }
        geometryBySession[sessionId] = geometry
    }

    /// The session's last-captured window geometry, if any.
    public func windowGeometry(forSession sessionId: String) -> WindowGeometry? {
        geometryLock.lock(); defer { geometryLock.unlock() }
        return geometryBySession[sessionId]
    }

    /// Test seam: override the live current-window-frame lookup so contract tests can supply a
    /// deterministic frame without a real WindowServer window. `nil` in production.
    var currentWindowFrameOverride: ((String) -> Rect?)?

    /// The target window's CURRENT on-screen global frame for a session — the coordinate-safety
    /// staleness source consulted before a coordinate fallback posts a pointer event (§16.3).
    /// Live path: match the captured WindowServer id AND the session's owning pid in the public
    /// `CGWindowListCopyWindowInfo` catalog (scalar bounds need no Screen Recording grant; the
    /// pid match guards against window-id reuse). Returns `nil` when that window is no longer
    /// on-screen (closed, minimized, or moved off-Space), so delivery is refused rather than
    /// posting a pointer event at a stale location.
    func currentWindowFrame(forSession sessionId: String) -> Rect? {
        if let currentWindowFrameOverride { return currentWindowFrameOverride(sessionId) }
        guard let geometry = windowGeometry(forSession: sessionId) else { return nil }
        let ownerPID = sessionManager.session(id: sessionId)?.pid
        let match = WindowCatalog.cgWindows(includeOffscreen: false).first {
            $0.windowNumber == geometry.windowId && (ownerPID == nil || $0.ownerPID == ownerPID)
        }
        return match?.bounds
    }

    /// Drop a session's geometry (called from `end_app_session`).
    func releaseWindowGeometry(forSession sessionId: String) {
        geometryLock.lock(); defer { geometryLock.unlock() }
        geometryBySession.removeValue(forKey: sessionId)
    }

    /// The `ActionEnvironment` binding this context to the executor (§13.2): policy
    /// resolution, session-revision lookup, and element resolution.
    public func actionEnvironment() -> ActionEnvironment {
        ServiceActionEnvironment(context: self, resolver: appResolver)
    }

    /// The `FallbackEnvironment` binding this context to the executor's Phase 4 path (§16):
    /// the same environment, plus the fallback seams (target pid, geometry, workspace,
    /// synthesizer, interruption).
    public func fallbackEnvironment() -> FallbackEnvironment {
        ServiceActionEnvironment(context: self, resolver: appResolver)
    }

    // MARK: - Element tables

    /// The stable element table for a session, creating one on first use.
    ///
    /// Phase 3 turns on cross-revision id reuse (§15.2): a matched element keeps its id
    /// across `get_app_state` snapshots so diffs can be computed against a stable id
    /// space. Reuse is gated by the structural fingerprint **and** a live-element check
    /// (§11), and a removed/replaced element's id is retired and never resurrected, so
    /// `stale_element` still fires for an id absent from the current revision. Ids
    /// remain monotonic and session-unique (§3).
    func elementTable(forSession sessionId: String) -> StableElementTable {
        tableLock.lock()
        defer { tableLock.unlock() }
        if let existing = tablesBySession[sessionId] { return existing }
        let table = StableElementTable(reuseAcrossPasses: true)
        tablesBySession[sessionId] = table
        return table
    }

    /// Drop a session's element table (called from `end_app_session`).
    func releaseElementTable(forSession sessionId: String) {
        tableLock.lock()
        defer { tableLock.unlock() }
        tablesBySession.removeValue(forKey: sessionId)
    }

    // MARK: - Web-content accessibility (§18.1)

    /// Whether the web-AX enable attempt already ran (without fault) for a session, so it is
    /// not re-attempted this snapshot.
    func webAXEnablementAttempted(forSession sessionId: String) -> Bool {
        webAXLock.lock(); defer { webAXLock.unlock() }
        return webAXAttemptedSessions.contains(sessionId)
    }

    /// Mark the web-AX enable attempt complete for a session (fault-free), so subsequent
    /// snapshots skip it (§18.1).
    func markWebAXEnablementAttempted(forSession sessionId: String) {
        webAXLock.lock(); defer { webAXLock.unlock() }
        webAXAttemptedSessions.insert(sessionId)
    }

    /// Record the attributes THIS server flipped `false`→`true` for a session (with the owning
    /// pid), so they — and only they — are reset on `end_app_session`/shutdown (§18.1).
    func recordWebAXFlipped(_ attributes: [String], pid: pid_t, forSession sessionId: String) {
        guard !attributes.isEmpty else { return }
        webAXLock.lock(); defer { webAXLock.unlock() }
        var entry = webAXFlippedBySession[sessionId] ?? (pid: pid, attributes: [])
        entry.pid = pid
        entry.attributes.formUnion(attributes)
        webAXFlippedBySession[sessionId] = entry
    }

    /// Reset (to `false`) exactly the web-AX attributes this server flipped for a session,
    /// then forget the session's web-AX bookkeeping (§18.1). Best-effort live AX write;
    /// per-attribute failures are silent. A no-op for a session that flipped nothing.
    func resetWebContentAccessibility(forSession sessionId: String) {
        webAXLock.lock()
        webAXAttemptedSessions.remove(sessionId)
        let entry = webAXFlippedBySession.removeValue(forKey: sessionId)
        webAXLock.unlock()
        guard let entry, !entry.attributes.isEmpty else { return }
        let element = axClient.applicationElement(pid: entry.pid)
        let seam = LiveWebAXAppElement(element: element, client: axClient)
        // Deterministic order over the canonical attribute list; never a pre-existing `true`.
        WebContentAccessibility.reset(
            seam,
            attributes: WebContentAccessibility.attributes.filter { entry.attributes.contains($0) }
        )
    }

    /// Reset every session's server-flipped web-AX attributes (process shutdown, §18.1).
    public func resetAllWebContentAccessibility() {
        webAXLock.lock()
        let sessionIds = Array(webAXFlippedBySession.keys)
        webAXLock.unlock()
        for sessionId in sessionIds {
            resetWebContentAccessibility(forSession: sessionId)
        }
    }

    // MARK: - Tree snapshots (diff base)

    /// The previous tree snapshot for a session, if any.
    func snapshot(forSession sessionId: String) -> TreeSnapshot? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshotsBySession[sessionId]
    }

    /// Store the current tree snapshot as the base for the next diff.
    func storeSnapshot(forSession sessionId: String, _ snapshot: TreeSnapshot) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        snapshotsBySession[sessionId] = snapshot
    }

    /// Whether the session's lineage broke (an observer signalled an event that
    /// invalidates incremental correlation). Consumed once by `get_app_state`.
    func isLineageBroken(forSession sessionId: String) -> Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return lineageBroken.contains(sessionId)
    }

    /// Mark a session's lineage broken so the next `get_app_state` returns a full tree
    /// with a `diff_reset` warning.
    func markLineageBroken(forSession sessionId: String) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        lineageBroken.insert(sessionId)
    }

    /// Clear the lineage-broken flag (after a full resync).
    func clearLineageBroken(forSession sessionId: String) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        lineageBroken.remove(sessionId)
    }

    /// Drop a session's snapshot + lineage state (called from `end_app_session`).
    func releaseSnapshot(forSession sessionId: String) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        snapshotsBySession.removeValue(forKey: sessionId)
        lineageBroken.remove(sessionId)
    }

    // MARK: - Dirty marking (mutations → settle)

    /// Mark a session dirty after a mutation so the next `get_app_state` settles before
    /// rebuilding (§15.3). Routes to the observer coordinator by the session's pid.
    public func markSessionDirty(sessionId: String) {
        guard let pid = sessionManager.session(id: sessionId)?.pid else { return }
        observerCoordinator.state.markDirty(pid: pid)
    }
}
