import Foundation
import Security

/// Private host↔relay protocol constants and envelopes (protocol version 1).
///
/// Framing: 4-byte unsigned big-endian payload length, then UTF-8 JSON.
/// Hello frames are capped at 16 KiB; control frames at 1 MiB. After a successful
/// MCP hello (`mode: raw-mcp`), the connection switches to opaque raw bytes —
/// this module never parses MCP/JSON-RPC.
public enum HostProtocol {
    /// Private host-socket protocol major version. Not the public MCP contract version.
    public static let version: UInt32 = 1

    public static let lengthHeaderSize = 4
    public static let helloMaxFrameBytes = 16 * 1024
    public static let controlMaxFrameBytes = 1 * 1024 * 1024

    /// Host app bundle / code identifier.
    public static let hostCodeIdentifier = "tech.watzon.semantouch"
    /// Nested relay / CLI code identifier.
    public static let relayCodeIdentifier = "tech.watzon.semantouch.cli"
    /// Developer ID Team / OU.
    public static let teamIdentifier = "MB5789APU7"

    public static let runtimeDirectoryName = "tech.watzon.semantouch"
    public static let socketFileName = "host-v1.sock"
    public static let lockFileName = "host-v1.lock"

    /// 32-byte hello nonce, base64-encoded on the wire.
    public static let nonceByteCount = 32

    public static func makeNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    public static func makeNonceBase64() -> String {
        makeNonce().base64EncodedString()
    }
}

// MARK: - Roles / modes

/// Connection role presented in the hello request.
public enum ConnectionRole: String, Codable, Equatable, Sendable {
    case mcp
    case control
}

/// Post-hello connection mode returned by the host.
public enum ConnectionMode: String, Codable, Equatable, Sendable {
    case rawMCP = "raw-mcp"
    case control
}

// MARK: - Hello envelopes

/// Client → host hello request.
public struct HelloRequest: Codable, Equatable, Sendable {
    public var type: String
    public var `protocol`: UInt32
    public var role: ConnectionRole
    public var clientVersion: String
    public var nonce: String

    public init(
        type: String = "hello",
        protocol protocolVersion: UInt32 = HostProtocol.version,
        role: ConnectionRole,
        clientVersion: String,
        nonce: String
    ) {
        self.type = type
        self.protocol = protocolVersion
        self.role = role
        self.clientVersion = clientVersion
        self.nonce = nonce
    }

    public static func make(
        role: ConnectionRole,
        clientVersion: String,
        nonce: String = HostProtocol.makeNonceBase64()
    ) -> HelloRequest {
        HelloRequest(role: role, clientVersion: clientVersion, nonce: nonce)
    }
}

/// Host → client successful hello result.
public struct HelloResult: Codable, Equatable, Sendable {
    public var type: String
    public var `protocol`: UInt32
    public var hostVersion: String
    public var bundleId: String
    public var bootId: String
    public var sessionId: String
    public var echoNonce: String
    public var mode: ConnectionMode

    public init(
        type: String = "helloResult",
        protocol protocolVersion: UInt32 = HostProtocol.version,
        hostVersion: String,
        bundleId: String = HostProtocol.hostCodeIdentifier,
        bootId: String,
        sessionId: String,
        echoNonce: String,
        mode: ConnectionMode
    ) {
        self.type = type
        self.protocol = protocolVersion
        self.hostVersion = hostVersion
        self.bundleId = bundleId
        self.bootId = bootId
        self.sessionId = sessionId
        self.echoNonce = echoNonce
        self.mode = mode
    }

    public static func make(
        hostVersion: String,
        bootId: String = UUID().uuidString,
        sessionId: String = UUID().uuidString,
        echoNonce: String,
        role: ConnectionRole
    ) -> HelloResult {
        HelloResult(
            hostVersion: hostVersion,
            bootId: bootId,
            sessionId: sessionId,
            echoNonce: echoNonce,
            mode: role == .mcp ? .rawMCP : .control
        )
    }
}

/// Host → client error envelope (hello or control).
public struct HostErrorEnvelope: Codable, Equatable, Sendable {
    public var type: String
    public var code: String
    public var message: String
    public var retryable: Bool

    public init(
        type: String = "error",
        code: String,
        message: String,
        retryable: Bool = false
    ) {
        self.type = type
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

// MARK: - Control envelopes

/// Client → host control request (post-hello control mode).
public struct ControlRequest: Codable, Equatable, Sendable {
    public var type: String
    public var `protocol`: UInt32
    public var id: String
    public var method: String
    /// Opaque JSON object; IPC does not interpret method params.
    public var params: [String: JSONValue]?

    public init(
        type: String = "request",
        protocol protocolVersion: UInt32 = HostProtocol.version,
        id: String = UUID().uuidString,
        method: String,
        params: [String: JSONValue]? = nil
    ) {
        self.type = type
        self.protocol = protocolVersion
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Host → client control response.
public struct ControlResponse: Codable, Equatable, Sendable {
    public var type: String
    public var `protocol`: UInt32
    public var id: String
    public var ok: Bool
    public var result: JSONValue?
    public var error: ControlErrorBody?

    public init(
        type: String = "response",
        protocol protocolVersion: UInt32 = HostProtocol.version,
        id: String,
        ok: Bool,
        result: JSONValue? = nil,
        error: ControlErrorBody? = nil
    ) {
        self.type = type
        self.protocol = protocolVersion
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }
}

public struct ControlErrorBody: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

/// Closed control method surface (enumerated; unknown methods are errors).
public enum ControlMethod: String, Codable, Equatable, Sendable, CaseIterable {
    case ping
    case doctor
    case listApps
    case probe
    case showOnboarding
    case checkForUpdate
    case installUpdate
    case shutdownIfIdle
}

// MARK: - Minimal JSON value (no MCP knowledge)

/// Tiny JSON AST for control params/results. Not an MCP parser.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

// MARK: - Canonical JSON encode/decode helpers

public enum HostCodec {
    /// Encode an envelope to UTF-8 JSON data (sorted keys via `JSONEncoder` default is
    /// not sorted; we use a deterministic encoder configuration and avoid pretty print).
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    public static func decodeHelloRequest(_ data: Data) throws -> HelloRequest {
        let request = try decode(HelloRequest.self, from: data)
        guard request.type == "hello" else {
            throw IPCError.invalidFrame(reason: "hello type must be \"hello\"")
        }
        return request
    }

    public static func decodeHelloResult(_ data: Data) throws -> HelloResult {
        // Prefer success shape; if type is error, surface as HostErrorEnvelope.
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = obj["type"] as? String, type == "error" {
            let error = try decode(HostErrorEnvelope.self, from: data)
            throw IPCError.hostError(code: error.code, message: error.message, retryable: error.retryable)
        }
        let result = try decode(HelloResult.self, from: data)
        guard result.type == "helloResult" else {
            throw IPCError.invalidFrame(reason: "hello result type must be \"helloResult\"")
        }
        return result
    }
}
