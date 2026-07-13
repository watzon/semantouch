import XCTest
@testable import ComputerUseCore

final class CUErrorTests: XCTestCase {
    /// Encode an error and parse it back into a loosely-typed dictionary so the
    /// assertions target the wire structure, not Swift types or number formatting.
    private func wire(_ error: CUError) throws -> [String: Any] {
        let string = try error.jsonString()
        let object = try JSONSerialization.jsonObject(with: Data(string.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - Code coverage

    func testEveryProtocolCodeHasACase() {
        // §6 defines exactly 16 tool-level error codes (v1.3 added focus_required;
        // v1.4 added cancelled).
        XCTAssertEqual(CUErrorCode.allCases.count, 16)
    }

    // MARK: - cancelled (v1.4 §17)

    func testCancelledWithoutReasonOmitsData() throws {
        let object = try wire(.cancelled(reason: nil))
        XCTAssertEqual(object["code"] as? String, "cancelled")
        XCTAssertFalse((object["message"] as? String ?? "").isEmpty)
        XCTAssertNil(object["data"], "data is omitted when there is no reason")
    }

    func testCancelledWithReasonIncludesData() throws {
        let object = try wire(.cancelled(reason: "client requested"))
        XCTAssertEqual(object["code"] as? String, "cancelled")
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["reason"] as? String, "client requested")
    }

    func testCancelledRoundTrips() throws {
        for original in [CUError.cancelled(reason: nil), CUError.cancelled(reason: "shutdown")] {
            let decoded = try CanonicalJSON.decode(CUError.self, from: try original.jsonString())
            XCTAssertEqual(decoded, original)
        }
    }

    // MARK: - Wire shape

    func testAppNotFoundWireShape() throws {
        let object = try wire(.appNotFound(query: "Foo"))
        XCTAssertEqual(object["code"] as? String, "app_not_found")
        XCTAssertFalse((object["message"] as? String ?? "").isEmpty)
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["query"] as? String, "Foo")
    }

    func testSortedKeysDeterministicOrdering() throws {
        // Canonical encoding sorts object keys: code < data < message.
        let string = try CUError.appNotFound(query: "Foo").jsonString()
        let codeIndex = try XCTUnwrap(string.range(of: "\"code\"")).lowerBound
        let dataIndex = try XCTUnwrap(string.range(of: "\"data\"")).lowerBound
        let messageIndex = try XCTUnwrap(string.range(of: "\"message\"")).lowerBound
        XCTAssertTrue(codeIndex < dataIndex)
        XCTAssertTrue(dataIndex < messageIndex)
    }

    func testPermissionDeniedWireShape() throws {
        let object = try wire(.permissionDenied(
            permission: .accessibility,
            helperPath: "/usr/local/bin/semantouch",
            remediation: ["Grant Accessibility to semantouch in System Settings."]
        ))
        XCTAssertEqual(object["code"] as? String, "permission_denied")
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["permission"] as? String, "accessibility")
        XCTAssertEqual(data["helperPath"] as? String, "/usr/local/bin/semantouch")
        XCTAssertEqual((data["remediation"] as? [String])?.count, 1)
    }

    func testAmbiguousAppCandidatesWireShape() throws {
        let candidates = [
            AppSummary(id: "com.a.player", displayName: "Player", isRunning: true, windows: 1),
            AppSummary(id: "com.b.player", displayName: "Player", isRunning: true, windows: 1),
        ]
        let object = try wire(.ambiguousApp(query: "Player", candidates: candidates))
        XCTAssertEqual(object["code"] as? String, "ambiguous_app")
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["query"] as? String, "Player")
        let arr = try XCTUnwrap(data["candidates"] as? [[String: Any]])
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[0]["id"] as? String, "com.a.player")
    }

    func testWindowNotFoundOmitsAbsentWindowId() throws {
        let object = try wire(.windowNotFound(app: "Safari", windowId: nil))
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["app"] as? String, "Safari")
        XCTAssertNil(data["windowId"], "windowId must be omitted when nil")
    }

    func testWindowNotFoundIncludesPresentWindowId() throws {
        let object = try wire(.windowNotFound(app: "Safari", windowId: 42))
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual((data["windowId"] as? NSNumber)?.intValue, 42)
    }

    func testPolicyDeniedToolDisabledWireShape() throws {
        let object = try wire(.policyDenied(reason: .toolDisabled, app: nil, tool: "click"))
        XCTAssertEqual(object["code"] as? String, "policy_denied")
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["reason"] as? String, "tool_disabled")
        XCTAssertEqual(data["tool"] as? String, "click")
        XCTAssertNil(data["app"], "app must be omitted when nil")
    }

    func testStaleRevisionWireShape() throws {
        let object = try wire(.staleRevision(sessionId: "s1", provided: 3, current: 5))
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["sessionId"] as? String, "s1")
        XCTAssertEqual((data["provided"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual((data["current"] as? NSNumber)?.intValue, 5)
    }

    func testStaleRevisionNullCurrentIsExplicitNull() throws {
        // v1.1 (§13.2): an unknown/ended session emits current as an explicit null.
        let object = try wire(.staleRevision(sessionId: "s1", provided: 3, current: nil))
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertTrue(data.keys.contains("current"), "current is present…")
        XCTAssertTrue(data["current"] is NSNull, "…and is JSON null")
    }

    func testStaleRevisionNullCurrentRoundTrips() throws {
        let original = CUError.staleRevision(sessionId: "s1", provided: 3, current: nil)
        let decoded = try CanonicalJSON.decode(CUError.self, from: try original.jsonString())
        XCTAssertEqual(decoded, original)
    }

    func testUnsupportedActionReasonWireShape() throws {
        // v1.1 (§13.3): the optional reason is emitted when present.
        let object = try wire(.unsupportedAction(elementId: "e1", action: nil, supported: ["AXPress"], reason: "no scrollable region"))
        XCTAssertEqual(object["code"] as? String, "unsupported_action")
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["elementId"] as? String, "e1")
        XCTAssertEqual(data["reason"] as? String, "no scrollable region")
        XCTAssertNil(data["action"], "action is omitted when nil")
        XCTAssertEqual((data["supported"] as? [String])?.count, 1)
    }

    func testUnsupportedActionOmitsReasonWhenNil() throws {
        let object = try wire(.unsupportedAction(elementId: "e1", action: "AXPress", supported: [], reason: nil))
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertNil(data["reason"], "reason is omitted when nil")
    }

    func testUncapturableWindowReasonRawValue() throws {
        let object = try wire(.uncapturableWindow(app: "Safari", windowId: 7, reason: .unsupportedSurface))
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["reason"] as? String, "unsupported_surface")
    }

    // MARK: - Optional-only data → data omitted

    func testUserInterruptedWithoutTimestampOmitsData() throws {
        let object = try wire(.userInterrupted(at: nil))
        XCTAssertEqual(object["code"] as? String, "user_interrupted")
        XCTAssertNil(object["data"], "data must be omitted when there is no payload")
    }

    func testInternalErrorWithoutDetailOmitsData() throws {
        let object = try wire(.internalError(detail: nil))
        XCTAssertNil(object["data"])
    }

    func testInternalErrorWithDetailIncludesData() throws {
        let object = try wire(.internalError(detail: "boom"))
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["detail"] as? String, "boom")
    }

    // MARK: - Round trip (exercises Decodable)

    func testRoundTripSimple() throws {
        let original = CUError.appNotFound(query: "Bar")
        let decoded = try CanonicalJSON.decode(CUError.self, from: try original.jsonString())
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripWithCandidates() throws {
        let original = CUError.ambiguousApp(
            query: "Player",
            candidates: [AppSummary(id: "com.a.player", displayName: "Player", isRunning: true, windows: 1)]
        )
        let decoded = try CanonicalJSON.decode(CUError.self, from: try original.jsonString())
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripOptionalDataAbsent() throws {
        let original = CUError.userInterrupted(at: nil)
        let decoded = try CanonicalJSON.decode(CUError.self, from: try original.jsonString())
        XCTAssertEqual(decoded, original)
    }
}
