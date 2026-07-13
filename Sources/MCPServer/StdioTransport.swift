import Foundation
import Dispatch

/// Newline-delimited stdio transport (§1).
///
/// - The read side runs a **blocking loop on a dedicated thread**, accumulating raw
///   bytes and splitting on `\n` (U+000A). CRLF is tolerated (a trailing `\r` is
///   stripped). There is no line-length limit — a message may be several MB.
/// - The write side serializes one single-line JSON message plus a `\n` to stdout
///   **behind a lock**, so concurrent writers cannot interleave. **Nothing else may
///   touch stdout**; the process's only other output channel is stderr, via `log`.
public final class StdioTransport: @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let writeLock = NSLock()

    /// - Parameters:
    ///   - input: byte source for incoming lines (defaults to stdin).
    ///   - output: sink for framed replies (defaults to stdout).
    public init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.input = input
        self.output = output
    }

    // MARK: - stderr logging

    /// Write a diagnostic line to **stderr** (never stdout). This is the only
    /// sanctioned logging path for the server and library code.
    public static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Instance convenience for `log`.
    public func log(_ message: String) { StdioTransport.log(message) }

    // MARK: - Writing

    /// Serialize `line` (already a single-line JSON message, no embedded newline)
    /// followed by a single `\n`, atomically, under the write lock.
    public func writeLine(_ line: String) {
        writeLock.lock()
        defer { writeLock.unlock() }
        var data = Data(line.utf8)
        data.append(0x0A)
        do {
            try output.write(contentsOf: data)
        } catch {
            StdioTransport.log("semantouch: stdout write failed: \(error)")
        }
    }

    // MARK: - Reading

    /// Spawn a dedicated read thread, deliver each complete line to `onLine` (in
    /// arrival order, on the read thread), then call `onEOF` once the input closes.
    /// **Blocks the calling thread until EOF**, so a server can simply call `run()`
    /// and return when stdin closes.
    public func run(onLine: @escaping (String) -> Void, onEOF: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let handle = input
        let thread = Thread {
            StdioTransport.readLoop(input: handle, onLine: onLine)
            onEOF()
            done.signal()
        }
        thread.name = "dev.watzon.semantouch.stdin"
        thread.stackSize = 4 << 20
        thread.start()
        done.wait()
    }

    /// Blocking read loop: pull chunks from `input`, split into lines, deliver each.
    /// Returns on EOF (an empty chunk), after flushing any final unterminated line.
    static func readLoop(input: FileHandle, onLine: (String) -> Void) {
        var buffer: [UInt8] = []
        while true {
            let chunk = input.availableData
            if chunk.isEmpty {
                for line in extractLines(&buffer, flush: true) { onLine(line) }
                return
            }
            buffer.append(contentsOf: chunk)
            for line in extractLines(&buffer, flush: false) { onLine(line) }
        }
    }

    /// Pure line splitter. Consumes complete `\n`-terminated lines from `buffer`
    /// (leaving any partial remainder in place) and returns them decoded as UTF-8.
    /// A trailing `\r` on any line is stripped (CRLF tolerance) and blank lines are
    /// skipped. When `flush` is true, a final unterminated remainder is also emitted
    /// and `buffer` is cleared.
    static func extractLines(_ buffer: inout [UInt8], flush: Bool) -> [String] {
        var lines: [String] = []
        var start = 0
        var index = 0
        while index < buffer.count {
            if buffer[index] == 0x0A {
                appendLine(buffer[start..<index], to: &lines)
                start = index + 1
            }
            index += 1
        }
        if flush {
            if start < buffer.count {
                appendLine(buffer[start..<buffer.count], to: &lines)
            }
            buffer.removeAll(keepingCapacity: false)
        } else if start > 0 {
            buffer.removeFirst(start)
        }
        return lines
    }

    private static func appendLine(_ slice: ArraySlice<UInt8>, to lines: inout [String]) {
        var bytes = Array(slice)
        if bytes.last == 0x0D { bytes.removeLast() } // tolerate CRLF
        if bytes.isEmpty { return } // ignore blank lines
        lines.append(String(decoding: bytes, as: UTF8.self))
    }
}
