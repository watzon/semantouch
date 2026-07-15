import XCTest
import ComputerUseCore
import AccessibilityEngine
@testable import MCPServer
@testable import ComputerUseService

/// Contract coverage for the read-only `read_text` tool: DTO decode/encode, schema
/// oneOf limit validation, catalog order/annotations, gate ordering before any value
/// read, secure-field rejection, Unicode/byte truncation, max full-text path, and
/// no session mutation. Permission-free: live AX is never exercised; pure helpers and
/// early gates are driven through faked sessions/resolvers.
final class ReadTextToolTests: XCTestCase {

    // MARK: - Decode / encode

    func testReadTextRequestDefaultsLimitTo4096() throws {
        let request = try CanonicalJSON.decode(
            ReadTextRequest.self,
            from: #"{"app":"TextEdit","sessionId":"s1","revision":1,"elementId":"e1"}"#
        )
        XCTAssertEqual(request.app, "TextEdit")
        XCTAssertEqual(request.sessionId, "s1")
        XCTAssertEqual(request.revision, 1)
        XCTAssertEqual(request.elementId, "e1")
        XCTAssertEqual(request.limit, .bytes(4096))
    }

    func testReadTextRequestDecodesNumericLimit() throws {
        let request = try CanonicalJSON.decode(
            ReadTextRequest.self,
            from: #"{"app":"TextEdit","sessionId":"s1","revision":2,"elementId":"e3","limit":128}"#
        )
        XCTAssertEqual(request.limit, .bytes(128))
    }

    func testReadTextRequestDecodesMaxLimit() throws {
        let request = try CanonicalJSON.decode(
            ReadTextRequest.self,
            from: #"{"app":"TextEdit","sessionId":"s1","revision":1,"elementId":"e1","limit":"max"}"#
        )
        XCTAssertEqual(request.limit, .max)
    }

    func testReadTextLimitRejectsZeroAndNegative() {
        XCTAssertThrowsError(
            try CanonicalJSON.decode(ReadTextLimit.self, from: "0")
        )
        XCTAssertThrowsError(
            try CanonicalJSON.decode(ReadTextLimit.self, from: "-1")
        )
    }

    func testReadTextLimitRejectsUnknownStringAndBool() {
        XCTAssertThrowsError(
            try CanonicalJSON.decode(ReadTextLimit.self, from: #""full""#)
        )
        XCTAssertThrowsError(
            try CanonicalJSON.decode(ReadTextLimit.self, from: "true")
        )
    }

    func testReadTextLimitRoundTrips() throws {
        XCTAssertEqual(try CanonicalJSON.encodeToString(ReadTextLimit.bytes(4096)), "4096")
        XCTAssertEqual(try CanonicalJSON.encodeToString(ReadTextLimit.max), #""max""#)
        XCTAssertEqual(
            try CanonicalJSON.decode(ReadTextLimit.self, from: try CanonicalJSON.encodeToString(ReadTextLimit.bytes(7))),
            .bytes(7)
        )
        XCTAssertEqual(
            try CanonicalJSON.decode(ReadTextLimit.self, from: try CanonicalJSON.encodeToString(ReadTextLimit.max)),
            .max
        )
    }

    func testReadTextResultExactContract() throws {
        let result = ReadTextResult(text: "hello", totalBytes: 5, returnedBytes: 5, truncated: false)
        XCTAssertEqual(
            try CanonicalJSON.encodeToString(result),
            #"{"returnedBytes":5,"text":"hello","totalBytes":5,"truncated":false}"#
        )
    }

    // MARK: - Schema / catalog / annotations

    func testReadTextSitsImmediatelyAfterGetAppState() {
        let names = ToolCatalog.enabledNames
        XCTAssertEqual(names.count, 16)
        guard let getIdx = names.firstIndex(of: "get_app_state"),
              let readIdx = names.firstIndex(of: "read_text") else {
            return XCTFail("get_app_state and read_text must both be enabled")
        }
        XCTAssertEqual(readIdx, getIdx + 1)
        XCTAssertEqual(ToolCatalog.all.first { $0.name == "read_text" }?.phase, 1)
        XCTAssertTrue(ToolCatalog.isEnabled("read_text"))
    }

    func testReadTextSchemaIsStrictOneOfLimit() throws {
        let schema = try XCTUnwrap(ToolSchemas.schema(for: "read_text"))
        // Required ElementTarget quadruple; additionalProperties false.
        XCTAssertNil(SchemaValidator.validate(
            try JSONValue.parse(#"{"app":"x","sessionId":"s1","revision":1,"elementId":"e1"}"#),
            schema: schema
        ))
        XCTAssertNil(SchemaValidator.validate(
            try JSONValue.parse(#"{"app":"x","sessionId":"s1","revision":1,"elementId":"e1","limit":4096}"#),
            schema: schema
        ))
        XCTAssertNil(SchemaValidator.validate(
            try JSONValue.parse(#"{"app":"x","sessionId":"s1","revision":1,"elementId":"e1","limit":"max"}"#),
            schema: schema
        ))

        // Malformed limits rejected by oneOf.
        XCTAssertNotNil(SchemaValidator.validate(
            try JSONValue.parse(#"{"app":"x","sessionId":"s1","revision":1,"elementId":"e1","limit":0}"#),
            schema: schema
        ))
        XCTAssertNotNil(SchemaValidator.validate(
            try JSONValue.parse(#"{"app":"x","sessionId":"s1","revision":1,"elementId":"e1","limit":"full"}"#),
            schema: schema
        ))
        XCTAssertNotNil(SchemaValidator.validate(
            try JSONValue.parse(#"{"app":"x","sessionId":"s1","revision":1,"elementId":"e1","limit":true}"#),
            schema: schema
        ))
        // Extra property.
        XCTAssertNotNil(SchemaValidator.validate(
            try JSONValue.parse(#"{"app":"x","sessionId":"s1","revision":1,"elementId":"e1","extra":1}"#),
            schema: schema
        ))
        // Missing required.
        XCTAssertNotNil(SchemaValidator.validate(
            try JSONValue.parse(#"{"app":"x","sessionId":"s1","revision":1}"#),
            schema: schema
        ))
    }

    func testReadTextAnnotationsAreConservativeReadOnly() throws {
        let server = makeServer()
        initialize(server)
        let tools = try XCTUnwrap(
            try parse(server.process(request(id: 3, method: "tools/list")))["result"]?["tools"]?.arrayValue
        )
        let read = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "read_text" })
        let annotations = try XCTUnwrap(read["annotations"])
        XCTAssertEqual(annotations["readOnlyHint"]?.boolValue, true)
        XCTAssertEqual(annotations["destructiveHint"]?.boolValue, false)
        XCTAssertEqual(annotations["idempotentHint"]?.boolValue, true)
        XCTAssertEqual(annotations["openWorldHint"]?.boolValue, true)
    }

    func testReadTextMalformedLimitIsInvalidParams() throws {
        let server = makeServer()
        initialize(server)
        XCTAssertEqual(
            try parse(server.process(call(
                id: 10,
                name: "read_text",
                arguments: #"{"app":"x","sessionId":"s1","revision":1,"elementId":"e1","limit":0}"#
            )))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
        XCTAssertEqual(
            try parse(server.process(call(
                id: 11,
                name: "read_text",
                arguments: #"{"app":"x","sessionId":"s1","revision":1,"elementId":"e1","limit":"full"}"#
            )))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
        XCTAssertEqual(
            try parse(server.process(call(
                id: 12,
                name: "read_text",
                arguments: #"{"app":"x","sessionId":"s1","revision":1}"#
            )))["error"]?["code"]?.intValue,
            MCPServer.RPCErrorCode.invalidParams
        )
    }

    // MARK: - Gate ordering (policy → session → ownership → revision → element)

    func testReadTextOnDeniedAppIsPolicyDenied() throws {
        let blocked = AppRecord(
            bundleId: "com.example.blocked",
            displayName: "Blocked",
            path: nil,
            pid: 999,
            isRunning: true,
            windows: 1
        )
        let (server, _) = actionServer(records: [blocked], deniedApps: ["com.example.blocked"])
        let payload = try toolErrorPayload(try parse(server.process(call(
            id: 20,
            name: "read_text",
            arguments: #"{"app":"com.example.blocked","sessionId":"s1","revision":1,"elementId":"e1"}"#
        ))))
        XCTAssertEqual(payload["code"]?.stringValue, "policy_denied")
        XCTAssertEqual(payload["data"]?["reason"]?.stringValue, "app_denied")
        XCTAssertEqual(payload["data"]?["tool"]?.stringValue, "read_text")
    }

    func testReadTextUnknownSessionIsStaleRevisionWithNullCurrent() throws {
        let (server, _) = actionServer(records: [fixtureRecord()])
        let payload = try toolErrorPayload(try parse(server.process(call(
            id: 21,
            name: "read_text",
            arguments: #"{"app":"computer-use-fixture","sessionId":"s404","revision":1,"elementId":"e1"}"#
        ))))
        XCTAssertEqual(payload["code"]?.stringValue, "stale_revision")
        XCTAssertEqual(payload["data"]?["provided"]?.intValue, 1)
        XCTAssertEqual(payload["data"]?["current"]?.isNull, true)
    }

    func testReadTextForeignSessionIsPolicyDeniedBeforeRevision() throws {
        // Session owned by pid 999; caller's app resolves to pid 4242 → confused deputy.
        let blocked = AppRecord(
            bundleId: "com.example.blocked",
            displayName: "Blocked",
            path: nil,
            pid: 999,
            isRunning: true,
            windows: 1
        )
        let (server, context) = actionServer(records: [fixtureRecord(), blocked])
        let session = context.sessionManager.ensureSession(appId: "pid:999", pid: 999)
        XCTAssertEqual(session.sessionId, "s1")
        // Seed a matching revision so only the ownership gate should fire.
        let payload = try toolErrorPayload(try parse(server.process(call(
            id: 22,
            name: "read_text",
            arguments: #"{"app":"computer-use-fixture","sessionId":"s1","revision":1,"elementId":"e1"}"#
        ))))
        XCTAssertEqual(payload["code"]?.stringValue, "policy_denied")
        XCTAssertEqual(payload["data"]?["reason"]?.stringValue, "app_denied")
        XCTAssertEqual(payload["data"]?["tool"]?.stringValue, "read_text")
    }

    func testReadTextStaleRevisionBeforeElement() throws {
        let (server, context) = actionServer(records: [fixtureRecord()])
        _ = context.sessionManager.ensureSession(appId: "pid:4242", pid: 4242) // revision 1
        let payload = try toolErrorPayload(try parse(server.process(call(
            id: 23,
            name: "read_text",
            arguments: #"{"app":"computer-use-fixture","sessionId":"s1","revision":5,"elementId":"e1"}"#
        ))))
        XCTAssertEqual(payload["code"]?.stringValue, "stale_revision")
        XCTAssertEqual(payload["data"]?["provided"]?.intValue, 5)
        XCTAssertEqual(payload["data"]?["current"]?.intValue, 1)
    }

    func testReadTextStaleElementAfterRevisionMatch() throws {
        let (server, context) = actionServer(records: [fixtureRecord()])
        _ = context.sessionManager.ensureSession(appId: "pid:4242", pid: 4242)
        // Empty element table → any id is stale_element.
        let payload = try toolErrorPayload(try parse(server.process(call(
            id: 24,
            name: "read_text",
            arguments: #"{"app":"computer-use-fixture","sessionId":"s1","revision":1,"elementId":"e99"}"#
        ))))
        XCTAssertEqual(payload["code"]?.stringValue, "stale_element")
        XCTAssertEqual(payload["data"]?["elementId"]?.stringValue, "e99")
        XCTAssertEqual(payload["data"]?["revision"]?.intValue, 1)
    }

    func testReadTextNonAXHandleIsInternalError() throws {
        let (server, context) = actionServer(records: [fixtureRecord()])
        _ = context.sessionManager.ensureSession(appId: "pid:4242", pid: 4242)
        let table = context.elementTable(forSession: "s1")
        table.beginPass()
        let id = table.assign(
            handle: FakeHandle(),
            fingerprint: ElementFingerprint(
                role: "AXTextField",
                subrole: nil,
                axIdentifier: nil,
                parentHash: ElementFingerprint.rootParentHash,
                siblingOrdinal: 0,
                normalizedTitle: ""
            )
        )
        table.endPass()
        let elementId = StableElementTable.idString(id)
        let payload = try toolErrorPayload(try parse(server.process(call(
            id: 25,
            name: "read_text",
            arguments: #"{"app":"computer-use-fixture","sessionId":"s1","revision":1,"elementId":"\#(elementId)"}"#
        ))))
        XCTAssertEqual(payload["code"]?.stringValue, "internal_error")
        // No session mutation: revision stays 1, id still live.
        XCTAssertEqual(context.sessionManager.currentRevision(forSession: "s1"), 1)
        XCTAssertTrue(table.contains(numericId: id))
    }

    // MARK: - Secure / non-string / truncation pure helpers

    func testSecureFieldRejectedByRoleOrSubrole() {
        XCTAssertTrue(ReadTextService.isSecureTextField(role: "AXSecureTextField", subrole: nil))
        XCTAssertTrue(ReadTextService.isSecureTextField(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertFalse(ReadTextService.isSecureTextField(role: "AXTextField", subrole: nil))
        XCTAssertFalse(ReadTextService.isSecureTextField(role: "AXStaticText", subrole: nil))

        XCTAssertThrowsError(
            try ReadTextService.rejectSecureField(role: "AXSecureTextField", subrole: nil, elementId: "e1")
        ) { error in
            guard case let CUError.unsupportedAction(elementId, _, _, reason) = error else {
                return XCTFail("expected unsupported_action, got \(error)")
            }
            XCTAssertEqual(elementId, "e1")
            XCTAssertTrue((reason ?? "").localizedCaseInsensitiveContains("secure"))
        }
        XCTAssertNoThrow(
            try ReadTextService.rejectSecureField(role: "AXTextField", subrole: nil, elementId: "e1")
        )
    }

    func testNonStringAndAbsentValueErrors() {
        XCTAssertThrowsError(
            try ReadTextService.requireStringValue(.absent, elementId: "e7")
        ) { error in
            guard case let CUError.unsupportedAction(elementId, _, _, reason) = error else {
                return XCTFail("expected unsupported_action, got \(error)")
            }
            XCTAssertEqual(elementId, "e7")
            XCTAssertTrue((reason ?? "").contains("no AXValue"))
        }
        XCTAssertThrowsError(
            try ReadTextService.requireStringValue(.nonString, elementId: "e8")
        ) { error in
            guard case let CUError.unsupportedAction(elementId, _, _, reason) = error else {
                return XCTFail("expected unsupported_action, got \(error)")
            }
            XCTAssertEqual(elementId, "e8")
            XCTAssertTrue((reason ?? "").localizedCaseInsensitiveContains("not a string"))
        }
        XCTAssertEqual(
            try ReadTextService.requireStringValue(.string("ok"), elementId: "e1"),
            "ok"
        )
    }

    func testUnicodeGraphemeBoundaryTruncation() {
        // Family emoji is one Character, 25 UTF-8 bytes (four people + ZWJs).
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(family.utf8.count, 25)

        // Budget smaller than the grapheme → empty returned text, truncated.
        let tight = ReadTextService.applyLimit(family, limit: .bytes(10))
        XCTAssertEqual(tight.text, "")
        XCTAssertEqual(tight.totalBytes, 25)
        XCTAssertEqual(tight.returnedBytes, 0)
        XCTAssertTrue(tight.truncated)

        // Budget exactly the grapheme → full character returned.
        let exact = ReadTextService.applyLimit(family, limit: .bytes(25))
        XCTAssertEqual(exact.text, family)
        XCTAssertEqual(exact.returnedBytes, 25)
        XCTAssertFalse(exact.truncated)

        // Mixed: ASCII + grapheme + ASCII; budget covers "ab" + family only.
        let mixed = "ab" + family + "cd"
        let partial = ReadTextService.applyLimit(mixed, limit: .bytes(2 + 25))
        XCTAssertEqual(partial.text, "ab" + family)
        XCTAssertEqual(partial.totalBytes, mixed.utf8.count)
        XCTAssertEqual(partial.returnedBytes, 2 + 25)
        XCTAssertTrue(partial.truncated)

        // Multi-byte non-emoji (é = 2 bytes) must not split either.
        let accented = "café" // c a f é → 5 UTF-8 bytes
        XCTAssertEqual(accented.utf8.count, 5)
        let cut = ReadTextService.applyLimit(accented, limit: .bytes(4))
        XCTAssertEqual(cut.text, "caf")
        XCTAssertEqual(cut.returnedBytes, 3)
        XCTAssertTrue(cut.truncated)
    }

    func testExactByteCountersAndDefaultBudgetShape() {
        let body = String(repeating: "a", count: 100)
        let result = ReadTextService.applyLimit(body, limit: .bytes(40))
        XCTAssertEqual(result.totalBytes, 100)
        XCTAssertEqual(result.returnedBytes, 40)
        XCTAssertEqual(result.text.count, 40)
        XCTAssertEqual(result.text.utf8.count, 40)
        XCTAssertTrue(result.truncated)

        let full = ReadTextService.applyLimit(body, limit: .bytes(100))
        XCTAssertEqual(full.text, body)
        XCTAssertEqual(full.returnedBytes, 100)
        XCTAssertFalse(full.truncated)
    }

    func testMaxReturnsFullTextBeyond256Bytes() {
        let long = String(repeating: "x", count: 512)
        XCTAssertGreaterThan(long.utf8.count, 256)
        let result = ReadTextService.applyLimit(long, limit: .max)
        XCTAssertEqual(result.text, long)
        XCTAssertEqual(result.totalBytes, 512)
        XCTAssertEqual(result.returnedBytes, 512)
        XCTAssertFalse(result.truncated)
    }

    func testNoSessionMutationOnGateFailures() throws {
        let (server, context) = actionServer(records: [fixtureRecord()])
        let session = context.sessionManager.ensureSession(appId: "pid:4242", pid: 4242)
        XCTAssertEqual(session.sessionId, "s1")
        XCTAssertEqual(context.sessionManager.currentRevision(forSession: "s1"), 1)

        // Stale revision must not bump.
        _ = try toolErrorPayload(try parse(server.process(call(
            id: 40,
            name: "read_text",
            arguments: #"{"app":"computer-use-fixture","sessionId":"s1","revision":9,"elementId":"e1"}"#
        ))))
        XCTAssertEqual(context.sessionManager.currentRevision(forSession: "s1"), 1)

        // Stale element must not bump or mint ids.
        let table = context.elementTable(forSession: "s1")
        let before = table.liveNumericIds
        _ = try toolErrorPayload(try parse(server.process(call(
            id: 41,
            name: "read_text",
            arguments: #"{"app":"computer-use-fixture","sessionId":"s1","revision":1,"elementId":"e1"}"#
        ))))
        XCTAssertEqual(context.sessionManager.currentRevision(forSession: "s1"), 1)
        XCTAssertEqual(table.liveNumericIds, before)
    }

    // MARK: - Tool-level error mapping via MCP

    func testReadTextToolLevelErrorMapping() throws {
        let blocked = AppRecord(
            bundleId: "com.example.blocked",
            displayName: "Blocked",
            path: nil,
            pid: 999,
            isRunning: true,
            windows: 1
        )
        let (server, _) = actionServer(records: [blocked], deniedApps: ["com.example.blocked"])
        let response = try parse(server.process(call(
            id: 50,
            name: "read_text",
            arguments: #"{"app":"com.example.blocked","sessionId":"s1","revision":1,"elementId":"e1"}"#
        )))
        // Tool-level error: successful JSON-RPC envelope with isError:true.
        XCTAssertNil(response["error"])
        XCTAssertEqual(response["result"]?["isError"]?.boolValue, true)
        let text = try XCTUnwrap(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let payload = try JSONValue.parse(text)
        XCTAssertEqual(payload["code"]?.stringValue, "policy_denied")
    }

    // MARK: - Helpers

    private final class FakeHandle: ElementHandle {
        var live: Bool
        init(live: Bool = true) { self.live = live }
        var isLive: Bool { live }
    }

    private struct FakeAppEnvironment: AppEnvironment {
        let records: [AppRecord]
        func allApps() -> [AppRecord] { records }
        func app(forPID pid: Int32) -> AppRecord? { records.first { $0.pid == pid } }
        func pathExists(_ path: String) -> Bool { false }
    }

    private func fixtureRecord() -> AppRecord {
        AppRecord(
            bundleId: nil,
            displayName: "computer-use-fixture",
            path: nil,
            pid: 4242,
            isRunning: true,
            windows: 1
        )
    }

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
