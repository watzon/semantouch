import Foundation

// MARK: - Shared string enums (frozen wire vocabularies)

/// macOS permission grant state for `doctor` / `permission_denied` (§4.1, §6).
public enum PermissionStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case granted
    case denied
    case unknown
}

/// Which macOS grant an error refers to (§6 `permission_denied.data.permission`).
public enum Permission: String, Codable, Equatable, Sendable, CaseIterable {
    case accessibility
    case screenRecording
}

/// `get_app_state.includeScreenshot` (§4.1).
public enum ScreenshotMode: String, Codable, Equatable, Sendable, CaseIterable {
    case auto
    case always
    case never
}

/// `ActionResult.status` (§4.4).
public enum ActionStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case completed
    case rejected
    case interrupted
}

/// `ActionResult.method` (§4.4).
public enum ActionMethod: String, Codable, Equatable, Sendable, CaseIterable {
    case accessibility
    case keyboard
    case pointer
}

/// Origin of a `WindowRef` in error payloads (§6).
public enum WindowSource: String, Codable, Equatable, Sendable, CaseIterable {
    case ax
    case screencapturekit
}

/// `uncapturable_window.data.reason` (§6).
public enum UncapturableReason: String, Codable, Equatable, Sendable, CaseIterable {
    case minimized
    case offscreen
    case protected
    case stale
    case unsupportedSurface = "unsupported_surface"
}

/// `policy_denied.data.reason` (§6).
public enum PolicyDenyReason: String, Codable, Equatable, Sendable, CaseIterable {
    case toolDisabled = "tool_disabled"
    case appDenied = "app_denied"
    case recursiveControl = "recursive_control"
    case actionConfirmationRequired = "action_confirmation_required"
}

/// Frozen `StateWarning.code` set (§4.1). Stored on the wire as a plain string;
/// this enum is the canonical vocabulary and warning-factory key.
public enum StateWarningCode: String, Codable, Equatable, Sendable, CaseIterable {
    case truncatedTree = "truncated_tree"
    case screenshotOmitted = "screenshot_omitted"
    case screenshotUnavailable = "screenshot_unavailable"
    case possiblyUnsettled = "possibly_unsettled" // Phase 3+
    case lowCorrelationConfidence = "low_correlation_confidence"
    case diffReset = "diff_reset" // Phase 3: lineage broke, a full tree was returned
    case webContentEnabled = "web_content_enabled" // v1.5 §18.1: web-AX just enabled this snapshot
    case scopeIgnored = "scope_ignored" // v1.5 §18.2: unhonorable scopeElementId degraded to a full unscoped snapshot
}

// MARK: - AppSummary (list_apps, get_app_state, ambiguous_app candidates)

/// One application as reported by `list_apps` / `launch_app` and embedded in
/// `AppState`/errors (§4.1).
///
/// `id` is the bundle id when available, else the absolute `.app` path, else
/// `"pid:<pid>"`. `pid`/`path`/`lastUsedAt`/`useCount` are optional and omit-when-nil
/// on the wire. `lastUsedAt` / `useCount` are populated from public Spotlight metadata
/// when available.
public struct AppSummary: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var path: String?
    public var pid: Int?
    public var isRunning: Bool
    public var windows: Int
    public var lastUsedAt: String?
    /// Spotlight-derived use rank when available; omitted when unknown.
    public var useCount: Int?

    public init(
        id: String,
        displayName: String,
        path: String? = nil,
        pid: Int? = nil,
        isRunning: Bool,
        windows: Int,
        lastUsedAt: String? = nil,
        useCount: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.pid = pid
        self.isRunning = isRunning
        self.windows = windows
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
    }
}

/// `list_apps` result payload: `{ "apps": AppSummary[] }` (§4.1).
public struct ListAppsResult: Codable, Equatable, Sendable {
    public var apps: [AppSummary]

    public init(apps: [AppSummary]) {
        self.apps = apps
    }
}

// MARK: - LaunchApp (launch_app input/output)

/// Decoded `launch_app` params. Custom `Decodable` applies protocol defaults
/// (`activate=true`, `waitForWindowMs=3000`) for missing keys.
///
/// Explicit lifecycle tool only: ordinary app resolution must never silently launch
/// or recover a hidden/minimized app. No `SnapshotOptions` — this is not an action
/// with post-mutation state attachment.
public struct LaunchAppRequest: Codable, Equatable, Sendable {
    public var app: String
    /// Whether to activate (bring forward) the app after launch/recovery. Default `true`.
    public var activate: Bool
    /// Bound, in milliseconds, on waiting for a first capturable window after launch
    /// or recovery. Default `3000`.
    public var waitForWindowMs: Int

    public init(app: String, activate: Bool = true, waitForWindowMs: Int = 3000) {
        self.app = app
        self.activate = activate
        self.waitForWindowMs = waitForWindowMs
    }

    private enum CodingKeys: String, CodingKey {
        case app, activate, waitForWindowMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.app = try container.decode(String.self, forKey: .app)
        self.activate = try container.decodeIfPresent(Bool.self, forKey: .activate) ?? true
        self.waitForWindowMs = try container.decodeIfPresent(Int.self, forKey: .waitForWindowMs) ?? 3000
    }
}

/// `launch_app` result payload: `{ "app": AppSummary, "launched": Bool, "recovered": Bool }`.
///
/// `launched` is true when this call started a not-yet-running process.
/// `recovered` is true when this call unhid/unminimized an already-running app
/// (or otherwise recovered a hidden window surface). Both may be false when the
/// app was already running and visible and only activation was applied.
public struct LaunchAppResult: Codable, Equatable, Sendable {
    public var app: AppSummary
    public var launched: Bool
    public var recovered: Bool

    public init(app: AppSummary, launched: Bool, recovered: Bool) {
        self.app = app
        self.launched = launched
        self.recovered = recovered
    }
}

/// `end_app_session` result payload: `{ "sessionId": "s1", "ended": true }` (§4.1).
public struct EndSessionResult: Codable, Equatable, Sendable {
    public var sessionId: String
    public var ended: Bool

    public init(sessionId: String, ended: Bool) {
        self.sessionId = sessionId
        self.ended = ended
    }
}

// MARK: - DoctorResult (doctor, §4.1)

public struct DoctorResult: Codable, Equatable, Sendable {
    /// The exact helper binary the OS grants are checked against.
    public struct HelperInfo: Codable, Equatable, Sendable {
        public var path: String
        public var signed: Bool
        public var version: String

        public init(path: String, signed: Bool, version: String) {
            self.path = path
            self.signed = signed
            self.version = version
        }
    }

    public var helper: HelperInfo
    public var accessibility: PermissionStatus
    public var screenRecording: PermissionStatus
    public var ready: Bool
    /// Exact remediation steps; each step names the binary at `helper.path`.
    public var remediation: [String]

    public init(
        helper: HelperInfo,
        accessibility: PermissionStatus,
        screenRecording: PermissionStatus,
        ready: Bool,
        remediation: [String]
    ) {
        self.helper = helper
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.ready = ready
        self.remediation = remediation
    }
}

// MARK: - SnapshotOptions (shared observation options)

/// Shared observation options for `get_app_state` and post-action state refresh.
/// Defaults match `get_app_state` (`forceFullTree=false`, `disableDiff=false`,
/// `includeScreenshot="auto"`). Decoded from flat tool arguments — unknown keys
/// (e.g. action fields) are ignored by Codable; schemas still enforce
/// `additionalProperties: false` at the wire boundary.
///
/// `forceFullTree` and `disableDiff` are both diff-suppression switches (§15.1): either
/// one forces a full tree for that snapshot, and the server treats a full tree they
/// request as **deliberate**, so it carries no `diff_reset` warning (that warning is
/// reserved for lineage that broke unexpectedly). They differ in one respect:
/// `forceFullTree` also **rebuilds ids** (the session's element table is retired so every
/// element is re-minted a fresh id), whereas `disableDiff` keeps ids stable and only
/// re-sends the whole tree text. Both leave the monotonic id counter intact (§3).
public struct SnapshotOptions: Codable, Equatable, Sendable {
    /// A positive WindowServer id. `nil` or the null WindowServer id `0` requests automatic selection.
    public var windowId: Int?
    public var forceFullTree: Bool
    public var disableDiff: Bool
    public var includeScreenshot: ScreenshotMode
    /// Root the walk at an element of the session's **current** snapshot instead of the
    /// window (`^e[0-9]+$`). `nil` requests an ordinary whole-window snapshot.
    public var scopeElementId: String?
    /// Per-snapshot node budget overriding the §7.5 default (600). Clamped to the frozen
    /// hard ceiling `1...2000` by the pipeline; `nil` uses the default.
    public var maxNodes: Int?

    public init(
        windowId: Int? = nil,
        forceFullTree: Bool = false,
        disableDiff: Bool = false,
        includeScreenshot: ScreenshotMode = .auto,
        scopeElementId: String? = nil,
        maxNodes: Int? = nil
    ) {
        self.windowId = windowId == 0 ? nil : windowId
        self.forceFullTree = forceFullTree
        self.disableDiff = disableDiff
        self.includeScreenshot = includeScreenshot
        self.scopeElementId = scopeElementId
        self.maxNodes = maxNodes
    }

    /// Whether this request suppresses the diff and demands a full tree (§15.1).
    public var suppressesDiff: Bool { forceFullTree || disableDiff }

    /// Whether this is a scoped snapshot (§18.2): rooted at an element, always full,
    /// never a diff base.
    public var isScoped: Bool { scopeElementId != nil }

    /// Convert to a flat `get_app_state` request for the given app. Wire shape of
    /// `GetAppStateRequest` stays flat; this is a computed conversion, not nesting.
    public func asGetAppStateRequest(app: String) -> GetAppStateRequest {
        GetAppStateRequest(
            app: app,
            windowId: windowId,
            forceFullTree: forceFullTree,
            disableDiff: disableDiff,
            includeScreenshot: includeScreenshot,
            scopeElementId: scopeElementId,
            maxNodes: maxNodes
        )
    }

    private enum CodingKeys: String, CodingKey {
        case windowId, forceFullTree, disableDiff, includeScreenshot, scopeElementId, maxNodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedWindowId = try container.decodeIfPresent(Int.self, forKey: .windowId)
        self.windowId = decodedWindowId == 0 ? nil : decodedWindowId
        self.forceFullTree = try container.decodeIfPresent(Bool.self, forKey: .forceFullTree) ?? false
        self.disableDiff = try container.decodeIfPresent(Bool.self, forKey: .disableDiff) ?? false
        self.includeScreenshot = try container.decodeIfPresent(ScreenshotMode.self, forKey: .includeScreenshot) ?? .auto
        self.scopeElementId = try container.decodeIfPresent(String.self, forKey: .scopeElementId)
        self.maxNodes = try container.decodeIfPresent(Int.self, forKey: .maxNodes)
    }
}

// MARK: - GetAppStateRequest (get_app_state input, §4.1)

/// Decoded `get_app_state` params. Custom `Decodable` applies the protocol
/// defaults (`forceFullTree=false`, `disableDiff=false`, `includeScreenshot="auto"`)
/// for missing keys, which synthesized `Codable` would not do.
///
/// Public properties and the flat wire shape are unchanged; observation knobs are
/// shared with mutating tools via `SnapshotOptions` (see `snapshotOptions`).
public struct GetAppStateRequest: Codable, Equatable, Sendable {
    public var app: String
    /// A positive WindowServer id. `nil` or the null WindowServer id `0` requests automatic selection.
    public var windowId: Int?
    public var forceFullTree: Bool
    public var disableDiff: Bool
    public var includeScreenshot: ScreenshotMode
    /// v1.5 (§18.2): root the walk at an element of the session's **current** snapshot
    /// instead of the window (`^e[0-9]+$`). `nil` requests an ordinary whole-window snapshot.
    public var scopeElementId: String?
    /// v1.5 (§18.2): per-snapshot node budget overriding the §7.5 default (600). Clamped to
    /// the frozen hard ceiling `1...2000` by the pipeline; `nil` uses the default.
    public var maxNodes: Int?

    public init(
        app: String,
        windowId: Int? = nil,
        forceFullTree: Bool = false,
        disableDiff: Bool = false,
        includeScreenshot: ScreenshotMode = .auto,
        scopeElementId: String? = nil,
        maxNodes: Int? = nil
    ) {
        self.app = app
        self.windowId = windowId == 0 ? nil : windowId
        self.forceFullTree = forceFullTree
        self.disableDiff = disableDiff
        self.includeScreenshot = includeScreenshot
        self.scopeElementId = scopeElementId
        self.maxNodes = maxNodes
    }

    /// Build from shared observation options without nesting them on the wire.
    public init(app: String, options: SnapshotOptions) {
        self.init(
            app: app,
            windowId: options.windowId,
            forceFullTree: options.forceFullTree,
            disableDiff: options.disableDiff,
            includeScreenshot: options.includeScreenshot,
            scopeElementId: options.scopeElementId,
            maxNodes: options.maxNodes
        )
    }

    /// The shared observation options carried by this request.
    public var snapshotOptions: SnapshotOptions {
        SnapshotOptions(
            windowId: windowId,
            forceFullTree: forceFullTree,
            disableDiff: disableDiff,
            includeScreenshot: includeScreenshot,
            scopeElementId: scopeElementId,
            maxNodes: maxNodes
        )
    }

    /// Whether this request suppresses the diff and demands a full tree (§15.1).
    public var suppressesDiff: Bool { snapshotOptions.suppressesDiff }

    /// Whether this is a scoped snapshot (§18.2): rooted at an element, always full,
    /// never a diff base.
    public var isScoped: Bool { snapshotOptions.isScoped }

    private enum CodingKeys: String, CodingKey {
        case app, windowId, forceFullTree, disableDiff, includeScreenshot, scopeElementId, maxNodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.app = try container.decode(String.self, forKey: .app)
        // Reuse SnapshotOptions defaults/normalization; extra keys (none on this schema)
        // are ignored by its CodingKeys.
        let options = try SnapshotOptions(from: decoder)
        self.windowId = options.windowId
        self.forceFullTree = options.forceFullTree
        self.disableDiff = options.disableDiff
        self.includeScreenshot = options.includeScreenshot
        self.scopeElementId = options.scopeElementId
        self.maxNodes = options.maxNodes
    }
}

// MARK: - ScreenshotRequest (screenshot input, §18.9)

/// Decoded `screenshot` params (§18.9). `windowId` shares get_app_state's §10.2 semantics:
/// a positive WindowServer id targets that window; `nil` or the null WindowServer id `0`
/// requests automatic selection. Custom `Decodable` normalizes `0`→`nil` and rejects no
/// extra keys (the schema already enforces `additionalProperties: false`).
public struct ScreenshotRequest: Codable, Equatable, Sendable {
    public var app: String
    /// A positive WindowServer id. `nil` or the null WindowServer id `0` requests automatic selection.
    public var windowId: Int?

    public init(app: String, windowId: Int? = nil) {
        self.app = app
        self.windowId = windowId == 0 ? nil : windowId
    }

    private enum CodingKeys: String, CodingKey {
        case app, windowId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.app = try container.decode(String.self, forKey: .app)
        let decodedWindowId = try container.decodeIfPresent(Int.self, forKey: .windowId)
        self.windowId = decodedWindowId == 0 ? nil : decodedWindowId
    }
}

// MARK: - AppState (get_app_state output, §4.1)

public struct AppState: Codable, Equatable, Sendable {
    /// The resolved window. `framePoints` is GLOBAL points; `scale` is the display
    /// backing scale; `screenshotPixels` is present only when a screenshot exists.
    public struct WindowInfo: Codable, Equatable, Sendable {
        public var id: Int
        public var title: String?
        public var framePoints: Rect
        public var screenshotPixels: Size?
        public var scale: Double
        /// v1.5 (§18.4): observable document identity read from the selected window's
        /// principal `AXWebArea`. Omitted when the tree contains no web area or neither
        /// field is readable, so pre-v1.5 output stays byte-identical.
        public var document: DocumentInfo?

        public init(
            id: Int,
            title: String? = nil,
            framePoints: Rect,
            screenshotPixels: Size? = nil,
            scale: Double,
            document: DocumentInfo? = nil
        ) {
            self.id = id
            self.title = title
            self.framePoints = framePoints
            self.screenshotPixels = screenshotPixels
            self.scale = scale
            self.document = document
        }

        /// v1.5 (§18.4): the principal web area's URL / title. Web-page text is untrusted
        /// data (SECURITY.md §2) — these are state observations, never instructions.
        public struct DocumentInfo: Codable, Equatable, Sendable {
            /// The web area's `AXURL` in absolute-string form; omitted when unreadable.
            public var url: String?
            /// The web area's nonempty `AXTitle`/`AXDescription`; omitted when unreadable.
            public var title: String?

            public init(url: String? = nil, title: String? = nil) {
                self.url = url
                self.title = title
            }
        }
    }

    /// v1.5 (§18.3): one entry of the optional `AppState.windows` enumeration. Best-effort
    /// per AX window; `id` is present only when the window correlated to a WindowServer id
    /// (only such entries are re-targetable via `windowId`).
    public struct WindowSummary: Codable, Equatable, Sendable {
        public var id: Int?
        public var title: String?
        public var framePoints: Rect
        public var focused: Bool
        public var main: Bool
        public var onScreen: Bool

        public init(
            id: Int? = nil,
            title: String? = nil,
            framePoints: Rect,
            focused: Bool,
            main: Bool,
            onScreen: Bool
        ) {
            self.id = id
            self.title = title
            self.framePoints = framePoints
            self.focused = focused
            self.main = main
            self.onScreen = onScreen
        }
    }

    /// v1.5 (§18.2): echoes a scoped snapshot's request. `elementId` is the (now-retired)
    /// id the caller sent, for correlation only.
    public struct Scope: Codable, Equatable, Sendable {
        public var elementId: String

        public init(elementId: String) {
            self.elementId = elementId
        }
    }

    /// The rendered accessibility tree. `format` is always `semantouch-ax-tree-v1`.
    public struct TreeInfo: Codable, Equatable, Sendable {
        public var format: String
        public var text: String
        public var nodeCount: Int
        public var truncated: Bool

        public init(
            format: String = TreeInfo.currentFormat,
            text: String,
            nodeCount: Int,
            truncated: Bool
        ) {
            self.format = format
            self.text = text
            self.nodeCount = nodeCount
            self.truncated = truncated
        }

        public static let currentFormat = "semantouch-ax-tree-v1"
    }

    /// Screenshot METADATA only — the bytes travel in a separate image content
    /// block (§5, §8). `mimeType` on the MCP path is always `image/jpeg`.
    public struct ScreenshotMeta: Codable, Equatable, Sendable {
        public var mimeType: String
        public var width: Int
        public var height: Int
        public var byteLength: Int

        public init(
            mimeType: String = "image/jpeg",
            width: Int,
            height: Int,
            byteLength: Int
        ) {
            self.mimeType = mimeType
            self.width = width
            self.height = height
            self.byteLength = byteLength
        }
    }

    public var sessionId: String
    public var app: AppSummary
    public var window: WindowInfo
    public var revision: Int
    public var full: Bool
    /// Omitted when `full` is true (Phase 1 is always full).
    public var baseRevision: Int?
    public var tree: TreeInfo
    /// Omitted when no screenshot is delivered.
    public var screenshot: ScreenshotMeta?
    public var focusedElementId: String?
    public var warnings: [StateWarning]
    /// v1.5 (§18.3): best-effort enumeration of every AX window. Omitted when gathering
    /// failed, so pre-v1.5 output stays byte-identical.
    public var windows: [WindowSummary]?
    /// v1.5 (§18.2): present only on a scoped snapshot, echoing the requested element id.
    public var scope: Scope?

    public init(
        sessionId: String,
        app: AppSummary,
        window: WindowInfo,
        revision: Int = 1,
        full: Bool = true,
        baseRevision: Int? = nil,
        tree: TreeInfo,
        screenshot: ScreenshotMeta? = nil,
        focusedElementId: String? = nil,
        warnings: [StateWarning] = [],
        windows: [WindowSummary]? = nil,
        scope: Scope? = nil
    ) {
        self.sessionId = sessionId
        self.app = app
        self.window = window
        self.revision = revision
        self.full = full
        self.baseRevision = baseRevision
        self.tree = tree
        self.screenshot = screenshot
        self.focusedElementId = focusedElementId
        self.warnings = warnings
        self.windows = windows
        self.scope = scope
    }
}

// MARK: - StateWarning (§4.1)

public struct StateWarning: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// Build a warning from a frozen code.
    public init(_ code: StateWarningCode, message: String) {
        self.code = code.rawValue
        self.message = message
    }
}

// MARK: - ElementTarget (shared action input, §4)

/// The `{ app, sessionId, revision, elementId }` quadruple every element-targeted
/// action carries. All four fields are required.
public struct ElementTarget: Codable, Equatable, Sendable {
    public var app: String
    public var sessionId: String
    public var revision: Int
    public var elementId: String

    public init(app: String, sessionId: String, revision: Int, elementId: String) {
        self.app = app
        self.sessionId = sessionId
        self.revision = revision
        self.elementId = elementId
    }
}

// MARK: - ActionResult (shared action output, §4.4)

public struct ActionResult: Codable, Equatable, Sendable {
    public var status: ActionStatus
    public var method: ActionMethod
    public var stateChanged: Bool
    public var refreshRecommended: Bool
    public var warning: String?
    /// Phase 4 (§16): whether this action changed the foreground app as part of a
    /// focus transaction (`allow-brief-focus` / `foreground-takeover`). Omitted (nil)
    /// for background-safe semantic actions, so Phase 2 results stay byte-identical.
    public var focusChanged: Bool?
    /// Phase 4 (§16): whether the user's prior foreground was restored after a brief
    /// focus transaction. Meaningful only when `focusChanged` is true. Omitted otherwise.
    public var focusRestored: Bool?
    /// Phase 4 (§16): whether the intended target app — not the user's app — was
    /// confirmed to be the one that received the fallback input (frontmost during
    /// delivery). Omitted for background-safe semantic actions.
    public var targetVerified: Bool?
    /// v1.5 (§18.5): present only when `set_value` was called with `commit: true`.
    /// `true` iff the element advertised `AXConfirm` and it was performed successfully;
    /// `false` when the value was written but no Confirm action ran. Omitted (nil) for
    /// every other action, so pre-v1.5 results stay byte-identical.
    public var committed: Bool?
    /// v1.5 (§18.6): present only when an element-targeted `press_key`/`type_text` supplied
    /// an `elementId`. `true` iff the bounded AXFocusedUIElement re-read confirmed the target
    /// element (or a descendant) holds keyboard focus. Omitted (nil) otherwise.
    public var elementFocused: Bool?
    /// Post-action observation: a fresh `AppState` (preferring a reconstructable diff)
    /// attached after a committed mutation. Omitted (nil) when no refresh ran (rejected
    /// actions, or a non-cancellation refresh failure that keeps the committed result).
    /// Optional screenshot bytes remain a separate MCP image content block, not embedded here.
    public var state: AppState?

    public init(
        status: ActionStatus,
        method: ActionMethod,
        stateChanged: Bool,
        refreshRecommended: Bool,
        warning: String? = nil,
        focusChanged: Bool? = nil,
        focusRestored: Bool? = nil,
        targetVerified: Bool? = nil,
        committed: Bool? = nil,
        elementFocused: Bool? = nil,
        state: AppState? = nil
    ) {
        self.status = status
        self.method = method
        self.stateChanged = stateChanged
        self.refreshRecommended = refreshRecommended
        self.warning = warning
        self.focusChanged = focusChanged
        self.focusRestored = focusRestored
        self.targetVerified = targetVerified
        self.committed = committed
        self.elementFocused = elementFocused
        self.state = state
    }
}

// MARK: - WaitForResult (wait_for output, §18.7)

/// The result of the read-only `wait_for` verification tool (§18.7). `wait_for` polls
/// observable window state (title, document URL, element existence) until a set of
/// conditions holds or the deadline expires; an expired deadline is a **normal** result
/// with `satisfied: false`, never a `timeout` error. It never advances the revision,
/// mints/retires ids, or synthesizes input.
public struct WaitForResult: Codable, Equatable, Sendable {
    /// One condition's outcome, echoed in request order.
    public struct ConditionResult: Codable, Equatable, Sendable {
        /// The condition's discriminant (`url_contains`, `title_changed`, …).
        public var kind: String
        public var satisfied: Bool

        public init(kind: String, satisfied: Bool) {
            self.kind = kind
            self.satisfied = satisfied
        }
    }

    /// Best-effort observations taken at the final poll. Fields are omitted when unreadable
    /// so a non-web window (no URL) or an unreadable title produces no key.
    public struct Observed: Codable, Equatable, Sendable {
        public var windowTitle: String?
        public var url: String?

        public init(windowTitle: String? = nil, url: String? = nil) {
            self.windowTitle = windowTitle
            self.url = url
        }
    }

    /// The mode-combined outcome (`all`/`any`).
    public var satisfied: Bool
    /// Elapsed wall-clock time to the deciding poll, in milliseconds.
    public var elapsedMs: Int
    /// Per-condition outcomes, in request order.
    public var conditions: [ConditionResult]
    /// Best-effort window observations at the final poll.
    public var observed: Observed
    /// Always `true`: poll results are not a snapshot, so the client SHOULD refresh via
    /// `get_app_state` before retargeting elements.
    public var refreshRecommended: Bool

    public init(
        satisfied: Bool,
        elapsedMs: Int,
        conditions: [ConditionResult],
        observed: Observed = Observed(),
        refreshRecommended: Bool = true
    ) {
        self.satisfied = satisfied
        self.elapsedMs = elapsedMs
        self.conditions = conditions
        self.observed = observed
        self.refreshRecommended = refreshRecommended
    }
}

// MARK: - ReadText (read_text input/output)

/// Byte budget for `read_text` (§ full-text read). Either a positive UTF-8 byte
/// count or the exact string `"max"` (return the full live `AXValue` string).
public enum ReadTextLimit: Codable, Equatable, Sendable {
    /// Positive UTF-8 byte budget. Truncation never splits a Swift `Character`
    /// (extended grapheme cluster).
    case bytes(Int)
    /// Return the entire live string value with no byte budget.
    case max

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            guard int > 0 else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "read_text limit integer must be > 0"
                )
            }
            self = .bytes(int)
            return
        }
        if let string = try? container.decode(String.self) {
            guard string == "max" else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "read_text limit string must be exactly \"max\""
                )
            }
            self = .max
            return
        }
        throw DecodingError.typeMismatch(
            ReadTextLimit.self,
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "read_text limit must be a positive integer or \"max\""
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bytes(count):
            try container.encode(count)
        case .max:
            try container.encode("max")
        }
    }
}

/// Decoded `read_text` params. Custom `Decodable` applies the protocol default
/// (`limit` = 4096 bytes) when the key is omitted.
///
/// Reads the live `AXValue` of one revision-checked element without advancing the
/// revision or mutating the session element table. Secure text fields are rejected
/// before any value is copied.
public struct ReadTextRequest: Codable, Equatable, Sendable {
    public var app: String
    public var sessionId: String
    public var revision: Int
    public var elementId: String
    /// UTF-8 byte budget or `"max"`. Default: 4096 bytes.
    public var limit: ReadTextLimit

    public static let defaultLimit: ReadTextLimit = .bytes(4096)

    public init(
        app: String,
        sessionId: String,
        revision: Int,
        elementId: String,
        limit: ReadTextLimit = ReadTextRequest.defaultLimit
    ) {
        self.app = app
        self.sessionId = sessionId
        self.revision = revision
        self.elementId = elementId
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey {
        case app, sessionId, revision, elementId, limit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.app = try container.decode(String.self, forKey: .app)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.revision = try container.decode(Int.self, forKey: .revision)
        self.elementId = try container.decode(String.self, forKey: .elementId)
        self.limit = try container.decodeIfPresent(ReadTextLimit.self, forKey: .limit) ?? Self.defaultLimit
    }
}

/// `read_text` result payload:
/// `{ "text", "totalBytes", "returnedBytes", "truncated" }`.
///
/// `totalBytes` is the full live string's UTF-8 length; `returnedBytes` is the
/// length of `text` after the caller's limit is applied on a Character boundary.
public struct ReadTextResult: Codable, Equatable, Sendable {
    public var text: String
    public var totalBytes: Int
    public var returnedBytes: Int
    public var truncated: Bool

    public init(text: String, totalBytes: Int, returnedBytes: Int, truncated: Bool) {
        self.text = text
        self.totalBytes = totalBytes
        self.returnedBytes = returnedBytes
        self.truncated = truncated
    }
}

// MARK: - ScreenshotResult (screenshot output, §18.9)

/// The result of the read-only `screenshot` tool (§18.9): the resolved window captured as a
/// JPEG WITHOUT building an accessibility tree. Delivered as the §5 JSON text block, with the
/// JPEG in a separate image content block. It reuses `AppState.WindowInfo`,
/// `AppState.ScreenshotMeta`, and `StateWarning` — but unlike `get_app_state` the image is the
/// product, so `window.screenshotPixels` and `window.scale` are always present here.
/// `window.title` follows its omit-when-nil rule; `window.document` is never populated (no tree
/// walk) and so is always omitted. `screenshot` never advances the revision or mints/retires
/// element ids (§18.9).
public struct ScreenshotResult: Codable, Equatable, Sendable {
    public var sessionId: String
    public var window: AppState.WindowInfo
    public var screenshot: AppState.ScreenshotMeta
    /// Advisory warnings, e.g. `low_correlation_confidence`. Always present (possibly empty),
    /// mirroring `AppState.warnings`.
    public var warnings: [StateWarning]

    public init(
        sessionId: String,
        window: AppState.WindowInfo,
        screenshot: AppState.ScreenshotMeta,
        warnings: [StateWarning] = []
    ) {
        self.sessionId = sessionId
        self.window = window
        self.screenshot = screenshot
        self.warnings = warnings
    }
}

// MARK: - WindowRef (error payloads, §6)

/// A window as seen from one side of correlation (AX or ScreenCaptureKit),
/// used in `ambiguous_window` / `uncorrelated_window` error data.
public struct WindowRef: Codable, Equatable, Sendable {
    public var windowId: Int?
    public var title: String?
    public var framePoints: Rect?
    public var pid: Int?
    public var source: WindowSource

    public init(
        windowId: Int? = nil,
        title: String? = nil,
        framePoints: Rect? = nil,
        pid: Int? = nil,
        source: WindowSource
    ) {
        self.windowId = windowId
        self.title = title
        self.framePoints = framePoints
        self.pid = pid
        self.source = source
    }
}
