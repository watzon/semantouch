import XCTest
import Foundation
@testable import MCPServer

/// Line framing (§1): splitting on `\n`, CRLF tolerance, no length limit, split
/// writes, blank-line handling, plus an end-to-end pipe run and the write path.
final class StdioTransportTests: XCTestCase {
    // MARK: Pure splitter

    func testSplitsCompleteLines() {
        var buffer = Array("a\nb\nc\n".utf8)
        let lines = StdioTransport.extractLines(&buffer, flush: false)
        XCTAssertEqual(lines, ["a", "b", "c"])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testToleratesCRLF() {
        var buffer = Array("a\r\nb\r\n".utf8)
        XCTAssertEqual(StdioTransport.extractLines(&buffer, flush: false), ["a", "b"])
    }

    func testKeepsPartialRemainderUntilNewline() {
        var buffer = Array("partial".utf8)
        XCTAssertEqual(StdioTransport.extractLines(&buffer, flush: false), [])
        XCTAssertEqual(buffer, Array("partial".utf8))

        buffer.append(contentsOf: Array("-rest\n".utf8))
        XCTAssertEqual(StdioTransport.extractLines(&buffer, flush: false), ["partial-rest"])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testSplitWritesReassembleAcrossChunks() {
        var buffer: [UInt8] = []
        buffer.append(contentsOf: Array("{\"a\":".utf8))
        XCTAssertEqual(StdioTransport.extractLines(&buffer, flush: false), [])
        buffer.append(contentsOf: Array("1}".utf8))
        XCTAssertEqual(StdioTransport.extractLines(&buffer, flush: false), [])
        buffer.append(contentsOf: Array("\n".utf8))
        XCTAssertEqual(StdioTransport.extractLines(&buffer, flush: false), ["{\"a\":1}"])
    }

    func testNoLineLengthLimit() {
        let long = String(repeating: "x", count: 250_000)
        var buffer = Array((long + "\n").utf8)
        let lines = StdioTransport.extractLines(&buffer, flush: false)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.count, 250_000)
    }

    func testBlankLinesAreSkipped() {
        var buffer = Array("\n\na\n\n".utf8)
        XCTAssertEqual(StdioTransport.extractLines(&buffer, flush: false), ["a"])
    }

    func testFlushEmitsUnterminatedRemainder() {
        var buffer = Array("tail".utf8)
        XCTAssertEqual(StdioTransport.extractLines(&buffer, flush: true), ["tail"])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testFlushWithEmptyBufferEmitsNothing() {
        var buffer: [UInt8] = []
        XCTAssertEqual(StdioTransport.extractLines(&buffer, flush: true), [])
    }

    // MARK: End-to-end over pipes

    func testRunDeliversLinesAndReportsEOF() {
        let inPipe = Pipe()
        let outPipe = Pipe()
        let transport = StdioTransport(
            input: inPipe.fileHandleForReading,
            output: outPipe.fileHandleForWriting
        )

        let collector = LineCollector()
        let eof = expectation(description: "EOF")

        Thread.detachNewThread {
            transport.run(
                onLine: { collector.append($0) },
                onEOF: { eof.fulfill() }
            )
        }

        let writer = inPipe.fileHandleForWriting
        writer.write(Data("hel".utf8))
        writer.write(Data("lo\nwor".utf8))
        writer.write(Data("ld\r\n".utf8))
        writer.write(Data("tail-without-newline".utf8))
        writer.closeFile() // EOF

        wait(for: [eof], timeout: 5)
        XCTAssertEqual(collector.snapshot(), ["hello", "world", "tail-without-newline"])
    }

    func testWriteLineAppendsSingleNewlineUnderLock() throws {
        let outPipe = Pipe()
        let transport = StdioTransport(
            input: FileHandle(fileDescriptor: FileHandle.standardInput.fileDescriptor),
            output: outPipe.fileHandleForWriting
        )
        transport.writeLine(#"{"ok":true}"#)
        let data = outPipe.fileHandleForReading.availableData
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"ok\":true}\n")
    }
}

/// Small thread-safe line accumulator for the pipe test.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
