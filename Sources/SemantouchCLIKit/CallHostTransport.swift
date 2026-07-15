import Foundation
import Darwin
import SemantouchIPC

// MARK: - Host session adapter
/// Live newline JSON-RPC adapter over a connected host session fd (post-hello raw MCP).
public enum CallHostTransport {
    /// Build a `CallTransport` that reads/writes newline-delimited JSON on `fd`.
    public static func make(
        fd: Int32,
        syscalls: SocketSyscalls = .live
    ) -> CallTransport {
        let lock = NSLock()
        var buffer = [UInt8]()

        return CallTransport(
            writeLine: { line in
                var payload = Array(line.utf8)
                payload.append(0x0A) // \n
                var offset = 0
                while offset < payload.count {
                    let written: Int = payload.withUnsafeBytes { raw in
                        let base = raw.baseAddress!.advanced(by: offset)
                        return syscalls.write(fd, base, payload.count - offset)
                    }
                    if written < 0 {
                        let code = errno
                        if code == EINTR { continue }
                        throw CallRuntimeError("write failed: errno \(code)")
                    }
                    if written == 0 {
                        throw CallRuntimeError("write failed: short write")
                    }
                    offset += written
                }
            },
            readLine: {
                lock.lock()
                defer { lock.unlock() }
                while true {
                    if let line = extractLine(from: &buffer) {
                        return line
                    }
                    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                    let capacity = chunk.count
                    let n = chunk.withUnsafeMutableBytes { raw in
                        syscalls.read(fd, raw.baseAddress!, capacity)
                    }
                    if n < 0 {
                        let code = errno
                        if code == EINTR { continue }
                        throw CallRuntimeError("read failed: errno \(code)")
                    }
                    if n == 0 {
                        if buffer.isEmpty { return nil }
                        let line = String(bytes: buffer, encoding: .utf8)
                        buffer.removeAll(keepingCapacity: false)
                        if let line, !line.isEmpty { return line }
                        return nil
                    }
                    buffer.append(contentsOf: chunk.prefix(n))
                }
            }
        )
    }

    private static func extractLine(from buffer: inout [UInt8]) -> String? {
        guard let nl = buffer.firstIndex(of: 0x0A) else { return nil }
        var slice = Array(buffer[..<nl])
        buffer.removeSubrange(...nl)
        if slice.last == 0x0D { slice.removeLast() }
        if slice.isEmpty { return "" }
        return String(bytes: slice, encoding: .utf8)
    }
}
