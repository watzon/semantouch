import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ComputerUseCore

// ScreenshotEncoder — CGImage → JPEG (MCP path) / PNG (CLI probe path) via ImageIO
// (PROTOCOL §8). JPEG at quality 0.75, long edge ≤ 1568 px, 3 MB byte cap.

/// The result of encoding a `CGImage`: the encoded bytes and the dimensions and
/// quality actually delivered. `width`/`height` are the pixels of the encoded
/// image (S space) — the caller MUST feed these back into `CoordinateMapper`
/// (§9 uses delivered pixel dims, not `scale`, for `kx`/`ky`).
public struct EncodedImage: Equatable, Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    /// The JPEG quality actually used (PNG reports `1.0`).
    public let quality: Double

    public init(data: Data, width: Int, height: Int, quality: Double) {
        self.data = data
        self.width = width
        self.height = height
        self.quality = quality
    }

    public var byteCount: Int { data.count }
}

public enum ScreenshotEncoderError: Error, Equatable, Sendable {
    /// The source image had a zero dimension.
    case emptyImage
    /// A CoreGraphics downscale context could not be built or rendered.
    case downscaleFailed
    /// ImageIO refused to create or finalize the destination.
    case encodeFailed
    /// Even at the smallest allowed dimension and the lowest quality step the
    /// encoded image still exceeds the byte cap.
    case byteCapExceeded(bytes: Int, cap: Int)
}

public enum ScreenshotEncoder {
    /// Deterministic quality fallback ladder. Used only as the LAST
    /// resort, after §8's mandatory dimension-shrink at q0.75 has bottomed out at
    /// `minLongEdge`. §8 forbids raising quality above 0.75; these steps only ever
    /// lower it.
    static let qualityLadder: [Double] = [0.6, 0.45, 0.3]

    /// The smallest long edge the dimension-shrink loop will fall to before
    /// switching to the quality ladder.
    static let minLongEdge = 64

    /// Multiplicative step for the dimension-shrink loop (deterministic).
    static let shrinkFactor = 0.85

    // MARK: - JPEG (MCP path)

    /// Encode a `CGImage` to JPEG for the MCP path (§8):
    ///
    /// 1. Downscale so the long edge ≤ `maxLongEdge` (never upscale).
    /// 2. Encode at `quality` (default 0.75). If ≤ `byteCap`, done.
    /// 3. §8: shrink the long-edge dimension (at the same quality) until it fits or
    ///    bottoms out at `minLongEdge`.
    /// 4. Last resort: step quality down 0.6 → 0.45 → 0.3 at the
    ///    smallest dimension.
    /// 5. Still over cap → throw `byteCapExceeded`.
    ///
    /// In practice a 1568-px JPEG at q0.75 is far under 3 MB, so steps 3–5 are
    /// essentially unreachable; they exist so the byte cap is a hard guarantee.
    public static func encodeJPEG(
        _ image: CGImage,
        maxLongEdge: Int = CaptureEngine.maxLongEdgePixels,
        quality: Double = CaptureEngine.jpegQuality,
        byteCap: Int = CaptureEngine.maxEncodedBytes
    ) throws -> EncodedImage {
        guard image.width > 0, image.height > 0 else { throw ScreenshotEncoderError.emptyImage }

        // 1–2: fit to maxLongEdge, encode at the contract quality.
        var longEdge = min(maxLongEdge, max(image.width, image.height))
        var current = try fit(image, toLongEdge: longEdge)
        var data = try jpegData(current, quality: quality)
        if data.count <= byteCap {
            return EncodedImage(data: data, width: current.width, height: current.height, quality: quality)
        }

        // 3: §8 dimension shrink at the same quality.
        while data.count > byteCap, longEdge > minLongEdge {
            longEdge = max(minLongEdge, Int((Double(longEdge) * shrinkFactor).rounded(.down)))
            current = try fit(image, toLongEdge: longEdge)
            data = try jpegData(current, quality: quality)
        }
        if data.count <= byteCap {
            return EncodedImage(data: data, width: current.width, height: current.height, quality: quality)
        }

        // 4: Quality ladder as the final fallback at the smallest dimension.
        for q in qualityLadder {
            data = try jpegData(current, quality: q)
            if data.count <= byteCap {
                return EncodedImage(data: data, width: current.width, height: current.height, quality: q)
            }
        }

        // 5: cannot satisfy the cap.
        throw ScreenshotEncoderError.byteCapExceeded(bytes: data.count, cap: byteCap)
    }

    // MARK: - PNG (CLI probe path only)

    /// Encode a `CGImage` to PNG. **CLI/probe output only** — never the MCP path
    /// (§8). No downscaling, no byte cap; lossless.
    public static func encodePNG(_ image: CGImage) throws -> EncodedImage {
        guard image.width > 0, image.height > 0 else { throw ScreenshotEncoderError.emptyImage }
        let data = try pngData(image)
        return EncodedImage(data: data, width: image.width, height: image.height, quality: 1.0)
    }

    // MARK: - Primitives

    /// Downscale so the long edge is `longEdge` px, preserving aspect ratio. Never
    /// upscales: if the image already fits it is returned unchanged.
    static func fit(_ image: CGImage, toLongEdge longEdge: Int) throws -> CGImage {
        let w = image.width
        let h = image.height
        let current = max(w, h)
        guard current > longEdge, longEdge > 0 else { return image }

        let scale = Double(longEdge) / Double(current)
        let newWidth = max(1, Int((Double(w) * scale).rounded()))
        let newHeight = max(1, Int((Double(h) * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenshotEncoderError.downscaleFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let output = context.makeImage() else { throw ScreenshotEncoderError.downscaleFailed }
        return output
    }

    /// JPEG-encode via ImageIO at `quality` (clamped to 0…1).
    static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotEncoderError.encodeFailed
        }
        let clamped = min(max(quality, 0.0), 1.0)
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: clamped]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotEncoderError.encodeFailed }
        return buffer as Data
    }

    /// PNG-encode via ImageIO (lossless).
    static func pngData(_ image: CGImage) throws -> Data {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotEncoderError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotEncoderError.encodeFailed }
        return buffer as Data
    }
}
