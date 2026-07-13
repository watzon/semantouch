import XCTest
@testable import ComputerUseCore

/// Encoding/decoding coverage for the v1.5 `screenshot` DTOs (§18.9). `ScreenshotResult`
/// reuses `AppState.WindowInfo`/`ScreenshotMeta`/`StateWarning`; the image is the product, so
/// `window.screenshotPixels`/`scale` are always present, `window.title` is omit-when-nil, and
/// `window.document` is never populated (no tree walk) so it is always omitted.
/// `ScreenshotRequest` normalizes the null WindowServer id `0`→`nil` exactly like get_app_state.
final class ScreenshotResultEncodingTests: XCTestCase {
    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try CanonicalJSON.encodeToData(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func result(
        title: String? = "Main",
        warnings: [StateWarning] = []
    ) -> ScreenshotResult {
        ScreenshotResult(
            sessionId: "s1",
            window: AppState.WindowInfo(
                id: 123,
                title: title,
                framePoints: Rect(x: 0, y: 0, width: 400, height: 300),
                screenshotPixels: Size(width: 800, height: 600),
                scale: 2
            ),
            screenshot: AppState.ScreenshotMeta(width: 800, height: 600, byteLength: 4096),
            warnings: warnings
        )
    }

    func testCanonicalShapeOfAPopulatedResult() throws {
        // Byte-stable canonical JSON (sorted keys); `warnings` is always present (possibly
        // empty), mirroring AppState.warnings, and `window.document` is absent (no tree walk).
        let data = try CanonicalJSON.encodeToString(result())
        XCTAssertEqual(
            data,
            #"{"screenshot":{"byteLength":4096,"height":600,"mimeType":"image/jpeg","width":800},"sessionId":"s1","warnings":[],"window":{"framePoints":{"height":300,"width":400,"x":0,"y":0},"id":123,"scale":2,"screenshotPixels":{"height":600,"width":800},"title":"Main"}}"#
        )
    }

    func testTitleOmittedWhenNilAndDocumentNeverEmitted() throws {
        let obj = try encodedObject(result(title: nil))
        let window = try XCTUnwrap(obj["window"] as? [String: Any])
        XCTAssertNil(window["title"], "title omit-when-nil (§18.9)")
        XCTAssertNil(window["document"], "document never populated by screenshot (§18.9)")
        // screenshotPixels/scale are always present here — the image is the product.
        XCTAssertNotNil(window["screenshotPixels"])
        XCTAssertNotNil(window["scale"])
        // warnings is always present, even empty.
        XCTAssertEqual((obj["warnings"] as? [Any])?.count, 0)
    }

    func testWarningsEmittedWhenPresent() throws {
        let warned = result(warnings: [StateWarning(.lowCorrelationConfidence, message: "weak")])
        let obj = try encodedObject(warned)
        let warnings = try XCTUnwrap(obj["warnings"] as? [[String: Any]])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?["code"] as? String, "low_correlation_confidence")
    }

    func testRoundTripPreservesAllFields() throws {
        let value = result(title: "Docs", warnings: [StateWarning(.lowCorrelationConfidence, message: "weak")])
        let decoded = try CanonicalJSON.decode(ScreenshotResult.self, from: CanonicalJSON.encodeToData(value))
        XCTAssertEqual(decoded, value)
    }

    // MARK: - ScreenshotRequest decoding (§18.9)

    private func decodeRequest(_ json: String) throws -> ScreenshotRequest {
        try CanonicalJSON.decode(ScreenshotRequest.self, from: json)
    }

    func testRequestDecodesWindowId() throws {
        XCTAssertEqual(try decodeRequest(#"{"app":"Safari","windowId":40213}"#).windowId, 40_213)
    }

    func testRequestNormalizesNullWindowIdZeroToNil() throws {
        // §10.2: the null WindowServer id 0 (and an omitted windowId) both request auto-select.
        XCTAssertNil(try decodeRequest(#"{"app":"Safari","windowId":0}"#).windowId)
        XCTAssertNil(try decodeRequest(#"{"app":"Safari"}"#).windowId)
        // The memberwise initializer applies the same normalization.
        XCTAssertNil(ScreenshotRequest(app: "Safari", windowId: 0).windowId)
    }
}
