//! JSON-RPC 2.0 message models for newline-delimited MCP framing.
//!
//! Mirrors `Sources/MCPServer/JSONRPC.swift`. Ids are carried as `serde_json::Value`
//! so string and number ids are echoed verbatim. Tool-level failures are **not**
//! JSON-RPC errors — they travel inside a successful `tools/call` result.

use serde_json::{json, Map, Value};

/// JSON-RPC protocol tag.
pub const VERSION: &str = "2.0";

/// Method-level (transport/RPC) error codes. Distinct from tool-level `ToolError`.
pub mod error_code {
    pub const PARSE_ERROR: i64 = -32700;
    pub const INVALID_REQUEST: i64 = -32600;
    pub const METHOD_NOT_FOUND: i64 = -32601;
    pub const INVALID_PARAMS: i64 = -32602;
    pub const INTERNAL_ERROR: i64 = -32603;
    /// Request other than `initialize` before handshake completed.
    pub const SERVER_NOT_INITIALIZED: i64 = -32002;
}

/// A JSON-RPC request: has an `id` (echoed in the reply) and a `method`.
#[derive(Clone, Debug, PartialEq)]
pub struct RpcRequest {
    pub id: Value,
    pub method: String,
    pub params: Option<Value>,
}

/// A JSON-RPC notification: a `method` with no `id`; never answered.
#[derive(Clone, Debug, PartialEq)]
pub struct RpcNotification {
    pub method: String,
    pub params: Option<Value>,
}

/// Classification of a parsed line.
#[derive(Clone, Debug, PartialEq)]
pub enum RpcIncoming {
    Request(RpcRequest),
    Notification(RpcNotification),
}

/// Outcome of classifying a parsed JSON value as a JSON-RPC message.
#[derive(Clone, Debug, PartialEq)]
pub enum RpcClassification {
    /// A well-formed request or notification.
    Parsed(RpcIncoming),
    /// A structurally invalid message that still warrants an error reply.
    Invalid {
        id: Value,
        code: i64,
        message: String,
    },
    /// Nothing to reply with (e.g. a message with neither `method` nor `id`).
    Ignore,
}

/// Classify an already-parsed JSON value. Malformed JSON is handled one layer up
/// (parse failure → `-32700`).
pub fn classify(value: &Value) -> RpcClassification {
    let Some(object) = value.as_object() else {
        return RpcClassification::Invalid {
            id: Value::Null,
            code: error_code::INVALID_REQUEST,
            message: "Request must be a JSON object".into(),
        };
    };

    let id = object.get("id").cloned();
    let params = object.get("params").cloned();

    let method = match object.get("method") {
        Some(Value::String(s)) => s.clone(),
        _ => {
            if let Some(id) = id {
                if !id.is_null() {
                    return RpcClassification::Invalid {
                        id,
                        code: error_code::INVALID_REQUEST,
                        message: "Missing or non-string \"method\"".into(),
                    };
                }
            }
            return RpcClassification::Ignore;
        }
    };

    if let Some(id) = id {
        RpcClassification::Parsed(RpcIncoming::Request(RpcRequest {
            id,
            method,
            params,
        }))
    } else {
        RpcClassification::Parsed(RpcIncoming::Notification(RpcNotification {
            method,
            params,
        }))
    }
}

/// Successful response `{ "jsonrpc": "2.0", "id": <id>, "result": <result> }`.
pub fn success_response(id: Value, result: Value) -> Value {
    json!({
        "jsonrpc": VERSION,
        "id": id,
        "result": result,
    })
}

/// Error response `{ "jsonrpc": "2.0", "id": <id>, "error": { code, message, data? } }`.
pub fn error_response(
    id: Value,
    code: i64,
    message: impl Into<String>,
    data: Option<Value>,
) -> Value {
    let mut error = Map::new();
    error.insert("code".into(), json!(code));
    error.insert("message".into(), Value::String(message.into()));
    if let Some(data) = data {
        error.insert("data".into(), data);
    }
    json!({
        "jsonrpc": VERSION,
        "id": id,
        "error": Value::Object(error),
    })
}

/// Serialize a response as a single-line JSON string (no trailing newline).
pub fn serialize_line(value: &Value) -> String {
    value.to_string()
}

/// Canonical key for a JSON-RPC id used in the cancellation registry.
///
/// Numbers and strings must not collide; the notification's `requestId` must
/// resolve to the same key as the request's `id`.
pub fn id_key(id: &Value) -> String {
    id.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_request_and_notification() {
        let req = json!({"jsonrpc":"2.0","id":1,"method":"ping"});
        match classify(&req) {
            RpcClassification::Parsed(RpcIncoming::Request(r)) => {
                assert_eq!(r.method, "ping");
                assert_eq!(r.id, json!(1));
            }
            other => panic!("unexpected {other:?}"),
        }

        let note = json!({"jsonrpc":"2.0","method":"notifications/initialized"});
        match classify(&note) {
            RpcClassification::Parsed(RpcIncoming::Notification(n)) => {
                assert_eq!(n.method, "notifications/initialized");
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn missing_method_with_id_is_invalid_request() {
        let v = json!({"jsonrpc":"2.0","id":11});
        match classify(&v) {
            RpcClassification::Invalid { id, code, .. } => {
                assert_eq!(id, json!(11));
                assert_eq!(code, error_code::INVALID_REQUEST);
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn empty_object_is_ignore() {
        assert_eq!(classify(&json!({})), RpcClassification::Ignore);
    }
}
