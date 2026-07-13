import XCTest
import ComputerUseCore
@testable import CursorOverlay

#if canImport(AppKit)
import AppKit

/// Golden for the global-top-left → Cocoa-bottom-left coordinate flip used by the live
/// presenter (protocol §9 vs Cocoa's bottom-left origin). Hermetic: the primary screen
/// height is supplied, so no display is required.
final class CocoaRectTests: XCTestCase {
    func testGlobalTopLeftMapsToCocoaBottomLeft() {
        // Primary screen 900 pt tall. A window at global (100, 200), 400×300.
        // Its top edge is 200 pt below the top, bottom edge at 500 pt below the top,
        // i.e. 900 − 500 = 400 pt up from the Cocoa origin.
        let rect = AppKitCursorPresenter.cocoaRect(
            fromGlobalTopLeft: Rect(x: 100, y: 200, width: 400, height: 300),
            primaryHeight: 900
        )
        XCTAssertEqual(rect.origin.x, 100, accuracy: 1e-9)
        XCTAssertEqual(rect.origin.y, 400, accuracy: 1e-9)
        XCTAssertEqual(rect.size.width, 400, accuracy: 1e-9)
        XCTAssertEqual(rect.size.height, 300, accuracy: 1e-9)
    }

    func testWindowFlushToTopMapsToTopOfCocoaSpace() {
        let rect = AppKitCursorPresenter.cocoaRect(
            fromGlobalTopLeft: Rect(x: 0, y: 0, width: 200, height: 100),
            primaryHeight: 800
        )
        // Top-left window: Cocoa y = 800 − (0 + 100) = 700.
        XCTAssertEqual(rect.origin.y, 700, accuracy: 1e-9)
    }
}

#endif
