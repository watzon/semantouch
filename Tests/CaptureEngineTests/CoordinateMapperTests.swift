import XCTest
import CoreGraphics
import ComputerUseCore
@testable import CaptureEngine

/// Coordinate conversions and pure sizing/rounding (PROTOCOL §9). No permissions.
final class CoordinateMapperTests: XCTestCase {
    private let eps = 1e-9

    private func assertPointEqual(_ a: CGPoint, _ b: CGPoint, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: eps, msg, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: eps, msg, file: file, line: line)
    }

    // MARK: - Round trips (2x scale, non-integer origin)

    func testGlobalWindowRoundTripNonIntegerOrigin() {
        let frame = Rect(x: 13.5, y: 47.25, width: 640, height: 480)
        let pixels = CoordinateMapper.screenshotPixelSize(framePoints: frame, scale: 2.0)
        // 1280x960 backing, long edge <= 1568 so no downscale.
        XCTAssertEqual(pixels, Size(width: 1280, height: 960))
        let mapper = CoordinateMapper(framePoints: frame, screenshotPixels: pixels)

        let g = CGPoint(x: 113.5, y: 247.25)
        let w = mapper.windowPoint(fromGlobal: g)
        assertPointEqual(w, CGPoint(x: 100, y: 200))
        assertPointEqual(mapper.globalPoint(fromWindow: w), g)
    }

    func testWindowScreenshotRoundTrip2x() {
        let frame = Rect(x: 13.5, y: 47.25, width: 640, height: 480)
        let mapper = CoordinateMapper(framePoints: frame, screenshotPixels: Size(width: 1280, height: 960))
        XCTAssertEqual(mapper.kx, 2.0, accuracy: eps)
        XCTAssertEqual(mapper.ky, 2.0, accuracy: eps)

        let w = CGPoint(x: 100, y: 200)
        let s = mapper.screenshotPoint(fromWindow: w)
        assertPointEqual(s, CGPoint(x: 200, y: 400))
        assertPointEqual(mapper.windowPoint(fromScreenshot: s), w)
    }

    func testGlobalScreenshotComposeRoundTripWithDownscale() {
        // 2000x1000 pt @2x = 4000x2000 backing; long edge 4000 -> downscaled to 1568.
        let frame = Rect(x: 5.25, y: 9.75, width: 2000, height: 1000)
        let pixels = CoordinateMapper.screenshotPixelSize(framePoints: frame, scale: 2.0)
        XCTAssertEqual(pixels, Size(width: 1568, height: 784))
        let mapper = CoordinateMapper(framePoints: frame, screenshotPixels: pixels)

        let g = CGPoint(x: 1005.25, y: 509.75)
        let s = mapper.screenshotPoint(fromGlobal: g)
        assertPointEqual(mapper.globalPoint(fromScreenshot: s), g)
        // kx/ky derived from delivered pixels, not scale alone (§9).
        XCTAssertEqual(mapper.kx, 1568.0 / 2000.0, accuracy: eps)
        XCTAssertEqual(mapper.ky, 784.0 / 1000.0, accuracy: eps)
    }

    func testWindowRectFromGlobalTranslatesOriginKeepsSize() {
        let frame = Rect(x: 100, y: 200, width: 800, height: 600)
        let mapper = CoordinateMapper(framePoints: frame, screenshotPixels: Size(width: 800, height: 600))
        let axFrameG = Rect(x: 150, y: 260, width: 120, height: 32)
        let w = mapper.windowRect(fromGlobal: axFrameG)
        XCTAssertEqual(w, Rect(x: 50, y: 60, width: 120, height: 32))
        XCTAssertEqual(mapper.globalRect(fromWindow: w), axFrameG)
    }

    // MARK: - Sizing helpers

    func testBackingPixelSizeRoundsComponents() {
        let frame = Rect(x: 0, y: 0, width: 100.4, height: 50.6)
        XCTAssertEqual(
            CoordinateMapper.backingPixelSize(framePoints: frame, scale: 2.0),
            Size(width: 201, height: 101)
        )
    }

    func testScreenshotPixelSizeNoUpscaleWhenSmall() {
        let frame = Rect(x: 0, y: 0, width: 300, height: 200)
        // 300x200 @1x, well under 1568 -> unchanged, no upscaling.
        XCTAssertEqual(
            CoordinateMapper.screenshotPixelSize(framePoints: frame, scale: 1.0),
            Size(width: 300, height: 200)
        )
    }

    // MARK: - Rounding (ties away from zero, §7.2)

    func testRoundedWindowFrameTiesAwayFromZero() {
        let r = Rect(x: 2.5, y: -2.5, width: 3.5, height: 0.5)
        let f = CoordinateMapper.roundedWindowFrame(r)
        XCTAssertEqual(f.x, 3)
        XCTAssertEqual(f.y, -3)
        XCTAssertEqual(f.width, 4)
        XCTAssertEqual(f.height, 1)
    }

    func testRoundedIntTiesAway() {
        XCTAssertEqual(CoordinateMapper.roundedInt(0.5), 1)
        XCTAssertEqual(CoordinateMapper.roundedInt(-0.5), -1)
        XCTAssertEqual(CoordinateMapper.roundedInt(1.4999), 1)
        XCTAssertEqual(CoordinateMapper.roundedInt(-1.5), -2)
    }

    // MARK: - Degenerate frames

    func testDegenerateFrameYieldsZeroRatios() {
        let mapper = CoordinateMapper(
            framePoints: Rect(x: 0, y: 0, width: 0, height: 0),
            screenshotPixels: Size(width: 0, height: 0)
        )
        XCTAssertEqual(mapper.kx, 0)
        XCTAssertEqual(mapper.ky, 0)
        // S -> W on a degenerate axis clamps to 0 rather than dividing by zero.
        assertPointEqual(mapper.windowPoint(fromScreenshot: CGPoint(x: 10, y: 10)), .zero)
    }

    // MARK: - AppKit bottom-left hazard helper

    func testTopLeftYFlip() {
        // AppKit rect y=100 h=50 on a 900pt screen -> top-left y = 900-100-50 = 750.
        XCTAssertEqual(
            CoordinateMapper.topLeftY(fromBottomLeftY: 100, height: 50, screenHeight: 900),
            750,
            accuracy: eps
        )
    }

    // MARK: - Multiple displays
    //
    // A window's mapper is defined purely by its GLOBAL frame + delivered pixels, so a
    // multi-display arrangement is exercised by giving windows the origins and scales those
    // displays impose — including a secondary display LEFT of primary (negative global X),
    // ABOVE primary (negative global Y), and at a different backing scale. No real NSScreen
    // is needed: the round trips must be exact for points on each display, including the
    // top-left origin hazard and the scale/downscale boundary.

    /// A round-trip check for one point through a mapper: G→W→G, W→S→W, and the composed G→S→G.
    private func assertExactRoundTrip(
        _ mapper: CoordinateMapper,
        global: CGPoint,
        window: CGPoint,
        screenshot: CGPoint,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertPointEqual(mapper.windowPoint(fromGlobal: global), window, "\(label): G→W", file: file, line: line)
        assertPointEqual(mapper.globalPoint(fromWindow: window), global, "\(label): W→G", file: file, line: line)
        assertPointEqual(mapper.screenshotPoint(fromWindow: window), screenshot, "\(label): W→S", file: file, line: line)
        assertPointEqual(mapper.windowPoint(fromScreenshot: screenshot), window, "\(label): S→W", file: file, line: line)
        assertPointEqual(mapper.screenshotPoint(fromGlobal: global), screenshot, "\(label): G→S", file: file, line: line)
        assertPointEqual(mapper.globalPoint(fromScreenshot: screenshot), global, "\(label): S→G", file: file, line: line)
    }

    func testSecondaryDisplayLeftOfPrimaryNegativeOriginRoundTrip() {
        // Non-Retina (1x) display to the LEFT of primary → negative global X.
        let frame = Rect(x: -1200, y: 100, width: 800, height: 600)
        let pixels = CoordinateMapper.screenshotPixelSize(framePoints: frame, scale: 1.0)
        XCTAssertEqual(pixels, Size(width: 800, height: 600))
        let mapper = CoordinateMapper(framePoints: frame, screenshotPixels: pixels)
        XCTAssertEqual(mapper.kx, 1.0, accuracy: eps)

        // Top-left origin hazard: the window origin (a NEGATIVE global point) is window (0,0).
        assertExactRoundTrip(mapper, global: CGPoint(x: -1200, y: 100), window: .zero, screenshot: .zero, "origin")
        assertExactRoundTrip(mapper, global: CGPoint(x: -800, y: 250), window: CGPoint(x: 400, y: 150), screenshot: CGPoint(x: 400, y: 150), "interior")
        // Scale boundary: the far corner maps to the exact pixel extent.
        assertExactRoundTrip(mapper, global: CGPoint(x: -400, y: 700), window: CGPoint(x: 800, y: 600), screenshot: CGPoint(x: 800, y: 600), "far-corner")
    }

    func testSecondaryDisplayAbovePrimaryNegativeYRoundTrip() {
        // Retina (2x) display ABOVE primary → negative global Y; 600×400 @2x = 1200×800 (<1568,
        // no downscale).
        let frame = Rect(x: 200, y: -900, width: 600, height: 400)
        let pixels = CoordinateMapper.screenshotPixelSize(framePoints: frame, scale: 2.0)
        XCTAssertEqual(pixels, Size(width: 1200, height: 800))
        let mapper = CoordinateMapper(framePoints: frame, screenshotPixels: pixels)
        XCTAssertEqual(mapper.ky, 2.0, accuracy: eps)

        assertExactRoundTrip(mapper, global: CGPoint(x: 200, y: -900), window: .zero, screenshot: .zero, "origin")
        assertExactRoundTrip(mapper, global: CGPoint(x: 500, y: -700), window: CGPoint(x: 300, y: 200), screenshot: CGPoint(x: 600, y: 400), "interior")
        assertExactRoundTrip(mapper, global: CGPoint(x: 800, y: -500), window: CGPoint(x: 600, y: 400), screenshot: CGPoint(x: 1200, y: 800), "far-corner")
    }

    func testTwoDisplaysDifferentScalesIndependentRoundTrips() {
        // Primary: Retina 2x window at the global origin.
        let frameA = Rect(x: 0, y: 0, width: 640, height: 480)
        let pixelsA = CoordinateMapper.screenshotPixelSize(framePoints: frameA, scale: 2.0)
        let mapperA = CoordinateMapper(framePoints: frameA, screenshotPixels: pixelsA)
        // Secondary: non-Retina 1x window to the left (negative global X).
        let frameB = Rect(x: -1600, y: 0, width: 800, height: 600)
        let pixelsB = CoordinateMapper.screenshotPixelSize(framePoints: frameB, scale: 1.0)
        let mapperB = CoordinateMapper(framePoints: frameB, screenshotPixels: pixelsB)

        XCTAssertEqual(mapperA.kx, 2.0, accuracy: eps)
        XCTAssertEqual(mapperB.kx, 1.0, accuracy: eps)

        // A point on the primary display.
        assertExactRoundTrip(mapperA, global: CGPoint(x: 320, y: 240), window: CGPoint(x: 320, y: 240), screenshot: CGPoint(x: 640, y: 480), "displayA")
        // A point on the secondary display: a negative global X maps to a POSITIVE window x.
        let bWindow = mapperB.windowPoint(fromGlobal: CGPoint(x: -1200, y: 300))
        XCTAssertGreaterThan(bWindow.x, 0, "a point on the left display must land at a positive window x")
        assertExactRoundTrip(mapperB, global: CGPoint(x: -1200, y: 300), window: CGPoint(x: 400, y: 300), screenshot: CGPoint(x: 400, y: 300), "displayB")
    }

    func testTopLeftFlipComposesWithMapperOnSecondaryDisplayRoundTrip() {
        // The bottom-left→top-left flip (AppKit/NSScreen hazard) must compose with the mapper
        // without drift: a window given in a non-primary display's BOTTOM-LEFT coordinates is
        // flipped to CoreGraphics TOP-LEFT global via `topLeftY(...)`, then its mapper is built
        // from that global frame and an exact G↔W↔S round trip is asserted (reusing the shared
        // exact-round-trip helper).
        let screenHeight = 1080.0   // the secondary display's point height
        let bottomLeftY = 240.0     // AppKit y: the window bottom's distance from the display bottom
        let winW = 700.0, winH = 500.0
        let globalX = -1600.0       // display sits LEFT of primary → negative global X

        // Flip to top-left global y: screenHeight - bottomLeftY - height = 1080 - 240 - 500 = 340.
        let topLeftY = CoordinateMapper.topLeftY(fromBottomLeftY: bottomLeftY, height: winH, screenHeight: screenHeight)
        XCTAssertEqual(topLeftY, 340, accuracy: eps)

        let frame = Rect(x: globalX, y: topLeftY, width: winW, height: winH)
        let pixels = CoordinateMapper.screenshotPixelSize(framePoints: frame, scale: 2.0)
        // 700×500 @2x = 1400×1000 backing; long edge 1400 < 1568 → no downscale, kx=ky=2.
        XCTAssertEqual(pixels, Size(width: 1400, height: 1000))
        let mapper = CoordinateMapper(framePoints: frame, screenshotPixels: pixels)
        XCTAssertEqual(mapper.kx, 2.0, accuracy: eps)
        XCTAssertEqual(mapper.ky, 2.0, accuracy: eps)

        // The flipped top-left origin (negative global X) is the window/screenshot origin.
        assertExactRoundTrip(mapper, global: CGPoint(x: -1600, y: 340), window: .zero, screenshot: .zero, "flip-origin")
        assertExactRoundTrip(mapper, global: CGPoint(x: -1250, y: 590), window: CGPoint(x: 350, y: 250), screenshot: CGPoint(x: 700, y: 500), "flip-interior")
        assertExactRoundTrip(mapper, global: CGPoint(x: -900, y: 840), window: CGPoint(x: 700, y: 500), screenshot: CGPoint(x: 1400, y: 1000), "flip-far-corner")
    }

    func testSecondaryDisplayDownscaleBoundaryRoundTrip() {
        // Large Retina window on a secondary display that starts at a NEGATIVE global origin and
        // exceeds the long-edge cap, so the delivered pixels are downscaled — kx/ky derive from
        // the delivered pixels (§9), and the round trip must still be exact.
        let frame = Rect(x: -2000, y: -1000, width: 2000, height: 1000)
        let pixels = CoordinateMapper.screenshotPixelSize(framePoints: frame, scale: 2.0)
        // 2000×1000 @2x = 4000×2000 backing; long edge 4000 → downscaled to 1568×784.
        XCTAssertEqual(pixels, Size(width: 1568, height: 784))
        let mapper = CoordinateMapper(framePoints: frame, screenshotPixels: pixels)
        XCTAssertEqual(mapper.kx, 1568.0 / 2000.0, accuracy: eps)

        // Top-left origin (negative on both axes) → window/screenshot origin.
        assertExactRoundTrip(mapper, global: CGPoint(x: -2000, y: -1000), window: .zero, screenshot: .zero, "origin")
        // Far corner (the primary-display corner at the global origin) → the full pixel extent.
        assertExactRoundTrip(mapper, global: CGPoint(x: 0, y: 0), window: CGPoint(x: 2000, y: 1000), screenshot: CGPoint(x: 1568, y: 784), "far-corner")
    }

    // MARK: - Rect <-> CGRect bridging (no Y flip)

    func testRectCGRectBridgingNoFlip() {
        let cg = CGRect(x: 12, y: 34, width: 56, height: 78)
        let r = Rect(cg)
        XCTAssertEqual(r, Rect(x: 12, y: 34, width: 56, height: 78))
        XCTAssertEqual(r.cgRect, cg)
    }
}
