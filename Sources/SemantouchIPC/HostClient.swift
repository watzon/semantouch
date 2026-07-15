import Foundation
import Darwin

/// Client-side connection to the app host over the private Unix-domain socket.
///
/// Pre-hello only: bounded retry is allowed for `ENOENT` / `ECONNREFUSED`.
/// After hello succeeds, the connection is sticky — callers must not reconnect
/// or replay on later failures.
public final class HostClient: @unchecked Sendable {
    public let location: SocketLocation
    public let policy: PeerTrustPolicy
    public let verifier: any PeerVerifying
    public let clientVersion: String
    private let fileSystem: FileSystemSeam
    private let syscalls: SocketSyscalls
    private let euid: uid_t

    public init(
        location: SocketLocation,
        policy: PeerTrustPolicy,
        clientVersion: String,
        verifier: any PeerVerifying = SecurityPeerVerifier(),
        fileSystem: FileSystemSeam = .live,
        syscalls: SocketSyscalls = .live,
        euid: uid_t = geteuid()
    ) {
        self.location = location
        self.policy = policy
        self.clientVersion = clientVersion
        self.verifier = verifier
        self.fileSystem = fileSystem
        self.syscalls = syscalls
        self.euid = euid
    }

    /// Connect, verify peer, exchange hello. Returns a session ready for raw MCP
    /// or control traffic depending on `role`.
    public func connect(
        role: ConnectionRole,
        retry: ConnectRetryPolicy = .default,
        helloDeadline: Date? = nil,
        onRetry: ((Int, IPCError) -> Void)? = nil
    ) throws -> HostSession {
        let connection = try connectWithRetry(retry: retry, onRetry: onRetry)
        do {
            let peer = try verifier.verify(fd: connection.fd, policy: policy)
            let (request, result) = try performHello(
                fd: connection.fd,
                role: role,
                deadline: helloDeadline
            )
            return HostSession(
                connection: connection,
                peer: peer,
                role: role,
                helloRequest: request,
                helloResult: result
            )
        } catch {
            connection.close()
            throw error
        }
    }

    /// Single connect attempt with socket-path validation.
    public func connectOnce() throws -> SocketConnection {
        try SocketLocation.validateDirectory(
            location.directoryPath,
            fileSystem: fileSystem,
            euid: euid
        )
        // Socket may not exist yet (ENOENT) — that's a retryable connect failure.
        if fileSystem.fileExists(location.socketPath) {
            try SocketLocation.validateSocketPath(
                location.socketPath,
                fileSystem: fileSystem,
                euid: euid
            )
        }

        let fd = syscalls.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw IPCError.connectFailed(path: location.socketPath, errnoCode: errno)
        }
        _ = syscalls.fcntl(fd, F_SETFD, FD_CLOEXEC)

        do {
            try UnixSocketAddress.withSockaddr(path: location.socketPath) { addr, len in
                if syscalls.connect(fd, addr, len) != 0 {
                    throw IPCError.connectFailed(path: location.socketPath, errnoCode: errno)
                }
            }
        } catch {
            _ = syscalls.close(fd)
            throw error
        }
        return SocketConnection(fd: fd, syscalls: syscalls)
    }

    // MARK: - Retry seam

    public func connectWithRetry(
        retry: ConnectRetryPolicy = .default,
        onRetry: ((Int, IPCError) -> Void)? = nil,
        sleep: (useconds_t) -> Void = { usleep($0) }
    ) throws -> SocketConnection {
        var attempt = 0
        var lastError: IPCError = .retryExhausted(attempts: 0, lastError: "no attempt")
        let deadline = Date().addingTimeInterval(retry.totalBudget)

        while attempt < retry.maximumAttempts {
            attempt += 1
            if Date() > deadline {
                break
            }
            do {
                return try connectOnce()
            } catch let error as IPCError {
                lastError = error
                if !error.isPreHelloRetryable || attempt >= retry.maximumAttempts {
                    throw error
                }
                onRetry?(attempt, error)
                let delay = retry.delay(forAttempt: attempt)
                if delay > 0 {
                    sleep(useconds_t(delay * 1_000_000))
                }
            } catch {
                throw error
            }
        }
        throw IPCError.retryExhausted(
            attempts: attempt,
            lastError: lastError.description
        )
    }

    // MARK: - Hello

    private func performHello(
        fd: Int32,
        role: ConnectionRole,
        deadline: Date?
    ) throws -> (HelloRequest, HelloResult) {
        let request = HelloRequest.make(role: role, clientVersion: clientVersion)
        let encoded = try HostCodec.encode(request)
        if encoded.count > HostProtocol.helloMaxFrameBytes {
            throw IPCError.oversizedFrame(
                length: encoded.count,
                maximum: HostProtocol.helloMaxFrameBytes
            )
        }
        try FrameIO.writeFrame(
            fd: fd,
            payload: encoded,
            deadline: deadline,
            syscalls: syscalls
        )
        let responseData = try FrameIO.readFrame(
            fd: fd,
            maximumFrameBytes: HostProtocol.helloMaxFrameBytes,
            deadline: deadline,
            syscalls: syscalls
        )
        let result: HelloResult
        do {
            result = try HostCodec.decodeHelloResult(responseData)
        } catch let error as IPCError {
            throw error
        } catch {
            throw IPCError.invalidJSON(reason: String(describing: error))
        }

        if result.protocol != HostProtocol.version {
            throw IPCError.protocolMismatch(
                expected: HostProtocol.version,
                received: result.protocol
            )
        }
        if result.echoNonce != request.nonce {
            throw IPCError.nonceMismatch
        }
        let expectedMode: ConnectionMode = role == .mcp ? .rawMCP : .control
        if result.mode != expectedMode {
            throw IPCError.invalidFrame(
                reason: "hello mode \(result.mode.rawValue) != \(expectedMode.rawValue)"
            )
        }
        return (request, result)
    }
}

// MARK: - Retry policy

/// Bounded pre-hello connect retry. Defaults: ~50 ms … 500 ms, ≤ 5 s budget.
public struct ConnectRetryPolicy: Equatable, Sendable {
    public var maximumAttempts: Int
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval
    public var totalBudget: TimeInterval
    public var multiplier: Double

    public init(
        maximumAttempts: Int = 12,
        initialDelay: TimeInterval = 0.05,
        maximumDelay: TimeInterval = 0.5,
        totalBudget: TimeInterval = 5.0,
        multiplier: Double = 1.6
    ) {
        self.maximumAttempts = maximumAttempts
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.totalBudget = totalBudget
        self.multiplier = multiplier
    }

    public static let `default` = ConnectRetryPolicy()
    /// No retries (single attempt).
    public static let none = ConnectRetryPolicy(
        maximumAttempts: 1,
        initialDelay: 0,
        maximumDelay: 0,
        totalBudget: 30.0,
        multiplier: 1
    )

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt >= 1 else { return initialDelay }
        let raw = initialDelay * pow(multiplier, Double(attempt - 1))
        return min(raw, maximumDelay)
    }
}

// MARK: - Session

/// Authenticated post-hello session. For MCP role, use `OpaqueRelay` on
/// `connection` + stdio. For control role, exchange framed control messages.
public final class HostSession: @unchecked Sendable {
    public let connection: SocketConnection
    public let peer: PeerIdentity
    public let role: ConnectionRole
    public let helloRequest: HelloRequest
    public let helloResult: HelloResult

    public init(
        connection: SocketConnection,
        peer: PeerIdentity,
        role: ConnectionRole,
        helloRequest: HelloRequest,
        helloResult: HelloResult
    ) {
        self.connection = connection
        self.peer = peer
        self.role = role
        self.helloRequest = helloRequest
        self.helloResult = helloResult
    }

    public var fd: Int32 { connection.fd }

    public func close() {
        connection.close()
    }

    /// Send a control request and wait for the matching response (control role only).
    public func sendControl(
        _ request: ControlRequest,
        deadline: Date? = nil,
        syscalls: SocketSyscalls = .live
    ) throws -> ControlResponse {
        let payload = try HostCodec.encode(request)
        if payload.count > HostProtocol.controlMaxFrameBytes {
            throw IPCError.oversizedFrame(
                length: payload.count,
                maximum: HostProtocol.controlMaxFrameBytes
            )
        }
        try FrameIO.writeFrame(
            fd: fd,
            payload: payload,
            deadline: deadline,
            syscalls: syscalls
        )
        let responseData = try FrameIO.readFrame(
            fd: fd,
            maximumFrameBytes: HostProtocol.controlMaxFrameBytes,
            deadline: deadline,
            syscalls: syscalls
        )
        let response: ControlResponse
        do {
            response = try HostCodec.decode(ControlResponse.self, from: responseData)
        } catch {
            throw IPCError.invalidJSON(reason: String(describing: error))
        }
        if response.id != request.id {
            throw IPCError.invalidFrame(
                reason: "control response id mismatch"
            )
        }
        return response
    }
}
