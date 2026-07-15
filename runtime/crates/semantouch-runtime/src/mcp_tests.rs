//! Focused MCP stdio tests with a fake adapter (no live OS APIs).

use crate::jsonrpc::error_code;
use crate::server::{base64_encode, tool_error_to_envelope, tool_output_to_envelope, IMAGE_CONTENT_LIMITATION};
use crate::stdio::{process_lines_sync, run_server_stdio};
use crate::{McpServer, Runtime};
use parking_lot::Mutex;
use semantouch_adapter::{
    CaptureOutcome, DeliveryEvidence, LaunchOutcome, LaunchRequest, NativeAction, NativeHandle,
    PermissionSnapshot, PlatformAdapter, RawNode, RawObservation, WaitObservation,
};
use semantouch_core::PolicyEngine;
use semantouch_protocol::{
    enabled_tool_names, ActionMethod, ActionStatus, AppSummary, CapabilityEntry, CapabilityKey,
    CapabilityReport, PermissionStatus, PlatformKind, Rect, ToolError, ToolResult, WindowInfo,
    WindowSummary,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::Cursor;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

// ---------------------------------------------------------------------------
// Fake adapter
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct TestHandle {
    id: u64,
    live: AtomicBool,
}

impl TestHandle {
    fn new(id: u64) -> Arc<dyn NativeHandle> {
        Arc::new(Self {
            id,
            live: AtomicBool::new(true),
        })
    }
}

impl NativeHandle for TestHandle {
    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
    fn is_live(&self) -> bool {
        self.live.load(Ordering::SeqCst)
    }
    fn clone_handle(&self) -> Arc<dyn NativeHandle> {
        Arc::new(Self {
            id: self.id,
            live: AtomicBool::new(self.live.load(Ordering::SeqCst)),
        })
    }
}

struct FakeAdapter {
    apps: Vec<AppSummary>,
    tree_title: Mutex<String>,
    values: Mutex<HashMap<u64, String>>,
    next_handle: AtomicU64,
    frontmost: Mutex<bool>,
    /// Optional latch: when set, observe/call blocks until cancelled or released.
    block_on_observe: Mutex<Option<Arc<AtomicBool>>>,
    observe_entered: Arc<AtomicBool>,
    /// When true, capture_window returns a tiny real JPEG for image-block tests.
    capture_ok: bool,
    jpeg: Vec<u8>,
    jpeg_width: i32,
    jpeg_height: i32,
}

impl FakeAdapter {
    fn new() -> Self {
        Self {
            apps: vec![AppSummary {
                id: "demo.app".into(),
                display_name: "Demo".into(),
                path: Some("/apps/Demo".into()),
                pid: Some(42),
                is_running: true,
                windows: 1,
                last_used_at: None,
                use_count: None,
            }],
            tree_title: Mutex::new("Demo".into()),
            values: Mutex::new(HashMap::new()),
            next_handle: AtomicU64::new(1),
            frontmost: Mutex::new(true),
            block_on_observe: Mutex::new(None),
            observe_entered: Arc::new(AtomicBool::new(false)),
            capture_ok: false,
            jpeg: vec![0xFF, 0xD8, 0xFF, 0xD9],
            jpeg_width: 10,
            jpeg_height: 10,
        }
    }

    fn with_capture(mut self) -> Self {
        self.capture_ok = true;
        self
    }

    fn mint(&self) -> Arc<dyn NativeHandle> {
        let id = self.next_handle.fetch_add(1, Ordering::SeqCst);
        TestHandle::new(id)
    }
}

impl PlatformAdapter for FakeAdapter {
    fn platform_name(&self) -> &'static str {
        "test"
    }

    fn permissions(&self) -> ToolResult<PermissionSnapshot> {
        Ok(PermissionSnapshot {
            accessibility: PermissionStatus::Granted,
            screen_capture: PermissionStatus::Granted,
            helper_path: "/tmp/semantouch-test".into(),
            signed: false,
            remediation: vec![],
            capabilities: CapabilityReport {
                platform: PlatformKind::Unknown,
                entries: vec![
                    CapabilityEntry::available(CapabilityKey::AccessibilityTree),
                    CapabilityEntry::available(CapabilityKey::StableElementIds),
                ],
                limitations: vec![IMAGE_CONTENT_LIMITATION.into()],
            },
        })
    }

    fn list_apps(&self) -> ToolResult<Vec<AppSummary>> {
        Ok(self.apps.clone())
    }

    fn launch_app(&self, request: LaunchRequest) -> ToolResult<LaunchOutcome> {
        let app = self.resolve_app(&request.app)?;
        Ok(LaunchOutcome {
            app,
            launched: true,
            recovered: false,
        })
    }

    fn resolve_app(&self, query: &str) -> ToolResult<AppSummary> {
        self.apps
            .iter()
            .find(|a| {
                a.id == query
                    || a.display_name.eq_ignore_ascii_case(query)
                    || a.path.as_deref() == Some(query)
            })
            .cloned()
            .ok_or_else(|| ToolError::AppNotFound {
                query: query.into(),
            })
    }

    fn observe(
        &self,
        app: &AppSummary,
        window_id: Option<i64>,
        _scope: Option<Arc<dyn NativeHandle>>,
    ) -> ToolResult<RawObservation> {
        self.observe_entered.store(true, Ordering::SeqCst);
        // Optional cooperative block for cancellation tests.
        if let Some(gate) = self.block_on_observe.lock().clone() {
            while !gate.load(Ordering::SeqCst) {
                thread::sleep(Duration::from_millis(5));
            }
        }
        let root_h = self.mint();
        let btn_h = self.mint();
        let title = self.tree_title.lock().clone();
        Ok(RawObservation {
            app: app.clone(),
            window: WindowInfo {
                id: window_id.unwrap_or(100),
                title: Some(title.clone()),
                frame_points: Rect::new(0.0, 0.0, 800.0, 600.0),
                screenshot_pixels: None,
                scale: 1.0,
                document: None,
            },
            windows: vec![WindowSummary {
                id: Some(100),
                title: Some(title),
                frame_points: Rect::new(0.0, 0.0, 800.0, 600.0),
                focused: true,
                main: true,
                on_screen: true,
            }],
            root: RawNode {
                handle: root_h,
                role: "AXWindow".into(),
                subrole: None,
                title: Some(self.tree_title.lock().clone()),
                value: None,
                description: None,
                placeholder: None,
                identifier: None,
                enabled: true,
                focused: false,
                selected: false,
                frame: Some(Rect::new(0.0, 0.0, 800.0, 600.0)),
                actions: vec![],
                settable_attributes: vec![],
                secure: false,
                children: vec![RawNode {
                    handle: btn_h,
                    role: "AXButton".into(),
                    subrole: None,
                    title: Some("OK".into()),
                    value: None,
                    description: None,
                    placeholder: None,
                    identifier: Some("ok".into()),
                    enabled: true,
                    focused: true,
                    selected: false,
                    frame: Some(Rect::new(10.0, 10.0, 80.0, 24.0)),
                    actions: vec!["AXPress".into()],
                    settable_attributes: vec!["AXValue".into()],
                    children: vec![],
                    secure: false,
                }],
            },
            focused_handle: None,
            document: None,
        })
    }

    fn capture_window(
        &self,
        _app: &AppSummary,
        _window_id: Option<i64>,
    ) -> ToolResult<CaptureOutcome> {
        if self.capture_ok {
            Ok(CaptureOutcome::Image {
                jpeg: self.jpeg.clone(),
                width: self.jpeg_width,
                height: self.jpeg_height,
                scale: 1.0,
            })
        } else {
            // Unavailable captures never invent screenshot/image payloads.
            Ok(CaptureOutcome::Unavailable {
                reason: "test capture disabled".into(),
                capability: Some("window_capture".into()),
            })
        }
    }

    fn read_value(&self, handle: &Arc<dyn NativeHandle>) -> ToolResult<String> {
        let id = handle
            .as_any()
            .downcast_ref::<TestHandle>()
            .map(|h| h.id)
            .unwrap_or(0);
        Ok(self
            .values
            .lock()
            .get(&id)
            .cloned()
            .unwrap_or_else(|| "hello".into()))
    }

    fn perform(
        &self,
        action: NativeAction,
        _interference: semantouch_protocol::InterferencePolicy,
        _target_is_frontmost: bool,
    ) -> ToolResult<DeliveryEvidence> {
        match action {
            NativeAction::SetValue {
                handle, value, commit, ..
            } => {
                if let Some(h) = handle.as_any().downcast_ref::<TestHandle>() {
                    self.values.lock().insert(h.id, value);
                }
                Ok(DeliveryEvidence {
                    status: ActionStatus::Completed,
                    method: ActionMethod::Accessibility,
                    state_changed: true,
                    focus_changed: false,
                    focus_restored: false,
                    target_verified: true,
                    delivery_lane: "semantic".into(),
                    committed: Some(commit),
                    element_focused: None,
                    warning: None,
                })
            }
            _ => Ok(DeliveryEvidence {
                status: ActionStatus::Completed,
                method: ActionMethod::Accessibility,
                state_changed: true,
                focus_changed: false,
                focus_restored: false,
                target_verified: true,
                delivery_lane: "semantic".into(),
                committed: None,
                element_focused: None,
                warning: None,
            }),
        }
    }

    fn is_frontmost(&self, _app: &AppSummary) -> bool {
        *self.frontmost.lock()
    }

    fn frontmost_app_name(&self) -> Option<String> {
        Some("Front".into())
    }

    fn poll_wait(
        &self,
        _app: &AppSummary,
        _window_id: Option<i64>,
        _conditions: &[semantouch_protocol::WaitCondition],
    ) -> ToolResult<WaitObservation> {
        Ok(WaitObservation {
            window_title: Some(self.tree_title.lock().clone()),
            url: None,
            roles_titles_values: vec![("AXButton".into(), Some("OK".into()), None)],
        })
    }

    fn end_session(&self, _session_key: &str) -> ToolResult<()> {
        Ok(())
    }

    fn supports_process_targeted_input(&self) -> bool {
        true
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn server() -> McpServer<FakeAdapter> {
    let runtime = Runtime::with_policy(FakeAdapter::new(), PolicyEngine::with_denylist([]));
    McpServer::new(runtime)
}

fn parse(line: &str) -> Value {
    serde_json::from_str(line).unwrap_or_else(|e| panic!("parse {line:?}: {e}"))
}

fn req(id: impl Into<Value>, method: &str, params: Option<Value>) -> String {
    let mut obj = json!({
        "jsonrpc": "2.0",
        "id": id.into(),
        "method": method,
    });
    if let Some(p) = params {
        obj["params"] = p;
    }
    obj.to_string()
}

fn initialize(server: &McpServer<FakeAdapter>) {
    let reply = server
        .process(&req(0, "initialize", Some(json!({}))))
        .expect("initialize reply");
    let v = parse(&reply);
    assert!(v.get("result").is_some(), "initialize failed: {v}");
}

fn tools_call(id: i64, name: &str, arguments: Value) -> String {
    req(
        id,
        "tools/call",
        Some(json!({
            "name": name,
            "arguments": arguments,
        })),
    )
}

fn tool_error_payload(response: &Value) -> Value {
    assert!(response.get("error").is_none(), "unexpected RPC error: {response}");
    assert_eq!(response["result"]["isError"], true);
    let text = response["result"]["content"][0]["text"]
        .as_str()
        .expect("text block");
    serde_json::from_str(text).expect("tool error json")
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[test]
fn initialize_returns_protocol_and_instructions() {
    let server = server();
    let reply = server
        .process(&req(1, "initialize", Some(json!({"protocolVersion":"1999-01-01"}))))
        .unwrap();
    let v = parse(&reply);
    assert_eq!(v["id"], 1);
    assert_eq!(v["result"]["protocolVersion"], "2025-06-18");
    assert_eq!(v["result"]["serverInfo"]["name"], "semantouch");
    assert!(v["result"]["instructions"]
        .as_str()
        .unwrap()
        .contains("stale_revision"));
    assert_eq!(v["result"]["semantouch"]["toolCount"], 16);
    assert!(server.is_initialized());
}

#[test]
fn ping_requires_initialize_then_succeeds() {
    let server = server();
    let before = parse(&server.process(&req(3, "ping", None)).unwrap());
    assert_eq!(
        before["error"]["code"],
        error_code::SERVER_NOT_INITIALIZED
    );

    initialize(&server);
    let after = parse(&server.process(&req(4, "ping", None)).unwrap());
    assert_eq!(after["result"], json!({}));
    assert!(after.get("error").is_none());
}

#[test]
fn tools_list_matches_enabled_catalog_order() {
    let server = server();
    initialize(&server);
    let reply = parse(&server.process(&req(1, "tools/list", None)).unwrap());
    let tools = reply["result"]["tools"].as_array().unwrap();
    let names: Vec<&str> = tools
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(names.len(), 16);
    assert_eq!(names, enabled_tool_names());
    // Each descriptor has annotations + inputSchema.
    for t in tools {
        assert!(t.get("inputSchema").is_some());
        assert!(t.get("annotations").is_some());
        assert!(t["annotations"].get("readOnlyHint").is_some());
    }
}

#[test]
fn invalid_params_and_unknown_method() {
    let server = server();
    initialize(&server);

    // Unknown method → -32601
    let unknown = parse(&server.process(&req(9, "does/not/exist", None)).unwrap());
    assert_eq!(unknown["error"]["code"], error_code::METHOD_NOT_FOUND);

    // tools/call missing name → -32602
    let missing_name = parse(
        &server
            .process(&req(10, "tools/call", Some(json!({}))))
            .unwrap(),
    );
    assert_eq!(
        missing_name["error"]["code"],
        error_code::INVALID_PARAMS
    );

    // tools/call non-object arguments → -32602
    let bad_args = parse(
        &server
            .process(&req(
                11,
                "tools/call",
                Some(json!({"name":"doctor","arguments":[]})),
            ))
            .unwrap(),
    );
    assert_eq!(bad_args["error"]["code"], error_code::INVALID_PARAMS);

    // Unknown tool → -32602
    let unknown_tool = parse(
        &server
            .process(&tools_call(12, "not_a_tool", json!({})))
            .unwrap(),
    );
    assert_eq!(
        unknown_tool["error"]["code"],
        error_code::INVALID_PARAMS
    );

    // Parse error → -32700 null id
    let parse_err = parse(&server.process("{ this is not json").unwrap());
    assert_eq!(parse_err["error"]["code"], error_code::PARSE_ERROR);
    assert!(parse_err["id"].is_null());

    // Missing method with id → -32600
    let invalid = parse(&server.process(r#"{"jsonrpc":"2.0","id":11}"#).unwrap());
    assert_eq!(invalid["error"]["code"], error_code::INVALID_REQUEST);
    assert_eq!(invalid["id"], 11);
}

#[test]
fn notifications_produce_no_replies() {
    let server = server();
    initialize(&server);

    assert!(server
        .process(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        .is_none());
    assert!(server
        .process(r#"{"jsonrpc":"2.0","method":"notifications/anything"}"#)
        .is_none());
    assert!(server
        .process(r#"{"jsonrpc":"2.0","method":"notifications/turn-ended","params":{"reason":"done"}}"#)
        .is_none());
    assert!(server
        .process(r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":99}}"#)
        .is_none());
    // Empty object → ignore
    assert!(server.process("{}").is_none());

    // turn-ended reaches host callback; cancelled does not.
    let seen = Arc::new(Mutex::new(Vec::<String>::new()));
    let seen2 = Arc::clone(&seen);
    server.set_on_notification(move |method, _| {
        seen2.lock().push(method.to_string());
    });
    assert!(server
        .process(r#"{"jsonrpc":"2.0","method":"notifications/turn-ended"}"#)
        .is_none());
    assert!(server
        .process(r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#)
        .is_none());
    assert!(server
        .process(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        .is_none());
    assert_eq!(seen.lock().as_slice(), &["notifications/turn-ended".to_string()]);
}

#[test]
fn tool_error_is_successful_envelope_not_rpc_error() {
    let server = server();
    initialize(&server);

    // list_apps succeeds with text content.
    let ok = parse(
        &server
            .process(&tools_call(1, "list_apps", json!({})))
            .unwrap(),
    );
    assert!(ok.get("error").is_none());
    assert_eq!(ok["result"]["isError"], false);
    assert_eq!(ok["result"]["content"][0]["type"], "text");
    let apps_text = ok["result"]["content"][0]["text"].as_str().unwrap();
    let apps: Value = serde_json::from_str(apps_text).unwrap();
    assert!(apps["apps"].as_array().unwrap().len() >= 1);

    // app_not_found is tool-level isError:true, not JSON-RPC error.
    let err = parse(
        &server
            .process(&tools_call(
                2,
                "get_app_state",
                json!({"app":"no-such-app","includeScreenshot":"never"}),
            ))
            .unwrap(),
    );
    let payload = tool_error_payload(&err);
    assert_eq!(payload["code"], "app_not_found");
    assert_eq!(err["id"], 2);

    // doctor returns ready helper info as success text.
    let doctor = parse(
        &server
            .process(&tools_call(3, "doctor", json!({})))
            .unwrap(),
    );
    assert_eq!(doctor["result"]["isError"], false);
}

#[test]
fn cancellation_before_execution_returns_cancelled_envelope() {
    let server = server();
    initialize(&server);

    // Register a token as the concurrent path would, cancel it, then handle.
    let id = json!(7);
    let token = server.cancellation().register(&id);
    token.cancel(Some("client".into()));
    assert!(token.is_cancelled());

    let request = crate::jsonrpc::RpcRequest {
        id: id.clone(),
        method: "tools/call".into(),
        params: Some(json!({
            "name": "list_apps",
            "arguments": {},
        })),
    };
    let response = server.handle_request(&request, &token);
    server.cancellation().deregister(&id, &token);

    assert!(response.get("error").is_none());
    assert_eq!(response["result"]["isError"], true);
    let text = response["result"]["content"][0]["text"].as_str().unwrap();
    let payload: Value = serde_json::from_str(text).unwrap();
    assert_eq!(payload["code"], "cancelled");
}

#[test]
fn concurrent_cancel_while_queued_latches_token() {
    // Reader-path register before enqueue: cancel while a slow prior request holds the worker.
    let adapter = FakeAdapter::new();
    let gate = Arc::new(AtomicBool::new(false));
    *adapter.block_on_observe.lock() = Some(Arc::clone(&gate));
    let runtime = Runtime::with_policy(adapter, PolicyEngine::with_denylist([]));
    let server = Arc::new(McpServer::new(runtime));

    let (out_tx, out_rx) = mpsc::channel::<Vec<u8>>();
    let output = ChannelWriter { tx: out_tx };

    let server_thread = {
        let server = Arc::clone(&server);
        thread::spawn(move || {
            // Script: initialize, slow get_app_state (id=1), tools/call list (id=2), cancel id=2, EOF.
            // Actually: initialize first needs to complete. Use process for init, then concurrent loop.
            let input = concat!(
                r#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#,
                "\n",
                r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_app_state","arguments":{"app":"Demo","includeScreenshot":"never"}}}"#,
                "\n",
                r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}"#,
                "\n",
                r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2,"reason":"client"}}"#,
                "\n",
            );
            // Release the gate after a short delay so cancel is processed while id=1 is still running
            // and id=2 is registered/queued.
            let gate2 = Arc::clone(&gate);
            thread::spawn(move || {
                thread::sleep(Duration::from_millis(50));
                // Keep blocking a bit longer so cancel lands while id=2 is still queued.
                thread::sleep(Duration::from_millis(50));
                gate2.store(true, Ordering::SeqCst);
            });
            run_server_stdio(server, Cursor::new(input.as_bytes()), output);
        })
    };

    let mut collected = Vec::new();
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    while std::time::Instant::now() < deadline {
        match out_rx.recv_timeout(Duration::from_millis(100)) {
            Ok(chunk) => collected.extend(chunk),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if server_thread.is_finished() {
                    break;
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    let _ = server_thread.join();
    // Drain remaining
    while let Ok(chunk) = out_rx.try_recv() {
        collected.extend(chunk);
    }

    let text = String::from_utf8_lossy(&collected);
    let lines: Vec<&str> = text.lines().filter(|l| !l.is_empty()).collect();
    assert!(
        lines.len() >= 3,
        "expected initialize + 2 tools/call replies, got: {text}"
    );

    let responses: Vec<Value> = lines.iter().map(|l| parse(l)).collect();
    let call2 = responses
        .iter()
        .find(|r| r["id"] == 2)
        .expect("reply for cancelled call id=2");
    // Either cancelled (preferred) or success if it raced past the cancel; assert no RPC error.
    assert!(call2.get("error").is_none(), "tool cancel must not be RPC error: {call2}");
    if call2["result"]["isError"] == true {
        let payload = tool_error_payload(call2);
        assert_eq!(payload["code"], "cancelled");
    }
}

#[test]
fn eof_drains_and_cancels_in_flight() {
    let server = Arc::new(server());
    let input = concat!(
        r#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#,
        "\n",
        r#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#,
        "\n",
    );
    let (out_tx, out_rx) = mpsc::channel::<Vec<u8>>();
    let output = ChannelWriter { tx: out_tx };
    run_server_stdio(Arc::clone(&server), Cursor::new(input.as_bytes()), output);
    let mut collected = Vec::new();
    while let Ok(chunk) = out_rx.try_recv() {
        collected.extend(chunk);
    }
    let text = String::from_utf8(collected).unwrap();
    let lines: Vec<&str> = text.lines().filter(|l| !l.is_empty()).collect();
    assert_eq!(lines.len(), 2, "expected initialize + ping: {text}");
    assert_eq!(parse(lines[1])["result"], json!({}));
    // After EOF, cancellation registry should be empty (no leaked tokens).
    assert_eq!(server.cancellation().in_flight_count(), 0);
}

#[test]
fn process_lines_sync_covers_handshake_batch() {
    let server = server();
    let replies = process_lines_sync(
        &server,
        [
            req(1, "initialize", Some(json!({}))).as_str(),
            r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            req(2, "ping", None).as_str(),
            req(3, "tools/list", None).as_str(),
        ],
    );
    assert_eq!(replies.len(), 3); // notification produces no reply
    assert_eq!(parse(&replies[1])["result"], json!({}));
    assert_eq!(
        parse(&replies[2])["result"]["tools"]
            .as_array()
            .unwrap()
            .len(),
        16
    );
}

#[test]
fn string_id_is_echoed_verbatim() {
    let server = server();
    let reply = parse(
        &server
            .process(&req("abc", "initialize", Some(json!({}))))
            .unwrap(),
    );
    assert_eq!(reply["id"], "abc");
}

#[test]
fn screenshot_emits_text_then_image_content_blocks() {
    let runtime = Runtime::with_policy(
        FakeAdapter::new().with_capture(),
        PolicyEngine::with_denylist([]),
    );
    let server = McpServer::new(runtime);
    initialize(&server);

    let reply = parse(
        &server
            .process(&tools_call(20, "screenshot", json!({"app": "Demo"})))
            .unwrap(),
    );
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(reply["result"]["isError"], false);
    let content = reply["result"]["content"].as_array().unwrap();
    assert_eq!(content.len(), 2, "text + image: {content:?}");
    assert_eq!(content[0]["type"], "text");
    assert_eq!(content[1]["type"], "image");
    assert_eq!(content[1]["mimeType"], "image/jpeg");
    assert_eq!(
        content[1]["data"],
        base64_encode(&[0xFF, 0xD8, 0xFF, 0xD9])
    );
    assert!(!content[1]["data"].as_str().unwrap().contains('\n'));

    // JSON metadata in the text block matches capture dimensions/bytes.
    let payload: Value = serde_json::from_str(content[0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(payload["screenshot"]["mimeType"], "image/jpeg");
    assert_eq!(payload["screenshot"]["width"], 10);
    assert_eq!(payload["screenshot"]["height"], 10);
    assert_eq!(payload["screenshot"]["byteLength"], 4);
}

#[test]
fn get_app_state_always_emits_image_block_with_metadata() {
    let runtime = Runtime::with_policy(
        FakeAdapter::new().with_capture(),
        PolicyEngine::with_denylist([]),
    );
    let server = McpServer::new(runtime);
    initialize(&server);

    let reply = parse(
        &server
            .process(&tools_call(
                21,
                "get_app_state",
                json!({"app": "Demo", "includeScreenshot": "always"}),
            ))
            .unwrap(),
    );
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(reply["result"]["isError"], false);
    let content = reply["result"]["content"].as_array().unwrap();
    assert_eq!(content.len(), 2, "text + image: {content:?}");
    assert_eq!(content[0]["type"], "text");
    assert_eq!(content[1]["type"], "image");
    assert_eq!(content[1]["mimeType"], "image/jpeg");
    assert_eq!(
        content[1]["data"],
        base64_encode(&[0xFF, 0xD8, 0xFF, 0xD9])
    );

    let payload: Value = serde_json::from_str(content[0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(payload["screenshot"]["mimeType"], "image/jpeg");
    assert_eq!(payload["screenshot"]["width"], 10);
    assert_eq!(payload["screenshot"]["height"], 10);
    assert_eq!(payload["screenshot"]["byteLength"], 4);
    assert!(payload.get("sessionId").is_some());
}

#[test]
fn get_app_state_never_has_no_image_block() {
    let runtime = Runtime::with_policy(
        FakeAdapter::new().with_capture(),
        PolicyEngine::with_denylist([]),
    );
    let server = McpServer::new(runtime);
    initialize(&server);

    let reply = parse(
        &server
            .process(&tools_call(
                22,
                "get_app_state",
                json!({"app": "Demo", "includeScreenshot": "never"}),
            ))
            .unwrap(),
    );
    assert_eq!(reply["result"]["isError"], false);
    let content = reply["result"]["content"].as_array().unwrap();
    assert_eq!(content.len(), 1, "no invented image when never: {content:?}");
    assert_eq!(content[0]["type"], "text");
}

#[test]
fn unavailable_capture_never_invents_image_block() {
    // Default FakeAdapter has capture_ok=false.
    let server = server();
    initialize(&server);
    let reply = parse(
        &server
            .process(&tools_call(23, "screenshot", json!({"app": "Demo"})))
            .unwrap(),
    );
    // Capability unavailable is a tool-level error envelope, not a fake image.
    assert!(reply.get("error").is_none());
    assert_eq!(reply["result"]["isError"], true);
    let content = reply["result"]["content"].as_array().unwrap();
    assert_eq!(content.len(), 1);
    assert_eq!(content[0]["type"], "text");
    let payload: Value = serde_json::from_str(content[0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(payload["code"], "capability_unavailable");
    assert!(IMAGE_CONTENT_LIMITATION.contains("never invent"));
}

#[test]
fn value_only_envelope_has_no_image_block() {
    let env = tool_output_to_envelope(json!({"screenshot": null}));
    let content = env["content"].as_array().unwrap();
    assert_eq!(content.len(), 1, "no invented image block");
    assert_eq!(content[0]["type"], "text");
}

#[test]
fn cancelled_tool_error_envelope_shape() {
    let err = ToolError::Cancelled {
        reason: Some("shutdown".into()),
    };
    let env = tool_error_to_envelope(&err);
    assert_eq!(env["isError"], true);
    let payload: Value =
        serde_json::from_str(env["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(payload["code"], "cancelled");
    assert_eq!(payload["data"]["reason"], "shutdown");
}

// ---------------------------------------------------------------------------
// Channel writer for concurrent tests
// ---------------------------------------------------------------------------

struct ChannelWriter {
    tx: mpsc::Sender<Vec<u8>>,
}

impl std::io::Write for ChannelWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let _ = self.tx.send(buf.to_vec());
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
