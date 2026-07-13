import Foundation
import ComputerUseCore
import MCPServer

/// Deterministic generators for the OMP MCP server config and plugin manifest,
/// plus the single-source-of-truth packaging constants (version, bundle id,
/// minimum macOS, tool list, and TCC permissions).
///
/// These are outputs of the `config` **CLI subcommand**, NOT the MCP wire channel. That
/// subcommand is the one sanctioned place a command prints JSON to stdout because it is
/// an explicit generator, not the framed JSON-RPC transport (PROTOCOL.md §1); logs still
/// go to stderr, and the `mcp` server itself never emits any of this.
///
/// **Version discipline.** Everything version-bearing (`--version`, `doctor`,
/// `serverInfo.version`, and the manifest below) reads `MCPServer.serverVersion` so the
/// number can never drift between the wire and the package metadata.
public enum Packaging {
    // MARK: - Single source of truth

    /// Plugin short name (the OMP/MCP server key and manifest `name`).
    public static let pluginName = "semantouch"

    /// Human-facing plugin name.
    public static let pluginDisplayName = "Semantouch"

    /// **Placeholder** bundle-id namespace. Deliberately neutral — NOT `com.openai.*`
    /// and NOT `com.apple.*` (clean-room / no-masquerade constraint, docs/SECURITY.md §5).
    /// Replace with the real publisher id when a signing identity exists (docs/RELEASE.md).
    public static let bundleIdPlaceholder = "dev.watzon.semantouch"

    /// Minimum supported macOS (matches `Package.swift` `.macOS(.v14)` and docs/INSTALL.md).
    public static let minimumMacOS = "14.4"

    /// Supported architectures for the shipped binary.
    public static let architectures = ["arm64"]

    /// The plugin/helper version, sourced from the one wire constant.
    public static var version: String { MCPServer.serverVersion }

    /// Default server key inside an OMP `mcpServers` map.
    public static let defaultServerKey = "semantouch"

    /// The subcommand OMP launches the helper with (docs/INSTALL.md).
    public static let mcpArgs = ["mcp"]

    /// Default OMP client `tools/call` timeout, in milliseconds.
    public static let defaultTimeoutMs = 30_000

    /// Canonical install location used only in generated **examples** (docs/INSTALL.md).
    /// The live `config` subcommand resolves the actual running/`--path` binary instead.
    public static let exampleInstalledPath =
        "/Applications/Semantouch.app/Contents/MacOS/semantouch"

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
        /// How OMP launches the helper (the stdio MCP entrypoint).
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
        public var server: Server
        public var tools: [ToolEntry]
        public var permissions: [PermissionEntry]
    }

    // MARK: - TCC permissions (single source of truth)

    /// The two grants the signed helper requires (docs/SECURITY.md §1). `doctor`
    /// reports each independently; a missing grant surfaces as `permission_denied`.
    public static let requiredPermissions: [PluginManifest.PermissionEntry] = [
        .init(
            key: Permission.accessibility.rawValue,
            required: true,
            reason: "Read the accessibility tree of the target window and perform semantic AX actions."
        ),
        .init(
            key: Permission.screenRecording.rawValue,
            required: true,
            reason: "Capture a still image of the target window (including a covered/background window) via ScreenCaptureKit."
        ),
    ]

    // MARK: - Builders

    /// One MCP stdio server entry pointing at `command`.
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

    /// The plugin manifest. `command` is the launch path (an install path for the
    /// checked-in artifact, or the resolved running binary from the `config` subcommand).
    public static func manifest(command: String) -> PluginManifest {
        PluginManifest(
            manifestVersion: 1,
            name: pluginName,
            displayName: pluginDisplayName,
            description: "Semantouch provides native macOS computer use: per-window capture (including covered windows), a compact accessibility tree with stable element ids, semantic accessibility actions, incremental tree diffs, guarded native input fallback, and a decorative virtual-cursor overlay — exposed as a stdio MCP server.",
            version: version,
            bundleId: bundleIdPlaceholder,
            bundleIdIsPlaceholder: true,
            minimumMacOS: minimumMacOS,
            architectures: architectures,
            mcpProtocolVersion: MCPServer.mcpProtocolVersion,
            contractVersion: MCPServer.contractVersion,
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
