import XCTest
import CoreGraphics
import ComputerUseCore
@testable import CaptureEngine

/// CGWindowList dictionary parsing on synthetic input (PROTOCOL §10.2). The pure
/// `parseCGWindow` seam needs no Screen Recording permission.
final class WindowCatalogTests: XCTestCase {
    private func baseDict() -> [String: Any] {
        [
            kCGWindowNumber as String: 42,
            kCGWindowOwnerPID as String: 1234,
            kCGWindowBounds as String: ["X": 10.0, "Y": 20.0, "Width": 300.0, "Height": 200.0],
            kCGWindowName as String: "Hello",
            kCGWindowLayer as String: 0,
            kCGWindowIsOnscreen as String: true,
            kCGWindowAlpha as String: 1.0,
        ]
    }

    func testParsesFullDictionary() {
        let info = WindowCatalog.parseCGWindow(baseDict())
        XCTAssertEqual(info?.windowNumber, 42)
        XCTAssertEqual(info?.ownerPID, 1234)
        XCTAssertEqual(info?.bounds, Rect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(info?.title, "Hello")
        XCTAssertEqual(info?.layer, 0)
        XCTAssertEqual(info?.isOnscreen, true)
        XCTAssertEqual(info?.alpha, 1.0)
        XCTAssertEqual(info?.hasShareableWindow, false) // set only by snapshot()
    }

    func testMissingWindowNumberYieldsNil() {
        var dict = baseDict()
        dict.removeValue(forKey: kCGWindowNumber as String)
        XCTAssertNil(WindowCatalog.parseCGWindow(dict))
    }

    func testMissingOwnerPIDYieldsNil() {
        var dict = baseDict()
        dict.removeValue(forKey: kCGWindowOwnerPID as String)
        XCTAssertNil(WindowCatalog.parseCGWindow(dict))
    }

    func testOptionalKeysDefault() {
        let dict: [String: Any] = [
            kCGWindowNumber as String: 7,
            kCGWindowOwnerPID as String: 99,
        ]
        let info = WindowCatalog.parseCGWindow(dict)
        XCTAssertEqual(info?.windowNumber, 7)
        XCTAssertEqual(info?.ownerPID, 99)
        XCTAssertEqual(info?.bounds, Rect(x: 0, y: 0, width: 0, height: 0))
        XCTAssertNil(info?.title)
        XCTAssertEqual(info?.layer, 0)
        XCTAssertEqual(info?.isOnscreen, false)
        XCTAssertEqual(info?.alpha, 1.0)
    }

    func testIsNormalVisibleClassification() {
        let normal = WindowInfo(windowNumber: 1, ownerPID: 1, bounds: Rect(x: 0, y: 0, width: 100, height: 100), layer: 0, isOnscreen: true, alpha: 1)
        XCTAssertTrue(normal.isNormalVisible)

        let overlay = WindowInfo(windowNumber: 2, ownerPID: 1, bounds: Rect(x: 0, y: 0, width: 100, height: 100), layer: 3, isOnscreen: true, alpha: 1)
        XCTAssertFalse(overlay.isNormalVisible)

        let offscreen = WindowInfo(windowNumber: 3, ownerPID: 1, bounds: Rect(x: 0, y: 0, width: 100, height: 100), layer: 0, isOnscreen: false, alpha: 1)
        XCTAssertFalse(offscreen.isNormalVisible)

        let transparent = WindowInfo(windowNumber: 4, ownerPID: 1, bounds: Rect(x: 0, y: 0, width: 100, height: 100), layer: 0, isOnscreen: true, alpha: 0)
        XCTAssertFalse(transparent.isNormalVisible)

        let zeroArea = WindowInfo(windowNumber: 5, ownerPID: 1, bounds: Rect(x: 0, y: 0, width: 0, height: 100), layer: 0, isOnscreen: true, alpha: 1)
        XCTAssertFalse(zeroArea.isNormalVisible)
    }

    func testCapturableWindowCountFiltersByPidVisibilityAndShareable() {
        let snapshot = WindowCatalogSnapshot(
            windows: [
                WindowInfo(windowNumber: 1, ownerPID: 10, bounds: Rect(x: 0, y: 0, width: 100, height: 100), layer: 0, isOnscreen: true, alpha: 1, hasShareableWindow: true),
                WindowInfo(windowNumber: 2, ownerPID: 10, bounds: Rect(x: 0, y: 0, width: 100, height: 100), layer: 0, isOnscreen: true, alpha: 1, hasShareableWindow: false), // no SCWindow
                WindowInfo(windowNumber: 3, ownerPID: 10, bounds: Rect(x: 0, y: 0, width: 100, height: 100), layer: 3, isOnscreen: true, alpha: 1, hasShareableWindow: true), // overlay layer
                WindowInfo(windowNumber: 4, ownerPID: 20, bounds: Rect(x: 0, y: 0, width: 100, height: 100), layer: 0, isOnscreen: true, alpha: 1, hasShareableWindow: true), // other pid
            ],
            shareableByNumber: [:]
        )
        XCTAssertEqual(snapshot.capturableWindowCount(forPID: 10), 1)
        XCTAssertEqual(snapshot.windows(forPID: 10).count, 3)
        XCTAssertEqual(snapshot.window(number: 4)?.ownerPID, 20)
    }
}
