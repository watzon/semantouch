import Foundation

/// Fail-closed errors for the private host↔relay IPC layer.
public enum IPCError: Error, Equatable, CustomStringConvertible {
    // Framing
    case incompleteFrame
    case zeroLengthFrame
    case oversizedFrame(length: Int, maximum: Int)
    case invalidFrame(reason: String)
    case invalidUTF8
    case invalidJSON(reason: String)

    // Location / filesystem
    case pathTooLong(path: String, limit: Int)
    case userTempUnavailable
    case directoryInvalid(path: String, reason: String)
    case socketInvalid(path: String, reason: String)
    case lockBusy(path: String)
    case lockFailed(path: String, reason: String)
    case staleSocketRejected(path: String, reason: String)
    case alreadyListening
    case notListening

    // Transport
    case connectFailed(path: String, errnoCode: Int32)
    case acceptFailed(errnoCode: Int32)
    case bindFailed(path: String, errnoCode: Int32)
    case ioFailed(operation: String, errnoCode: Int32)
    case timedOut(operation: String)
    case closed

    // Trust
    case peerRejected(reason: String)
    case peerCredentialsUnavailable
    case peerAuditTokenUnavailable
    case peerCodeUntrusted(reason: String)

    // Hello / protocol
    case protocolMismatch(expected: UInt32, received: UInt32)
    case nonceMismatch
    case unexpectedRole(String)
    case hostError(code: String, message: String, retryable: Bool)

    // Retry
    case retryExhausted(attempts: Int, lastError: String)

    public var description: String {
        switch self {
        case .incompleteFrame:
            return "incomplete IPC frame"
        case .zeroLengthFrame:
            return "zero-length IPC frame"
        case let .oversizedFrame(length, maximum):
            return "IPC frame length \(length) exceeds maximum \(maximum)"
        case let .invalidFrame(reason):
            return "invalid IPC frame: \(reason)"
        case .invalidUTF8:
            return "IPC frame is not valid UTF-8"
        case let .invalidJSON(reason):
            return "IPC frame JSON invalid: \(reason)"
        case let .pathTooLong(path, limit):
            return "socket path exceeds sockaddr_un.sun_path (\(limit)): \(path)"
        case .userTempUnavailable:
            return "confstr(_CS_DARWIN_USER_TEMP_DIR) unavailable"
        case let .directoryInvalid(path, reason):
            return "IPC directory invalid at \(path): \(reason)"
        case let .socketInvalid(path, reason):
            return "IPC socket invalid at \(path): \(reason)"
        case let .lockBusy(path):
            return "host lock busy: \(path)"
        case let .lockFailed(path, reason):
            return "host lock failed at \(path): \(reason)"
        case let .staleSocketRejected(path, reason):
            return "stale socket rejected at \(path): \(reason)"
        case .alreadyListening:
            return "host listener already active"
        case .notListening:
            return "host listener is not active"
        case let .connectFailed(path, errnoCode):
            return "connect failed for \(path): errno \(errnoCode)"
        case let .acceptFailed(errnoCode):
            return "accept failed: errno \(errnoCode)"
        case let .bindFailed(path, errnoCode):
            return "bind failed for \(path): errno \(errnoCode)"
        case let .ioFailed(operation, errnoCode):
            return "IPC \(operation) failed: errno \(errnoCode)"
        case let .timedOut(operation):
            return "IPC \(operation) timed out"
        case .closed:
            return "IPC connection closed"
        case let .peerRejected(reason):
            return "peer rejected: \(reason)"
        case .peerCredentialsUnavailable:
            return "peer credentials unavailable (getpeereid)"
        case .peerAuditTokenUnavailable:
            return "peer audit token unavailable (LOCAL_PEERTOKEN)"
        case let .peerCodeUntrusted(reason):
            return "peer code untrusted: \(reason)"
        case let .protocolMismatch(expected, received):
            return "host protocol mismatch: expected \(expected), received \(received)"
        case .nonceMismatch:
            return "hello nonce mismatch"
        case let .unexpectedRole(role):
            return "unexpected connection role: \(role)"
        case let .hostError(code, message, _):
            return "host error \(code): \(message)"
        case let .retryExhausted(attempts, lastError):
            return "pre-hello connect retry exhausted after \(attempts) attempts: \(lastError)"
        }
    }

    /// Whether a pre-hello connect failure is eligible for bounded retry.
    public var isPreHelloRetryable: Bool {
        switch self {
        case let .connectFailed(_, errnoCode):
            return errnoCode == ENOENT || errnoCode == ECONNREFUSED || errnoCode == EINTR
        case .timedOut:
            return true
        default:
            return false
        }
    }
}
