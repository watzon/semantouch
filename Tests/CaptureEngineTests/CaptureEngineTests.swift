import XCTest
import ComputerUseCore
@testable import CaptureEngine

/// Placeholder suite. Real tests (window correlation, covered-window capture,
/// coordinate round-trips, screenshot encoding) land with the engine in Stage B.
final class CaptureEngineTests: XCTestCase {
    func testScreenshotPolicyConstantsMatchProtocol() {
        // §8: JPEG q0.75, long edge 1568 px, 3 MB cap, JPEG on the MCP path.
        XCTAssertEqual(CaptureEngine.jpegQuality, 0.75, accuracy: 0.0001)
        XCTAssertEqual(CaptureEngine.maxLongEdgePixels, 1568)
        XCTAssertEqual(CaptureEngine.maxEncodedBytes, 3 * 1024 * 1024)
        XCTAssertEqual(CaptureEngine.mcpMimeType, "image/jpeg")
    }
}
