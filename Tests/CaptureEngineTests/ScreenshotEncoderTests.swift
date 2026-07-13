import XCTest
import CoreGraphics
import ComputerUseCore
@testable import CaptureEngine

/// Encoder behavior on a synthetically drawn CGImage (PROTOCOL §8). No permissions.
final class ScreenshotEncoderTests: XCTestCase {
    /// Draw a simple two-tone bitmap so JPEG/PNG have real content to encode.
    private func makeImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: max(1, width / 2), height: max(1, height / 2)))
        return context.makeImage()!
    }

    private func hasJPEGMagic(_ data: Data) -> Bool {
        data.count >= 3 && data[data.startIndex] == 0xFF
            && data[data.index(data.startIndex, offsetBy: 1)] == 0xD8
            && data[data.index(data.startIndex, offsetBy: 2)] == 0xFF
    }

    private func hasPNGMagic(_ data: Data) -> Bool {
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 8 else { return false }
        for (offset, byte) in sig.enumerated() where data[data.index(data.startIndex, offsetBy: offset)] != byte {
            return false
        }
        return true
    }

    // MARK: - JPEG

    func testJPEGEncodesSmallImageWithoutUpscaling() throws {
        let image = makeImage(width: 100, height: 50)
        let encoded = try ScreenshotEncoder.encodeJPEG(image)
        XCTAssertEqual(encoded.width, 100)
        XCTAssertEqual(encoded.height, 50)
        XCTAssertEqual(encoded.quality, 0.75, accuracy: 1e-9)
        XCTAssertGreaterThan(encoded.byteCount, 0)
        XCTAssertTrue(hasJPEGMagic(encoded.data), "expected JPEG SOI marker")
    }

    func testJPEGDownscalesToLongEdge1568PreservingAspect() throws {
        let image = makeImage(width: 3000, height: 1000)
        let encoded = try ScreenshotEncoder.encodeJPEG(image)
        XCTAssertEqual(encoded.width, 1568)
        // 1000 * (1568/3000) = 522.67 -> 523
        XCTAssertEqual(encoded.height, 523)
        XCTAssertTrue(hasJPEGMagic(encoded.data))
        XCTAssertLessThanOrEqual(encoded.byteCount, CaptureEngine.maxEncodedBytes)
    }

    func testJPEGRespectsCustomMaxLongEdge() throws {
        let image = makeImage(width: 800, height: 400)
        let encoded = try ScreenshotEncoder.encodeJPEG(image, maxLongEdge: 400)
        XCTAssertEqual(encoded.width, 400)
        XCTAssertEqual(encoded.height, 200)
    }

    func testJPEGImpossibleByteCapThrows() {
        let image = makeImage(width: 256, height: 256)
        // No encoding can fit in a single byte -> deterministic byteCapExceeded.
        XCTAssertThrowsError(try ScreenshotEncoder.encodeJPEG(image, byteCap: 1)) { error in
            guard case ScreenshotEncoderError.byteCapExceeded = error else {
                return XCTFail("expected byteCapExceeded, got \(error)")
            }
        }
    }

    // MARK: - PNG (probe path)

    func testPNGEncodesLosslessAtNativeSize() throws {
        let image = makeImage(width: 40, height: 30)
        let encoded = try ScreenshotEncoder.encodePNG(image)
        XCTAssertEqual(encoded.width, 40)
        XCTAssertEqual(encoded.height, 30)
        XCTAssertEqual(encoded.quality, 1.0, accuracy: 1e-9)
        XCTAssertTrue(hasPNGMagic(encoded.data), "expected PNG signature")
    }

    // MARK: - fit primitive

    func testFitDoesNotUpscale() throws {
        let image = makeImage(width: 100, height: 50)
        let out = try ScreenshotEncoder.fit(image, toLongEdge: 1568)
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(out.height, 50)
    }

    func testFitShrinksToTargetLongEdge() throws {
        let image = makeImage(width: 1000, height: 400)
        let out = try ScreenshotEncoder.fit(image, toLongEdge: 500)
        XCTAssertEqual(out.width, 500)
        XCTAssertEqual(out.height, 200)
    }
}
