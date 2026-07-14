import XCTest
import ComputerUseCore
@testable import MCPServer

/// Handshake, method dispatch, and `tools/call` behavior (§2–§6): golden
/// initialize/tools/list output, error mapping (-32700/-32601/-32602/not-init),
/// tool-level `CUError` rendering, disabled-tool gating, and content blocks.
final class MCPServerTests: XCTestCase {
    // MARK: Identity constants

    func testServerIdentity() {
        XCTAssertEqual(MCPServer.serverName, "semantouch")
        XCTAssertEqual(MCPServer.mcpProtocolVersion, "2025-06-18")
        XCTAssertEqual(MCPServer.contractVersion, "semantouch/1")
        XCTAssertEqual(MCPServer.serverVersion, "0.2.1")
    }

    func testHandledMethodSet() {
        XCTAssertEqual(
            Set(MCPServer.handledMethods),
            ["initialize", "notifications/initialized", "ping", "tools/list", "tools/call"]
        )
    }

    // MARK: Shutdown drain (§17.4)

    /// With nothing in flight, the bounded SIGTERM drain (§17.4) returns `.success`
    /// immediately rather than blocking until the deadline — so shutdown is not delayed when
    /// no worker is mid-`writeLine`.
    func testDrainInFlightReturnsSuccessWhenIdle() {
        let server = MCPServer()
        XCTAssertEqual(server.drainInFlight(deadline: .now() + .seconds(1)), .success)
    }

    // MARK: Handshake

    func testInitializeGoldenResponse() throws {
        let server = MCPServer()
        let response = server.process(request(id: 1, method: "initialize", params: "{}"))
        XCTAssertEqual(
            response,
            #"{"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{}},"protocolVersion":"2025-06-18","serverInfo":{"name":"semantouch","version":"0.2.1"}}}"#
        )
    }

    func testInitializeIgnoresClientProposedVersion() throws {
        let server = MCPServer()
        let response = try parse(server.process(request(
            id: 1, method: "initialize",
            params: #"{"protocolVersion":"1999-01-01","capabilities":{}}"#
        )))
        XCTAssertEqual(response["result"]?["protocolVersion"]?.stringValue, "2025-06-18")
    }

    func testRequestBeforeInitializeIsRejected() throws {
        let server = MCPServer()
        let response = try parse(server.process(request(id: 2, method: "tools/list")))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.serverNotInitialized)
    }

    func testPingRequiresInitializeFirst() throws {
        let server = MCPServer()
        let before = try parse(server.process(request(id: 3, method: "ping")))
        XCTAssertNotNil(before["error"])

        initialize(server)
        let after = try parse(server.process(request(id: 4, method: "ping")))
        XCTAssertEqual(after["result"], .object([:]))
        XCTAssertNil(after["error"])
    }

    func testNotificationsProduceNoResponse() {
        let server = MCPServer()
        initialize(server)
        XCTAssertNil(server.process(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(server.process(#"{"jsonrpc":"2.0","method":"notifications/anything"}"#))
    }

    // MARK: Error mapping

    func testMalformedJSONYieldsParseErrorWithNullId() throws {
        let server = MCPServer()
        let response = try parse(server.process("{ this is not json"))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.parseError)
        XCTAssertEqual(response["id"]?.isNull, true)
    }

    func testUnknownMethodYields32601() throws {
        let server = MCPServer()
        initialize(server)
        let response = try parse(server.process(request(id: 9, method: "does/not/exist")))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.methodNotFound)
    }

    func testMissingMethodWithIdYieldsInvalidRequest() throws {
        let server = MCPServer()
        let response = try parse(server.process(#"{"jsonrpc":"2.0","id":11}"#))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidRequest)
        XCTAssertEqual(response["id"]?.intValue, 11)
    }

    func testEmptyObjectWithoutIdIsIgnored() {
        let server = MCPServer()
        XCTAssertNil(server.process("{}"))
    }

    func testStringIdIsEchoedVerbatim() throws {
        let server = MCPServer()
        let response = try parse(server.process(
            #"{"jsonrpc":"2.0","id":"abc-1","method":"initialize","params":{}}"#
        ))
        XCTAssertEqual(response["id"]?.stringValue, "abc-1")
    }

    // MARK: tools/list

    func testToolsListShowsOnlyEnabledTools() throws {
        let server = MCPServer()
        initialize(server)
        let response = try parse(server.process(request(id: 20, method: "tools/list")))
        let tools = try XCTUnwrap(response["result"]?["tools"]?.arrayValue)
        let names = tools.compactMap { $0["name"]?.stringValue }
        // Phase 1 read-only + v1.5 screenshot + Phase 2 semantic actions + Phase 4 fallback
        // input + v1.5 wait_for.
        XCTAssertEqual(names, ["doctor", "list_apps", "get_app_state", "screenshot", "end_app_session",
                               "click", "perform_action", "set_value", "select_text", "scroll",
                               "press_key", "type_text", "drag", "wait_for"])

        for tool in tools {
            XCTAssertNotNil(tool["description"]?.stringValue)
            XCTAssertEqual(tool["inputSchema"]?["type"]?.stringValue, "object")
        }
    }

    func testDoctorDescriptorSchemaIsExact() throws {
        let server = MCPServer()
        initialize(server)
        let response = try parse(server.process(request(id: 21, method: "tools/list")))
        let tools = try XCTUnwrap(response["result"]?["tools"]?.arrayValue)
        let doctor = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "doctor" })
        XCTAssertEqual(
            doctor["inputSchema"]?.serialized(),
            #"{"additionalProperties":false,"properties":{"requestOnboarding":{"default":false,"type":"boolean"}},"type":"object"}"#
        )
    }

    // MARK: tools/call — dispatch

    func testToolsCallSuccessRendersContentBlocks() throws {
        let registry = ToolRegistry.standard(handlers: [
            "list_apps": { _ in ToolResult.text(#"{"apps":[]}"#) },
        ])
        let server = MCPServer(registry: registry)
        initialize(server)
        let response = try parse(server.process(call(id: 30, name: "list_apps")))
        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["isError"]?.boolValue, false)
        let content = try XCTUnwrap(result["content"]?.arrayValue)
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"]?.stringValue, "text")
        XCTAssertEqual(content[0]["text"]?.stringValue, #"{"apps":[]}"#)
    }

    func testToolsCallDeliversImageContentBlock() throws {
        let registry = ToolRegistry.standard(handlers: [
            "get_app_state": { _ in
                ToolResult(content: [
                    .text(#"{"sessionId":"s1"}"#),
                    .image(base64: "QUJD", mimeType: "image/jpeg"),
                ])
            },
        ])
        let server = MCPServer(registry: registry)
        initialize(server)
        let response = try parse(server.process(
            call(id: 31, name: "get_app_state", arguments: #"{"app":"Finder"}"#)
        ))
        let content = try XCTUnwrap(response["result"]?["content"]?.arrayValue)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1]["type"]?.stringValue, "image")
        XCTAssertEqual(content[1]["data"]?.stringValue, "QUJD")
        XCTAssertEqual(content[1]["mimeType"]?.stringValue, "image/jpeg")
    }

    func testHandlerCUErrorRendersAsToolLevelError() throws {
        let registry = ToolRegistry.standard(handlers: [
            "list_apps": { _ in throw CUError.appNotFound(query: "Ghost") },
        ])
        let server = MCPServer(registry: registry)
        initialize(server)
        let response = try parse(server.process(call(id: 32, name: "list_apps")))
        let result = try XCTUnwrap(response["result"])
        // Tool-level failure: successful JSON-RPC response, isError true.
        XCTAssertNil(response["error"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        let text = try XCTUnwrap(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        let errorPayload = try JSONValue.parse(text)
        XCTAssertEqual(errorPayload["code"]?.stringValue, "app_not_found")
        XCTAssertEqual(errorPayload["data"]?["query"]?.stringValue, "Ghost")
    }

    func testUnexpectedHandlerErrorBecomesInternalToolError() throws {
        struct Boom: Error {}
        let registry = ToolRegistry.standard(handlers: [
            "list_apps": { _ in throw Boom() },
        ])
        let server = MCPServer(registry: registry)
        initialize(server)
        let response = try parse(server.process(call(id: 33, name: "list_apps")))
        XCTAssertEqual(response["result"]?["isError"]?.boolValue, true)
        let text = try XCTUnwrap(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertEqual(try JSONValue.parse(text)["code"]?.stringValue, "internal_error")
    }

    func testHandlerInvalidArgumentsMapTo32602() throws {
        let registry = ToolRegistry.standard(handlers: [
            "list_apps": { _ in throw ToolInvalidArguments("bad shape") },
        ])
        let server = MCPServer(registry: registry)
        initialize(server)
        let response = try parse(server.process(call(id: 34, name: "list_apps")))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    // MARK: tools/call — gating & validation

    func testDisabledToolReturnsPolicyDenied() throws {
        // Every defined tool is enabled in Phase 4, so exercise the disabled-tool mechanism
        // directly over a registry that omits one tool from its enabled set: the call
        // short-circuits to a tool-level policy_denied / tool_disabled before argument
        // validation, so empty arguments are fine (§4, §6).
        let registry = ToolRegistry.standard(
            enabled: Set(ToolCatalog.enabledNames).subtracting(["scroll"])
        )
        let server = MCPServer(registry: registry)
        initialize(server)
        let response = try parse(server.process(call(id: 40, name: "scroll")))
        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        let text = try XCTUnwrap(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        let payload = try JSONValue.parse(text)
        XCTAssertEqual(payload["code"]?.stringValue, "policy_denied")
        XCTAssertEqual(payload["data"]?["reason"]?.stringValue, "tool_disabled")
        XCTAssertEqual(payload["data"]?["tool"]?.stringValue, "scroll")
    }

    func testUnknownToolYields32602() throws {
        let server = MCPServer()
        initialize(server)
        let response = try parse(server.process(call(id: 41, name: "not_a_tool")))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    func testMissingRequiredArgumentYields32602() throws {
        let server = MCPServer()
        initialize(server)
        // get_app_state requires "app".
        let response = try parse(server.process(call(id: 42, name: "get_app_state", arguments: "{}")))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    func testAdditionalPropertyYields32602() throws {
        let server = MCPServer()
        initialize(server)
        let response = try parse(server.process(
            call(id: 43, name: "get_app_state", arguments: #"{"app":"Finder","bogus":1}"#)
        ))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    func testEnumViolationYields32602() throws {
        let server = MCPServer()
        initialize(server)
        let response = try parse(server.process(
            call(id: 44, name: "get_app_state", arguments: #"{"app":"Finder","includeScreenshot":"maybe"}"#)
        ))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    func testMissingNameYields32602() throws {
        let server = MCPServer()
        initialize(server)
        let response = try parse(server.process(request(id: 45, method: "tools/call", params: "{}")))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    func testArrayItemEnumViolationYields32602() throws {
        // `modifiers` is { type: array, items: { enum: [cmd|ctrl|opt|shift|fn] } } on click.
        // An out-of-enum entry must be a clean -32602, not accepted-then-silently-dropped.
        let server = MCPServer()
        initialize(server)
        let response = try parse(server.process(call(
            id: 46, name: "click",
            arguments: #"{"app":"x","sessionId":"s1","at":{"x":1,"y":1},"modifiers":["hyper"]}"#
        )))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    func testValidModifierArrayPassesSchema() throws {
        // A modifiers array whose entries are all in the enum must pass schema validation
        // (it then dispatches to the handler; here the fake registry has no click handler,
        // so a *tool-level* internal_error — not -32602 — proves validation passed).
        let registry = ToolRegistry.standard() // placeholder handlers only
        let server = MCPServer(registry: registry)
        initialize(server)
        let response = try parse(server.process(call(
            id: 47, name: "click",
            arguments: #"{"app":"x","sessionId":"s1","at":{"x":1,"y":1},"modifiers":["cmd","shift"]}"#
        )))
        XCTAssertNil(response["error"], "a valid modifiers array must clear schema validation")
    }

    func testSessionIdWithTrailingNewlineYields32602() throws {
        // The frozen `^s[0-9]+$` pattern must not accept a trailing newline: ICU anchors
        // `$` before a trailing line terminator, so a plain firstMatch would leak "s1\n".
        // The JSON escape \n decodes to a real newline inside the string value.
        let server = MCPServer()
        initialize(server)
        let response = try parse(server.process(call(
            id: 48, name: "click",
            arguments: #"{"app":"x","sessionId":"s1\n","at":{"x":1,"y":1}}"#
        )))
        XCTAssertEqual(response["error"]?["code"]?.intValue, MCPServer.RPCErrorCode.invalidParams)
    }

    // MARK: Determinism

    func testResponsesAreDeterministic() {
        let a = MCPServer()
        let b = MCPServer()
        let lhs = a.process(request(id: 1, method: "initialize", params: "{}"))
        let rhs = b.process(request(id: 1, method: "initialize", params: "{}"))
        XCTAssertEqual(lhs, rhs)
    }

    // MARK: - Helpers

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
}
