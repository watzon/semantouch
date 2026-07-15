import XCTest
import ComputerUseCore
@testable import MCPServer
@testable import ComputerUseService

/// Contract for the additive `launch_app` tool surface and `AppSummary.useCount`.
///
/// Focused on DTOs, strict schema, catalog order, registry wiring, and error mapping.
/// Does not drive live launches (AppLauncher ownership is elsewhere).
final class LaunchToolContractTests: XCTestCase {

    // MARK: - AppSummary.useCount omit-when-nil

    func testAppSummaryOmitsUseCountWhenNil() throws {
        let summary = AppSummary(
            id: "com.example.app",
            displayName: "Example",
            path: "/Applications/Example.app",
            pid: 42,
            isRunning: true,
            windows: 1,
            lastUsedAt: nil,
            useCount: nil
        )
        let wire = try JSONValue.parse(try CanonicalJSON.encodeToString(summary))
        XCTAssertNil(wire["useCount"], "useCount must be omit-when-nil")
        XCTAssertNil(wire["lastUsedAt"], "lastUsedAt remains omit-when-nil")
        XCTAssertEqual(wire["id"]?.stringValue, "com.example.app")
        XCTAssertEqual(wire["displayName"]?.stringValue, "Example")
        XCTAssertEqual(wire["path"]?.stringValue, "/Applications/Example.app")
        XCTAssertEqual(wire["pid"]?.intValue, 42)
        XCTAssertEqual(wire["isRunning"]?.boolValue, true)
        XCTAssertEqual(wire["windows"]?.intValue, 1)
    }

    func testAppSummaryEmitsUseCountWhenPresent() throws {
        let summary = AppSummary(
            id: "com.example.app",
            displayName: "Example",
            isRunning: false,
            windows: 0,
            lastUsedAt: "2026-01-02T03:04:05Z",
            useCount: 17
        )
        let encoded = try CanonicalJSON.encodeToString(summary)
        XCTAssertEqual(
            encoded,
            #"{"displayName":"Example","id":"com.example.app","isRunning":false,"lastUsedAt":"2026-01-02T03:04:05Z","useCount":17,"windows":0}"#
        )
        let decoded = try CanonicalJSON.decode(AppSummary.self, from: encoded)
        XCTAssertEqual(decoded.useCount, 17)
        XCTAssertEqual(decoded.lastUsedAt, "2026-01-02T03:04:05Z")
        XCTAssertNil(decoded.path)
        XCTAssertNil(decoded.pid)
    }

    // MARK: - LaunchAppRequest defaults + LaunchAppResult shape

    func testLaunchAppRequestDefaults() throws {
        let request = try CanonicalJSON.decode(LaunchAppRequest.self, from: #"{"app":"TextEdit"}"#)
        XCTAssertEqual(request.app, "TextEdit")
        XCTAssertTrue(request.activate, "activate defaults to true")
        XCTAssertEqual(request.waitForWindowMs, 3000, "waitForWindowMs defaults to 3000")
    }

    func testLaunchAppRequestExplicitOverrides() throws {
        let request = try CanonicalJSON.decode(
            LaunchAppRequest.self,
            from: #"{"app":"Notes","activate":false,"waitForWindowMs":0}"#
        )
        XCTAssertEqual(request.app, "Notes")
        XCTAssertFalse(request.activate)
        XCTAssertEqual(request.waitForWindowMs, 0)
    }

    func testLaunchAppResultCanonicalJSON() throws {
        let result = LaunchAppResult(
            app: AppSummary(
                id: "com.apple.TextEdit",
                displayName: "TextEdit",
                path: "/System/Applications/TextEdit.app",
                pid: 999,
                isRunning: true,
                windows: 1,
                useCount: 3
            ),
            launched: true,
            recovered: false
        )
        XCTAssertEqual(
            try CanonicalJSON.encodeToString(result),
            #"{"app":{"displayName":"TextEdit","id":"com.apple.TextEdit","isRunning":true,"path":"/System/Applications/TextEdit.app","pid":999,"useCount":3,"windows":1},"launched":true,"recovered":false}"#
        )
    }

    func testLaunchAppResultOmitsNilAppOptionalFields() throws {
        let result = LaunchAppResult(
            app: AppSummary(id: "pid:1", displayName: "X", isRunning: true, windows: 0),
            launched: false,
            recovered: true
        )
        let wire = try JSONValue.parse(try CanonicalJSON.encodeToString(result))
        XCTAssertEqual(wire["launched"]?.boolValue, false)
        XCTAssertEqual(wire["recovered"]?.boolValue, true)
        XCTAssertNil(wire["app"]?["useCount"])
        XCTAssertNil(wire["app"]?["lastUsedAt"])
        XCTAssertNil(wire["app"]?["path"])
        XCTAssertNil(wire["app"]?["pid"])
    }

    // MARK: - Schema: strict, defaults, no SnapshotOptions

    func testLaunchAppSchemaIsStrictAndFrozen() throws {
        let schema = try XCTUnwrap(ToolSchemas.schema(for: "launch_app"))
        XCTAssertEqual(
            schema.serialized(),
            #"{"additionalProperties":false,"properties":{"activate":{"default":true,"type":"boolean"},"app":{"type":"string"},"waitForWindowMs":{"default":3000,"description":"Milliseconds to wait for a capturable window after launch or recovery. Default 3000.","minimum":0,"type":"integer"}},"required":["app"],"type":"object"}"#
        )

        // Lifecycle tool: no action-attached SnapshotOptions fields.
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        for key in ["forceFullTree", "disableDiff", "includeScreenshot", "scopeElementId", "maxNodes", "windowId", "sessionId", "revision", "elementId"] {
            XCTAssertNil(properties[key], "launch_app must not accept SnapshotOptions/\(key)")
        }
    }

    func testLaunchAppSchemaRejectsUnknownKeys() throws {
        let schema = try XCTUnwrap(ToolSchemas.schema(for: "launch_app"))
        XCTAssertNotNil(
            SchemaValidator.validate(
                try JSONValue.parse(#"{"app":"TextEdit","notAField":true}"#),
                schema: schema
            )
        )
        XCTAssertNil(
            SchemaValidator.validate(
                try JSONValue.parse(#"{"app":"TextEdit"}"#),
                schema: schema
            )
        )
        XCTAssertNil(
            SchemaValidator.validate(
                try JSONValue.parse(#"{"app":"TextEdit","activate":false,"waitForWindowMs":500}"#),
                schema: schema
            )
        )
        // Negative waitForWindowMs fails minimum: 0.
        XCTAssertNotNil(
            SchemaValidator.validate(
                try JSONValue.parse(#"{"app":"TextEdit","waitForWindowMs":-1}"#),
                schema: schema
            )
        )
    }

    func testLaunchAppUnknownKeyYieldsInvalidParamsOverRealRegistry() throws {
        let server = makeServer()
        initialize(server)
        let response = try parse(server.process(call(
            id: 1,
            name: "launch_app",
            arguments: #"{"app":"TextEdit","extra":true}"#
        )))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    func testLaunchAppMissingAppYieldsInvalidParams() throws {
        let server = makeServer()
        initialize(server)
        let response = try parse(server.process(call(id: 2, name: "launch_app", arguments: "{}")))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    // MARK: - Catalog order / count / annotations

    func testLaunchAppSitsImmediatelyAfterListApps() {
        let names = ToolCatalog.enabledNames
        XCTAssertEqual(names.count, 16)
        XCTAssertEqual(ToolCatalog.all.count, 16)
        guard let listIdx = names.firstIndex(of: "list_apps"),
              let launchIdx = names.firstIndex(of: "launch_app") else {
            return XCTFail("list_apps and launch_app must both be enabled")
        }
        XCTAssertEqual(launchIdx, listIdx + 1)

        // Existing tools preserve relative order around the insertion.
        XCTAssertEqual(
            names,
            [
                "doctor", "list_apps", "launch_app", "get_app_state", "read_text", "screenshot", "end_app_session",
                "click", "perform_action", "set_value", "select_text", "scroll",
                "press_key", "type_text", "drag", "wait_for",
            ]
        )
        XCTAssertTrue(ToolCatalog.isEnabled("launch_app"))
        XCTAssertEqual(ToolCatalog.all.first { $0.name == "launch_app" }?.phase, 1)
    }

    func testLaunchAppAnnotationsAreConservativeMutating() throws {
        let server = makeServer()
        initialize(server)
        let tools = try XCTUnwrap(try parse(server.process(request(id: 3, method: "tools/list")))["result"]?["tools"]?.arrayValue)
        let launch = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "launch_app" })
        let annotations = try XCTUnwrap(launch["annotations"])
        // Default descriptor policy: mutating tools are not read-only, may be destructive,
        // non-idempotent, and open-world.
        XCTAssertEqual(annotations["readOnlyHint"]?.boolValue, false)
        XCTAssertEqual(annotations["destructiveHint"]?.boolValue, true)
        XCTAssertEqual(annotations["idempotentHint"]?.boolValue, false)
        XCTAssertEqual(annotations["openWorldHint"]?.boolValue, true)

        // list_apps remains read-only and still immediately precedes launch_app.
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names.firstIndex(of: "launch_app"), names.firstIndex(of: "list_apps").map { $0 + 1 })
        let list = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "list_apps" })
        XCTAssertEqual(list["annotations"]?["readOnlyHint"]?.boolValue, true)
    }

    // MARK: - Registry handler presence + policy / tool error mapping

    func testRegistryWiresLaunchAppHandler() {
        let context = ServiceContext()
        let handlers = ToolHandlers.handlers(context: context)
        XCTAssertNotNil(handlers["launch_app"], "launch_app must be present in the handler map")
        // Full standard registry enables every catalog tool, including launch_app.
        let registry = ToolHandlers.registry(context: context)
        XCTAssertTrue(registry.isEnabled("launch_app"))
        XCTAssertNotNil(registry.tool(named: "launch_app"))
    }

    func testLaunchAppOnDeniedAppIsPolicyDenied() throws {
        // Policy gate runs before launch/read/action dispatch. With a denylisted app
        // that resolves, launch_app must surface policy_denied / app_denied without
        // treating the call as a schema fault.
        let blocked = AppRecord(
            bundleId: "com.example.blocked",
            displayName: "Blocked",
            path: nil,
            pid: 999,
            isRunning: true,
            windows: 1
        )
        let context = ServiceContext(
            policyEngine: PolicyEngine(appDenylist: ["com.example.blocked"]),
            appResolver: AppResolver(environment: FakeAppEnvironment(records: [blocked]))
        )
        let server = MCPServer(registry: ToolHandlers.registry(context: context))
        initialize(server)

        let response = try parse(server.process(call(
            id: 10,
            name: "launch_app",
            arguments: #"{"app":"com.example.blocked","activate":false,"waitForWindowMs":0}"#
        )))
        XCTAssertNil(response["error"], "policy denial is a tool-level error, not JSON-RPC -32602")
        let payload = try toolErrorPayload(response)
        XCTAssertEqual(payload["code"]?.stringValue, "policy_denied")
        XCTAssertEqual(payload["data"]?["reason"]?.stringValue, "app_denied")
        XCTAssertEqual(payload["data"]?["app"]?.stringValue, "com.example.blocked")
        XCTAssertEqual(payload["data"]?["tool"]?.stringValue, "launch_app")
    }

    func testLaunchAppUnknownAppIsAppNotFound() throws {
        let context = ServiceContext(
            appResolver: AppResolver(environment: FakeAppEnvironment(records: []))
        )
        let server = MCPServer(registry: ToolHandlers.registry(context: context))
        initialize(server)

        let response = try parse(server.process(call(
            id: 11,
            name: "launch_app",
            arguments: #"{"app":"no-such-app-xyz","waitForWindowMs":0}"#
        )))
        XCTAssertNil(response["error"])
        let payload = try toolErrorPayload(response)
        XCTAssertEqual(payload["code"]?.stringValue, "app_not_found")
    }

    // MARK: - Helpers

    private struct FakeAppEnvironment: AppEnvironment {
        let records: [AppRecord]
        func allApps() -> [AppRecord] { records }
        func app(forPID pid: Int32) -> AppRecord? { records.first { $0.pid == pid } }
        func pathExists(_ path: String) -> Bool { false }
    }

    private func makeServer() -> MCPServer {
        MCPServer(registry: ToolHandlers.registry(context: ServiceContext()))
    }

    private func initialize(_ server: MCPServer) {
        _ = server.process(request(id: 0, method: "initialize", params: "{}"))
    }

    private func request(id: Int, method: String, params: String? = nil) -> String {
        if let params {
            return #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
        }
        return #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"}"#
    }

    private func call(id: Int, name: String, arguments: String = "{}") -> String {
        request(id: id, method: "tools/call", params: #"{"name":"\#(name)","arguments":\#(arguments)}"#)
    }

    private func parse(_ line: String?) throws -> JSONValue {
        try JSONValue.parse(try XCTUnwrap(line))
    }

    private func toolErrorPayload(_ response: JSONValue) throws -> JSONValue {
        XCTAssertEqual(response["result"]?["isError"]?.boolValue, true)
        let text = try XCTUnwrap(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        return try JSONValue.parse(text)
    }
}
