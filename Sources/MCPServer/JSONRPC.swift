import Foundation

/// JSON-RPC 2.0 message models over `JSONValue` (§1, §2). Ids may be a string or a
/// number; they are carried verbatim as `JSONValue` so the server can echo the
/// client's id exactly (the spec requires echoing it byte-for-byte in the reply).
public enum JSONRPC {
    /// The JSON-RPC protocol tag.
    public static let version = "2.0"

    /// Method-level (transport/RPC) error codes (§1). These are distinct from
    /// tool-level failures, which travel inside a successful `tools/call` result
    /// with `isError: true` (§5, §6).
    public enum ErrorCode {
        /// Malformed JSON that cannot be parsed.
        public static let parseError = -32700
        /// Well-formed JSON that is not a valid request object.
        public static let invalidRequest = -32600
        /// Unknown method.
        public static let methodNotFound = -32601
        /// Missing or invalid params for a known method (incl. unknown/invalid tool).
        public static let invalidParams = -32602
        /// Unhandled server fault at the RPC layer.
        public static let internalError = -32603
        /// A request other than `initialize` arrived before the handshake completed.
        /// Reserved server-error range (-32000…-32099); the widely used MCP value.
        public static let serverNotInitialized = -32002
    }
}

// MARK: - Incoming messages

/// A JSON-RPC request: has an `id` (echoed in the reply) and a `method`.
public struct RPCRequest: Equatable, Sendable {
    public let id: JSONValue
    public let method: String
    public let params: JSONValue?

    public init(id: JSONValue, method: String, params: JSONValue?) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// A JSON-RPC notification: a `method` with no `id`; never answered.
public struct RPCNotification: Equatable, Sendable {
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue?) {
        self.method = method
        self.params = params
    }
}

/// Classification of a parsed line.
public enum RPCIncoming: Equatable, Sendable {
    case request(RPCRequest)
    case notification(RPCNotification)
}

/// The outcome of classifying a parsed JSON value as a JSON-RPC message.
public enum RPCClassification: Equatable, Sendable {
    /// A well-formed request or notification.
    case parsed(RPCIncoming)
    /// A structurally invalid message that still warrants an error reply. `id` is
    /// the message's id when present, else `.null`.
    case invalid(id: JSONValue, code: Int, message: String)
    /// Nothing to reply with (e.g. a message with neither `method` nor `id`).
    case ignore
}

public extension JSONRPC {
    /// Classify an already-parsed JSON value into a request, a notification, an
    /// error to answer, or a silent ignore. This never inspects raw text — malformed
    /// JSON is handled one layer up (parse failure → `-32700`).
    static func classify(_ value: JSONValue) -> RPCClassification {
        guard case let .object(object) = value else {
            // Valid JSON, but not a request object. No usable id → null.
            return .invalid(
                id: .null,
                code: ErrorCode.invalidRequest,
                message: "Request must be a JSON object"
            )
        }

        let id = object["id"]
        let params = object["params"]

        guard let method = object["method"]?.stringValue else {
            // No dispatchable method. Answer only if we can echo an id.
            if let id, !id.isNull {
                return .invalid(
                    id: id,
                    code: ErrorCode.invalidRequest,
                    message: "Missing or non-string \"method\""
                )
            }
            return .ignore
        }

        if let id {
            return .parsed(.request(RPCRequest(id: id, method: method, params: params)))
        }
        return .parsed(.notification(RPCNotification(method: method, params: params)))
    }

    // MARK: - Outgoing messages

    /// A successful response `{ "jsonrpc": "2.0", "id": <id>, "result": <result> }`.
    static func successResponse(id: JSONValue, result: JSONValue) -> JSONValue {
        [
            "jsonrpc": .string(version),
            "id": id,
            "result": result,
        ]
    }

    /// An error response `{ "jsonrpc": "2.0", "id": <id>, "error": { code, message, data? } }`.
    static func errorResponse(
        id: JSONValue,
        code: Int,
        message: String,
        data: JSONValue? = nil
    ) -> JSONValue {
        var error: [String: JSONValue] = [
            "code": .int(code),
            "message": .string(message),
        ]
        if let data {
            error["data"] = data
        }
        return [
            "jsonrpc": .string(version),
            "id": id,
            "error": .object(error),
        ]
    }
}
