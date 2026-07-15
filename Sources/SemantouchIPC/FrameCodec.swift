import Foundation
import Darwin

/// 4-byte big-endian length-prefixed frame codec.
///
/// Wire layout: `UInt32` payload length (big-endian) followed by exactly that many
/// payload bytes. Zero-length and oversized frames are rejected before allocation
/// of the announced body.
public enum FrameCodec {
    /// Encode `payload` as a single length-prefixed frame.
    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: HostProtocol.lengthHeaderSize)
        frame.append(payload)
        return frame
    }

    /// Decode a big-endian length header. Rejects zero and values above `maximum`.
    public static func decodeLength(header: Data, maximum: Int) throws -> Int {
        guard header.count >= HostProtocol.lengthHeaderSize else {
            throw IPCError.incompleteFrame
        }
        let length: UInt32 = header.withUnsafeBytes { raw in
            raw.load(as: UInt32.self).bigEndian
        }
        if length == 0 {
            throw IPCError.zeroLengthFrame
        }
        let value = Int(length)
        if value > maximum {
            throw IPCError.oversizedFrame(length: value, maximum: maximum)
        }
        return value
    }
}

/// Streaming frame reader. Accumulates fragmented/coalesced socket reads and emits
/// complete frames without allocating attacker-controlled unbounded buffers.
public final class FrameReader {
    private var buffer = Data()
    public let maximumFrameBytes: Int
    /// Hard cap on buffered unread bytes (header + partial body). Prevents
    /// unbounded growth when a peer dribbles data.
    public let maximumBufferBytes: Int

    public init(
        maximumFrameBytes: Int,
        maximumBufferBytes: Int? = nil
    ) {
        self.maximumFrameBytes = maximumFrameBytes
        // Header + one max body.
        self.maximumBufferBytes = maximumBufferBytes
            ?? (HostProtocol.lengthHeaderSize + maximumFrameBytes)
    }

    public var bufferedByteCount: Int { buffer.count }

    /// Append raw socket bytes. Throws if the buffer would exceed its hard cap
    /// or if a complete header already declares an illegal length.
    public func append(_ data: Data) throws {
        if data.isEmpty { return }
        if buffer.count + data.count > maximumBufferBytes {
            throw IPCError.oversizedFrame(
                length: buffer.count + data.count,
                maximum: maximumBufferBytes
            )
        }
        buffer.append(data)
        // Eagerly reject a complete illegal header so callers fail fast.
        _ = try peekLengthIfAvailable()
    }

    /// Pop the next complete frame payload, or `nil` if more bytes are needed.
    public func nextFrame() throws -> Data? {
        guard let length = try peekLengthIfAvailable() else {
            return nil
        }
        let total = HostProtocol.lengthHeaderSize + length
        guard buffer.count >= total else {
            return nil
        }
        let payload = buffer.subdata(in: HostProtocol.lengthHeaderSize..<total)
        buffer.removeSubrange(0..<total)
        return payload
    }

    /// Drain every complete frame currently buffered.
    public func drainFrames() throws -> [Data] {
        var frames: [Data] = []
        while let frame = try nextFrame() {
            frames.append(frame)
        }
        return frames
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: false)
    }

    private func peekLengthIfAvailable() throws -> Int? {
        guard buffer.count >= HostProtocol.lengthHeaderSize else {
            return nil
        }
        let header = buffer.prefix(HostProtocol.lengthHeaderSize)
        return try FrameCodec.decodeLength(header: Data(header), maximum: maximumFrameBytes)
    }
}

/// Blocking helpers over a POSIX file descriptor. Used by client/listener hello
/// exchange; production raw-MCP traffic uses `OpaqueRelay` instead.
public enum FrameIO {
    /// Read exactly one frame from `fd`, assembling across short reads.
    public static func readFrame(
        fd: Int32,
        maximumFrameBytes: Int,
        deadline: Date? = nil,
        syscalls: SocketSyscalls = .live
    ) throws -> Data {
        let reader = FrameReader(maximumFrameBytes: maximumFrameBytes)
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let frame = try reader.nextFrame() {
                return frame
            }
            try checkDeadline(deadline, operation: "readFrame")

            let capacity = scratch.count
            let n = scratch.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                return syscalls.read(fd, base, capacity)
            }
            if n == 0 {
                throw IPCError.closed
            }
            if n < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK {
                    try checkDeadline(deadline, operation: "readFrame")
                    usleep(1_000)
                    continue
                }
                throw IPCError.ioFailed(operation: "read", errnoCode: code)
            }
            try reader.append(Data(scratch[0..<n]))
        }
    }

    /// Write one complete length-prefixed frame to `fd`.
    public static func writeFrame(
        fd: Int32,
        payload: Data,
        deadline: Date? = nil,
        syscalls: SocketSyscalls = .live
    ) throws {
        let frame = FrameCodec.encode(payload)
        try writeAll(fd: fd, data: frame, deadline: deadline, syscalls: syscalls)
    }

    public static func writeAll(
        fd: Int32,
        data: Data,
        deadline: Date? = nil,
        syscalls: SocketSyscalls = .live
    ) throws {
        var offset = 0
        let total = data.count
        while offset < total {
            try checkDeadline(deadline, operation: "write")
            let wrote: Int = data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                return syscalls.write(fd, base.advanced(by: offset), total - offset)
            }
            if wrote == 0 {
                throw IPCError.closed
            }
            if wrote < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK {
                    try checkDeadline(deadline, operation: "write")
                    usleep(1_000)
                    continue
                }
                throw IPCError.ioFailed(operation: "write", errnoCode: code)
            }
            offset += wrote
        }
    }

    private static func checkDeadline(_ deadline: Date?, operation: String) throws {
        if let deadline, Date() > deadline {
            throw IPCError.timedOut(operation: operation)
        }
    }
}
