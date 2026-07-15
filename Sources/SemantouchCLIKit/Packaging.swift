import Foundation
import ComputerUseCore
import MCPServer

/// Deterministic generators for the OMP MCP server config and plugin manifest,
/// plus the single-source-of-truth packaging constants (version, bundle id,
/// minimum macOS, tool list, TCC ownership, and app-bundle layout).
///
/// These are outputs of the `config` **CLI subcommand**, NOT the MCP wire channel. That
/// subcommand is the one sanctioned place a command prints JSON to stdout because it is
/// an explicit generator, not the framed JSON-RPC transport (PROTOCOL.md §1); logs still
/// go to stderr, and the `mcp` server itself never emits any of this.
///
/// **Version discipline.** Everything version-bearing (`--version`, `doctor`,
/// `serverInfo.version`, and the manifest below) reads `MCPServer.serverVersion` so the
/// number can never drift between the wire and the package metadata.
///
/// **TCC ownership.** Accessibility and Screen Recording are granted to the signed
/// `Semantouch.app` host (`tech.watzon.semantouch` / `SemantouchHost`). The nested
/// `Contents/MacOS/semantouch` relay is a stdio/control client only and never holds TCC.
public enum Packaging {
    // MARK: - Single source of truth

    /// Plugin short name (the OMP/MCP server key and manifest `name`).
    public static let pluginName = "semantouch"

    /// Human-facing plugin name / app display name.
    public static let pluginDisplayName = "Semantouch"

    /// On-disk app bundle leaf name.
    public static let appBundleName = "Semantouch.app"

    /// Stable publisher identifier used for Developer ID signing and notarization.
    /// Matches the `tech.watzon` namespace used by the publisher's other macOS apps.
    public static let bundleId = "tech.watzon.semantouch"

    /// Nested relay / CLI code signature identifier.
    public static let relayCodeIdentifier = "tech.watzon.semantouch.cli"

    /// Developer ID Team / OU (Watzon Ventures LLc).
    public static let teamIdentifier = "MB5789APU7"

    /// Host product / CFBundleExecutable leaf inside the app bundle.
    /// Named `SemantouchHost` (not `Semantouch`) so it cannot collide with the
    /// nested `semantouch` relay on case-insensitive APFS volumes.
    public static let hostExecutableName = "SemantouchHost"

    /// Nested public stdio/control relay leaf inside the app bundle.
    public static let relayExecutableName = "semantouch"

    /// Path of the host executable relative to the app bundle root.
    public static let hostRelativePath = "Contents/MacOS/\(hostExecutableName)"

    /// Path of the nested relay relative to the app bundle root.
    public static let relayRelativePath = "Contents/MacOS/\(relayExecutableName)"

    /// Preferred system-wide install path.
    public static let systemAppPath = "/Applications/\(appBundleName)"

    /// Preferred per-user install path (expanded against the process home).
    public static var userAppPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications/\(appBundleName)")
    }

    /// Minimum supported macOS (matches `Package.swift` `.macOS(.v14)` and docs/INSTALL.md).
    public static let minimumMacOS = "14.0"

    /// Supported architectures for the shipped app (universal2).
    public static let architectures = ["arm64", "x86_64"]

    /// The plugin/helper version, sourced from the one wire constant.
    public static var version: String { MCPServer.serverVersion }

    /// Default server key inside an OMP `mcpServers` map.
    public static let defaultServerKey = "semantouch"

    /// The subcommand OMP launches the nested relay with (docs/INSTALL.md).
    public static let mcpArgs = ["mcp"]

    /// Default OMP client `tools/call` timeout, in milliseconds.
    public static let defaultTimeoutMs = 30_000

    /// Canonical install location used only in generated **examples** (docs/INSTALL.md).
    /// Points at the nested public relay path inside the preferred system app.
    public static let exampleInstalledPath =
        "/Applications/Semantouch.app/Contents/MacOS/semantouch"

    /// Human-readable note that the signed app host owns TCC, not the nested relay.
    public static let tccOwnershipDescription =
        "TCC grants (Accessibility, Screen Recording) are owned by the signed Semantouch.app host "
        + "(bundle id tech.watzon.semantouch, executable SemantouchHost). "
        + "The nested Contents/MacOS/semantouch relay is stdio/control only and does not hold TCC."

    /// Canonical release architecture tag used in immutable asset names.
    public static let releaseArchitectureTag = "universal2"

    /// Versioned universal2 app ZIP release asset name (canonical immutable artifact).
    public static func appZipAssetName(forVersion version: String) -> String {
        "Semantouch-v\(version)-macos-\(releaseArchitectureTag).zip"
    }

    /// SHA-256 sidecar for the versioned universal2 app ZIP.
    public static func appZipChecksumAssetName(forVersion version: String) -> String {
        appZipAssetName(forVersion: version) + ".sha256"
    }

    /// Versioned universal2 app DMG release asset name (canonical immutable artifact).
    public static func appDmgAssetName(forVersion version: String) -> String {
        "Semantouch-v\(version)-macos-\(releaseArchitectureTag).dmg"
    }

    /// SHA-256 sidecar for the versioned universal2 app DMG.
    public static func appDmgChecksumAssetName(forVersion version: String) -> String {
        appDmgAssetName(forVersion: version) + ".sha256"
    }

    // MARK: - Wire shapes

    /// OMP's `MCPStdioServerConfig` shape:
    /// `{ type?, command, args?, env?, cwd?, timeout? }`. `cwd` is omitted when nil
    /// (synthesized `Codable` skips nil optionals); keys are sorted by `CanonicalJSON`.
    public struct MCPStdioServerConfig: Codable, Equatable, Sendable {
        public var type: String
        public var command: String
        public var args: [String]
        public var cwd: String?
        public var timeout: Int

        public init(type: String = "stdio", command: String, args: [String], cwd: String? = nil, timeout: Int) {
            self.type = type
            self.command = command
            self.args = args
            self.cwd = cwd
            self.timeout = timeout
        }
    }

    /// The `{ "mcpServers": { "<key>": MCPStdioServerConfig } }` block a user pastes into
    /// (or merges with) OMP's config.
    public struct OMPMCPServersConfig: Codable, Equatable, Sendable {
        public var mcpServers: [String: MCPStdioServerConfig]

        public init(mcpServers: [String: MCPStdioServerConfig]) {
            self.mcpServers = mcpServers
        }
    }

    /// The plugin manifest describing this helper as an OMP/MCP plugin.
    public struct PluginManifest: Codable, Equatable, Sendable {
        /// How OMP launches the nested relay (the stdio MCP entrypoint).
        public struct Server: Codable, Equatable, Sendable {
            public var type: String
            public var command: String
            public var args: [String]
        }

        /// One exposed MCP tool and the delivery phase it belongs to.
        public struct ToolEntry: Codable, Equatable, Sendable {
            public var name: String
            public var phase: Int
        }

        /// One required macOS TCC grant, with the reason it is needed.
        public struct PermissionEntry: Codable, Equatable, Sendable {
            public var key: String
            public var required: Bool
            public var reason: String
        }

        public var manifestVersion: Int
        public var name: String
        public var displayName: String
        public var description: String
        public var version: String
        public var bundleId: String
        public var bundleIdIsPlaceholder: Bool
        public var minimumMacOS: String
        public var architectures: [String]
        public var mcpProtocolVersion: String
        public var contractVersion: String
        /// Explains that the signed app host owns TCC, not the nested relay.
        public var tccOwnership: String
        public var appBundleName: String
        public var hostExecutableName: String
        public var relayExecutableName: String
        public var teamIdentifier: String
        public var server: Server
        public var tools: [ToolEntry]
        public var permissions: [PermissionEntry]
    }

    // MARK: - TCC permissions (single source of truth)

    /// The two grants the signed **app host** requires (docs/SECURITY.md §1). `doctor`
    /// reports each independently; a missing grant surfaces as `permission_denied`.
    /// The nested relay never receives these grants.
    public static let requiredPermissions: [PluginManifest.PermissionEntry] = [
        .init(
            key: Permission.accessibility.rawValue,
            required: true,
            reason: "Granted to Semantouch.app (tech.watzon.semantouch / SemantouchHost). "
                + "The resident app host reads the accessibility tree and performs semantic AX actions; "
                + "the nested Contents/MacOS/semantouch relay does not hold Accessibility TCC."
        ),
        .init(
            key: Permission.screenRecording.rawValue,
            required: true,
            reason: "Granted to Semantouch.app (tech.watzon.semantouch / SemantouchHost). "
                + "The resident app host captures still images via ScreenCaptureKit; "
                + "the nested Contents/MacOS/semantouch relay does not hold Screen Recording TCC."
        ),
    ]

    // MARK: - Builders

    /// One MCP stdio server entry pointing at `command` (the nested relay path).
    public static func serverConfig(command: String, cwd: String? = nil, timeoutMs: Int = defaultTimeoutMs) -> MCPStdioServerConfig {
        MCPStdioServerConfig(type: "stdio", command: command, args: mcpArgs, cwd: cwd, timeout: timeoutMs)
    }

    /// The full `mcpServers` block keyed by `key` (default `semantouch`).
    public static func serversConfig(
        key: String = defaultServerKey,
        command: String,
        cwd: String? = nil,
        timeoutMs: Int = defaultTimeoutMs
    ) -> OMPMCPServersConfig {
        OMPMCPServersConfig(mcpServers: [key: serverConfig(command: command, cwd: cwd, timeoutMs: timeoutMs)])
    }

    /// The plugin manifest. `command` is the nested relay launch path (an install path for the
    /// checked-in artifact, or the resolved running binary from the `config` subcommand).
    public static func manifest(command: String) -> PluginManifest {
        PluginManifest(
            manifestVersion: 1,
            name: pluginName,
            displayName: pluginDisplayName,
            description: "Semantouch provides native macOS computer use via a resident signed Semantouch.app host: "
                + "per-window capture (including covered windows), a compact accessibility tree with stable element ids, "
                + "semantic accessibility actions, incremental tree diffs, guarded native input fallback, and a decorative "
                + "virtual-cursor overlay — exposed through a nested stdio MCP relay. "
                + tccOwnershipDescription,
            version: version,
            bundleId: bundleId,
            bundleIdIsPlaceholder: false,
            minimumMacOS: minimumMacOS,
            architectures: architectures,
            mcpProtocolVersion: MCPServer.mcpProtocolVersion,
            contractVersion: MCPServer.contractVersion,
            tccOwnership: tccOwnershipDescription,
            appBundleName: appBundleName,
            hostExecutableName: hostExecutableName,
            relayExecutableName: relayExecutableName,
            teamIdentifier: teamIdentifier,
            server: PluginManifest.Server(type: "stdio", command: command, args: mcpArgs),
            tools: ToolCatalog.enabled.map { PluginManifest.ToolEntry(name: $0.name, phase: $0.phase) },
            permissions: requiredPermissions
        )
    }

    // MARK: - Canonical JSON

    /// The `mcpServers` block as a deterministic JSON string (no trailing newline).
    public static func serversConfigJSON(
        key: String = defaultServerKey,
        command: String,
        cwd: String? = nil,
        timeoutMs: Int = defaultTimeoutMs
    ) throws -> String {
        try CanonicalJSON.encodeToString(serversConfig(key: key, command: command, cwd: cwd, timeoutMs: timeoutMs))
    }

    /// A bare single `MCPStdioServerConfig` object as a deterministic JSON string.
    public static func serverConfigJSON(command: String, cwd: String? = nil, timeoutMs: Int = defaultTimeoutMs) throws -> String {
        try CanonicalJSON.encodeToString(serverConfig(command: command, cwd: cwd, timeoutMs: timeoutMs))
    }

    /// The plugin manifest as a deterministic JSON string.
    public static func manifestJSON(command: String) throws -> String {
        try CanonicalJSON.encodeToString(manifest(command: command))
    }
}
