import XCTest
@testable import ComputerUseCore

/// Encoding coverage for the additive v1.5 `AppState` fields (§18.2–18.4): every new field
/// is **omit-when-absent** so a snapshot that uses none of them stays byte-identical to
/// pre-v1.5 output, and each surfaces only when populated.
final class AppStateEncodingTests: XCTestCase {
    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try CanonicalJSON.encodeToData(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func plainWindow() -> AppState.WindowInfo {
        AppState.WindowInfo(id: 7, framePoints: Rect(x: 0, y: 0, width: 10, height: 10), scale: 2)
    }

    private func baseState(
        window: AppState.WindowInfo,
        windows: [AppState.WindowSummary]? = nil,
        scope: AppState.Scope? = nil
    ) -> AppState {
        AppState(
            sessionId: "s1",
            app: AppSummary(id: "com.example", displayName: "Example", isRunning: true, windows: 2),
            window: window,
            tree: AppState.TreeInfo(text: "[e1] AXWindow frame=0,0,10,10", nodeCount: 1, truncated: false),
            windows: windows,
            scope: scope
        )
    }

    func testAdditiveFieldsOmittedForByteIdentity() throws {
        let obj = try encodedObject(baseState(window: plainWindow()))
        XCTAssertNil(obj["windows"], "top-level windows array omitted when nil (§18.3)")
        XCTAssertNil(obj["scope"], "scope omitted when nil (§18.2)")
        let window = try XCTUnwrap(obj["window"] as? [String: Any])
        XCTAssertNil(window["document"], "window.document omitted when nil (§18.4)")
    }

    func testWindowsScopeAndDocumentEmittedWhenPresent() throws {
        let window = AppState.WindowInfo(
            id: 7, framePoints: Rect(x: 0, y: 0, width: 10, height: 10), scale: 2,
            document: AppState.WindowInfo.DocumentInfo(url: "https://example.com/", title: "Example")
        )
        let windows = [
            AppState.WindowSummary(
                id: 7, title: "Main",
                framePoints: Rect(x: 0, y: 0, width: 10, height: 10),
                focused: true, main: true, onScreen: true
            ),
        ]
        let obj = try encodedObject(baseState(window: window, windows: windows, scope: AppState.Scope(elementId: "e42")))
        XCTAssertEqual((obj["windows"] as? [Any])?.count, 1)
        XCTAssertEqual((obj["scope"] as? [String: Any])?["elementId"] as? String, "e42")
        let doc = try XCTUnwrap((obj["window"] as? [String: Any])?["document"] as? [String: Any])
        XCTAssertEqual(doc["url"] as? String, "https://example.com/")
        XCTAssertEqual(doc["title"] as? String, "Example")
    }

    func testWindowSummaryOmitsIdWhenUncorrelated() throws {
        // §18.3: an entry without a WindowServer id is not re-targetable, but still carries
        // its focus/main/onScreen flags (always present booleans).
        let summary = AppState.WindowSummary(
            id: nil, framePoints: Rect(x: 0, y: 0, width: 5, height: 5),
            focused: false, main: false, onScreen: false
        )
        let obj = try encodedObject(summary)
        XCTAssertNil(obj["id"])
        XCTAssertEqual(obj["focused"] as? Bool, false)
        XCTAssertEqual(obj["main"] as? Bool, false)
        XCTAssertEqual(obj["onScreen"] as? Bool, false)
    }

    func testDocumentOmitsUnreadableField() throws {
        // §18.4: only the readable field is emitted.
        let obj = try encodedObject(AppState.WindowInfo.DocumentInfo(url: "https://x/"))
        XCTAssertEqual(obj["url"] as? String, "https://x/")
        XCTAssertNil(obj["title"])
    }

    func testRoundTripPreservesAdditiveFields() throws {
        let window = AppState.WindowInfo(
            id: 7, framePoints: Rect(x: 0, y: 0, width: 10, height: 10), scale: 2,
            document: AppState.WindowInfo.DocumentInfo(url: "https://example.com/", title: nil)
        )
        let state = baseState(
            window: window,
            windows: [AppState.WindowSummary(id: 3, framePoints: Rect(x: 1, y: 2, width: 3, height: 4), focused: false, main: true, onScreen: true)],
            scope: AppState.Scope(elementId: "e9")
        )
        let decoded = try CanonicalJSON.decode(AppState.self, from: CanonicalJSON.encodeToData(state))
        XCTAssertEqual(decoded, state)
    }

    func testWebContentEnabledWarningCode() {
        XCTAssertEqual(StateWarningCode.webContentEnabled.rawValue, "web_content_enabled")
    }
}
