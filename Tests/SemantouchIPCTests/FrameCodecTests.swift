import XCTest
@testable import SemantouchIPC
import Foundation

final class FrameCodecTests: XCTestCase {
    func testEncodeDecodeRoundTrip() throws {
        let payload = Data("{\"type\":\"hello\"}".utf8)
        let frame = FrameCodec.encode(payload)
        XCTAssertEqual(frame.count, 4 + payload.count)
        let length = try FrameCodec.decodeLength(header: frame.prefix(4), maximum: 1024)
        XCTAssertEqual(length, payload.count)
        XCTAssertEqual(frame.suffix(from: 4), payload)
    }

    func testBigEndianLengthHeader() {
        // length 0x00000100 = 256
        var payload = Data(count: 256)
        for i in 0..<256 { payload[i] = UInt8(i & 0xff) }
        let frame = FrameCodec.encode(payload)
        XCTAssertEqual(frame[0], 0x00)
        XCTAssertEqual(frame[1], 0x00)
        XCTAssertEqual(frame[2], 0x01)
        XCTAssertEqual(frame[3], 0x00)
    }

    func testZeroLengthRejected() {
        var header = Data([0, 0, 0, 0])
        XCTAssertThrowsError(try FrameCodec.decodeLength(header: header, maximum: 1024)) { error in
            XCTAssertEqual(error as? IPCError, .zeroLengthFrame)
        }
        // Also via reader
        let reader = FrameReader(maximumFrameBytes: 1024)
        XCTAssertThrowsError(try reader.append(header)) { error in
            XCTAssertEqual(error as? IPCError, .zeroLengthFrame)
        }
    }

    func testOversizedLengthRejectedBeforeBodyAllocation() {
        // Claim 1 MiB + 1 on a hello-sized reader (16 KiB).
        var length = UInt32(HostProtocol.helloMaxFrameBytes + 1).bigEndian
        let header = Data(bytes: &length, count: 4)
        XCTAssertThrowsError(
            try FrameCodec.decodeLength(header: header, maximum: HostProtocol.helloMaxFrameBytes)
        ) { error in
            guard case let .oversizedFrame(length, maximum)? = error as? IPCError else {
                return XCTFail("expected oversizedFrame, got \(error)")
            }
            XCTAssertEqual(length, HostProtocol.helloMaxFrameBytes + 1)
            XCTAssertEqual(maximum, HostProtocol.helloMaxFrameBytes)
        }
        let reader = FrameReader(maximumFrameBytes: HostProtocol.helloMaxFrameBytes)
        XCTAssertThrowsError(try reader.append(header))
    }

    func testFragmentedHeaderAndBody() throws {
        let payload = Data("abcdefghij".utf8)
        let frame = FrameCodec.encode(payload)
        let reader = FrameReader(maximumFrameBytes: 1024)

        // Feed one byte at a time.
        for i in 0..<frame.count {
            try reader.append(frame.subdata(in: i..<(i + 1)))
            if i < frame.count - 1 {
                XCTAssertNil(try reader.nextFrame())
            }
        }
        let got = try reader.nextFrame()
        XCTAssertEqual(got, payload)
    }

    func testCoalescedFrames() throws {
        let a = Data("one".utf8)
        let b = Data("two-two".utf8)
        let c = Data("three".utf8)
        var blob = Data()
        blob.append(FrameCodec.encode(a))
        blob.append(FrameCodec.encode(b))
        blob.append(FrameCodec.encode(c))

        let reader = FrameReader(maximumFrameBytes: 1024)
        // Deliver all at once.
        try reader.append(blob)
        let frames = try reader.drainFrames()
        XCTAssertEqual(frames, [a, b, c])
    }

    func testCoalescedWithPartialTrailing() throws {
        let a = Data("alpha".utf8)
        let b = Data("beta-beta".utf8)
        var blob = FrameCodec.encode(a)
        let bFrame = FrameCodec.encode(b)
        blob.append(bFrame.prefix(3)) // partial header of second frame

        let reader = FrameReader(maximumFrameBytes: 1024)
        try reader.append(blob)
        XCTAssertEqual(try reader.nextFrame(), a)
        XCTAssertNil(try reader.nextFrame())

        try reader.append(bFrame.suffix(from: 3))
        XCTAssertEqual(try reader.nextFrame(), b)
    }

    func testInvalidUTF8RejectedAtHelloDecode() {
        // Frame codec itself is binary-transparent; HostCodec JSON decode fails.
        let junk = Data([0xff, 0xfe, 0xfd, 0xfc])
        XCTAssertThrowsError(try HostCodec.decodeHelloRequest(junk))
    }

    func testInvalidJSONRejected() {
        let data = Data("not-json".utf8)
        XCTAssertThrowsError(try HostCodec.decodeHelloRequest(data))
    }

    func testHelloEnvelopeRoundTrip() throws {
        let nonce = HostProtocol.makeNonceBase64()
        let request = HelloRequest.make(role: .mcp, clientVersion: "0.0-test", nonce: nonce)
        let encoded = try HostCodec.encode(request)
        XCTAssertLessThanOrEqual(encoded.count, HostProtocol.helloMaxFrameBytes)
        let decoded = try HostCodec.decodeHelloRequest(encoded)
        XCTAssertEqual(decoded, request)

        let result = HelloResult.make(
            hostVersion: "0.0-host",
            echoNonce: nonce,
            role: .mcp
        )
        let resultData = try HostCodec.encode(result)
        let decodedResult = try HostCodec.decodeHelloResult(resultData)
        XCTAssertEqual(decodedResult.echoNonce, nonce)
        XCTAssertEqual(decodedResult.mode, .rawMCP)
        XCTAssertEqual(decodedResult.protocol, HostProtocol.version)
    }

    func testHelloErrorEnvelope() throws {
        let error = HostErrorEnvelope(
            code: "host_version_mismatch",
            message: "bad",
            retryable: false
        )
        let data = try HostCodec.encode(error)
        XCTAssertThrowsError(try HostCodec.decodeHelloResult(data)) { err in
            guard case let .hostError(code, message, retryable)? = err as? IPCError else {
                return XCTFail("expected hostError, got \(err)")
            }
            XCTAssertEqual(code, "host_version_mismatch")
            XCTAssertEqual(message, "bad")
            XCTAssertFalse(retryable)
        }
    }

    func testControlMaxLargerThanHello() {
        XCTAssertEqual(HostProtocol.helloMaxFrameBytes, 16 * 1024)
        XCTAssertEqual(HostProtocol.controlMaxFrameBytes, 1 * 1024 * 1024)
        XCTAssertGreaterThan(HostProtocol.controlMaxFrameBytes, HostProtocol.helloMaxFrameBytes)
    }

    func testBufferHardCap() throws {
        let reader = FrameReader(maximumFrameBytes: 100, maximumBufferBytes: 20)
        // 4-byte legal header for length 10, then more than remaining buffer allows.
        var length = UInt32(10).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(Data(count: 17)) // 4+17 = 21 > 20
        XCTAssertThrowsError(try reader.append(data)) { error in
            guard case .oversizedFrame? = error as? IPCError else {
                return XCTFail("expected oversizedFrame, got \(error)")
            }
        }
    }
}
