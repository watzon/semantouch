import XCTest
@testable import SemantouchCLIKit
import MCPServer
import Foundation

/// Permission-free tests for `semantouch call` parsing, initialize ordering,
/// tools/call sequencing, placeholder resolution, and stdout/stderr discipline.
final class CallCommandTests: XCTestCase {

    // MARK: - Helpers

    private func tempFile(named name: String, contents: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-call-\(UUID().uuidString)-\(name)")
        try Data(contents.utf8).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url.path
    }

    private func toolResult(textJSON: String, isError: Bool = false) -> JSONValue {
        [
            "content": .array([
                ["type": .string("text"), "text": .string(textJSON)],
            ]),
            "isError": .bool(isError),
        ]
    }

    private func successResponse(id: Int, result: JSONValue) -> String {
        JSONRPC.successResponse(id: .int(id), result: result).serialized()
    }

    private func errorResponse(id: Int, code: Int, message: String) -> String {
        JSONRPC.errorResponse(id: .int(id), code: code, message: message).serialized()
    }

    /// Fake server that auto-answers initialize and scripted tools/call replies.
    private final class ScriptedPeer {
        var inbound: [JSONValue] = []
        private var outbound: [String]
        private var readIndex = 0

        init(toolReplies: [String]) {
            // initialize result is always first response (id 1).
            let initResult: JSONValue = [
                "protocolVersion": .string(MCPServer.mcpProtocolVersion),
                "capabilities": ["tools": .object([:])],
                "serverInfo": [
                    "name": .string("semantouch"),
                    "version": .string(MCPServer.serverVersion),
                ],
            ]
            var lines = [ScriptedPeer.successResponse(id: 1, result: initResult)]
            // tools/call ids start at 2
            for (offset, reply) in toolReplies.enumerated() {
                lines.append(reply.replacingOccurrences(of: "__ID__", with: String(offset + 2)))
            }
            self.outbound = lines
        }

        /// Build from raw outbound lines (including initialize).
        init(rawOutbound: [String]) {
            self.outbound = rawOutbound
        }

        func transport(recordWrites: Bool = true) -> (CallTransport, CallClient) {
            let peer = self
            let transport = CallTransport(
                writeLine: { line in
                    let value = try JSONValue.parse(line)
                    peer.inbound.append(value)
                },
                readLine: {
                    if peer.readIndex >= peer.outbound.count {
                        return nil
                    }
                    let line = peer.outbound[peer.readIndex]
                    peer.readIndex += 1
                    return line
                }
            )
            let client = CallClient(transport: transport, recordWrites: recordWrites)
            return (transport, client)
        }

        static func successResponse(id: Int, result: JSONValue) -> String {
            JSONRPC.successResponse(id: .int(id), result: result).serialized()
        }
    }

    private func captureIO() -> (CallIO, () -> [String], () -> [String], () -> [Double]) {
        var out: [String] = []
        var err: [String] = []
        var sleeps: [Double] = []
        let io = CallIO(
            stdout: { out.append($0) },
            stderr: { err.append($0) },
            sleep: { sleeps.append($0) }
        )
        return (io, { out }, { err }, { sleeps })
    }

    // MARK: - Help

    func testCallHelpExitsZeroAndDocumentsExamples() {
        let (io, out, err, _) = captureIO()
        var connectCount = 0
        let code = CallRunner.run(
            arguments: ["--help"],
            io: io,
            connect: {
                connectCount += 1
                throw CallRuntimeError("should not connect")
            }
        )
        XCTAssertEqual(code, CallExitCode.success)
        XCTAssertEqual(connectCount, 0)
        XCTAssertTrue(err().isEmpty)
        let text = out().joined(separator: "\n")
        XCTAssertTrue(text.contains("semantouch call"))
        XCTAssertTrue(text.contains("--args"))
        XCTAssertTrue(text.contains("--calls"))
        XCTAssertTrue(text.contains("--sleep"))
        XCTAssertTrue(text.contains("${state.sessionId}"))
        XCTAssertTrue(text.contains("press_key"))
        XCTAssertTrue(text.contains("cmd+l"))
        XCTAssertTrue(text.contains("EXAMPLES:"))
    }

    // MARK: - Parsing

    func testParseSingleToolDefaultArgs() throws {
        let inv = try CallCommand.parse(["list_apps"])
        guard case let .single(record) = inv else {
            return XCTFail("expected single")
        }
        XCTAssertEqual(record.tool, "list_apps")
        XCTAssertEqual(record.args, .object([:]))
        XCTAssertNil(record.asName)
    }

    func testParseSingleToolInlineArgs() throws {
        let inv = try CallCommand.parse(["get_app_state", "--args", #"{"app":"Finder"}"#])
        guard case let .single(record) = inv else {
            return XCTFail("expected single")
        }
        XCTAssertEqual(record.tool, "get_app_state")
        XCTAssertEqual(record.args["app"]?.stringValue, "Finder")
    }

    func testParseSingleToolEqualsArgs() throws {
        let inv = try CallCommand.parse([#"--args={"app":"X"}"#, "doctor"])
        guard case let .single(record) = inv else {
            return XCTFail("expected single")
        }
        XCTAssertEqual(record.tool, "doctor")
        XCTAssertEqual(record.args["app"]?.stringValue, "X")
    }

    func testParseArgsFile() throws {
        let path = try tempFile(named: "args.json", contents: #"{"app":"Notes"}"#)
        let inv = try CallCommand.parse(["get_app_state", "--args-file", path])
        guard case let .single(record) = inv else {
            return XCTFail("expected single")
        }
        XCTAssertEqual(record.args["app"]?.stringValue, "Notes")
    }

    func testParseSequenceAndSleep() throws {
        let json = #"[{"tool":"list_apps"},{"tool":"doctor","args":{}}]"#
        let inv = try CallCommand.parse(["--calls", json, "--sleep", "0.5"])
        guard case let .sequence(calls, sleep) = inv else {
            return XCTFail("expected sequence")
        }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].tool, "list_apps")
        XCTAssertEqual(calls[1].tool, "doctor")
        XCTAssertEqual(sleep, 0.5)
    }

    func testParseCallsFileWithAsBinding() throws {
        let json = """
        [
          {"tool":"get_app_state","args":{"app":"Finder"},"as":"state"},
          {"tool":"press","args":{"sessionId":"${state.sessionId}"}}
        ]
        """
        let path = try tempFile(named: "calls.json", contents: json)
        let inv = try CallCommand.parse(["--calls-file", path])
        guard case let .sequence(calls, sleep) = inv else {
            return XCTFail("expected sequence")
        }
        XCTAssertEqual(sleep, 0)
        XCTAssertEqual(calls[0].asName, "state")
        XCTAssertEqual(calls[1].args["sessionId"]?.stringValue, "${state.sessionId}")
    }

    func testRejectUnknownFlag() {
        XCTAssertThrowsError(try CallCommand.parse(["list_apps", "--verbose"])) { error in
            let usage = error as? CallUsageError
            XCTAssertTrue(usage?.message.contains("unknown flag") == true)
        }
    }

    func testRejectDuplicateArgsFlag() {
        XCTAssertThrowsError(
            try CallCommand.parse(["list_apps", "--args", "{}", "--args", "{}"])
        ) { error in
            XCTAssertTrue((error as? CallUsageError)?.message.contains("duplicate") == true)
        }
    }

    func testRejectExclusiveArgsModes() {
        XCTAssertThrowsError(
            try CallCommand.parse(["list_apps", "--args", "{}", "--args-file", "x"])
        ) { error in
            XCTAssertTrue((error as? CallUsageError)?.message.contains("mutually exclusive") == true)
        }
    }

    func testRejectExclusiveCallsModes() {
        XCTAssertThrowsError(
            try CallCommand.parse(["--calls", "[]", "--calls-file", "x"])
        ) { error in
            XCTAssertTrue((error as? CallUsageError)?.message.contains("mutually exclusive") == true)
        }
    }

    func testRejectEmptyCallsArray() {
        XCTAssertThrowsError(try CallCommand.parse(["--calls", "[]"])) { error in
            XCTAssertTrue((error as? CallUsageError)?.message.contains("nonempty") == true)
        }
    }

    func testRejectNonObjectArgs() {
        XCTAssertThrowsError(try CallCommand.parse(["list_apps", "--args", "[1]"])) { error in
            XCTAssertTrue((error as? CallUsageError)?.message.contains("object") == true)
        }
    }

    func testRejectNegativeSleep() {
        XCTAssertThrowsError(
            try CallCommand.parse(["--calls", #"[{"tool":"a"}]"#, "--sleep", "-1"])
        ) { error in
            XCTAssertTrue((error as? CallUsageError)?.message.contains("nonnegative") == true)
        }
    }

    func testRejectNaNSleep() {
        XCTAssertThrowsError(
            try CallCommand.parse(["--calls", #"[{"tool":"a"}]"#, "--sleep", "nan"])
        ) { error in
            XCTAssertTrue((error as? CallUsageError)?.message.contains("nonnegative") == true)
        }
    }

    func testRejectSleepOutsideSequence() {
        XCTAssertThrowsError(try CallCommand.parse(["list_apps", "--sleep", "1"])) { error in
            XCTAssertTrue((error as? CallUsageError)?.message.contains("--sleep") == true)
        }
    }

    func testRejectDuplicateBindingNames() {
        let json = #"[{"tool":"a","as":"x"},{"tool":"b","as":"x"}]"#
        XCTAssertThrowsError(try CallCommand.parse(["--calls", json])) { error in
            XCTAssertTrue((error as? CallUsageError)?.message.contains("duplicate binding") == true)
        }
    }

    func testRejectUnknownRecordKey() {
        let json = #"[{"tool":"a","extra":1}]"#
        XCTAssertThrowsError(try CallCommand.parse(["--calls", json])) { error in
            XCTAssertTrue((error as? CallUsageError)?.message.contains("unknown key") == true)
        }
    }

    func testRejectUnreadableArgsFile() {
        XCTAssertThrowsError(
            try CallCommand.parse(["list_apps", "--args-file", "/no/such/file-\(UUID().uuidString)"])
        ) { error in
            XCTAssertTrue((error as? CallUsageError)?.message.contains("could not read") == true)
        }
    }

    func testRejectInvalidUTF8File() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-call-bin-\(UUID().uuidString)")
        // Invalid UTF-8 sequence.
        try Data([0xFF, 0xFE, 0xFD]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(
            try CallCommand.parse(["list_apps", "--args-file", url.path])
        ) { error in
            XCTAssertTrue((error as? CallUsageError)?.message.contains("UTF-8") == true)
        }
    }

    func testParseUsageExitCodeViaRunner() {
        let (io, _, err, _) = captureIO()
        var connects = 0
        let code = CallRunner.run(
            arguments: ["list_apps", "--nope"],
            io: io,
            connect: {
                connects += 1
                throw CallRuntimeError("no")
            }
        )
        XCTAssertEqual(code, CallExitCode.usage)
        XCTAssertEqual(connects, 0, "must not connect on usage errors")
        XCTAssertFalse(err().isEmpty)
    }

    // MARK: - Reference resolution

    func testWholePlaceholderPreservesNativeTypes() throws {
        let bindings: [String: JSONValue] = [
            "state": [
                "sessionId": .string("s1"),
                "revision": .int(3),
                "flag": .bool(true),
                "items": .array([.string("a"), .int(9)]),
                "nested": ["x": .double(1.5)],
            ],
        ]
        XCTAssertEqual(
            try CallReferenceResolver.resolve(.string("${state.sessionId}"), bindings: bindings),
            .string("s1")
        )
        XCTAssertEqual(
            try CallReferenceResolver.resolve(.string("${state.revision}"), bindings: bindings),
            .int(3)
        )
        XCTAssertEqual(
            try CallReferenceResolver.resolve(.string("${state.flag}"), bindings: bindings),
            .bool(true)
        )
        XCTAssertEqual(
            try CallReferenceResolver.resolve(.string("${state.items}"), bindings: bindings),
            .array([.string("a"), .int(9)])
        )
        XCTAssertEqual(
            try CallReferenceResolver.resolve(.string("${state.nested}"), bindings: bindings),
            ["x": .double(1.5)]
        )
        XCTAssertEqual(
            try CallReferenceResolver.resolve(.string("${state.items.1}"), bindings: bindings),
            .int(9)
        )
    }

    func testEmbeddedPlaceholderStringInterpolation() throws {
        let bindings: [String: JSONValue] = [
            "n": .int(7),
            "s": .string("hi"),
        ]
        XCTAssertEqual(
            try CallReferenceResolver.resolve(.string("id-${n}-${s}"), bindings: bindings),
            .string("id-7-hi")
        )
    }

    func testEmbeddedNonScalarFails() {
        let bindings: [String: JSONValue] = ["obj": ["a": 1]]
        XCTAssertThrowsError(
            try CallReferenceResolver.resolve(.string("x-${obj}-y"), bindings: bindings)
        ) { error in
            XCTAssertTrue((error as? CallUsageError)?.message.contains("scalar") == true)
        }
    }

    func testUnresolvedReferenceFails() {
        XCTAssertThrowsError(
            try CallReferenceResolver.resolve(.string("${missing}"), bindings: [:])
        ) { error in
            XCTAssertTrue((error as? CallUsageError)?.message.contains("unresolved") == true)
        }
    }

    func testNestedObjectResolution() throws {
        let input: JSONValue = [
            "a": .string("${state.sessionId}"),
            "b": ["rev": .string("${state.revision}")],
            "c": .array([.string("${state.items.0}")]),
        ]
        let bindings: [String: JSONValue] = [
            "state": [
                "sessionId": .string("s9"),
                "revision": .int(2),
                "items": .array([.string("e1")]),
            ],
        ]
        let out = try CallReferenceResolver.resolve(input, bindings: bindings)
        XCTAssertEqual(out["a"], .string("s9"))
        XCTAssertEqual(out["b"]?["rev"], .int(2))
        XCTAssertEqual(out["c"]?.arrayValue?.first, .string("e1"))
    }

    // MARK: - Client protocol

    func testInitializeOrderingAndIDs() throws {
        let peer = ScriptedPeer(toolReplies: [
            ScriptedPeer.successResponse(
                id: 2,
                result: toolResult(textJSON: #"{"apps":[]}"#)
            ),
        ])
        let (_, client) = peer.transport()
        let (io, out, err, _) = captureIO()
        let code = CallRunner.run(
            .single(CallRecord(tool: "list_apps")),
            client: client,
            io: io
        )
        XCTAssertEqual(code, CallExitCode.success)
        XCTAssertTrue(err().isEmpty)
        XCTAssertEqual(out().count, 1)

        // Written: initialize, notifications/initialized, tools/call
        XCTAssertEqual(client.writtenLines.count, 3)

        let initReq = try JSONValue.parse(client.writtenLines[0])
        XCTAssertEqual(initReq["method"]?.stringValue, "initialize")
        XCTAssertEqual(initReq["id"]?.intValue, 1)
        XCTAssertEqual(initReq["params"]?["protocolVersion"]?.stringValue, MCPServer.mcpProtocolVersion)
        XCTAssertEqual(initReq["params"]?["clientInfo"]?["name"]?.stringValue, "semantouch-call")

        let note = try JSONValue.parse(client.writtenLines[1])
        XCTAssertEqual(note["method"]?.stringValue, "notifications/initialized")
        XCTAssertNil(note["id"])

        let call = try JSONValue.parse(client.writtenLines[2])
        XCTAssertEqual(call["method"]?.stringValue, "tools/call")
        XCTAssertEqual(call["id"]?.intValue, 2)
        XCTAssertEqual(call["params"]?["name"]?.stringValue, "list_apps")
        XCTAssertEqual(call["params"]?["arguments"], .object([:]))

        // Canonical stdout is the result object only, not the full RPC response.
        let printed = try JSONValue.parse(out()[0])
        XCTAssertEqual(printed["isError"]?.boolValue, false)
        XCTAssertNil(printed["jsonrpc"])
    }

    func testSequenceStatePersistenceAndTypedRefs() throws {
        let statePayload = #"{"sessionId":"s1","revision":4,"items":["e1","e2"],"meta":{"ok":true}}"#
        let peer = ScriptedPeer(toolReplies: [
            ScriptedPeer.successResponse(id: 2, result: toolResult(textJSON: statePayload)),
            ScriptedPeer.successResponse(id: 3, result: toolResult(textJSON: #"{"ok":true}"#)),
        ])
        let (_, client) = peer.transport()
        let (io, out, err, sleeps) = captureIO()

        let records = [
            CallRecord(
                tool: "get_app_state",
                args: ["app": .string("Finder")],
                asName: "state"
            ),
            CallRecord(
                tool: "press",
                args: [
                    "sessionId": .string("${state.sessionId}"),
                    "revision": .string("${state.revision}"),
                    "elementId": .string("${state.items.0}"),
                    "flag": .string("${state.meta.ok}"),
                    "label": .string("item-${state.items.1}"),
                ]
            ),
        ]
        let code = CallRunner.run(
            .sequence(calls: records, sleepSeconds: 0.25),
            client: client,
            io: io
        )
        XCTAssertEqual(code, CallExitCode.success)
        XCTAssertTrue(err().isEmpty)
        XCTAssertEqual(out().count, 2)
        XCTAssertEqual(sleeps(), [0.25])

        // Second tools/call has resolved native types.
        let call2 = try JSONValue.parse(client.writtenLines[3]) // init, note, call1, call2
        XCTAssertEqual(call2["method"]?.stringValue, "tools/call")
        XCTAssertEqual(call2["id"]?.intValue, 3)
        let args = try XCTUnwrap(call2["params"]?["arguments"])
        XCTAssertEqual(args["sessionId"]?.stringValue, "s1")
        XCTAssertEqual(args["revision"]?.intValue, 4) // whole placeholder → int
        XCTAssertEqual(args["elementId"]?.stringValue, "e1")
        XCTAssertEqual(args["flag"]?.boolValue, true)
        XCTAssertEqual(args["label"]?.stringValue, "item-e2")

        // Binding stored parsed content text JSON.
        XCTAssertEqual(client.currentBindings["state"]?["sessionId"]?.stringValue, "s1")
    }

    func testStopOnIsErrorPrintsResultAndSkipsRemainder() throws {
        let peer = ScriptedPeer(toolReplies: [
            ScriptedPeer.successResponse(
                id: 2,
                result: toolResult(textJSON: #"{"code":"app_not_found","message":"no"}"#, isError: true)
            ),
            ScriptedPeer.successResponse(
                id: 3,
                result: toolResult(textJSON: #"{"should":"not-run"}"#)
            ),
        ])
        let (_, client) = peer.transport()
        let (io, out, err, _) = captureIO()
        let records = [
            CallRecord(tool: "list_apps", asName: "a"),
            CallRecord(tool: "doctor"),
        ]
        let code = CallRunner.run(
            .sequence(calls: records, sleepSeconds: 0),
            client: client,
            io: io
        )
        XCTAssertEqual(code, CallExitCode.failure)
        XCTAssertEqual(out().count, 1, "must print the isError result")
        let printed = try JSONValue.parse(out()[0])
        XCTAssertEqual(printed["isError"]?.boolValue, true)
        XCTAssertEqual(client.toolsCallCount, 1, "must not send remaining tools/call")
        XCTAssertTrue(err().contains { $0.contains("isError") })
    }

    func testUnresolvedRefBeforeSendIsUsageAndNoToolsCall() throws {
        let peer = ScriptedPeer(toolReplies: [
            ScriptedPeer.successResponse(id: 2, result: toolResult(textJSON: #"{"ok":1}"#)),
        ])
        let (_, client) = peer.transport()
        let (io, out, err, _) = captureIO()
        // First call binds nothing useful; second has unresolved ref.
        let records = [
            CallRecord(tool: "list_apps"),
            CallRecord(tool: "press", args: ["sessionId": .string("${missing}")]),
        ]
        let code = CallRunner.run(
            .sequence(calls: records, sleepSeconds: 0),
            client: client,
            io: io
        )
        XCTAssertEqual(code, CallExitCode.usage)
        XCTAssertEqual(out().count, 1, "first success still printed")
        XCTAssertEqual(client.toolsCallCount, 1, "second call never sent")
        XCTAssertTrue(err().contains { $0.contains("unresolved") })
    }

    func testServerJSONRPCErrorIsFailure() throws {
        let initResult: JSONValue = [
            "protocolVersion": .string(MCPServer.mcpProtocolVersion),
            "capabilities": .object([:]),
            "serverInfo": ["name": .string("s"), "version": .string("0")],
        ]
        let peer = ScriptedPeer(rawOutbound: [
            ScriptedPeer.successResponse(id: 1, result: initResult),
            JSONRPC.errorResponse(
                id: .int(2),
                code: JSONRPC.ErrorCode.invalidParams,
                message: "bad"
            ).serialized(),
        ])
        let (_, client) = peer.transport()
        let (io, out, err, _) = captureIO()
        let code = CallRunner.run(
            .single(CallRecord(tool: "list_apps")),
            client: client,
            io: io
        )
        XCTAssertEqual(code, CallExitCode.failure)
        XCTAssertTrue(out().isEmpty, "no result object on RPC error")
        XCTAssertTrue(err().contains { $0.contains("JSON-RPC error") || $0.contains("bad") })
    }

    func testMismatchedResponseIDIsFailure() throws {
        let initResult: JSONValue = [
            "protocolVersion": .string(MCPServer.mcpProtocolVersion),
            "capabilities": .object([:]),
            "serverInfo": ["name": .string("s"), "version": .string("0")],
        ]
        let peer = ScriptedPeer(rawOutbound: [
            ScriptedPeer.successResponse(id: 1, result: initResult),
            // Wrong id for tools/call (expected 2).
            ScriptedPeer.successResponse(id: 99, result: toolResult(textJSON: "{}")),
        ])
        let (_, client) = peer.transport()
        let (io, _, err, _) = captureIO()
        let code = CallRunner.run(
            .single(CallRecord(tool: "list_apps")),
            client: client,
            io: io
        )
        XCTAssertEqual(code, CallExitCode.failure)
        XCTAssertTrue(err().contains { $0.contains("mismatched") })
    }

    func testMalformedResponseIsFailure() throws {
        let initResult: JSONValue = [
            "protocolVersion": .string(MCPServer.mcpProtocolVersion),
            "capabilities": .object([:]),
            "serverInfo": ["name": .string("s"), "version": .string("0")],
        ]
        let peer = ScriptedPeer(rawOutbound: [
            ScriptedPeer.successResponse(id: 1, result: initResult),
            "{not-json",
        ])
        let (_, client) = peer.transport()
        let (io, _, err, _) = captureIO()
        let code = CallRunner.run(
            .single(CallRecord(tool: "list_apps")),
            client: client,
            io: io
        )
        XCTAssertEqual(code, CallExitCode.failure)
        XCTAssertTrue(err().contains { $0.contains("malformed") })
    }

    func testEOFDuringInitializeIsFailure() throws {
        let peer = ScriptedPeer(rawOutbound: []) // immediate EOF
        let (_, client) = peer.transport()
        let (io, _, err, _) = captureIO()
        let code = CallRunner.run(
            .single(CallRecord(tool: "list_apps")),
            client: client,
            io: io
        )
        XCTAssertEqual(code, CallExitCode.failure)
        XCTAssertTrue(err().contains { $0.contains("EOF") })
    }

    func testInitializeServerErrorIsFailure() throws {
        let peer = ScriptedPeer(rawOutbound: [
            JSONRPC.errorResponse(
                id: .int(1),
                code: -32603,
                message: "boom"
            ).serialized(),
        ])
        let (_, client) = peer.transport()
        let (io, _, err, _) = captureIO()
        let code = CallRunner.run(
            .single(CallRecord(tool: "list_apps")),
            client: client,
            io: io
        )
        XCTAssertEqual(code, CallExitCode.failure)
        XCTAssertTrue(err().contains { $0.contains("initialize") })
    }

    func testNoReplaySingleConnect() {
        let peer = ScriptedPeer(toolReplies: [
            ScriptedPeer.successResponse(id: 2, result: toolResult(textJSON: "{}")),
            ScriptedPeer.successResponse(id: 3, result: toolResult(textJSON: "{}")),
        ])
        var connectCount = 0
        let (io, out, _, _) = captureIO()
        let code = CallRunner.run(
            arguments: [
                "--calls",
                #"[{"tool":"a"},{"tool":"b"}]"#,
            ],
            io: io,
            connect: {
                connectCount += 1
                let (transport, _) = peer.transport(recordWrites: false)
                return transport
            }
        )
        XCTAssertEqual(code, CallExitCode.success)
        XCTAssertEqual(connectCount, 1, "exactly one host/MCP connection")
        XCTAssertEqual(out().count, 2)
    }

    func testConnectFailureIsExitOne() {
        let (io, out, err, _) = captureIO()
        let code = CallRunner.run(
            arguments: ["list_apps"],
            io: io,
            connect: { throw CallRuntimeError("host connection failed: gone") }
        )
        XCTAssertEqual(code, CallExitCode.failure)
        XCTAssertTrue(out().isEmpty)
        XCTAssertTrue(err().contains { $0.contains("host connection failed") })
    }

    func testStdoutStderrSeparationSeam() throws {
        let peer = ScriptedPeer(toolReplies: [
            ScriptedPeer.successResponse(id: 2, result: toolResult(textJSON: #"{"ok":true}"#)),
        ])
        let (_, client) = peer.transport()
        var stdout: [String] = []
        var stderr: [String] = []
        let io = CallIO(
            stdout: { stdout.append($0) },
            stderr: { stderr.append($0) }
        )
        let code = CallRunner.run(
            .single(CallRecord(tool: "list_apps")),
            client: client,
            io: io
        )
        XCTAssertEqual(code, 0)
        XCTAssertEqual(stdout.count, 1)
        XCTAssertTrue(stderr.isEmpty)
        // Canonical: sorted keys, no spaces.
        XCTAssertEqual(stdout[0], toolResult(textJSON: #"{"ok":true}"#).serialized())
    }

    func testEnsureInitializedIdempotent() throws {
        let peer = ScriptedPeer(toolReplies: [
            ScriptedPeer.successResponse(id: 2, result: toolResult(textJSON: "{}")),
        ])
        let (_, client) = peer.transport()
        try client.ensureInitialized()
        try client.ensureInitialized()
        XCTAssertEqual(client.writtenLines.count, 2, "initialize + notification only once")
        _ = try client.callTool(CallRecord(tool: "list_apps"))
        XCTAssertEqual(client.writtenLines.count, 3)
    }

    func testCanonicalArgsObjectInRequest() throws {
        let peer = ScriptedPeer(toolReplies: [
            ScriptedPeer.successResponse(id: 2, result: toolResult(textJSON: "{}")),
        ])
        let (_, client) = peer.transport()
        let (io, _, _, _) = captureIO()
        _ = CallRunner.run(
            .single(CallRecord(tool: "get_app_state", args: ["z": 1, "a": 2])),
            client: client,
            io: io
        )
        let call = try JSONValue.parse(client.writtenLines[2])
        // Serialized form has sorted keys.
        XCTAssertTrue(client.writtenLines[2].contains(#""arguments":{"a":2,"z":1}"#))
        XCTAssertEqual(call["params"]?["arguments"]?["a"]?.intValue, 2)
    }
}
