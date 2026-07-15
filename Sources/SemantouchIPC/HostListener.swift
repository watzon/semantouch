import Foundation
import Darwin

/// Exclusive per-user host lock + AF_UNIX listener.
///
/// Only the lock owner may remove a stale socket, and only after `lstat` proves
/// it is a socket owned by the current effective UID. Symlinks, foreign-owned
/// entries, unexpected file types, or permissive modes cause a hard failure.
public final class HostListener: @unchecked Sendable {
    public let location: SocketLocation
    public let policy: PeerTrustPolicy
    public let verifier: any PeerVerifying
    private let fileSystem: FileSystemSeam
    private let syscalls: SocketSyscalls
    private let euid: uid_t

    private let stateLock = NSLock()
    private var lockFD: Int32 = -1
    private var listenFD: Int32 = -1
    private var isRunning = false

    public init(
        location: SocketLocation,
        policy: PeerTrustPolicy,
        verifier: any PeerVerifying = SecurityPeerVerifier(),
        fileSystem: FileSystemSeam = .live,
        syscalls: SocketSyscalls = .live,
        euid: uid_t = geteuid()
    ) {
        self.location = location
        self.policy = policy
        self.verifier = verifier
        self.fileSystem = fileSystem
        self.syscalls = syscalls
        self.euid = euid
    }

    deinit {
        stop()
    }

    public var isListening: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }

    /// Acquire the exclusive lock, clear a valid stale socket if needed, bind and listen.
    public func start(backlog: Int32 = 16) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if isRunning {
            throw IPCError.alreadyListening
        }

        try SocketLocation.validateDirectory(
            location.directoryPath,
            fileSystem: fileSystem,
            euid: euid
        )

        try acquireLock()
        try prepareSocketPath()
        try bindAndListen(backlog: backlog)
        isRunning = true
    }

    /// Stop listening, close fds, and unlink the socket (lock owner only).
    public func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if listenFD >= 0 {
            _ = syscalls.close(listenFD)
            listenFD = -1
        }
        if fileSystem.fileExists(location.socketPath) {
            // Best-effort unlink of our socket.
            _ = syscalls.unlink(location.socketPath)
        }
        if lockFD >= 0 {
            _ = syscalls.close(lockFD)
            lockFD = -1
        }
        isRunning = false
    }

    /// Blocking accept + peer verification. Returns a trusted connection.
    /// Throws if the peer fails verification (the accepted fd is closed).
    public func accept() throws -> AcceptedConnection {
        let fd = try acceptRaw()
        do {
            let identity = try verifier.verify(fd: fd, policy: policy)
            return AcceptedConnection(
                connection: SocketConnection(fd: fd, syscalls: syscalls),
                peer: identity
            )
        } catch {
            _ = syscalls.close(fd)
            throw error
        }
    }

    /// Accept without verification (tests that inject their own verifier step).
    public func acceptRaw() throws -> Int32 {
        stateLock.lock()
        let fd = listenFD
        let running = isRunning
        stateLock.unlock()
        guard running, fd >= 0 else {
            throw IPCError.notListening
        }
        let client = syscalls.accept(fd, nil, nil)
        if client < 0 {
            throw IPCError.acceptFailed(errnoCode: errno)
        }
        return client
    }

    // MARK: - Lock

    private func acquireLock() throws {
        let path = location.lockPath
        let fd = path.withCString { cPath in
            Darwin.open(cPath, O_RDWR | O_CREAT, 0o600)
        }
        if fd < 0 {
            throw IPCError.lockFailed(path: path, reason: "open errno \(errno)")
        }
        // Force mode 0600 regardless of umask.
        _ = syscalls.chmodPath(path, 0o600)

        // Non-blocking exclusive flock. Only the lock owner may bind the socket.
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            _ = Darwin.close(fd)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw IPCError.lockBusy(path: path)
            }
            throw IPCError.lockFailed(path: path, reason: "flock errno \(code)")
        }
        lockFD = fd
    }

    // MARK: - Socket path prep

    private func prepareSocketPath() throws {
        let path = location.socketPath
        if !fileSystem.fileExists(path) {
            return
        }
        // Stale path present: only unlink if it is a same-euid socket.
        let info: FileStatInfo
        do {
            info = try fileSystem.lstat(path)
        } catch {
            throw IPCError.staleSocketRejected(path: path, reason: "lstat failed")
        }
        if info.isSymlink {
            throw IPCError.staleSocketRejected(path: path, reason: "path is a symlink")
        }
        if !info.isSocket {
            throw IPCError.staleSocketRejected(path: path, reason: "path is not a socket")
        }
        if info.uid != euid {
            throw IPCError.staleSocketRejected(
                path: path,
                reason: "owner uid \(info.uid) != euid \(euid)"
            )
        }
        let mode = info.mode & 0o777
        // Permissive sockets are rejected rather than cleaned up — fail closed.
        if mode != 0o600 {
            throw IPCError.staleSocketRejected(
                path: path,
                reason: String(format: "mode %04o is not 0600", mode)
            )
        }
        // Lock owner may unlink a valid same-user stale socket.
        if syscalls.unlink(path) != 0 {
            throw IPCError.staleSocketRejected(
                path: path,
                reason: "unlink errno \(errno)"
            )
        }
    }

    private func bindAndListen(backlog: Int32) throws {
        let fd = syscalls.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw IPCError.bindFailed(path: location.socketPath, errnoCode: errno)
        }

        // Close-on-exec.
        _ = syscalls.fcntl(fd, F_SETFD, FD_CLOEXEC)

        do {
            try UnixSocketAddress.withSockaddr(path: location.socketPath) { addr, len in
                if syscalls.bind(fd, addr, len) != 0 {
                    throw IPCError.bindFailed(path: location.socketPath, errnoCode: errno)
                }
            }
        } catch {
            _ = syscalls.close(fd)
            throw error
        }

        // Force socket mode 0600.
        if syscalls.chmodPath(location.socketPath, 0o600) != 0 {
            _ = syscalls.close(fd)
            _ = syscalls.unlink(location.socketPath)
            throw IPCError.bindFailed(path: location.socketPath, errnoCode: errno)
        }

        if syscalls.listen(fd, backlog) != 0 {
            let code = errno
            _ = syscalls.close(fd)
            _ = syscalls.unlink(location.socketPath)
            throw IPCError.bindFailed(path: location.socketPath, errnoCode: code)
        }

        listenFD = fd
    }
}

/// An accepted, peer-verified connection.
public struct AcceptedConnection: Sendable {
    public let connection: SocketConnection
    public let peer: PeerIdentity

    public init(connection: SocketConnection, peer: PeerIdentity) {
        self.connection = connection
        self.peer = peer
    }
}

// MARK: - Hello on an accepted connection

public extension HostListener {
    /// Read and validate a hello request, then write a success result.
    /// Peer must already have been verified.
    static func performHello(
        fd: Int32,
        hostVersion: String,
        bootId: String = UUID().uuidString,
        allowedRoles: Set<ConnectionRole> = [.mcp, .control],
        deadline: Date? = nil,
        syscalls: SocketSyscalls = .live
    ) throws -> (request: HelloRequest, result: HelloResult) {
        let payload = try FrameIO.readFrame(
            fd: fd,
            maximumFrameBytes: HostProtocol.helloMaxFrameBytes,
            deadline: deadline,
            syscalls: syscalls
        )
        let request: HelloRequest
        do {
            request = try HostCodec.decodeHelloRequest(payload)
        } catch let error as IPCError {
            throw error
        } catch {
            throw IPCError.invalidJSON(reason: String(describing: error))
        }

        if request.protocol != HostProtocol.version {
            let envelope = HostErrorEnvelope(
                code: "host_version_mismatch",
                message: "Unsupported host protocol \(request.protocol); expected \(HostProtocol.version).",
                retryable: false
            )
            if let data = try? HostCodec.encode(envelope) {
                try? FrameIO.writeFrame(fd: fd, payload: data, deadline: deadline, syscalls: syscalls)
            }
            throw IPCError.protocolMismatch(expected: HostProtocol.version, received: request.protocol)
        }
        if !allowedRoles.contains(request.role) {
            throw IPCError.unexpectedRole(request.role.rawValue)
        }
        // Nonce must be present and look like 32 raw bytes base64 (rough check).
        guard let nonceData = Data(base64Encoded: request.nonce),
              nonceData.count == HostProtocol.nonceByteCount else {
            throw IPCError.invalidFrame(reason: "hello nonce must be 32-byte base64")
        }

        let result = HelloResult.make(
            hostVersion: hostVersion,
            bootId: bootId,
            echoNonce: request.nonce,
            role: request.role
        )
        let encoded = try HostCodec.encode(result)
        if encoded.count > HostProtocol.helloMaxFrameBytes {
            throw IPCError.oversizedFrame(length: encoded.count, maximum: HostProtocol.helloMaxFrameBytes)
        }
        try FrameIO.writeFrame(fd: fd, payload: encoded, deadline: deadline, syscalls: syscalls)
        return (request, result)
    }
}
