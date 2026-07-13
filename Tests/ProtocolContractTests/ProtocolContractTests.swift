import XCTest
import CoreGraphics
import ComputerUseCore
@testable import ActionEngine
@testable import MCPServer
@testable import ComputerUseService

/// End-to-end contract checks over the **real** Phase 1 tool registry (the handlers
/// wired in `ComputerUseService`), driven through `MCPServer.process`. Everything
/// here is in-process and permission-free: no test invokes `list_apps` or
/// `get_app_state` (which read live system state), and `doctor` uses only the
/// non-prompting preflight APIs.
final class ProtocolContractTests: XCTestCase {
    // MARK: - Tool table (§4)

    func testAllDefinedToolsAreEnabled() {
        XCTAssertEqual(
            ToolCatalog.enabledNames,
            ["doctor", "list_apps", "get_app_state", "screenshot", "end_app_session",
             "click", "perform_action", "set_value", "select_text", "scroll",
             "press_key", "type_text", "drag", "wait_for"]
        )
    }

    func testPhase2ToolsAreEnabled() {
        for name in ["click", "perform_action", "set_value", "select_text", "scroll"] {
            XCTAssertTrue(ToolCatalog.isEnabled(name), "\(name) should be enabled in Phase 2")
        }
    }

    func testPhase4ToolsAreEnabled() {
        for name in ["press_key", "type_text", "drag"] {
            XCTAssertTrue(ToolCatalog.exists(name), "\(name) should be defined")
            XCTAssertTrue(ToolCatalog.isEnabled(name), "\(name) should be enabled in Phase 4")
        }
    }

    func testCatalogCoversAllDefinedTools() {
        XCTAssertEqual(ToolCatalog.all.count, 14)
    }

    func testProtocolVersionIsFrozen() {
        XCTAssertEqual(MCPServer.mcpProtocolVersion, "2025-06-18")
    }

    // MARK: - initialize → tools/list golden shape

    func testToolsListGoldenShapeOverRealRegistry() throws {
        let server = makeServer()
        initialize(server)
        let response = try parse(server.process(request(id: 1, method: "tools/list")))
        let tools = try XCTUnwrap(response["result"]?["tools"]?.arrayValue)

        // Exactly the fourteen enabled tools (Phase 1 + v1.5 screenshot + Phase 2 + Phase 4 +
        // v1.5 wait_for), in table order.
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue },
                       ["doctor", "list_apps", "get_app_state", "screenshot", "end_app_session",
                        "click", "perform_action", "set_value", "select_text", "scroll",
                        "press_key", "type_text", "drag", "wait_for"])

        // Every descriptor carries name/description/object-schema.
        for tool in tools {
            XCTAssertNotNil(tool["name"]?.stringValue)
            XCTAssertFalse((tool["description"]?.stringValue ?? "").isEmpty)
            XCTAssertEqual(tool["inputSchema"]?["type"]?.stringValue, "object")
        }

        // Golden: the get_app_state schema is byte-stable (frozen §4.1).
        let getState = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "get_app_state" })
        XCTAssertEqual(
            getState["inputSchema"]?.serialized(),
            #"{"additionalProperties":false,"properties":{"app":{"type":"string"},"disableDiff":{"default":false,"type":"boolean"},"forceFullTree":{"default":false,"type":"boolean"},"includeScreenshot":{"default":"auto","enum":["auto","always","never"]},"maxNodes":{"description":"Optional: raise this snapshot's emitted-node budget (default 600, hard max 2000) when a large tree truncates. Prefer scopeElementId for deep pages.","maximum":2000,"minimum":1,"type":"integer"},"scopeElementId":{"description":"Optional: re-walk the tree rooted at this element (e.g. a web area) instead of the window. Only meaningful with an element id copied from THIS session's CURRENT snapshot. An id that cannot be honored is ignored: the server returns a full unscoped snapshot with a scope_ignored warning — copy fresh ids from that tree, then scope. An honored scoped snapshot retires all other element ids.","pattern":"^e[0-9]+$","type":"string"},"windowId":{"description":"Optional WindowServer id from an earlier get_app_state window.id. Omit or pass 0 to auto-select. Never use list_apps.windows or a zero-based window index.","minimum":0,"type":"integer"}},"required":["app"],"type":"object"}"#
        )

        // Golden: the v1.5 screenshot schema (§18.9) — app required, optional windowId with the
        // same §10.2 semantics/description as get_app_state's windowId.
        let screenshot = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "screenshot" })
        XCTAssertEqual(
            screenshot["inputSchema"]?.serialized(),
            #"{"additionalProperties":false,"properties":{"app":{"type":"string"},"windowId":{"description":"Optional WindowServer id from an earlier get_app_state window.id. Omit or pass 0 to auto-select. Never use list_apps.windows or a zero-based window index.","minimum":0,"type":"integer"}},"required":["app"],"type":"object"}"#
        )
    }

    // MARK: - Phase 2 action tool schemas (§4.2)

    func testActionToolSchemasAreExposedAndFrozen() throws {
        let server = makeServer()
        initialize(server)
        let tools = try XCTUnwrap(try parse(server.process(request(id: 1, method: "tools/list")))["result"]?["tools"]?.arrayValue)
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool -> (String, JSONValue)? in
            guard let name = tool["name"]?.stringValue, let schema = tool["inputSchema"] else { return nil }
            return (name, schema)
        })

        // click carries the ElementTarget (semantic path) plus the Phase 4 coordinate
        // fallback fields (§16): app+sessionId required, revision/elementId optional (the
        // semantic path is validated in the handler), plus at/space/button/modifiers/interference.
        let click = try XCTUnwrap(byName["click"])
        XCTAssertEqual(
            click.serialized(),
            #"{"additionalProperties":false,"properties":{"app":{"type":"string"},"at":{"additionalProperties":false,"properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"],"type":"object"},"button":{"default":"left","enum":["left","right"]},"elementId":{"pattern":"^e[0-9]+$","type":"string"},"interference":{"default":"background-only","enum":["background-only","allow-brief-focus","foreground-takeover"]},"modifiers":{"items":{"enum":["cmd","ctrl","opt","shift","fn"]},"type":"array"},"revision":{"minimum":1,"type":"integer"},"sessionId":{"pattern":"^s[0-9]+$","type":"string"},"space":{"default":"window","enum":["window","screenshot"]}},"required":["app","sessionId"],"type":"object"}"#
        )

        // set_value adds a string|number|boolean value plus the optional v1.5 commit flag (§18.5).
        let setValue = try XCTUnwrap(byName["set_value"])
        XCTAssertEqual(
            setValue.serialized(),
            #"{"additionalProperties":false,"properties":{"app":{"type":"string"},"commit":{"default":false,"type":"boolean"},"elementId":{"pattern":"^e[0-9]+$","type":"string"},"revision":{"minimum":1,"type":"integer"},"sessionId":{"pattern":"^s[0-9]+$","type":"string"},"value":{"type":["string","number","boolean"]}},"required":["app","sessionId","revision","elementId","value"],"type":"object"}"#
        )

        // scroll adds direction/by/count plus the Phase 4 coordinate fields (at/space/interference);
        // only app+sessionId+direction are required (semantic vs coordinate dispatched on `at`).
        let scroll = try XCTUnwrap(byName["scroll"])
        XCTAssertEqual(
            scroll.serialized(),
            #"{"additionalProperties":false,"properties":{"app":{"type":"string"},"at":{"additionalProperties":false,"properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"],"type":"object"},"by":{"default":"line","enum":["line","page"]},"count":{"default":1,"minimum":1,"type":"integer"},"direction":{"enum":["up","down","left","right"]},"elementId":{"pattern":"^e[0-9]+$","type":"string"},"interference":{"default":"background-only","enum":["background-only","allow-brief-focus","foreground-takeover"]},"revision":{"minimum":1,"type":"integer"},"sessionId":{"pattern":"^s[0-9]+$","type":"string"},"space":{"default":"window","enum":["window","screenshot"]}},"required":["app","sessionId","direction"],"type":"object"}"#
        )

        // press_key: app+sessionId+combo required, optional interference plus the v1.5
        // element-targeting pair (revision+elementId, §18.6).
        let pressKey = try XCTUnwrap(byName["press_key"])
        XCTAssertEqual(
            pressKey.serialized(),
            #"{"additionalProperties":false,"properties":{"app":{"type":"string"},"combo":{"type":"string"},"elementId":{"pattern":"^e[0-9]+$","type":"string"},"interference":{"default":"background-only","enum":["background-only","allow-brief-focus","foreground-takeover"]},"revision":{"minimum":1,"type":"integer"},"sessionId":{"pattern":"^s[0-9]+$","type":"string"}},"required":["app","sessionId","combo"],"type":"object"}"#
        )

        // drag: app+sessionId+from+to required, plus space/button/modifiers/interference.
        let drag = try XCTUnwrap(byName["drag"])
        XCTAssertEqual(
            drag.serialized(),
            #"{"additionalProperties":false,"properties":{"app":{"type":"string"},"button":{"default":"left","enum":["left","right"]},"from":{"additionalProperties":false,"properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"],"type":"object"},"interference":{"default":"background-only","enum":["background-only","allow-brief-focus","foreground-takeover"]},"modifiers":{"items":{"enum":["cmd","ctrl","opt","shift","fn"]},"type":"array"},"sessionId":{"pattern":"^s[0-9]+$","type":"string"},"space":{"default":"window","enum":["window","screenshot"]},"to":{"additionalProperties":false,"properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"],"type":"object"}},"required":["app","sessionId","from","to"],"type":"object"}"#
        )

        // wait_for (§18.7): app+sessionId+conditions required; conditions is a 1–4 array of the
        // discriminated Condition definition; optional mode (all|any) and timeoutMs (100–30000).
        let waitFor = try XCTUnwrap(byName["wait_for"])
        XCTAssertEqual(
            waitFor.serialized(),
            ##"{"additionalProperties":false,"definitions":{"Condition":{"properties":{"from":{"type":"string"},"kind":{"enum":["title_changed","title_contains","url_changed","url_contains","element_exists","element_gone"]},"role":{"type":"string"},"titleContains":{"type":"string"},"value":{"type":"string"},"valueContains":{"type":"string"}},"required":["kind"],"type":"object"}},"properties":{"app":{"type":"string"},"conditions":{"items":{"$ref":"#/definitions/Condition"},"maxItems":4,"minItems":1,"type":"array"},"mode":{"default":"all","enum":["all","any"]},"sessionId":{"pattern":"^s[0-9]+$","type":"string"},"timeoutMs":{"default":5000,"maximum":30000,"minimum":100,"type":"integer"}},"required":["app","sessionId","conditions"],"type":"object"}"##
        )
    }

    // MARK: - v1.5 wait_for validation + gates (§18.7)

    func testWaitForRejectsMalformedConditions() throws {
        let server = makeServer()
        initialize(server)
        // Unknown condition kind → -32602 (the discriminated union the schema cannot express).
        XCTAssertEqual(
            try parse(server.process(call(id: 80, name: "wait_for",
                arguments: #"{"app":"x","sessionId":"s1","conditions":[{"kind":"page_loaded"}]}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
        // Missing the required per-kind field (title_changed needs "from").
        XCTAssertEqual(
            try parse(server.process(call(id: 81, name: "wait_for",
                arguments: #"{"app":"x","sessionId":"s1","conditions":[{"kind":"title_changed"}]}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
        // element matcher with no fields → -32602.
        XCTAssertEqual(
            try parse(server.process(call(id: 82, name: "wait_for",
                arguments: #"{"app":"x","sessionId":"s1","conditions":[{"kind":"element_exists"}]}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
        // Empty conditions array (minItems 1) and too many (maxItems 4) are schema-invalid.
        XCTAssertEqual(
            try parse(server.process(call(id: 83, name: "wait_for",
                arguments: #"{"app":"x","sessionId":"s1","conditions":[]}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
        let five = #"{"app":"x","sessionId":"s1","conditions":[{"kind":"title_contains","value":"a"},{"kind":"title_contains","value":"b"},{"kind":"title_contains","value":"c"},{"kind":"title_contains","value":"d"},{"kind":"title_contains","value":"e"}]}"#
        XCTAssertEqual(
            try parse(server.process(call(id: 84, name: "wait_for", arguments: five)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
        // Out-of-range timeoutMs is schema-invalid.
        XCTAssertEqual(
            try parse(server.process(call(id: 85, name: "wait_for",
                arguments: #"{"app":"x","sessionId":"s1","conditions":[{"kind":"title_contains","value":"a"}],"timeoutMs":50}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
    }

    func testWaitForUnknownSessionIsStaleRevisionWithNullCurrent() throws {
        // Session existence runs after the app policy gate and BEFORE any AX/window work, so an
        // unknown session is a permission-free stale_revision with the read-side sentinel
        // (provided: 0, current: null) — no live AX is touched (§18.7).
        let (server, _) = actionServer(records: [fixtureRecord()])
        let args = #"{"app":"computer-use-fixture","sessionId":"s404","conditions":[{"kind":"title_contains","value":"x"}]}"#
        let payload = try toolErrorPayload(try parse(server.process(call(id: 86, name: "wait_for", arguments: args))))
        XCTAssertEqual(payload["code"]?.stringValue, "stale_revision")
        XCTAssertEqual(payload["data"]?["provided"]?.intValue, 0)
        XCTAssertEqual(payload["data"]?["current"]?.isNull, true)
    }

    func testWaitForOnDeniedAppIsPolicyDenied() throws {
        // The read-side denylist gate runs first (§13.5/§18.7).
        let blocked = AppRecord(bundleId: "com.example.blocked", displayName: "Blocked", path: nil, pid: 999, isRunning: true, windows: 1)
        let (server, _) = actionServer(records: [blocked], deniedApps: ["com.example.blocked"])
        let args = #"{"app":"com.example.blocked","sessionId":"s1","conditions":[{"kind":"title_contains","value":"x"}]}"#
        let payload = try toolErrorPayload(try parse(server.process(call(id: 87, name: "wait_for", arguments: args))))
        XCTAssertEqual(payload["code"]?.stringValue, "policy_denied")
        XCTAssertEqual(payload["data"]?["reason"]?.stringValue, "app_denied")
        XCTAssertEqual(payload["data"]?["tool"]?.stringValue, "wait_for")
    }

    // MARK: - v1.5 screenshot: catalog, schema, and gate ordering (§18.9)

    func testScreenshotToolIsDefinedAndEnabled() throws {
        XCTAssertTrue(ToolCatalog.exists("screenshot"))
        XCTAssertTrue(ToolCatalog.isEnabled("screenshot"))
        // It is exposed over the real registry (tools/list), between get_app_state and
        // end_app_session (the two window-observation tools grouped together).
        let server = makeServer()
        initialize(server)
        let tools = try XCTUnwrap(try parse(server.process(request(id: 90, method: "tools/list")))["result"]?["tools"]?.arrayValue)
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(names.contains("screenshot"))
        let screenshot = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "screenshot" })
        XCTAssertFalse((screenshot["description"]?.stringValue ?? "").isEmpty)
        XCTAssertTrue((screenshot["description"]?.stringValue ?? "").contains("Screen Recording"))
    }

    func testScreenshotSchemaRejectsBadArguments() throws {
        let server = makeServer()
        initialize(server)
        // Missing the required "app".
        XCTAssertEqual(
            try parse(server.process(call(id: 91, name: "screenshot", arguments: "{}")))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
        // Unknown property (additionalProperties: false).
        XCTAssertEqual(
            try parse(server.process(call(id: 92, name: "screenshot",
                arguments: #"{"app":"x","extra":true}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
        // Negative windowId (minimum 0).
        XCTAssertEqual(
            try parse(server.process(call(id: 93, name: "screenshot",
                arguments: #"{"app":"x","windowId":-1}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
    }

    func testScreenshotOnDeniedAppIsPolicyDenied() throws {
        // §18.9 processing order: the read-side app policy gate (§13.5) runs before any AX or
        // Screen-Recording work, so a denied app short-circuits to policy_denied — permission-free
        // and independent of the live AX/SR grant state.
        let blocked = AppRecord(bundleId: "com.example.blocked", displayName: "Blocked", path: nil, pid: 999, isRunning: true, windows: 1)
        let (server, _) = actionServer(records: [blocked], deniedApps: ["com.example.blocked"])
        let payload = try toolErrorPayload(try parse(server.process(
            call(id: 94, name: "screenshot", arguments: #"{"app":"com.example.blocked"}"#)
        )))
        XCTAssertEqual(payload["code"]?.stringValue, "policy_denied")
        XCTAssertEqual(payload["data"]?["reason"]?.stringValue, "app_denied")
        XCTAssertEqual(payload["data"]?["tool"]?.stringValue, "screenshot")
    }

    func testScreenshotUnknownAppIsAppNotFound() throws {
        // App resolution (§10.1) precedes the AX preflight and Screen-Recording gate, so an
        // unresolved app is a permission-free app_not_found (no live AX/SR is ever touched).
        let (server, _) = actionServer(records: [fixtureRecord()])
        let payload = try toolErrorPayload(try parse(server.process(
            call(id: 95, name: "screenshot", arguments: #"{"app":"Ghost"}"#)
        )))
        XCTAssertEqual(payload["code"]?.stringValue, "app_not_found")
        XCTAssertEqual(payload["data"]?["query"]?.stringValue, "Ghost")
    }

    func testActionSchemaValidationRejectsBadArguments() throws {
        let server = makeServer()
        initialize(server)

        // Missing elementId (required).
        XCTAssertEqual(
            try parse(server.process(call(id: 30, name: "click",
                arguments: #"{"app":"x","sessionId":"s1","revision":1}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
        // revision below the minimum of 1.
        XCTAssertEqual(
            try parse(server.process(call(id: 31, name: "click",
                arguments: #"{"app":"x","sessionId":"s1","revision":0,"elementId":"e1"}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
        // Malformed sessionId (pattern ^s[0-9]+$).
        XCTAssertEqual(
            try parse(server.process(call(id: 32, name: "click",
                arguments: #"{"app":"x","sessionId":"nope","revision":1,"elementId":"e1"}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
        // Unknown scroll direction (enum).
        XCTAssertEqual(
            try parse(server.process(call(id: 33, name: "scroll",
                arguments: #"{"app":"x","sessionId":"s1","revision":1,"elementId":"e1","direction":"sideways"}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
        // perform_action missing the action name.
        XCTAssertEqual(
            try parse(server.process(call(id: 34, name: "perform_action",
                arguments: #"{"app":"x","sessionId":"s1","revision":1,"elementId":"e1"}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
    }

    // MARK: - Phase 2 policy + stale paths (faked resolver + session)

    func testMutationOnDeniedAppIsPolicyDenied() throws {
        let blocked = AppRecord(bundleId: "com.example.blocked", displayName: "Blocked", path: nil, pid: 999, isRunning: true, windows: 1)
        let (server, _) = actionServer(records: [blocked], deniedApps: ["com.example.blocked"])
        let args = #"{"app":"com.example.blocked","sessionId":"s1","revision":1,"elementId":"e1"}"#
        let payload = try toolErrorPayload(try parse(server.process(call(id: 40, name: "click", arguments: args))))
        XCTAssertEqual(payload["code"]?.stringValue, "policy_denied")
        XCTAssertEqual(payload["data"]?["reason"]?.stringValue, "app_denied")
        XCTAssertEqual(payload["data"]?["app"]?.stringValue, "com.example.blocked")
        XCTAssertEqual(payload["data"]?["tool"]?.stringValue, "click")
    }

    func testConfusedDeputyForeignSessionUnderFixtureNameIsPolicyDenied() throws {
        // A session belongs to one app, then a mutation names another app but points
        // at the foreign session. The app policy passes, but the confused-deputy guard
        // must reject it as policy_denied before any element resolution (§13.5).
        let blocked = AppRecord(bundleId: "com.example.blocked", displayName: "Blocked", path: nil, pid: 999, isRunning: true, windows: 1)
        let (server, context) = actionServer(records: [fixtureRecord(), blocked])
        let session = context.sessionManager.ensureSession(appId: "pid:999", pid: 999)
        XCTAssertEqual(session.sessionId, "s1")
        let args = #"{"app":"computer-use-fixture","sessionId":"s1","revision":1,"elementId":"e1"}"#
        let payload = try toolErrorPayload(try parse(server.process(call(id: 44, name: "click", arguments: args))))
        XCTAssertEqual(payload["code"]?.stringValue, "policy_denied")
        XCTAssertEqual(payload["data"]?["reason"]?.stringValue, "app_denied")
        XCTAssertEqual(payload["data"]?["app"]?.stringValue, "computer-use-fixture")
        XCTAssertEqual(payload["data"]?["tool"]?.stringValue, "click")
    }

    func testMutationWithUnknownSessionIsStaleRevisionWithNullCurrent() throws {
        let (server, _) = actionServer(records: [fixtureRecord()])
        let args = #"{"app":"computer-use-fixture","sessionId":"s404","revision":1,"elementId":"e1"}"#
        let payload = try toolErrorPayload(try parse(server.process(call(id: 41, name: "click", arguments: args))))
        XCTAssertEqual(payload["code"]?.stringValue, "stale_revision")
        XCTAssertEqual(payload["data"]?["sessionId"]?.stringValue, "s404")
        XCTAssertEqual(payload["data"]?["provided"]?.intValue, 1)
        XCTAssertEqual(payload["data"]?["current"]?.isNull, true, "unknown session ⇒ current is null")
    }

    func testMutationWithMismatchedRevisionIsStaleRevisionWithCurrent() throws {
        let (server, context) = actionServer(records: [fixtureRecord()])
        let session = context.sessionManager.ensureSession(appId: "pid:4242", pid: 4242)
        XCTAssertEqual(session.sessionId, "s1")
        let args = #"{"app":"computer-use-fixture","sessionId":"s1","revision":5,"elementId":"e1"}"#
        let payload = try toolErrorPayload(try parse(server.process(call(id: 42, name: "click", arguments: args))))
        XCTAssertEqual(payload["code"]?.stringValue, "stale_revision")
        XCTAssertEqual(payload["data"]?["provided"]?.intValue, 5)
        XCTAssertEqual(payload["data"]?["current"]?.intValue, 1)
    }

    func testMutationWithUnknownElementIsStaleElement() throws {
        let (server, context) = actionServer(records: [fixtureRecord()])
        _ = context.sessionManager.ensureSession(appId: "pid:4242", pid: 4242) // s1 @ revision 1
        let args = #"{"app":"computer-use-fixture","sessionId":"s1","revision":1,"elementId":"e99"}"#
        let payload = try toolErrorPayload(try parse(server.process(call(id: 43, name: "click", arguments: args))))
        XCTAssertEqual(payload["code"]?.stringValue, "stale_element")
        XCTAssertEqual(payload["data"]?["elementId"]?.stringValue, "e99")
        XCTAssertEqual(payload["data"]?["revision"]?.intValue, 1)
    }

    // MARK: - Phase 4 fallback tools over the real service (§16)

    func testPressKeyOnDeniedAppIsPolicyDenied() throws {
        let blocked = AppRecord(bundleId: "com.example.blocked", displayName: "Blocked", path: nil, pid: 999, isRunning: true, windows: 1)
        let (server, _, _) = fallbackServer(records: [blocked], frontmostPID: 999, deniedApps: ["com.example.blocked"])
        let args = #"{"app":"com.example.blocked","sessionId":"s1","combo":"cmd+a"}"#
        let payload = try toolErrorPayload(try parse(server.process(call(id: 60, name: "press_key", arguments: args))))
        XCTAssertEqual(payload["code"]?.stringValue, "policy_denied")
        XCTAssertEqual(payload["data"]?["reason"]?.stringValue, "app_denied")
        XCTAssertEqual(payload["data"]?["tool"]?.stringValue, "press_key")
    }

    func testPressKeyBackgroundOnlyNotFrontmostIsFocusRequired() throws {
        // Fixture session exists (pid 4242) but the user's app (pid 9999) is frontmost.
        let (server, context, synth) = fallbackServer(records: [fixtureRecord()], frontmostPID: 9999, frontmostName: "UserApp")
        _ = context.sessionManager.ensureSession(appId: "pid:4242", pid: 4242) // s1
        let args = #"{"app":"computer-use-fixture","sessionId":"s1","combo":"cmd+a"}"#
        let payload = try toolErrorPayload(try parse(server.process(call(id: 61, name: "press_key", arguments: args))))
        XCTAssertEqual(payload["code"]?.stringValue, "focus_required")
        XCTAssertEqual(payload["data"]?["frontmostApp"]?.stringValue, "UserApp")
        XCTAssertTrue(synth.events.isEmpty, "background-only must not deliver to a non-frontmost target")
    }

    func testPressKeyBackgroundOnlyFrontmostCompletes() throws {
        // Target is frontmost, so background-only delivers directly.
        let (server, context, synth) = fallbackServer(records: [fixtureRecord()], frontmostPID: 4242)
        _ = context.sessionManager.ensureSession(appId: "pid:4242", pid: 4242) // s1
        let args = #"{"app":"computer-use-fixture","sessionId":"s1","combo":"cmd+a"}"#
        let payload = try toolSuccessPayload(server.process(call(id: 62, name: "press_key", arguments: args)))
        XCTAssertEqual(payload["status"]?.stringValue, "completed")
        XCTAssertEqual(payload["method"]?.stringValue, "keyboard")
        XCTAssertEqual(payload["focusChanged"]?.boolValue, false)
        XCTAssertEqual(payload["targetVerified"]?.boolValue, true)
        XCTAssertFalse(synth.events.isEmpty, "the frontmost target received the key events")
    }

    func testPressKeyMalformedComboIs32602() throws {
        let (server, context, _) = fallbackServer(records: [fixtureRecord()], frontmostPID: 4242)
        _ = context.sessionManager.ensureSession(appId: "pid:4242", pid: 4242)
        let args = #"{"app":"computer-use-fixture","sessionId":"s1","combo":"cmd+kittens"}"#
        let response = try parse(server.process(call(id: 63, name: "press_key", arguments: args)))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    func testAllowBriefFocusCompletesWithFocusTransaction() throws {
        let (server, context, _) = fallbackServer(records: [fixtureRecord()], frontmostPID: 9999)
        _ = context.sessionManager.ensureSession(appId: "pid:4242", pid: 4242)
        let args = #"{"app":"computer-use-fixture","sessionId":"s1","text":"hi","interference":"allow-brief-focus"}"#
        let payload = try toolSuccessPayload(server.process(call(id: 64, name: "type_text", arguments: args)))
        XCTAssertEqual(payload["status"]?.stringValue, "completed")
        XCTAssertEqual(payload["method"]?.stringValue, "keyboard")
        XCTAssertEqual(payload["focusChanged"]?.boolValue, true)
        XCTAssertEqual(payload["focusRestored"]?.boolValue, true)
    }

    func testCoordinateClickMapsWindowPointAndCompletes() throws {
        let (server, context, synth) = fallbackServer(records: [fixtureRecord()], frontmostPID: 4242)
        _ = context.sessionManager.ensureSession(appId: "pid:4242", pid: 4242)
        context.storeWindowGeometry(
            WindowGeometry(windowId: 7, framePoints: Rect(x: 100, y: 200, width: 400, height: 300), screenshotPixels: nil, scale: 2.0),
            forSession: "s1"
        )
        // The coordinate-safety gate re-reads the window's live frame; in a permission-free
        // test there is no real WindowServer window, so supply the (unmoved) current frame.
        context.currentWindowFrameOverride = { _ in Rect(x: 100, y: 200, width: 400, height: 300) }
        let args = #"{"app":"computer-use-fixture","sessionId":"s1","at":{"x":10,"y":20}}"#
        let payload = try toolSuccessPayload(server.process(call(id: 65, name: "click", arguments: args)))
        XCTAssertEqual(payload["status"]?.stringValue, "completed")
        XCTAssertEqual(payload["method"]?.stringValue, "pointer")
        // Window point (10,20) + frame origin (100,200) → global (110,220).
        let point = try XCTUnwrap(synth.firstMouseDown)
        XCTAssertEqual(point, CGPoint(x: 110, y: 220))
    }

    func testSemanticClickStillTakesElementPathWithoutAt() throws {
        // Without `at`, click stays on the Phase 2 semantic path: a missing elementId is a
        // handler-level invalid-params (the coordinate fallback is never auto-selected).
        let (server, context, _) = fallbackServer(records: [fixtureRecord()], frontmostPID: 4242)
        _ = context.sessionManager.ensureSession(appId: "pid:4242", pid: 4242)
        let args = #"{"app":"computer-use-fixture","sessionId":"s1","revision":1}"#
        let response = try parse(server.process(call(id: 66, name: "click", arguments: args)))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    func testToolsListRejectedBeforeInitialize() throws {
        let server = makeServer()
        let response = try parse(server.process(request(id: 1, method: "tools/list")))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.serverNotInitialized)
    }

    // MARK: - Request validation errors

    func testUnknownToolYields32602() throws {
        let server = makeServer()
        initialize(server)
        let response = try parse(server.process(call(id: 2, name: "no_such_tool")))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    func testMissingRequiredArgumentYields32602() throws {
        let server = makeServer()
        initialize(server)
        let response = try parse(server.process(call(id: 3, name: "get_app_state", arguments: "{}")))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    // MARK: - v1.5 get_app_state schema (§18.2)

    func testGetAppStateRejectsOutOfRangeMaxNodes() throws {
        let server = makeServer()
        initialize(server)
        // Below the minimum (1) and above the frozen ceiling (2000) are both schema-invalid,
        // rejected before the handler ever touches live AX.
        XCTAssertEqual(
            try parse(server.process(call(id: 70, name: "get_app_state", arguments: #"{"app":"x","maxNodes":0}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
        XCTAssertEqual(
            try parse(server.process(call(id: 71, name: "get_app_state", arguments: #"{"app":"x","maxNodes":3000}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
    }

    func testGetAppStateRejectsMalformedScopeElementId() throws {
        let server = makeServer()
        initialize(server)
        // scopeElementId must match ^e[0-9]+$.
        XCTAssertEqual(
            try parse(server.process(call(id: 72, name: "get_app_state", arguments: #"{"app":"x","scopeElementId":"nope"}"#)))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
    }

    // MARK: - v1.5 web-content accessibility toggle (§18.1)

    func testWebAXEnabledByDefaultAndDisabledByEnv() {
        XCTAssertTrue(ServiceContext.webAXEnabledFromEnvironment([:]), "web-AX is on by default")
        XCTAssertFalse(ServiceContext.webAXEnabledFromEnvironment(["SEMANTOUCH_WEB_AX": "off"]))
        XCTAssertFalse(ServiceContext.webAXEnabledFromEnvironment(["SEMANTOUCH_WEB_AX": "OFF"]), "case-insensitive")
        XCTAssertTrue(ServiceContext.webAXEnabledFromEnvironment(["SEMANTOUCH_WEB_AX": "on"]))
    }

    func testWebAXAttemptedFlagTracksPerSession() {
        let context = ServiceContext()
        XCTAssertFalse(context.webAXEnablementAttempted(forSession: "s1"))
        context.markWebAXEnablementAttempted(forSession: "s1")
        XCTAssertTrue(context.webAXEnablementAttempted(forSession: "s1"))
        XCTAssertFalse(context.webAXEnablementAttempted(forSession: "s2"), "other sessions are independent")
    }

    func testAdditionalPropertyYields32602() throws {
        let server = makeServer()
        initialize(server)
        let response = try parse(server.process(
            call(id: 4, name: "end_app_session", arguments: #"{"sessionId":"s1","extra":true}"#)
        ))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    func testSessionIdPatternViolationYields32602() throws {
        let server = makeServer()
        initialize(server)
        // "abc" does not match ^s[0-9]+$.
        let response = try parse(server.process(
            call(id: 5, name: "end_app_session", arguments: #"{"sessionId":"abc"}"#)
        ))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    func testMalformedJSONYields32700() throws {
        let server = makeServer()
        let response = try parse(server.process("{not json"))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.parseError)
        XCTAssertEqual(response["id"]?.isNull, true)
    }

    func testUnknownMethodYields32601() throws {
        let server = makeServer()
        initialize(server)
        let response = try parse(server.process(request(id: 6, method: "totally/unknown")))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.methodNotFound)
    }

    // MARK: - Disabled-tool call → policy_denied (§4, §6)

    func testDisabledToolReturnsPolicyDenied() throws {
        // Every defined tool is enabled in Phase 4, so exercise the disabled-tool mechanism
        // (§4, §6) over a registry that deliberately omits one tool from its enabled set: a
        // call to it short-circuits to a tool-level policy_denied / tool_disabled before any
        // argument validation.
        let context = ServiceContext()
        let registry = ToolRegistry.standard(
            enabled: Set(ToolCatalog.enabledNames).subtracting(["press_key"]),
            handlers: ToolHandlers.handlers(context: context)
        )
        let server = MCPServer(registry: registry)
        initialize(server)
        let response = try parse(server.process(call(id: 7, name: "press_key")))
        XCTAssertNil(response["error"], "a disabled tool is a tool-level error, not a JSON-RPC error")
        let payload = try toolErrorPayload(response)
        XCTAssertEqual(payload["code"]?.stringValue, "policy_denied")
        XCTAssertEqual(payload["data"]?["reason"]?.stringValue, "tool_disabled")
        XCTAssertEqual(payload["data"]?["tool"]?.stringValue, "press_key")
    }

    // MARK: - end_app_session lifecycle (§4.1)

    func testEndAppSessionLifecycle() throws {
        let context = ServiceContext()
        // Seed a session as get_app_state would (permission-free).
        let session = context.sessionManager.ensureSession(appId: "com.example.demo", pid: 4242)
        _ = context.elementTable(forSession: session.sessionId)
        XCTAssertEqual(session.sessionId, "s1")

        let server = MCPServer(registry: ToolHandlers.registry(context: context))
        initialize(server)

        // First end: ended == true.
        let first = try toolSuccessPayload(server.process(
            call(id: 8, name: "end_app_session", arguments: #"{"sessionId":"s1"}"#)
        ))
        XCTAssertEqual(first["sessionId"]?.stringValue, "s1")
        XCTAssertEqual(first["ended"]?.boolValue, true)

        // Second end of the same id: ended == false (not an error).
        let second = try toolSuccessPayload(server.process(
            call(id: 9, name: "end_app_session", arguments: #"{"sessionId":"s1"}"#)
        ))
        XCTAssertEqual(second["ended"]?.boolValue, false)

        // Unknown session: ended == false.
        let unknown = try toolSuccessPayload(server.process(
            call(id: 10, name: "end_app_session", arguments: #"{"sessionId":"s999"}"#)
        ))
        XCTAssertEqual(unknown["ended"]?.boolValue, false)
    }

    // MARK: - doctor (permission-free, prompt-free)

    func testDoctorReturnsWellFormedResult() throws {
        let server = makeServer()
        initialize(server)
        let text = try toolSuccessText(server.process(call(id: 11, name: "doctor")))
        let result = try CanonicalJSON.decode(DoctorResult.self, from: text)
        XCTAssertEqual(result.helper.version, MCPServer.serverVersion)
        XCTAssertFalse(result.helper.path.isEmpty)
        // ready is exactly the conjunction of the two grants.
        XCTAssertEqual(result.ready, result.accessibility == .granted && result.screenRecording == .granted)
        // When not ready, remediation is non-empty and names the binary.
        if !result.ready {
            XCTAssertFalse(result.remediation.isEmpty)
            XCTAssertTrue(result.remediation.contains { $0.contains(result.helper.path) })
        }
    }

    func testDoctorDefaultDoesNotRequestOnboarding() {
        // Sanity: the default path uses non-prompting preflight APIs. This just
        // asserts it returns synchronously with a valid grant vocabulary.
        let result = DoctorService.run(requestOnboarding: false)
        XCTAssertTrue(PermissionStatus.allCases.contains(result.accessibility))
        XCTAssertTrue(PermissionStatus.allCases.contains(result.screenRecording))
    }

    // MARK: - CUError → wire mapping for every code (§6)

    func testEveryErrorCodeHasARepresentativeAndEncodesToItsCode() throws {
        // One representative per §6 code; if a code is added, this map must grow or
        // the coverage assertion below fails.
        let representatives: [CUErrorCode: CUError] = [
            .permissionDenied: .permissionDenied(permission: .screenRecording, helperPath: "/bin/x", remediation: ["a"]),
            .appNotFound: .appNotFound(query: "Ghost"),
            .ambiguousApp: .ambiguousApp(query: "Player", candidates: [
                AppSummary(id: "com.a", displayName: "Player", isRunning: true, windows: 1),
            ]),
            .windowNotFound: .windowNotFound(app: "Safari", windowId: 7),
            .ambiguousWindow: .ambiguousWindow(app: "Safari", candidates: [
                WindowRef(source: .ax),
            ]),
            .uncorrelatedWindow: .uncorrelatedWindow(app: "Safari", ax: WindowRef(source: .ax), sc: nil, signalsTried: ["pid"]),
            .uncapturableWindow: .uncapturableWindow(app: "Safari", windowId: 7, reason: .minimized),
            .staleRevision: .staleRevision(sessionId: "s1", provided: 1, current: 2),
            .staleElement: .staleElement(sessionId: "s1", elementId: "e5", revision: 1),
            .unsupportedAction: .unsupportedAction(elementId: "e5", action: "AXPress", supported: ["AXShowMenu"], reason: nil),
            .focusRequired: .focusRequired(app: "computer-use-fixture", frontmostApp: "Finder"),
            .userInterrupted: .userInterrupted(at: nil),
            .policyDenied: .policyDenied(reason: .appDenied, app: "Terminal", tool: nil),
            .timeout: .timeout(operation: "get_app_state", deadlineMs: 1000),
            .cancelled: .cancelled(reason: "client requested"),
            .internalError: .internalError(detail: "boom"),
        ]

        // Coverage: every frozen code has a representative.
        XCTAssertEqual(Set(representatives.keys), Set(CUErrorCode.allCases))
        XCTAssertEqual(CUErrorCode.allCases.count, 16)

        for (code, error) in representatives {
            XCTAssertEqual(error.code, code)
            let wire = try JSONValue.parse(try error.jsonString())
            XCTAssertEqual(wire["code"]?.stringValue, code.rawValue, "code mismatch for \(code)")
            XCTAssertFalse((wire["message"]?.stringValue ?? "").isEmpty, "empty message for \(code)")
            // Round-trip through Decodable.
            let decoded = try CanonicalJSON.decode(CUError.self, from: try error.jsonString())
            XCTAssertEqual(decoded, error, "round trip failed for \(code)")
        }
    }

    func testPermissionDeniedDataShape() throws {
        let error = CUError.permissionDenied(permission: .accessibility, helperPath: "/bin/x", remediation: ["step"])
        let wire = try JSONValue.parse(try error.jsonString())
        XCTAssertEqual(wire["data"]?["permission"]?.stringValue, "accessibility")
        XCTAssertEqual(wire["data"]?["helperPath"]?.stringValue, "/bin/x")
        XCTAssertEqual(wire["data"]?["remediation"]?.arrayValue?.count, 1)
    }

    // MARK: - Helpers

    private func makeServer() -> MCPServer {
        MCPServer(registry: ToolHandlers.registry(context: ServiceContext()))
    }

    /// A deterministic `AppEnvironment` so the mutation policy gate resolves apps
    /// without touching the live workspace (keeps these tests permission-free).
    private struct FakeAppEnvironment: AppEnvironment {
        let records: [AppRecord]
        func allApps() -> [AppRecord] { records }
        func app(forPID pid: Int32) -> AppRecord? { records.first { $0.pid == pid } }
        func pathExists(_ path: String) -> Bool { false }
    }

    /// The fixture as the resolver would see it.
    private func fixtureRecord() -> AppRecord {
        AppRecord(bundleId: nil, displayName: "computer-use-fixture", path: nil, pid: 4242, isRunning: true, windows: 1)
    }

    /// An initialized server over a context whose resolver is backed by `records`.
    private func actionServer(
        records: [AppRecord],
        deniedApps: Set<String> = []
    ) -> (MCPServer, ServiceContext) {
        let context = ServiceContext(
            policyEngine: PolicyEngine(appDenylist: deniedApps),
            appResolver: AppResolver(environment: FakeAppEnvironment(records: records))
        )
        let server = MCPServer(registry: ToolHandlers.registry(context: context))
        initialize(server)
        return (server, context)
    }

    /// A recording synthesizer for the wire-level fallback tests (no real CGEvent posted).
    final class TestSynthesizer: InputSynthesizer {
        enum Event: Equatable { case key, type, mouse, scroll }
        private(set) var events: [Event] = []
        private(set) var firstMouseDown: CGPoint?
        func keyDown(keyCode: CGKeyCode, flags: CGEventFlags) { events.append(.key) }
        func keyUp(keyCode: CGKeyCode, flags: CGEventFlags) { events.append(.key) }
        func typeUnicode(_ string: String) { events.append(.type) }
        func mouseDown(at: CGPoint, button: PointerButton, flags: CGEventFlags) {
            if firstMouseDown == nil { firstMouseDown = at }
            events.append(.mouse)
        }
        func mouseUp(at: CGPoint, button: PointerButton, flags: CGEventFlags) { events.append(.mouse) }
        func mouseDrag(to: CGPoint, button: PointerButton, flags: CGEventFlags) { events.append(.mouse) }
        func scroll(at: CGPoint, deltaX: Int32, deltaY: Int32, flags: CGEventFlags) { events.append(.scroll) }
        // Pointer restore (v1.5): report no readable pointer so the wire-level goldens see
        // exactly the delivered input events, with no trailing restore move.
        func pointerLocation() -> CGPoint? { nil }
        func movePointer(to: CGPoint) { events.append(.mouse) }
    }

    /// A fake workspace with a fixed frontmost pid; activation makes the target frontmost.
    final class TestWorkspace: WorkspaceControlling {
        var frontmostPID: pid_t?
        var frontmostAppName: String?
        init(frontmostPID: pid_t?, frontmostAppName: String?) {
            self.frontmostPID = frontmostPID
            self.frontmostAppName = frontmostAppName
        }
        func activate(pid: pid_t) -> Bool { frontmostPID = pid; return true }
        func raiseViaAccessibility(pid: pid_t) -> Bool { frontmostPID = pid; return true }
        func recordFocusedElement() -> FocusedElementToken? { FocusedElementToken(payload: "focused") }
        func restoreFocusedElement(_ token: FocusedElementToken) -> Bool { true }
    }

    /// An initialized server whose context injects a fake workspace/synthesizer/interruption
    /// so the Phase 4 interference decision is deterministic and no real input is posted.
    private func fallbackServer(
        records: [AppRecord],
        frontmostPID: pid_t?,
        frontmostName: String? = "OtherApp",
        deniedApps: Set<String> = []
    ) -> (MCPServer, ServiceContext, TestSynthesizer) {
        let synth = TestSynthesizer()
        let workspace = TestWorkspace(frontmostPID: frontmostPID, frontmostAppName: frontmostName)
        let context = ServiceContext(
            policyEngine: PolicyEngine(appDenylist: deniedApps),
            appResolver: AppResolver(environment: FakeAppEnvironment(records: records)),
            synthesizer: synth,
            workspace: workspace,
            interruption: InterruptionState()
        )
        let server = MCPServer(registry: ToolHandlers.registry(context: context))
        initialize(server)
        return (server, context, synth)
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

    /// The parsed JSON payload of a successful (`isError == false`) tool result.
    private func toolSuccessPayload(_ line: String?) throws -> JSONValue {
        try JSONValue.parse(try toolSuccessText(line))
    }

    private func toolSuccessText(_ line: String?) throws -> String {
        let response = try parse(line)
        XCTAssertNil(response["error"])
        XCTAssertEqual(response["result"]?["isError"]?.boolValue, false)
        return try XCTUnwrap(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
    }

    /// The parsed JSON payload of a tool-level error (`isError == true`).
    private func toolErrorPayload(_ response: JSONValue) throws -> JSONValue {
        XCTAssertEqual(response["result"]?["isError"]?.boolValue, true)
        let text = try XCTUnwrap(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        return try JSONValue.parse(text)
    }
}
