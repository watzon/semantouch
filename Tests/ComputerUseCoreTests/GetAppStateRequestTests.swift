import Foundation
import XCTest
@testable import ComputerUseCore

final class GetAppStateRequestTests: XCTestCase {
    func testOmittedWindowIdRequestsAutomaticSelection() throws {
        let request = try decode(#"{"app":"Aside"}"#)

        XCTAssertNil(request.windowId)
    }

    func testNullWindowIdRequestsAutomaticSelection() throws {
        let request = try decode(#"{"app":"Aside","windowId":0}"#)

        XCTAssertNil(request.windowId, "kCGNullWindowID must not enter explicit-window resolution")
    }

    func testPositiveWindowIdRemainsExplicit() throws {
        let request = try decode(#"{"app":"Aside","windowId":40213}"#)

        XCTAssertEqual(request.windowId, 40_213)
    }

    func testInitializerNormalizesNullWindowId() {
        XCTAssertNil(GetAppStateRequest(app: "Aside", windowId: 0).windowId)
        XCTAssertEqual(GetAppStateRequest(app: "Aside", windowId: 40_213).windowId, 40_213)
    }

    // MARK: - v1.5 scoped/bounded fields (§18.2)

    func testScopeAndMaxNodesDefaultToNilWhenOmitted() throws {
        let request = try decode(#"{"app":"Aside"}"#)
        XCTAssertNil(request.scopeElementId)
        XCTAssertNil(request.maxNodes)
        XCTAssertFalse(request.isScoped)
    }

    func testScopeElementIdDecodes() throws {
        let request = try decode(#"{"app":"Aside","scopeElementId":"e42"}"#)
        XCTAssertEqual(request.scopeElementId, "e42")
        XCTAssertTrue(request.isScoped)
    }

    func testMaxNodesDecodes() throws {
        let request = try decode(#"{"app":"Aside","maxNodes":1500}"#)
        XCTAssertEqual(request.maxNodes, 1500)
    }

    func testScopedFlagFollowsScopeElementId() {
        XCTAssertTrue(GetAppStateRequest(app: "Aside", scopeElementId: "e1").isScoped)
        XCTAssertFalse(GetAppStateRequest(app: "Aside").isScoped)
    }

    private func decode(_ json: String) throws -> GetAppStateRequest {
        try JSONDecoder().decode(GetAppStateRequest.self, from: Data(json.utf8))
    }
}
