import XCTest
import ComputerUseCore
@testable import MCPServer
@testable import ComputerUseService

/// Phase 6 packaging contract: the `config`-subcommand generators (MCP server config
/// + plugin manifest) stay pinned to the same single-source-of-truth constants the
/// wire uses (version, tool catalog, TCC permissions), and their output is a valid,
/// deterministic OMP `MCPStdioServerConfig`. Permission-free and pure.
final class PackagingTests: XCTestCase {
    // MARK: - Version single source of truth

    func testVersionTracksServerVersion() {
        XCTAssertEqual(Packaging.version, MCPServer.serverVersion)
        XCTAssertEqual(Packaging.manifest(command: "/x").version, MCPServer.serverVersion)
    }

    // MARK: - MCP server config shape (OMP MCPStdioServerConfig)

    func testServerConfigMatchesOMPStdioShape() {
        let config = Packaging.serverConfig(command: "/opt/omp/semantouch")
        XCTAssertEqual(config.type, "stdio")
        XCTAssertEqual(config.command, "/opt/omp/semantouch")
        XCTAssertEqual(config.args, ["mcp"])
        XCTAssertEqual(config.timeout, 30_000)
        XCTAssertNil(config.cwd)
    }

    func testServerConfigOmitsCwdWhenNil() throws {
        let json = try Packaging.serverConfigJSON(command: "/x/semantouch")
        XCTAssertFalse(json.contains("cwd"), "cwd MUST be omitted when not supplied")
    }

    func testServerConfigIncludesCwdWhenSet() throws {
        let json = try Packaging.serverConfigJSON(command: "/x/semantouch", cwd: "/work")
        XCTAssertTrue(json.contains("\"cwd\":\"/work\""))
    }

    func testServersConfigKeyIsConfigurable() {
        let wrapped = Packaging.serversConfig(key: "cu", command: "/x")
        XCTAssertEqual(Array(wrapped.mcpServers.keys), ["cu"])
        XCTAssertEqual(Packaging.defaultServerKey, "semantouch")
    }

    func testServersConfigJSONRoundTrips() throws {
        let json = try Packaging.serversConfigJSON(command: "/apps/semantouch", timeoutMs: 45_000)
        let decoded = try CanonicalJSON.decode(Packaging.OMPMCPServersConfig.self, from: json)
        let server = try XCTUnwrap(decoded.mcpServers["semantouch"])
        XCTAssertEqual(server.type, "stdio")
        XCTAssertEqual(server.command, "/apps/semantouch")
        XCTAssertEqual(server.args, ["mcp"])
        XCTAssertEqual(server.timeout, 45_000)
    }

    // MARK: - Determinism

    func testGeneratorsAreDeterministic() throws {
        let a = try Packaging.serversConfigJSON(command: "/x/semantouch", cwd: "/w")
        let b = try Packaging.serversConfigJSON(command: "/x/semantouch", cwd: "/w")
        XCTAssertEqual(a, b)
        let m1 = try Packaging.manifestJSON(command: "/x")
        let m2 = try Packaging.manifestJSON(command: "/x")
        XCTAssertEqual(m1, m2)
    }

    // MARK: - Plugin manifest

    func testManifestToolListEqualsEnabledCatalog() {
        let manifest = Packaging.manifest(command: "/x")
        XCTAssertEqual(manifest.tools.map { $0.name }, ToolCatalog.enabledNames)
        XCTAssertEqual(manifest.tools.count, 14)
        // Phases are carried through faithfully.
        for entry in manifest.tools {
            let descriptor = ToolCatalog.all.first { $0.name == entry.name }
            XCTAssertEqual(entry.phase, descriptor?.phase, "phase mismatch for \(entry.name)")
        }
    }

    func testManifestPermissionsAreTheTwoTCCGrants() {
        let keys = Packaging.manifest(command: "/x").permissions.map { $0.key }
        XCTAssertEqual(keys, [Permission.accessibility.rawValue, Permission.screenRecording.rawValue])
        XCTAssertTrue(Packaging.manifest(command: "/x").permissions.allSatisfy { $0.required })
    }

    func testManifestUsesPublisherBundleId() {
        let manifest = Packaging.manifest(command: "/x")
        XCTAssertEqual(manifest.name, "semantouch")
        XCTAssertEqual(manifest.minimumMacOS, "14.4")
        XCTAssertEqual(manifest.architectures, ["arm64"])
        XCTAssertEqual(manifest.mcpProtocolVersion, MCPServer.mcpProtocolVersion)
        XCTAssertEqual(manifest.contractVersion, MCPServer.contractVersion)
        XCTAssertFalse(manifest.bundleIdIsPlaceholder)
        XCTAssertEqual(manifest.bundleId, "tech.watzon.semantouch")
        XCTAssertFalse(manifest.bundleId.hasPrefix("com.apple."))
        XCTAssertFalse(manifest.bundleId.hasPrefix("com.openai."))
    }

    func testManifestServerLaunchShape() {
        let server = Packaging.manifest(command: "/apps/semantouch").server
        XCTAssertEqual(server.type, "stdio")
        XCTAssertEqual(server.command, "/apps/semantouch")
        XCTAssertEqual(server.args, ["mcp"])
    }
}
