import XCTest
import ComputerUseCore
@testable import CaptureEngine

/// The pure `uncapturable_window` classification decision table (PROTOCOL §6). The
/// live SCScreenshotManager path needs Screen Recording; this seam does not.
final class WindowCaptureTests: XCTestCase {
    func testZeroSizeFrameIsUnsupportedSurface() {
        XCTAssertEqual(
            WindowCapture.classifyUncapturable(
                frameIsZeroSize: true, stillPresent: true, isOnscreen: true, isScreenCaptureKitError: true
            ),
            .unsupportedSurface
        )
    }

    func testVanishedWindowIsStale() {
        XCTAssertEqual(
            WindowCapture.classifyUncapturable(
                frameIsZeroSize: false, stillPresent: false, isOnscreen: true, isScreenCaptureKitError: true
            ),
            .stale
        )
    }

    func testPresentButOffscreenIsMinimized() {
        XCTAssertEqual(
            WindowCapture.classifyUncapturable(
                frameIsZeroSize: false, stillPresent: true, isOnscreen: false, isScreenCaptureKitError: true
            ),
            .minimized
        )
    }

    func testPresentOnscreenScreenCaptureKitErrorIsProtected() {
        XCTAssertEqual(
            WindowCapture.classifyUncapturable(
                frameIsZeroSize: false, stillPresent: true, isOnscreen: true, isScreenCaptureKitError: true
            ),
            .protected
        )
    }

    func testPresentOnscreenNonScreenCaptureKitErrorIsUnsupportedSurface() {
        XCTAssertEqual(
            WindowCapture.classifyUncapturable(
                frameIsZeroSize: false, stillPresent: true, isOnscreen: true, isScreenCaptureKitError: false
            ),
            .unsupportedSurface
        )
    }
}
