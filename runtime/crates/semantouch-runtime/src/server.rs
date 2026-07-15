//! MCP server: handshake, tools surface, and cancellation routing.
//!
//! Mirrors `Sources/MCPServer/MCPServer.swift` over the shared Rust coordinator.
//! Request execution is serial; cancellation notifications are handled on the reader
//! path so an in-flight (or still-queued) `tools/call` can latch its token.

use crate::jsonrpc::{
    self, error_code, error_response, id_key, serialize_line, success_response, RpcClassification,
    RpcIncoming, RpcNotification, RpcRequest,
};
use crate::Runtime;
use parking_lot::Mutex;
use semantouch_adapter::PlatformAdapter;
use semantouch_core::CancellationToken;
use semantouch_protocol::{tool_exists, ToolError};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};

/// Bounded shutdown-drain budget (ms), matching Swift `shutdownDrainMilliseconds`.
pub const SHUTDOWN_DRAIN_MILLISECONDS: u64 = 500;

/// Methods the server handles; anything else is JSON-RPC `-32601`.
pub const HANDLED_METHODS: &[&str] = &[
    "initialize",
    "notifications/initialized",
    "ping",
    "tools/list",
    "tools/call",
];

/// Tracks the cancellation token of each in-flight `tools/call` by JSON-RPC id.
#[derive(Default)]
pub struct RequestCancellationRegistry {
    tokens: Mutex<HashMap<String, CancellationToken>>,
}

impl RequestCancellationRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register (and return) a fresh token for a request id.
    pub fn register(&self, id: &Value) -> CancellationToken {
        let key = id_key(id);
        let token = CancellationToken::new();
        self.tokens.lock().insert(key, token.clone());
        token
    }

    /// Drop the token for a completed request id.
    ///
    /// JSON-RPC forbids concurrent id reuse; removal by key is sufficient for the
    /// normal path.
    pub fn deregister(&self, id: &Value, _token: &CancellationToken) {
        let key = id_key(id);
        self.tokens.lock().remove(&key);
    }

    /// Cancel the token for a request id. Unknown/completed ids are a safe no-op.
    pub fn cancel(&self, id: &Value, reason: Option<String>) {
        let key = id_key(id);
        let token = self.tokens.lock().get(&key).cloned();
        if let Some(token) = token {
            token.cancel(reason);
        }
    }

    /// Cancel every in-flight token (process shutdown: stdin EOF / SIGTERM).
    pub fn cancel_all(&self, reason: impl Into<String>) {
        let reason = reason.into();
        let all: Vec<CancellationToken> = self.tokens.lock().values().cloned().collect();
        for token in all {
            token.cancel(Some(reason.clone()));
        }
    }

    /// Count of in-flight tokens (tests/diagnostics).
    pub fn in_flight_count(&self) -> usize {
        self.tokens.lock().len()
    }
}

// ---------------------------------------------------------------------------
// Tool call output seam
// ---------------------------------------------------------------------------

/// Optional image content for MCP image blocks (base64 wire form).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolImageContent {
    pub data_base64: String,
    pub mime_type: String,
}

/// Standard base64 (no newlines) encode for image data blocks.
pub fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    let mut i = 0;
    while i + 3 <= bytes.len() {
        let n = ((bytes[i] as u32) << 16) | ((bytes[i + 1] as u32) << 8) | (bytes[i + 2] as u32);
        out.push(TABLE[((n >> 18) & 0x3F) as usize] as char);
        out.push(TABLE[((n >> 12) & 0x3F) as usize] as char);
        out.push(TABLE[((n >> 6) & 0x3F) as usize] as char);
        out.push(TABLE[(n & 0x3F) as usize] as char);
        i += 3;
    }
    let rem = bytes.len() - i;
    if rem == 1 {
        let n = (bytes[i] as u32) << 16;
        out.push(TABLE[((n >> 18) & 0x3F) as usize] as char);
        out.push(TABLE[((n >> 12) & 0x3F) as usize] as char);
        out.push('=');
        out.push('=');
    } else if rem == 2 {
        let n = ((bytes[i] as u32) << 16) | ((bytes[i + 1] as u32) << 8);
        out.push(TABLE[((n >> 18) & 0x3F) as usize] as char);
        out.push(TABLE[((n >> 12) & 0x3F) as usize] as char);
        out.push(TABLE[((n >> 6) & 0x3F) as usize] as char);
        out.push('=');
    }
    out
}

/// Build image content from raw JPEG bytes.
pub fn image_from_jpeg(jpeg: &[u8], mime_type: &str) -> ToolImageContent {
    ToolImageContent {
        data_base64: base64_encode(jpeg),
        mime_type: mime_type.to_string(),
    }
}

/// Render core `ToolCallOutput` into the MCP result envelope.
///
/// Content order: text JSON first, then optional `{type:image,data,mimeType}`.
pub fn core_tool_output_to_envelope(output: &semantouch_core::ToolCallOutput) -> Value {
    let mut content = vec![json!({
        "type": "text",
        "text": output.value.to_string(),
    })];
    if let Some(image) = output.image.as_ref() {
        content.push(json!({
            "type": "image",
            "data": base64_encode(&image.jpeg),
            "mimeType": image.mime_type,
        }));
    }
    json!({
        "content": content,
        "isError": false,
    })
}

/// Render a JSON value (no image) into the MCP result envelope.
pub fn tool_output_to_envelope(value: Value) -> Value {
    core_tool_output_to_envelope(&semantouch_core::ToolCallOutput {
        value,
        image: None,
    })
}

/// Tool-level `ToolError` as a successful `tools/call` result with `isError: true`.
pub fn tool_error_to_envelope(error: &ToolError) -> Value {
    json!({
        "content": [{
            "type": "text",
            "text": error.to_wire().to_string(),
        }],
        "isError": true,
    })
}

/// Map a value-only `Result` through the output seam (no image).
pub fn tool_result_to_envelope(result: Result<Value, ToolError>) -> Value {
    match result {
        Ok(value) => tool_output_to_envelope(value),
        Err(err) => tool_error_to_envelope(&err),
    }
}

/// Map a core `ToolResult<ToolCallOutput>` through the output seam.
pub fn tool_call_output_result_to_envelope(
    result: Result<semantouch_core::ToolCallOutput, ToolError>,
) -> Value {
    match result {
        Ok(output) => core_tool_output_to_envelope(&output),
        Err(err) => tool_error_to_envelope(&err),
    }
}

/// Capture bytes are only emitted when core `call_tool_output` supplies `ToolImageBytes`.
pub const IMAGE_CONTENT_LIMITATION: &str = "MCP image content blocks are emitted only when Coordinator::call_tool_output returns ToolImageBytes from a real adapter capture; unavailable captures never invent screenshot/image payloads.";

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

/// Outcome of classifying one input line (before request execution).
#[derive(Debug)]
pub enum DispatchOutcome {
    Reply(Value),
    Request(RpcRequest),
    Notification(RpcNotification),
    Ignore,
}

/// MCP server over a `Runtime<A>`.
///
/// Thread-safe: the reader thread classifies lines and may cancel tokens while a
/// worker thread executes requests serially through `handle_request`.
pub struct McpServer<A: PlatformAdapter> {
    runtime: Runtime<A>,
    cancellation: RequestCancellationRegistry,
    initialized: AtomicBool,
    /// Optional host callback for `notifications/turn-ended` only.
    on_notification: Mutex<Option<Box<dyn FnMut(&str, Option<&Value>) + Send>>>,
}

impl<A: PlatformAdapter> McpServer<A> {
    pub fn new(runtime: Runtime<A>) -> Self {
        Self {
            runtime,
            cancellation: RequestCancellationRegistry::new(),
            initialized: AtomicBool::new(false),
            on_notification: Mutex::new(None),
        }
    }

    pub fn runtime(&self) -> &Runtime<A> {
        &self.runtime
    }

    pub fn cancellation(&self) -> &RequestCancellationRegistry {
        &self.cancellation
    }

    pub fn is_initialized(&self) -> bool {
        self.initialized.load(Ordering::SeqCst)
    }

    /// Install a host callback for `notifications/turn-ended`.
    pub fn set_on_notification<F>(&self, callback: F)
    where
        F: FnMut(&str, Option<&Value>) + Send + 'static,
    {
        *self.on_notification.lock() = Some(Box::new(callback));
    }

    /// Synchronous process path used by unit tests and simple hosts.
    ///
    /// Returns `None` for notifications and unanswerable messages. Cancellation
    /// tokens are fresh (never shared with a concurrent cancel notification).
    pub fn process(&self, line: &str) -> Option<String> {
        match self.dispatch_line(line) {
            DispatchOutcome::Reply(value) => Some(serialize_line(&value)),
            DispatchOutcome::Notification(note) => {
                self.handle_notification(&note);
                None
            }
            DispatchOutcome::Ignore => None,
            DispatchOutcome::Request(req) => {
                let token = CancellationToken::new();
                let response = self.handle_request(&req, &token);
                Some(serialize_line(&response))
            }
        }
    }

    /// Classify one line. Notifications are **not** handled here so the concurrent
    /// transport can run them on the reader thread.
    pub fn dispatch_line(&self, line: &str) -> DispatchOutcome {
        let value: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => {
                return DispatchOutcome::Reply(error_response(
                    Value::Null,
                    error_code::PARSE_ERROR,
                    "Parse error",
                    None,
                ));
            }
        };

        match jsonrpc::classify(&value) {
            RpcClassification::Invalid { id, code, message } => {
                DispatchOutcome::Reply(error_response(id, code, message, None))
            }
            RpcClassification::Ignore => DispatchOutcome::Ignore,
            RpcClassification::Parsed(RpcIncoming::Notification(n)) => {
                DispatchOutcome::Notification(n)
            }
            RpcClassification::Parsed(RpcIncoming::Request(r)) => DispatchOutcome::Request(r),
        }
    }

    /// Handle a client notification inline (reader thread).
    pub fn handle_notification(&self, notification: &RpcNotification) {
        match notification.method.as_str() {
            "notifications/cancelled" => self.handle_cancelled(notification.params.as_ref()),
            "notifications/turn-ended" => {
                if let Some(cb) = self.on_notification.lock().as_mut() {
                    cb(
                        notification.method.as_str(),
                        notification.params.as_ref(),
                    );
                }
            }
            // `notifications/initialized` is a no-op (state already set on initialize).
            // Unknown notifications are silently ignored.
            _ => {}
        }
    }

    fn handle_cancelled(&self, params: Option<&Value>) {
        let Some(params) = params.and_then(|p| p.as_object()) else {
            return;
        };
        let Some(request_id) = params.get("requestId") else {
            return;
        };
        if request_id.is_null() {
            return;
        }
        let reason = params
            .get("reason")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        self.cancellation.cancel(request_id, reason);
    }

    /// Execute one request and return the JSON-RPC response object.
    pub fn handle_request(&self, request: &RpcRequest, token: &CancellationToken) -> Value {
        if request.method != "initialize" && !self.is_initialized() {
            return error_response(
                request.id.clone(),
                error_code::SERVER_NOT_INITIALIZED,
                "Server not initialized; send initialize first",
                None,
            );
        }

        match request.method.as_str() {
            "initialize" => {
                self.initialized.store(true, Ordering::SeqCst);
                success_response(request.id.clone(), self.runtime.initialize_payload())
            }
            "ping" => success_response(request.id.clone(), json!({})),
            "tools/list" => success_response(request.id.clone(), self.runtime.tools_list()),
            "tools/call" => self.handle_tools_call(request, token),
            other => error_response(
                request.id.clone(),
                error_code::METHOD_NOT_FOUND,
                format!("Unknown method: {other}"),
                None,
            ),
        }
    }

    fn handle_tools_call(&self, request: &RpcRequest, token: &CancellationToken) -> Value {
        let Some(params) = request.params.as_ref() else {
            return self.invalid_params(
                request,
                "tools/call requires a params object with a tool name",
            );
        };
        let Some(params_obj) = params.as_object() else {
            return self.invalid_params(
                request,
                "tools/call requires a params object with a tool name",
            );
        };

        let Some(name_val) = params_obj.get("name") else {
            return self.invalid_params(request, "tools/call requires a string \"name\"");
        };
        let Some(name) = name_val.as_str() else {
            return self.invalid_params(request, "tools/call requires a string \"name\"");
        };

        let arguments = match params_obj.get("arguments") {
            None => json!({}),
            Some(Value::Object(_)) => params_obj.get("arguments").cloned().unwrap(),
            Some(_) => {
                return self.invalid_params(request, "\"arguments\" must be an object");
            }
        };

        // Unknown tool → JSON-RPC -32602 (matches Swift MCPServer).
        if !tool_exists(name) {
            return self.invalid_params(request, format!("Unknown tool: {name}"));
        }

        // Prefer call_tool_output when present on Runtime; value-only fallback otherwise.
        // Tool-level errors stay inside a successful JSON-RPC envelope.
        let envelope = self.runtime.call_tool_envelope(name, arguments, Some(token));
        success_response(request.id.clone(), envelope)
    }

    fn invalid_params(&self, request: &RpcRequest, message: impl Into<String>) -> Value {
        error_response(
            request.id.clone(),
            error_code::INVALID_PARAMS,
            message,
            None,
        )
    }
}

#[cfg(test)]
mod envelope_tests {
    use super::*;
    use semantouch_core::{ToolCallOutput, ToolImageBytes};

    #[test]
    fn success_envelope_is_single_text_block() {
        let env = tool_output_to_envelope(json!({"ok": true}));
        assert_eq!(env["isError"], false);
        let content = env["content"].as_array().unwrap();
        assert_eq!(content.len(), 1);
        assert_eq!(content[0]["type"], "text");
        assert!(content[0]["text"].as_str().unwrap().contains("ok"));
    }

    #[test]
    fn image_block_follows_text_with_base64() {
        let jpeg = vec![0xFFu8, 0xD8, 0xFF, 0xD9];
        let output = ToolCallOutput {
            value: json!({"meta": 1}),
            image: Some(ToolImageBytes {
                jpeg: jpeg.clone(),
                mime_type: "image/jpeg",
                width: 1,
                height: 1,
            }),
        };
        let env = core_tool_output_to_envelope(&output);
        let content = env["content"].as_array().unwrap();
        assert_eq!(content.len(), 2);
        assert_eq!(content[0]["type"], "text");
        assert_eq!(content[1]["type"], "image");
        assert_eq!(content[1]["mimeType"], "image/jpeg");
        assert_eq!(content[1]["data"], base64_encode(&jpeg));
        assert!(!content[1]["data"].as_str().unwrap().contains('\n'));
    }

    #[test]
    fn tool_error_envelope_is_error_true() {
        let err = ToolError::Cancelled {
            reason: Some("client".into()),
        };
        let env = tool_error_to_envelope(&err);
        assert_eq!(env["isError"], true);
        let text = env["content"][0]["text"].as_str().unwrap();
        let parsed: Value = serde_json::from_str(text).unwrap();
        assert_eq!(parsed["code"], "cancelled");
    }
}
