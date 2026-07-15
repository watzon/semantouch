import Foundation
import Darwin

/// Half-close-aware opaque byte pump between two file descriptors.
///
/// After a successful MCP hello, socket bytes map one-for-one to MCP stdin/stdout.
/// This type never parses, normalizes, re-encodes, retries, or replays traffic.
///
/// Semantics:
/// - EOF on the source half-closes the destination write side (`SHUT_WR`).
/// - Both directions run concurrently with fixed-size buffers.
/// - When both directions finish, the relay completes.
public final class OpaqueRelay: @unchecked Sendable {
    public static let defaultBufferSize = 64 * 1024

    public struct Endpoint: Sendable {
        public var fd: Int32
        public var label: String
        /// When true, EOF on this endpoint triggers `shutdown(destination, SHUT_WR)`.
        public var halfCloseOnEOF: Bool

        public init(fd: Int32, label: String, halfCloseOnEOF: Bool = true) {
            self.fd = fd
            self.label = label
            self.halfCloseOnEOF = halfCloseOnEOF
        }
    }

    public struct Result: Equatable, Sendable {
        public var bytesAtoB: Int
        public var bytesBtoA: Int
        public var aEOF: Bool
        public var bEOF: Bool
        public var errorDescription: String?

        public init(
            bytesAtoB: Int = 0,
            bytesBtoA: Int = 0,
            aEOF: Bool = false,
            bEOF: Bool = false,
            errorDescription: String? = nil
        ) {
            self.bytesAtoB = bytesAtoB
            self.bytesBtoA = bytesBtoA
            self.aEOF = aEOF
            self.bEOF = bEOF
            self.errorDescription = errorDescription
        }
    }

    private let bufferSize: Int
    private let syscalls: SocketSyscalls

    public init(bufferSize: Int = OpaqueRelay.defaultBufferSize, syscalls: SocketSyscalls = .live) {
        self.bufferSize = max(1, bufferSize)
        self.syscalls = syscalls
    }

    /// Pump `a → b` and `b → a` until both directions EOF or an error occurs.
    /// Blocks the calling thread; uses two dedicated pump threads internally.
    @discardableResult
    public func run(a: Endpoint, b: Endpoint) -> Result {
        let lock = NSLock()
        var result = Result()
        let group = DispatchGroup()

        group.enter()
        Thread.detachNewThread { [syscalls, bufferSize] in
            defer { group.leave() }
            do {
                let n = try Self.pump(
                    from: a,
                    to: b,
                    bufferSize: bufferSize,
                    syscalls: syscalls
                )
                lock.lock()
                result.bytesAtoB += n
                result.aEOF = true
                lock.unlock()
            } catch {
                lock.lock()
                if result.errorDescription == nil {
                    result.errorDescription = "\(a.label)→\(b.label): \(error)"
                }
                lock.unlock()
            }
        }

        group.enter()
        Thread.detachNewThread { [syscalls, bufferSize] in
            defer { group.leave() }
            do {
                let n = try Self.pump(
                    from: b,
                    to: a,
                    bufferSize: bufferSize,
                    syscalls: syscalls
                )
                lock.lock()
                result.bytesBtoA += n
                result.bEOF = true
                lock.unlock()
            } catch {
                lock.lock()
                if result.errorDescription == nil {
                    result.errorDescription = "\(b.label)→\(a.label): \(error)"
                }
                lock.unlock()
            }
        }

        group.wait()
        return result
    }

    /// Convenience: relay between stdio FileHandles and a connected socket fd.
    /// Maps stdin→socket and socket→stdout (not socket bidirectional alone).
    @discardableResult
    public func run(
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput,
        socketFD: Int32
    ) -> Result {
        runStdio(
            stdinFD: stdin.fileDescriptor,
            stdoutFD: stdout.fileDescriptor,
            socketFD: socketFD
        )
    }

    /// Stdio-aware relay: stdin→socket, socket→stdout with half-close.
    @discardableResult
    public func runStdio(
        stdinFD: Int32,
        stdoutFD: Int32,
        socketFD: Int32
    ) -> Result {
        let lock = NSLock()
        var result = Result()
        let group = DispatchGroup()

        // stdin → socket
        group.enter()
        Thread.detachNewThread { [syscalls, bufferSize] in
            defer { group.leave() }
            do {
                let n = try Self.pump(
                    from: Endpoint(fd: stdinFD, label: "stdin", halfCloseOnEOF: true),
                    to: Endpoint(fd: socketFD, label: "socket", halfCloseOnEOF: true),
                    bufferSize: bufferSize,
                    syscalls: syscalls
                )
                lock.lock()
                result.bytesAtoB += n
                result.aEOF = true
                lock.unlock()
            } catch {
                lock.lock()
                if result.errorDescription == nil {
                    result.errorDescription = "stdin→socket: \(error)"
                }
                lock.unlock()
            }
        }

        // socket → stdout
        group.enter()
        Thread.detachNewThread { [syscalls, bufferSize] in
            defer { group.leave() }
            do {
                let n = try Self.pump(
                    from: Endpoint(fd: socketFD, label: "socket", halfCloseOnEOF: true),
                    to: Endpoint(fd: stdoutFD, label: "stdout", halfCloseOnEOF: true),
                    bufferSize: bufferSize,
                    syscalls: syscalls
                )
                lock.lock()
                result.bytesBtoA += n
                result.bEOF = true
                lock.unlock()
            } catch {
                lock.lock()
                if result.errorDescription == nil {
                    result.errorDescription = "socket→stdout: \(error)"
                }
                lock.unlock()
            }
        }

        group.wait()
        return result
    }

    // MARK: - Single direction

    /// Copy bytes from `from` to `to` until EOF. On EOF, half-close `to` if configured.
    /// Returns total bytes copied.
    public static func pump(
        from: Endpoint,
        to: Endpoint,
        bufferSize: Int = OpaqueRelay.defaultBufferSize,
        syscalls: SocketSyscalls = .live
    ) throws -> Int {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var total = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                return syscalls.read(from.fd, base, bufferSize)
            }
            if n == 0 {
                // EOF
                if from.halfCloseOnEOF {
                    _ = syscalls.shutdown(to.fd, SHUT_WR)
                }
                return total
            }
            if n < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK {
                    usleep(1_000)
                    continue
                }
                throw IPCError.ioFailed(operation: "read:\(from.label)", errnoCode: code)
            }
            var offset = 0
            while offset < n {
                let wrote = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                        return -1
                    }
                    return syscalls.write(to.fd, base.advanced(by: offset), n - offset)
                }
                if wrote == 0 {
                    throw IPCError.closed
                }
                if wrote < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    if code == EAGAIN || code == EWOULDBLOCK {
                        usleep(1_000)
                        continue
                    }
                    throw IPCError.ioFailed(operation: "write:\(to.label)", errnoCode: code)
                }
                offset += wrote
                total += wrote
            }
        }
    }
}

// MARK: - FileHandle convenience

public extension OpaqueRelay {
    /// Pump two `FileHandle`s bidirectionally. Handles must remain valid for the
    /// duration of the call. Does not close either handle.
    @discardableResult
    func run(handleA: FileHandle, handleB: FileHandle) -> Result {
        run(
            a: Endpoint(fd: handleA.fileDescriptor, label: "a"),
            b: Endpoint(fd: handleB.fileDescriptor, label: "b")
        )
    }
}
