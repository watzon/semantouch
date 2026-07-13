import XCTest
import ComputerUseCore
@testable import ComputerUseService

/// Pure geometry for the drawn cursor's semantic-action anchor: a semantic
/// action anchors the overlay at the target element's frame
/// centre in WINDOW points, so the ghost cursor visibly does the work instead of resting
/// at the window centre.
final class CursorReflectionTests: XCTestCase {
    func testElementAnchorIsFrameCenterInWindowPoints() {
        let window = Rect(x: 100, y: 200, width: 800, height: 600)
        let element = Rect(x: 180, y: 260, width: 40, height: 20) // global points
        let anchor = CursorReflection.elementAnchor(frameGlobal: element, windowFrame: window)
        XCTAssertEqual(anchor, Point(x: 100, y: 70)) // (180+20-100, 260+10-200)
    }

    func testElementAnchorZeroSizeFrameStillAnchorsAtItsPoint() {
        // A zero-size frame (collapsed/offscreen web nodes report these) still names a
        // real location; the anchor is that point, not nil.
        let window = Rect(x: 0, y: 0, width: 800, height: 600)
        let element = Rect(x: 40, y: 60, width: 0, height: 0)
        XCTAssertEqual(
            CursorReflection.elementAnchor(frameGlobal: element, windowFrame: window),
            Point(x: 40, y: 60)
        )
    }

    func testElementAnchorNegativeFrameIsNil() {
        let window = Rect(x: 0, y: 0, width: 800, height: 600)
        let element = Rect(x: 40, y: 60, width: -1, height: 10)
        XCTAssertNil(CursorReflection.elementAnchor(frameGlobal: element, windowFrame: window))
    }
}
