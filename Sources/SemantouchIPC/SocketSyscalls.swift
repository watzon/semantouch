import Foundation
import Darwin

/// Injectable low-level socket / fd operations. Production uses `.live`;
/// tests substitute fakes for permission-free peer and I/O paths.
public struct SocketSyscalls: Sendable {
    public var socket: @Sendable (Int32, Int32, Int32) -> Int32
    public var bind: @Sendable (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32
    public var listen: @Sendable (Int32, Int32) -> Int32
    public var accept: @Sendable (Int32, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> Int32
    public var connect: @Sendable (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32
    public var close: @Sendable (Int32) -> Int32
    public var read: @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int
    public var write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    public var shutdown: @Sendable (Int32, Int32) -> Int32
    public var fcntl: @Sendable (Int32, Int32, Int32) -> Int32
    public var setsockopt: @Sendable (Int32, Int32, Int32, UnsafeRawPointer?, socklen_t) -> Int32
    public var getsockopt: @Sendable (Int32, Int32, Int32, UnsafeMutableRawPointer?, UnsafeMutablePointer<socklen_t>?) -> Int32
    public var chmodPath: @Sendable (String, mode_t) -> Int32
    public var unlink: @Sendable (String) -> Int32
    public var getpeereid: @Sendable (Int32, UnsafeMutablePointer<uid_t>, UnsafeMutablePointer<gid_t>) -> Int32

    public init(
        socket: @escaping @Sendable (Int32, Int32, Int32) -> Int32,
        bind: @escaping @Sendable (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32,
        listen: @escaping @Sendable (Int32, Int32) -> Int32,
        accept: @escaping @Sendable (Int32, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> Int32,
        connect: @escaping @Sendable (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32,
        close: @escaping @Sendable (Int32) -> Int32,
        read: @escaping @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int,
        write: @escaping @Sendable (Int32, UnsafeRawPointer, Int) -> Int,
        shutdown: @escaping @Sendable (Int32, Int32) -> Int32,
        fcntl: @escaping @Sendable (Int32, Int32, Int32) -> Int32,
        setsockopt: @escaping @Sendable (Int32, Int32, Int32, UnsafeRawPointer?, socklen_t) -> Int32,
        getsockopt: @escaping @Sendable (Int32, Int32, Int32, UnsafeMutableRawPointer?, UnsafeMutablePointer<socklen_t>?) -> Int32,
        chmodPath: @escaping @Sendable (String, mode_t) -> Int32,
        unlink: @escaping @Sendable (String) -> Int32,
        getpeereid: @escaping @Sendable (Int32, UnsafeMutablePointer<uid_t>, UnsafeMutablePointer<gid_t>) -> Int32
    ) {
        self.socket = socket
        self.bind = bind
        self.listen = listen
        self.accept = accept
        self.connect = connect
        self.close = close
        self.read = read
        self.write = write
        self.shutdown = shutdown
        self.fcntl = fcntl
        self.setsockopt = setsockopt
        self.getsockopt = getsockopt
        self.chmodPath = chmodPath
        self.unlink = unlink
        self.getpeereid = getpeereid
    }

    public static let live = SocketSyscalls(
        socket: { domain, type, protocolNumber in Darwin.socket(domain, type, protocolNumber) },
        bind: { fd, addr, len in Darwin.bind(fd, addr, len) },
        listen: { fd, backlog in Darwin.listen(fd, backlog) },
        accept: { fd, addr, len in Darwin.accept(fd, addr, len) },
        connect: { fd, addr, len in Darwin.connect(fd, addr, len) },
        close: { fd in Darwin.close(fd) },
        read: { fd, buf, n in Darwin.read(fd, buf, n) },
        write: { fd, buf, n in Darwin.write(fd, buf, n) },
        shutdown: { fd, how in Darwin.shutdown(fd, how) },
        fcntl: { fd, cmd, value in Darwin.fcntl(fd, cmd, value) },
        setsockopt: { fd, level, name, value, len in Darwin.setsockopt(fd, level, name, value, len) },
        getsockopt: { fd, level, name, value, len in Darwin.getsockopt(fd, level, name, value, len) },
        chmodPath: { path, mode in path.withCString { Darwin.chmod($0, mode) } },
        unlink: { path in path.withCString { Darwin.unlink($0) } },
        getpeereid: { fd, uid, gid in Darwin.getpeereid(fd, uid, gid) }
    )
}

// MARK: - sockaddr_un helpers

enum UnixSocketAddress {
    /// Build a `sockaddr_un` for `path`. Throws if the path cannot fit.
    static func make(path: String) throws -> (sockaddr_un, socklen_t) {
        try SocketLocation.validatePathLength(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(path.utf8)
        // sun_path is a tuple on Darwin; write via raw buffer.
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            for (i, byte) in utf8.enumerated() {
                raw[i] = byte
            }
        }
        // Length: family + path + NUL (Darwin convention).
        let len = socklen_t(
            MemoryLayout<sa_family_t>.size + utf8.count + 1
        )
        return (addr, len)
    }

    static func withSockaddr<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var (addr, len) = try make(path: path)
        return try withUnsafePointer(to: &addr) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                try body(sockaddrPtr, len)
            }
        }
    }
}

/// Connected peer endpoint wrapping a raw fd. Caller owns close.
public final class SocketConnection: @unchecked Sendable {
    public let fd: Int32
    private let syscalls: SocketSyscalls
    private let lock = NSLock()
    private var closed = false

    public init(fd: Int32, syscalls: SocketSyscalls = .live) {
        self.fd = fd
        self.syscalls = syscalls
    }

    deinit {
        close()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        _ = syscalls.close(fd)
    }

    public func shutdownWrite() {
        _ = syscalls.shutdown(fd, SHUT_WR)
    }

    public func shutdownRead() {
        _ = syscalls.shutdown(fd, SHUT_RD)
    }

    /// Wrap as an unowned `FileHandle` (does not close on deallocation of the handle
    /// when created via `FileHandle(fileDescriptor:closeOnDealloc: false)`).
    public func makeFileHandle(closeOnDealloc: Bool = false) -> FileHandle {
        FileHandle(fileDescriptor: fd, closeOnDealloc: closeOnDealloc)
    }
}
