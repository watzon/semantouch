import XCTest
@testable import ComputerUseCore

/// Canonical-JSON byte shape for `ActionResult` (§18.5/§18.6 additive fields) and the new
/// `WaitForResult` (§18.7). The additive fields are omitted when nil, so every pre-v1.5 result
/// stays byte-identical.
final class ActionResultEncodingTests: XCTestCase {
    private func encode<T: Encodable>(_ value: T) throws -> String {
        try CanonicalJSON.encodeToString(value)
    }

    func testSemanticResultOmitsAllV15Fields() throws {
        // A plain Phase-2 semantic result: none of committed/elementFocused/focus* appear.
        let result = ActionResult(status: .completed, method: .accessibility, stateChanged: true, refreshRecommended: true)
        XCTAssertEqual(
            try encode(result),
            #"{"method":"accessibility","refreshRecommended":true,"stateChanged":true,"status":"completed"}"#
        )
    }

    func testCommitResultCarriesCommittedOnly() throws {
        // §18.5: `committed` present, `elementFocused` (and focus*) absent.
        let result = ActionResult(status: .completed, method: .accessibility, stateChanged: true, refreshRecommended: true, committed: true)
        XCTAssertEqual(
            try encode(result),
            #"{"committed":true,"method":"accessibility","refreshRecommended":true,"stateChanged":true,"status":"completed"}"#
        )
    }

    func testElementFocusedResultCarriesElementFocusedOnly() throws {
        // §18.6: `elementFocused` present, `committed` absent.
        let result = ActionResult(status: .completed, method: .keyboard, stateChanged: false, refreshRecommended: true, elementFocused: false)
        XCTAssertEqual(
            try encode(result),
            #"{"elementFocused":false,"method":"keyboard","refreshRecommended":true,"stateChanged":false,"status":"completed"}"#
        )
    }

    func testWaitForResultByteShapeAndRoundTrip() throws {
        let result = WaitForResult(
            satisfied: true,
            elapsedMs: 640,
            conditions: [.init(kind: "url_contains", satisfied: true), .init(kind: "title_changed", satisfied: false)],
            observed: .init(windowTitle: "Example Domain", url: "https://example.com/")
        )
        XCTAssertEqual(
            try encode(result),
            #"{"conditions":[{"kind":"url_contains","satisfied":true},{"kind":"title_changed","satisfied":false}],"elapsedMs":640,"observed":{"url":"https://example.com/","windowTitle":"Example Domain"},"refreshRecommended":true,"satisfied":true}"#
        )
        // Round-trips through Decodable.
        let decoded = try CanonicalJSON.decode(WaitForResult.self, from: try encode(result))
        XCTAssertEqual(decoded, result)
    }

    func testWaitForResultOmitsUnreadableObservations() throws {
        // A non-web window with an unreadable title: observed is an empty object.
        let result = WaitForResult(satisfied: false, elapsedMs: 5000, conditions: [.init(kind: "element_gone", satisfied: false)])
        XCTAssertEqual(
            try encode(result),
            #"{"conditions":[{"kind":"element_gone","satisfied":false}],"elapsedMs":5000,"observed":{},"refreshRecommended":true,"satisfied":false}"#
        )
    }
}
