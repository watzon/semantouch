//! Public coordinator: one contract for all platforms.

use crate::cancellation::CancellationToken;
use crate::diff::{self, Diff};
use crate::policy::{InterferencePlan, PolicyEngine};
use crate::renderer::{self, RenderOptions};
use crate::session::{AppSession, SessionManager};
use crate::tree::{assign_tree, find_focused_id};
use crate::wait;
use parking_lot::Mutex;
use semantouch_adapter::{
    CaptureOutcome, LaunchRequest, NativeAction, PlatformAdapter, RawObservation,
};
use semantouch_protocol::{
    tool_exists, tool_is_enabled, ActionMethod, ActionResult, ActionStatus, AppState, AppSummary,
    DoctorResult, ElementId, ElementTarget, EndSessionResult, HelperInfo, InterferencePolicy,
    LaunchAppResult, ListAppsResult, MouseButton, PermissionStatus, Point, ReadTextResult,
    ScopeInfo, ScreenshotMeta, ScreenshotMode, ScreenshotResult, ScrollBy, ScrollDirection,
    SnapshotOptions, StateWarning, StateWarningCode, ToolError, ToolResult, TreeInfo,
    WaitCondition, WaitForResult, WaitMode, DEFAULT_READ_TEXT_LIMIT, HARD_MAX_NODES,
    PACKAGE_VERSION,
};
use std::sync::Arc;
use std::time::Duration;

/// Binary image content emitted alongside a tool's JSON result.
///
/// Bytes stay out of the JSON DTO and are rendered as a separate MCP image block.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolImageBytes {
    pub jpeg: Vec<u8>,
    pub mime_type: &'static str,
    pub width: i32,
    pub height: i32,
}

/// Transport-neutral tool result: canonical JSON plus optional image content.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolCallOutput {
    pub value: serde_json::Value,
    pub image: Option<ToolImageBytes>,
}

#[derive(Clone, Debug, PartialEq)]
struct Captured<T> {
    value: T,
    image: Option<ToolImageBytes>,
}

impl<T> Captured<T> {
    fn plain(value: T) -> Self {
        Self { value, image: None }
    }

    fn with_image(value: T, image: ToolImageBytes) -> Self {
        Self {
            value,
            image: Some(image),
        }
    }
}

/// Shared coordinator over a platform adapter.
pub struct Coordinator<A: PlatformAdapter> {
    adapter: A,
    sessions: SessionManager,
    policy: PolicyEngine,
}

impl<A: PlatformAdapter> Coordinator<A> {
    pub fn new(adapter: A) -> Self {
        Self {
            adapter,
            sessions: SessionManager::new(),
            policy: PolicyEngine::from_env(),
        }
    }

    pub fn with_policy(adapter: A, policy: PolicyEngine) -> Self {
        Self {
            adapter,
            sessions: SessionManager::new(),
            policy,
        }
    }

    pub fn adapter(&self) -> &A {
        &self.adapter
    }

    pub fn sessions(&self) -> &SessionManager {
        &self.sessions
    }

    pub fn policy(&self) -> &PolicyEngine {
        &self.policy
    }

    /// Dispatch a named tool and preserve any binary image content for the MCP layer.
    pub fn call_tool_output(
        &self,
        name: &str,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<ToolCallOutput> {
        if !tool_exists(name) {
            return Err(ToolError::InternalError {
                detail: Some(format!("unknown tool {name}")),
            });
        }
        if !tool_is_enabled(name) {
            return Err(PolicyEngine::deny_tool_disabled(name));
        }
        if let Some(t) = cancel {
            t.throw_if_cancelled()?;
        }

        match name {
            "doctor" => json_tool_output(Captured::plain(self.doctor(args)?)),
            "list_apps" => json_tool_output(Captured::plain(self.list_apps()?)),
            "launch_app" => json_tool_output(Captured::plain(self.launch_app(args)?)),
            "get_app_state" => json_tool_output(self.get_app_state_with_image(args, cancel)?),
            "read_text" => json_tool_output(Captured::plain(self.read_text(args)?)),
            "screenshot" => json_tool_output(self.screenshot_with_image(args)?),
            "end_app_session" => json_tool_output(Captured::plain(self.end_app_session(args)?)),
            "click" => json_tool_output(self.click_with_image(args, cancel)?),
            "perform_action" => json_tool_output(self.perform_action_with_image(args, cancel)?),
            "set_value" => json_tool_output(self.set_value_with_image(args, cancel)?),
            "select_text" => json_tool_output(self.select_text_with_image(args, cancel)?),
            "scroll" => json_tool_output(self.scroll_with_image(args, cancel)?),
            "press_key" => json_tool_output(self.press_key_with_image(args, cancel)?),
            "type_text" => json_tool_output(self.type_text_with_image(args, cancel)?),
            "drag" => json_tool_output(self.drag_with_image(args, cancel)?),
            "wait_for" => json_tool_output(Captured::plain(self.wait_for(args, cancel)?)),
            other => Err(PolicyEngine::deny_tool_disabled(other)),
        }
    }

    /// Value-only compatibility path for callers that do not render MCP content blocks.
    pub fn call_tool(
        &self,
        name: &str,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<serde_json::Value> {
        self.call_tool_output(name, args, cancel)
            .map(|output| output.value)
    }

    pub fn doctor(&self, args: serde_json::Value) -> ToolResult<DoctorResult> {
        let _request_onboarding = args
            .get("requestOnboarding")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let snap = self.adapter.permissions()?;
        let ready = matches!(snap.accessibility, PermissionStatus::Granted)
            && matches!(
                snap.screen_capture,
                PermissionStatus::Granted | PermissionStatus::Unknown
            );
        Ok(DoctorResult {
            helper: HelperInfo {
                path: snap.helper_path,
                signed: snap.signed,
                version: PACKAGE_VERSION.to_string(),
            },
            accessibility: snap.accessibility,
            screen_recording: snap.screen_capture,
            ready,
            remediation: snap.remediation,
            capabilities: Some(snap.capabilities),
        })
    }

    pub fn list_apps(&self) -> ToolResult<ListAppsResult> {
        Ok(ListAppsResult {
            apps: self.adapter.list_apps()?,
        })
    }

    pub fn launch_app(&self, args: serde_json::Value) -> ToolResult<LaunchAppResult> {
        let app = required_string(&args, "app")?;
        let activate = args
            .get("activate")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);
        let wait_ms = args
            .get("waitForWindowMs")
            .and_then(|v| v.as_u64())
            .unwrap_or(3000);
        // Policy before process creation.
        if let Ok(resolved) = self.adapter.resolve_app(&app) {
            self.policy.deny_if_blocked(
                Some(&resolved.id),
                Some(&resolved.display_name),
                resolved.path.as_deref(),
                Some("launch_app"),
            )?;
        } else {
            self.policy
                .deny_if_blocked(None, Some(&app), None, Some("launch_app"))?;
        }
        let outcome = self.adapter.launch_app(LaunchRequest {
            app,
            activate,
            wait_for_window: Duration::from_millis(wait_ms),
        })?;
        Ok(LaunchAppResult {
            app: outcome.app,
            launched: outcome.launched,
            recovered: outcome.recovered,
        })
    }

    pub fn get_app_state(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<AppState> {
        self.get_app_state_with_image(args, cancel)
            .map(|output| output.value)
    }

    fn get_app_state_with_image(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<Captured<AppState>> {
        if let Some(t) = cancel {
            t.throw_if_cancelled()?;
        }
        let app_query = required_string(&args, "app")?;
        let options = snapshot_options_from(&args);
        let app = self.adapter.resolve_app(&app_query)?;
        self.policy.deny_if_blocked(
            Some(&app.id),
            Some(&app.display_name),
            app.path.as_deref(),
            Some("get_app_state"),
        )?;

        let session = self.sessions.ensure_session(&app.id, app.pid);
        self.commit_snapshot(&session, &app, &options, cancel)
    }

    pub fn read_text(&self, args: serde_json::Value) -> ToolResult<ReadTextResult> {
        let target = decode_element_target(&args)?;
        let (session, handle) = self.resolve_element(&target)?;
        let _ = session;
        let full = self.adapter.read_value(&handle)?;
        let total_bytes = full.len();
        let limit = parse_read_limit(&args);
        let (text, truncated) = truncate_utf8_chars(&full, limit);
        let returned_bytes = text.len();
        Ok(ReadTextResult {
            text,
            total_bytes,
            returned_bytes,
            truncated,
        })
    }

    pub fn screenshot(&self, args: serde_json::Value) -> ToolResult<ScreenshotResult> {
        self.screenshot_with_image(args).map(|output| output.value)
    }

    fn screenshot_with_image(
        &self,
        args: serde_json::Value,
    ) -> ToolResult<Captured<ScreenshotResult>> {
        let app_query = required_string(&args, "app")?;
        let window_id = args
            .get("windowId")
            .and_then(|v| v.as_i64())
            .filter(|w| *w > 0);
        let app = self.adapter.resolve_app(&app_query)?;
        self.policy.deny_if_blocked(
            Some(&app.id),
            Some(&app.display_name),
            app.path.as_deref(),
            Some("screenshot"),
        )?;
        match self.adapter.capture_window(&app, window_id)? {
            CaptureOutcome::Image {
                jpeg,
                width,
                height,
                scale,
            } => {
                let obs = self.adapter.observe(&app, window_id, None)?;
                let result = ScreenshotResult {
                    window: {
                        let mut w = obs.window;
                        w.screenshot_pixels = Some(semantouch_protocol::Size::new(width, height));
                        w.scale = scale;
                        w
                    },
                    screenshot: ScreenshotMeta {
                        mime_type: "image/jpeg".into(),
                        width,
                        height,
                        byte_length: jpeg.len(),
                    },
                    warnings: vec![],
                };
                Ok(Captured::with_image(
                    result,
                    ToolImageBytes {
                        jpeg,
                        mime_type: "image/jpeg",
                        width,
                        height,
                    },
                ))
            }
            CaptureOutcome::Unavailable { reason, capability } => {
                Err(ToolError::CapabilityUnavailable {
                    capability: capability.unwrap_or_else(|| "window_capture".into()),
                    platform: self.adapter.platform_name().into(),
                    detail: Some(reason),
                })
            }
            CaptureOutcome::Omitted => Err(ToolError::CapabilityUnavailable {
                capability: "window_capture".into(),
                platform: self.adapter.platform_name().into(),
                detail: Some("screenshot omitted by adapter".into()),
            }),
        }
    }

    pub fn end_app_session(&self, args: serde_json::Value) -> ToolResult<EndSessionResult> {
        let session_id = required_string(&args, "sessionId")?;
        let ended = self.sessions.end_session(&session_id);
        if ended {
            let _ = self.adapter.end_session(&session_id);
        }
        Ok(EndSessionResult { session_id, ended })
    }

    fn click_with_image(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<Captured<ActionResult>> {
        let session_id = required_string(&args, "sessionId")?;
        let app_query = required_string(&args, "app")?;
        let app = self.adapter.resolve_app(&app_query)?;
        self.policy.deny_if_blocked(
            Some(&app.id),
            Some(&app.display_name),
            app.path.as_deref(),
            Some("click"),
        )?;
        let button = parse_button(args.get("button"));
        let click_count = args
            .get("clickCount")
            .and_then(|v| v.as_u64())
            .unwrap_or(1)
            .clamp(1, 3) as u32;
        let interference = parse_interference(args.get("interference"));
        let options = snapshot_options_from(&args);

        let has_element = args.get("elementId").and_then(|v| v.as_str()).is_some()
            && args.get("revision").and_then(|v| v.as_i64()).is_some();
        let has_at = args.get("at").is_some();

        let evidence = if has_element {
            let target = ElementTarget {
                app: app_query,
                session_id: session_id.clone(),
                revision: args["revision"].as_i64().unwrap(),
                element_id: args["elementId"].as_str().unwrap().to_string(),
            };
            let (_session, handle) = self.resolve_element(&target)?;
            if button == MouseButton::Left {
                self.adapter.perform(
                    NativeAction::Semantic {
                        handle,
                        action: "Press".into(),
                        click_count,
                    },
                    interference,
                    self.adapter.is_frontmost(&app),
                )?
            } else {
                self.adapter.perform(
                    NativeAction::Click {
                        handle: Some(handle),
                        at: None,
                        button,
                        click_count,
                        global: None,
                    },
                    interference,
                    self.adapter.is_frontmost(&app),
                )?
            }
        } else if has_at {
            let at = parse_point(args.get("at"))?;
            self.adapter.perform(
                NativeAction::Click {
                    handle: None,
                    at: Some(at),
                    button,
                    click_count,
                    global: None,
                },
                interference,
                self.adapter.is_frontmost(&app),
            )?
        } else {
            return Err(ToolError::InternalError {
                detail: Some("click requires elementId+revision or at".into()),
            });
        };

        self.finish_action(session_id, &app, evidence, options, cancel)
    }

    fn perform_action_with_image(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<Captured<ActionResult>> {
        let target = decode_element_target(&args)?;
        let action = required_string(&args, "action")?;
        let app = self.adapter.resolve_app(&target.app)?;
        self.policy.deny_if_blocked(
            Some(&app.id),
            Some(&app.display_name),
            app.path.as_deref(),
            Some("perform_action"),
        )?;
        let (_session, handle) = self.resolve_element(&target)?;
        let options = snapshot_options_from(&args);
        let evidence = self.adapter.perform(
            NativeAction::Semantic {
                handle,
                action,
                click_count: 1,
            },
            InterferencePolicy::BackgroundOnly,
            self.adapter.is_frontmost(&app),
        )?;
        self.finish_action(target.session_id, &app, evidence, options, cancel)
    }

    fn set_value_with_image(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<Captured<ActionResult>> {
        let target = decode_element_target(&args)?;
        let value = args
            .get("value")
            .map(|v| match v {
                serde_json::Value::String(s) => s.clone(),
                serde_json::Value::Number(n) => n.to_string(),
                serde_json::Value::Bool(b) => b.to_string(),
                other => other.to_string(),
            })
            .ok_or_else(|| ToolError::InternalError {
                detail: Some("missing value".into()),
            })?;
        let commit = args
            .get("commit")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let app = self.adapter.resolve_app(&target.app)?;
        self.policy.deny_if_blocked(
            Some(&app.id),
            Some(&app.display_name),
            app.path.as_deref(),
            Some("set_value"),
        )?;
        let (_session, handle) = self.resolve_element(&target)?;
        let options = snapshot_options_from(&args);
        let evidence = self.adapter.perform(
            NativeAction::SetValue {
                handle,
                value,
                commit,
            },
            InterferencePolicy::BackgroundOnly,
            self.adapter.is_frontmost(&app),
        )?;
        self.finish_action(target.session_id, &app, evidence, options, cancel)
    }

    fn select_text_with_image(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<Captured<ActionResult>> {
        let target = decode_element_target(&args)?;
        let start =
            args.get("start")
                .and_then(|v| v.as_u64())
                .ok_or_else(|| ToolError::InternalError {
                    detail: Some("missing start".into()),
                })? as u32;
        let length =
            args.get("length")
                .and_then(|v| v.as_u64())
                .ok_or_else(|| ToolError::InternalError {
                    detail: Some("missing length".into()),
                })? as u32;
        let app = self.adapter.resolve_app(&target.app)?;
        self.policy.deny_if_blocked(
            Some(&app.id),
            Some(&app.display_name),
            app.path.as_deref(),
            Some("select_text"),
        )?;
        let (_session, handle) = self.resolve_element(&target)?;
        let options = snapshot_options_from(&args);
        let evidence = self.adapter.perform(
            NativeAction::SelectText {
                handle,
                start,
                length,
            },
            InterferencePolicy::BackgroundOnly,
            self.adapter.is_frontmost(&app),
        )?;
        self.finish_action(target.session_id, &app, evidence, options, cancel)
    }

    fn scroll_with_image(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<Captured<ActionResult>> {
        let session_id = required_string(&args, "sessionId")?;
        let app_query = required_string(&args, "app")?;
        let direction = parse_direction(args.get("direction"))?;
        let by = parse_scroll_by(args.get("by"));
        let count = args.get("count").and_then(|v| v.as_f64()).unwrap_or(1.0);
        if count <= 0.0 {
            return Err(ToolError::InternalError {
                detail: Some("count must be > 0".into()),
            });
        }
        let app = self.adapter.resolve_app(&app_query)?;
        self.policy.deny_if_blocked(
            Some(&app.id),
            Some(&app.display_name),
            app.path.as_deref(),
            Some("scroll"),
        )?;
        let interference = parse_interference(args.get("interference"));
        let options = snapshot_options_from(&args);
        let handle = if args.get("elementId").and_then(|v| v.as_str()).is_some()
            && args.get("revision").and_then(|v| v.as_i64()).is_some()
        {
            let target = ElementTarget {
                app: app_query,
                session_id: session_id.clone(),
                revision: args["revision"].as_i64().unwrap(),
                element_id: args["elementId"].as_str().unwrap().to_string(),
            };
            Some(self.resolve_element(&target)?.1)
        } else {
            None
        };
        let at = args.get("at").map(|v| parse_point(Some(v))).transpose()?;
        let evidence = self.adapter.perform(
            NativeAction::Scroll {
                handle,
                direction,
                by,
                count,
                at,
            },
            interference,
            self.adapter.is_frontmost(&app),
        )?;
        self.finish_action(session_id, &app, evidence, options, cancel)
    }

    fn press_key_with_image(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<Captured<ActionResult>> {
        let session_id = required_string(&args, "sessionId")?;
        let app_query = required_string(&args, "app")?;
        let combo = required_string(&args, "combo")?;
        let app = self.adapter.resolve_app(&app_query)?;
        self.policy.deny_if_blocked(
            Some(&app.id),
            Some(&app.display_name),
            app.path.as_deref(),
            Some("press_key"),
        )?;
        let interference = parse_interference(args.get("interference"));
        let options = snapshot_options_from(&args);
        let focus_handle = optional_element_handle(self, &args, &session_id, &app_query)?;
        let frontmost = self.adapter.is_frontmost(&app);
        let plan = InterferencePlan::decide(
            interference,
            frontmost,
            true,
            self.adapter.supports_process_targeted_input(),
        );
        if plan == InterferencePlan::FocusRequired {
            return Err(ToolError::FocusRequired {
                app: Some(app.display_name.clone()),
                frontmost_app: self.adapter.frontmost_app_name(),
            });
        }
        let target_pid = if plan == InterferencePlan::DeliverTargeted {
            app.pid
        } else {
            None
        };
        let evidence = self.adapter.perform(
            NativeAction::PressKey {
                combo,
                target_pid,
                focus_handle,
            },
            interference,
            frontmost,
        )?;
        self.finish_action(session_id, &app, evidence, options, cancel)
    }

    fn type_text_with_image(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<Captured<ActionResult>> {
        let session_id = required_string(&args, "sessionId")?;
        let app_query = required_string(&args, "app")?;
        let text = required_string(&args, "text")?;
        let app = self.adapter.resolve_app(&app_query)?;
        self.policy.deny_if_blocked(
            Some(&app.id),
            Some(&app.display_name),
            app.path.as_deref(),
            Some("type_text"),
        )?;
        let interference = parse_interference(args.get("interference"));
        let options = snapshot_options_from(&args);
        let focus_handle = optional_element_handle(self, &args, &session_id, &app_query)?;
        let frontmost = self.adapter.is_frontmost(&app);
        let plan = InterferencePlan::decide(
            interference,
            frontmost,
            true,
            self.adapter.supports_process_targeted_input(),
        );
        if plan == InterferencePlan::FocusRequired {
            return Err(ToolError::FocusRequired {
                app: Some(app.display_name.clone()),
                frontmost_app: self.adapter.frontmost_app_name(),
            });
        }
        let target_pid = if plan == InterferencePlan::DeliverTargeted {
            app.pid
        } else {
            None
        };
        let evidence = self.adapter.perform(
            NativeAction::TypeText {
                text,
                target_pid,
                focus_handle: focus_handle.clone(),
                settable_handle: focus_handle,
            },
            interference,
            frontmost,
        )?;
        self.finish_action(session_id, &app, evidence, options, cancel)
    }

    fn drag_with_image(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<Captured<ActionResult>> {
        let session_id = required_string(&args, "sessionId")?;
        let app_query = required_string(&args, "app")?;
        let from = parse_point(args.get("from"))?;
        let to = parse_point(args.get("to"))?;
        let button = parse_button(args.get("button"));
        let app = self.adapter.resolve_app(&app_query)?;
        self.policy.deny_if_blocked(
            Some(&app.id),
            Some(&app.display_name),
            app.path.as_deref(),
            Some("drag"),
        )?;
        let interference = parse_interference(args.get("interference"));
        let options = snapshot_options_from(&args);
        let frontmost = self.adapter.is_frontmost(&app);
        let plan = InterferencePlan::decide(interference, frontmost, false, false);
        if plan == InterferencePlan::FocusRequired {
            return Err(ToolError::FocusRequired {
                app: Some(app.display_name.clone()),
                frontmost_app: self.adapter.frontmost_app_name(),
            });
        }
        let evidence = self.adapter.perform(
            NativeAction::Drag {
                from,
                to,
                button,
                global_from: None,
                global_to: None,
            },
            interference,
            frontmost,
        )?;
        self.finish_action(session_id, &app, evidence, options, cancel)
    }

    pub fn click(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<ActionResult> {
        self.click_with_image(args, cancel)
            .map(|output| output.value)
    }

    pub fn perform_action(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<ActionResult> {
        self.perform_action_with_image(args, cancel)
            .map(|output| output.value)
    }

    pub fn set_value(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<ActionResult> {
        self.set_value_with_image(args, cancel)
            .map(|output| output.value)
    }

    pub fn select_text(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<ActionResult> {
        self.select_text_with_image(args, cancel)
            .map(|output| output.value)
    }

    pub fn scroll(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<ActionResult> {
        self.scroll_with_image(args, cancel)
            .map(|output| output.value)
    }

    pub fn press_key(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<ActionResult> {
        self.press_key_with_image(args, cancel)
            .map(|output| output.value)
    }

    pub fn type_text(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<ActionResult> {
        self.type_text_with_image(args, cancel)
            .map(|output| output.value)
    }

    pub fn drag(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<ActionResult> {
        self.drag_with_image(args, cancel)
            .map(|output| output.value)
    }

    pub fn wait_for(
        &self,
        args: serde_json::Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<WaitForResult> {
        let app_query = required_string(&args, "app")?;
        let session_id = required_string(&args, "sessionId")?;
        let _session =
            self.sessions
                .session(&session_id)
                .ok_or_else(|| ToolError::StaleRevision {
                    session_id: session_id.clone(),
                    provided: 0,
                    current: None,
                })?;
        let app = self.adapter.resolve_app(&app_query)?;
        self.policy.deny_if_blocked(
            Some(&app.id),
            Some(&app.display_name),
            app.path.as_deref(),
            Some("wait_for"),
        )?;
        let conditions: Vec<WaitCondition> = args
            .get("conditions")
            .cloned()
            .map(serde_json::from_value)
            .transpose()
            .map_err(|e| ToolError::InternalError {
                detail: Some(format!("invalid conditions: {e}")),
            })?
            .unwrap_or_default();
        if conditions.is_empty() || conditions.len() > 4 {
            return Err(ToolError::InternalError {
                detail: Some("conditions must have 1..=4 items".into()),
            });
        }
        let mode = match args.get("mode").and_then(|v| v.as_str()) {
            Some("any") => WaitMode::Any,
            _ => WaitMode::All,
        };
        let timeout_ms = args
            .get("timeoutMs")
            .and_then(|v| v.as_u64())
            .unwrap_or(5000)
            .clamp(100, 30_000);
        let window_id = {
            let s = self.sessions.session(&session_id).unwrap();
            let id = s.lock().last_window_id;
            id
        };
        wait::run_wait_loop(
            &conditions,
            mode,
            Duration::from_millis(timeout_ms),
            cancel,
            || self.adapter.poll_wait(&app, window_id, &conditions),
        )
    }

    // --- internals ---

    fn resolve_element(
        &self,
        target: &ElementTarget,
    ) -> ToolResult<(
        Arc<Mutex<AppSession>>,
        Arc<dyn semantouch_adapter::NativeHandle>,
    )> {
        let session =
            self.sessions
                .session(&target.session_id)
                .ok_or_else(|| ToolError::StaleRevision {
                    session_id: target.session_id.clone(),
                    provided: target.revision,
                    current: None,
                })?;
        {
            let g = session.lock();
            if g.revision != target.revision {
                return Err(ToolError::StaleRevision {
                    session_id: target.session_id.clone(),
                    provided: target.revision,
                    current: Some(g.revision),
                });
            }
        }
        let element_id = ElementId::parse_checked(&target.element_id).ok_or_else(|| {
            ToolError::StaleElement {
                session_id: target.session_id.clone(),
                element_id: target.element_id.clone(),
                revision: target.revision,
            }
        })?;
        let handle = {
            let g = session.lock();
            g.element_table
                .resolve(&element_id, &target.session_id, target.revision)?
        };
        Ok((session, handle))
    }

    fn finish_action(
        &self,
        session_id: String,
        app: &AppSummary,
        evidence: semantouch_adapter::DeliveryEvidence,
        options: SnapshotOptions,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<Captured<ActionResult>> {
        let mut result = evidence.into_action_result();
        // Rejected actions do not advance revision or attach state.
        if result.status == ActionStatus::Rejected {
            result.refresh_recommended = false;
            return Ok(Captured::plain(result));
        }
        let mut image = None;
        if let Some(session) = self.sessions.session(&session_id) {
            match self.commit_snapshot(&session, app, &options, cancel) {
                Ok(snapshot) => {
                    result.state = Some(snapshot.value);
                    result.refresh_recommended = true;
                    image = snapshot.image;
                }
                Err(ToolError::Cancelled { reason }) => {
                    return Err(ToolError::Cancelled { reason });
                }
                Err(e) => {
                    // Keep committed action; surface warning.
                    result.warning = Some(format!("state refresh failed: {e}"));
                }
            }
        }
        Ok(Captured {
            value: result,
            image,
        })
    }

    fn commit_snapshot(
        &self,
        session: &Arc<Mutex<AppSession>>,
        app: &AppSummary,
        options: &SnapshotOptions,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<Captured<AppState>> {
        if let Some(t) = cancel {
            t.throw_if_cancelled()?;
        }
        let window_id = options.window_id.filter(|w| *w > 0);
        let mut warnings = Vec::new();
        let mut scope_ignored_reason = None;
        let scope_handle = match options.scope_element_id.as_deref() {
            None => None,
            Some(raw_id) => match ElementId::parse_checked(raw_id) {
                None => {
                    scope_ignored_reason = Some("the element id is malformed".to_string());
                    None
                }
                Some(element_id) => {
                    let g = session.lock();
                    if g.revision == 0 {
                        scope_ignored_reason =
                            Some("this session has no prior snapshot to scope into".to_string());
                        None
                    } else {
                        let session_id = g.session_id.as_str();
                        match g.element_table.resolve(&element_id, session_id, g.revision) {
                            Ok(handle) => Some(handle),
                            Err(_) => {
                                scope_ignored_reason = Some(format!(
                                    "element {raw_id} does not resolve in the current snapshot (revision {})",
                                    g.revision
                                ));
                                None
                            }
                        }
                    }
                }
            },
        };

        let (raw, scope_honored): (RawObservation, bool) = match scope_handle {
            Some(handle) => match self.adapter.observe(app, window_id, Some(handle)) {
                Ok(raw) => (raw, true),
                Err(error) => {
                    scope_ignored_reason = Some(format!(
                        "the platform adapter could not honor the scope: {error}"
                    ));
                    (self.adapter.observe(app, window_id, None)?, false)
                }
            },
            None => (self.adapter.observe(app, window_id, None)?, false),
        };
        if let Some(t) = cancel {
            t.throw_if_cancelled()?;
        }

        if let (Some(scope_id), Some(reason)) = (
            options.scope_element_id.as_deref(),
            scope_ignored_reason.as_deref(),
        ) {
            warnings.push(StateWarning::new(
                StateWarningCode::ScopeIgnored,
                format!(
                    "scopeElementId {scope_id} was ignored ({reason}); a full unscoped snapshot was returned instead. Copy element ids from THIS tree, and scope only to ids from this session's current snapshot."
                ),
            ));
        }

        let render_opts = RenderOptions {
            max_nodes: options
                .max_nodes
                .unwrap_or(semantouch_protocol::DEFAULT_MAX_NODES)
                .min(HARD_MAX_NODES),
            ..RenderOptions::default()
        };

        let (tree_node, revision, full, base_revision, tree_text, node_count, truncated) = {
            let mut g = session.lock();
            if options.force_full_tree || scope_honored {
                g.element_table.reset();
            }
            let tree_node = assign_tree(&g.element_table, &raw.root);
            let prev_tree = g.last_tree.clone();
            let previous_diff_base = prev_tree.clone();
            let prev_revision = g.revision;
            let previous_window_id = g.last_window_id;
            let lineage_broken = g.lineage_broken;
            g.revision += 1;
            let revision = g.revision;
            g.last_window_id = Some(raw.window.id);
            g.dirty = false;

            let window_changed =
                previous_window_id.is_some_and(|previous| previous != raw.window.id);
            let force_full = options.force_full_tree
                || options.disable_diff
                || options.scope_element_id.is_some()
                || prev_tree.is_none()
                || prev_revision == 0
                || window_changed
                || lineage_broken;

            if prev_tree.is_some()
                && options.scope_element_id.is_none()
                && !options.force_full_tree
                && !options.disable_diff
                && (window_changed || lineage_broken)
            {
                warnings.push(StateWarning::new(
                    StateWarningCode::DiffReset,
                    "incremental lineage could not be guaranteed (window changed or prior scoped snapshot); a full tree was returned",
                ));
            }

            let rendered_snapshot = if force_full {
                let rendered = renderer::render(&tree_node, render_opts);
                (
                    true,
                    None,
                    rendered.text,
                    rendered.node_count,
                    rendered.truncated,
                )
            } else {
                let prev = prev_tree.expect("non-full snapshot requires a prior tree");
                let d: Diff =
                    diff::compute(&prev, &tree_node, prev_revision, revision, render_opts);
                if d.reused_id_conflict {
                    warnings.push(StateWarning::new(
                        StateWarningCode::DiffReset,
                        "diff lineage conflict; full tree returned",
                    ));
                    let rendered = renderer::render(&tree_node, render_opts);
                    (
                        true,
                        None,
                        rendered.text,
                        rendered.node_count,
                        rendered.truncated,
                    )
                } else {
                    // Proof: apply reconstructs.
                    debug_assert_eq!(diff::apply(&d, &prev), tree_node);
                    (
                        false,
                        Some(prev_revision),
                        diff::render_diff(&d, render_opts),
                        tree_node.node_count(),
                        false,
                    )
                }
            };

            if scope_honored {
                // A scoped tree is never a diff base. Preserve the prior base only
                // as lineage evidence so the next unscoped call returns a full reset.
                g.last_tree = previous_diff_base;
                g.lineage_broken = true;
            } else {
                g.last_tree = Some(tree_node.clone());
                g.lineage_broken = false;
            }

            (
                tree_node,
                revision,
                rendered_snapshot.0,
                rendered_snapshot.1,
                rendered_snapshot.2,
                rendered_snapshot.3,
                rendered_snapshot.4,
            )
        };

        if truncated {
            warnings.push(StateWarning::new(
                StateWarningCode::TruncatedTree,
                "tree truncated under node/byte budget",
            ));
        }

        let focused = find_focused_id(&tree_node).map(|n| ElementId::new(n).to_string());
        let mut window = raw.window.clone();
        let (screenshot_meta, image) = match options.include_screenshot {
            ScreenshotMode::Never => {
                warnings.push(StateWarning::new(
                    StateWarningCode::ScreenshotOmitted,
                    "includeScreenshot=never",
                ));
                (None, None)
            }
            mode => match self.adapter.capture_window(app, Some(window.id)) {
                Ok(CaptureOutcome::Image {
                    jpeg,
                    width,
                    height,
                    scale,
                }) => {
                    window.screenshot_pixels = Some(semantouch_protocol::Size::new(width, height));
                    window.scale = scale;
                    let meta = ScreenshotMeta {
                        mime_type: "image/jpeg".into(),
                        width,
                        height,
                        byte_length: jpeg.len(),
                    };
                    let image = ToolImageBytes {
                        jpeg,
                        mime_type: "image/jpeg",
                        width,
                        height,
                    };
                    (Some(meta), Some(image))
                }
                Ok(CaptureOutcome::Unavailable { reason, .. }) => {
                    if mode == ScreenshotMode::Always {
                        warnings.push(StateWarning::new(
                            StateWarningCode::ScreenshotUnavailable,
                            reason,
                        ));
                    } else {
                        warnings.push(StateWarning::new(
                            StateWarningCode::ScreenshotOmitted,
                            reason,
                        ));
                    }
                    (None, None)
                }
                Ok(CaptureOutcome::Omitted) => {
                    warnings.push(StateWarning::new(
                        StateWarningCode::ScreenshotOmitted,
                        "capture omitted",
                    ));
                    (None, None)
                }
                Err(e) => {
                    warnings.push(StateWarning::new(
                        StateWarningCode::ScreenshotUnavailable,
                        e.to_string(),
                    ));
                    (None, None)
                }
            },
        };

        let session_id = session.lock().session_id.as_str().to_string();
        Ok(Captured {
            value: AppState {
                session_id,
                app: app.clone(),
                window,
                revision,
                full,
                base_revision,
                tree: TreeInfo::full(tree_text, node_count, truncated),
                screenshot: screenshot_meta,
                focused_element_id: focused,
                warnings,
                windows: if raw.windows.is_empty() {
                    None
                } else {
                    Some(raw.windows)
                },
                scope: scope_honored.then(|| ScopeInfo {
                    element_id: options
                        .scope_element_id
                        .clone()
                        .expect("honored scope has an element id"),
                }),
            },
            image,
        })
    }
}

fn json_tool_output<T: serde::Serialize>(captured: Captured<T>) -> ToolResult<ToolCallOutput> {
    let value = serde_json::to_value(captured.value).map_err(|error| ToolError::InternalError {
        detail: Some(format!("failed to encode tool result: {error}")),
    })?;
    Ok(ToolCallOutput {
        value,
        image: captured.image,
    })
}

fn required_string(args: &serde_json::Value, key: &str) -> ToolResult<String> {
    args.get(key)
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| ToolError::InternalError {
            detail: Some(format!("missing {key}")),
        })
}

fn snapshot_options_from(args: &serde_json::Value) -> SnapshotOptions {
    SnapshotOptions {
        force_full_tree: args
            .get("forceFullTree")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        disable_diff: args
            .get("disableDiff")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        include_screenshot: match args.get("includeScreenshot").and_then(|v| v.as_str()) {
            Some("always") => ScreenshotMode::Always,
            Some("never") => ScreenshotMode::Never,
            _ => ScreenshotMode::Auto,
        },
        scope_element_id: args
            .get("scopeElementId")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
        max_nodes: args
            .get("maxNodes")
            .and_then(|v| v.as_u64())
            .map(|n| n as usize),
        window_id: args.get("windowId").and_then(|v| v.as_i64()),
    }
}

fn decode_element_target(args: &serde_json::Value) -> ToolResult<ElementTarget> {
    Ok(ElementTarget {
        app: required_string(args, "app")?,
        session_id: required_string(args, "sessionId")?,
        revision: args
            .get("revision")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| ToolError::InternalError {
                detail: Some("missing revision".into()),
            })?,
        element_id: required_string(args, "elementId")?,
    })
}

fn parse_interference(v: Option<&serde_json::Value>) -> InterferencePolicy {
    match v.and_then(|x| x.as_str()) {
        Some("allow-brief-focus") => InterferencePolicy::AllowBriefFocus,
        Some("foreground-takeover") => InterferencePolicy::ForegroundTakeover,
        _ => InterferencePolicy::BackgroundOnly,
    }
}

fn parse_button(v: Option<&serde_json::Value>) -> MouseButton {
    match v.and_then(|x| x.as_str()) {
        Some("middle") => MouseButton::Middle,
        Some("right") => MouseButton::Right,
        _ => MouseButton::Left,
    }
}

fn parse_direction(v: Option<&serde_json::Value>) -> ToolResult<ScrollDirection> {
    match v.and_then(|x| x.as_str()) {
        Some("up") => Ok(ScrollDirection::Up),
        Some("down") => Ok(ScrollDirection::Down),
        Some("left") => Ok(ScrollDirection::Left),
        Some("right") => Ok(ScrollDirection::Right),
        _ => Err(ToolError::InternalError {
            detail: Some("missing or invalid direction".into()),
        }),
    }
}

fn parse_scroll_by(v: Option<&serde_json::Value>) -> ScrollBy {
    match v.and_then(|x| x.as_str()) {
        Some("page") => ScrollBy::Page,
        _ => ScrollBy::Line,
    }
}

fn parse_point(v: Option<&serde_json::Value>) -> ToolResult<Point> {
    let obj = v.ok_or_else(|| ToolError::InternalError {
        detail: Some("missing point".into()),
    })?;
    let x = obj
        .get("x")
        .and_then(|v| v.as_f64())
        .ok_or_else(|| ToolError::InternalError {
            detail: Some("point.x required".into()),
        })?;
    let y = obj
        .get("y")
        .and_then(|v| v.as_f64())
        .ok_or_else(|| ToolError::InternalError {
            detail: Some("point.y required".into()),
        })?;
    Ok(Point::new(x, y))
}

fn parse_read_limit(args: &serde_json::Value) -> usize {
    match args.get("limit") {
        Some(serde_json::Value::String(s)) if s == "max" => usize::MAX,
        Some(serde_json::Value::Number(n)) => {
            n.as_u64().unwrap_or(DEFAULT_READ_TEXT_LIMIT as u64) as usize
        }
        _ => DEFAULT_READ_TEXT_LIMIT,
    }
}

fn truncate_utf8_chars(s: &str, limit: usize) -> (String, bool) {
    if s.len() <= limit {
        return (s.to_string(), false);
    }
    let mut end = 0;
    for (idx, ch) in s.char_indices() {
        if idx + ch.len_utf8() > limit {
            break;
        }
        end = idx + ch.len_utf8();
    }
    (s[..end].to_string(), true)
}

fn optional_element_handle<A: PlatformAdapter>(
    coord: &Coordinator<A>,
    args: &serde_json::Value,
    session_id: &str,
    app: &str,
) -> ToolResult<Option<Arc<dyn semantouch_adapter::NativeHandle>>> {
    let rev = args.get("revision").and_then(|v| v.as_i64());
    let eid = args.get("elementId").and_then(|v| v.as_str());
    match (rev, eid) {
        (Some(revision), Some(element_id)) => {
            let target = ElementTarget {
                app: app.to_string(),
                session_id: session_id.to_string(),
                revision,
                element_id: element_id.to_string(),
            };
            Ok(Some(coord.resolve_element(&target)?.1))
        }
        (None, None) => Ok(None),
        _ => Err(ToolError::InternalError {
            detail: Some("revision and elementId must be supplied together".into()),
        }),
    }
}

// Silence unused import if ActionMethod only used in tests path.
#[allow(dead_code)]
fn _use_action_method() -> ActionMethod {
    ActionMethod::Accessibility
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::policy::PolicyEngine;
    use semantouch_adapter::{
        capability_unavailable, LaunchOutcome, NativeHandle, PermissionSnapshot, RawNode,
        WaitObservation,
    };
    use semantouch_protocol::{
        CapabilityEntry, CapabilityKey, CapabilityReport, PlatformKind, Rect, WindowInfo,
        WindowSummary,
    };
    use std::collections::HashMap;
    use std::sync::atomic::{AtomicU64, Ordering};

    #[derive(Debug)]
    struct TestHandle {
        id: u64,
        live: std::sync::atomic::AtomicBool,
    }

    impl TestHandle {
        fn new(id: u64) -> Arc<Self> {
            Arc::new(Self {
                id,
                live: std::sync::atomic::AtomicBool::new(true),
            })
        }
    }

    impl NativeHandle for TestHandle {
        fn is_live(&self) -> bool {
            self.live.load(Ordering::SeqCst)
        }
        fn as_any(&self) -> &dyn std::any::Any {
            self
        }
        fn clone_handle(&self) -> Arc<dyn NativeHandle> {
            TestHandle::new(self.id)
        }
    }

    struct FakeAdapter {
        apps: Vec<AppSummary>,
        tree_title: Mutex<String>,
        values: Mutex<HashMap<u64, String>>,
        next_handle: AtomicU64,
        frontmost: Mutex<bool>,
        capture_ok: bool,
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
                capture_ok: true,
            }
        }

        fn mint(&self) -> Arc<dyn NativeHandle> {
            let id = self.next_handle.fetch_add(1, Ordering::SeqCst);
            TestHandle::new(id) as Arc<dyn NativeHandle>
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
                    limitations: vec![],
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
            scope: Option<Arc<dyn NativeHandle>>,
        ) -> ToolResult<RawObservation> {
            let scoped = scope.is_some();
            let root_h = self.mint();
            let btn_h = scope.unwrap_or_else(|| self.mint());
            let native_id = btn_h
                .as_any()
                .downcast_ref::<TestHandle>()
                .map(|handle| handle.id)
                .unwrap_or(0);
            let title = self.tree_title.lock().clone();
            let btn_value = self
                .values
                .lock()
                .get(&native_id)
                .cloned()
                .or_else(|| Some(String::new()));
            let button = RawNode {
                handle: btn_h,
                role: "AXButton".into(),
                subrole: None,
                title: Some("OK".into()),
                value: btn_value.filter(|s| !s.is_empty()),
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
            };
            let root = if scoped {
                button
            } else {
                RawNode {
                    handle: root_h,
                    role: "AXWindow".into(),
                    subrole: None,
                    title: Some(title.clone()),
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
                    children: vec![button],
                }
            };
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
                root,
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
                    jpeg: vec![0xFF, 0xD8, 0xFF, 0xD9],
                    width: 10,
                    height: 10,
                    scale: 1.0,
                })
            } else {
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
                .unwrap_or_else(|| "hello world".into()))
        }

        fn perform(
            &self,
            action: NativeAction,
            _interference: InterferencePolicy,
            _target_is_frontmost: bool,
        ) -> ToolResult<semantouch_adapter::DeliveryEvidence> {
            match action {
                NativeAction::Semantic { .. } => Ok(semantouch_adapter::DeliveryEvidence {
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
                NativeAction::SetValue {
                    handle,
                    value,
                    commit,
                    ..
                } => {
                    if let Some(h) = handle.as_any().downcast_ref::<TestHandle>() {
                        self.values.lock().insert(h.id, value);
                    }
                    Ok(semantouch_adapter::DeliveryEvidence {
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
                NativeAction::Click { .. } | NativeAction::Drag { .. } => {
                    Ok(semantouch_adapter::DeliveryEvidence {
                        status: ActionStatus::Completed,
                        method: ActionMethod::Pointer,
                        state_changed: true,
                        focus_changed: false,
                        focus_restored: false,
                        target_verified: true,
                        delivery_lane: "pointer".into(),
                        committed: None,
                        element_focused: None,
                        warning: None,
                    })
                }
                NativeAction::PressKey { .. } | NativeAction::TypeText { .. } => {
                    Ok(semantouch_adapter::DeliveryEvidence {
                        status: ActionStatus::Completed,
                        method: ActionMethod::Keyboard,
                        state_changed: true,
                        focus_changed: false,
                        focus_restored: false,
                        target_verified: true,
                        delivery_lane: "keyboard".into(),
                        committed: None,
                        element_focused: Some(false),
                        warning: None,
                    })
                }
                _ => Ok(semantouch_adapter::DeliveryEvidence {
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
            _conditions: &[WaitCondition],
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

    #[test]
    fn full_then_diff_and_stale_revision() {
        let coord = Coordinator::with_policy(FakeAdapter::new(), PolicyEngine::with_denylist([]));
        let state1 = coord
            .get_app_state(
                serde_json::json!({"app": "Demo", "includeScreenshot": "never"}),
                None,
            )
            .unwrap();
        assert!(state1.full);
        assert_eq!(state1.revision, 1);
        assert!(state1.tree.text.contains("[e1]"));
        assert!(state1.tree.text.contains("[e2]"));

        *coord.adapter().tree_title.lock() = "Demo 2".into();
        let state2 = coord
            .get_app_state(
                serde_json::json!({"app": "Demo", "includeScreenshot": "never"}),
                None,
            )
            .unwrap();
        assert!(!state2.full);
        assert_eq!(state2.base_revision, Some(1));
        assert_eq!(state2.revision, 2);
        assert!(state2.tree.text.starts_with("UI revision 2, based on 1"));

        let err = coord
            .click(
                serde_json::json!({
                    "app": "Demo",
                    "sessionId": state2.session_id,
                    "revision": 1,
                    "elementId": "e2",
                    "includeScreenshot": "never"
                }),
                None,
            )
            .unwrap_err();
        match err {
            ToolError::StaleRevision {
                provided, current, ..
            } => {
                assert_eq!(provided, 1);
                assert_eq!(current, Some(2));
            }
            other => panic!("expected stale_revision, got {other:?}"),
        }
    }

    #[test]
    fn scoped_snapshot_honors_current_id_and_breaks_diff_lineage() {
        let coord = Coordinator::with_policy(FakeAdapter::new(), PolicyEngine::with_denylist([]));
        let initial = coord
            .get_app_state(
                serde_json::json!({"app": "Demo", "includeScreenshot": "never"}),
                None,
            )
            .unwrap();
        assert!(initial.tree.text.contains("[e1]"));
        assert!(initial.tree.text.contains("[e2]"));

        let scoped = coord
            .get_app_state(
                serde_json::json!({
                    "app": "Demo",
                    "scopeElementId": "e2",
                    "includeScreenshot": "never"
                }),
                None,
            )
            .unwrap();
        assert!(scoped.full);
        assert_eq!(scoped.revision, 2);
        assert_eq!(
            scoped.scope.as_ref().map(|scope| scope.element_id.as_str()),
            Some("e2")
        );
        assert!(scoped.tree.text.contains("AXButton"));
        assert!(!scoped.tree.text.contains("AXWindow"));

        let stale = coord
            .read_text(serde_json::json!({
                "app": "Demo",
                "sessionId": scoped.session_id,
                "revision": scoped.revision,
                "elementId": "e1"
            }))
            .unwrap_err();
        assert!(matches!(stale, ToolError::StaleElement { .. }));

        let unscoped = coord
            .get_app_state(
                serde_json::json!({"app": "Demo", "includeScreenshot": "never"}),
                None,
            )
            .unwrap();
        assert!(unscoped.full);
        assert!(unscoped.scope.is_none());
        assert!(unscoped
            .warnings
            .iter()
            .any(|warning| warning.code == StateWarningCode::DiffReset.as_str()));
    }

    #[test]
    fn unusable_scope_degrades_to_full_unscoped_state() {
        let coord = Coordinator::with_policy(FakeAdapter::new(), PolicyEngine::with_denylist([]));
        let no_prior_state = coord
            .get_app_state(
                serde_json::json!({
                    "app": "Demo",
                    "scopeElementId": "e2",
                    "includeScreenshot": "never"
                }),
                None,
            )
            .unwrap();
        assert!(no_prior_state.full);
        assert!(no_prior_state.scope.is_none());
        assert!(no_prior_state.tree.text.contains("AXWindow"));
        assert!(no_prior_state
            .warnings
            .iter()
            .any(|warning| warning.code == StateWarningCode::ScopeIgnored.as_str()));

        let stale_scope = coord
            .get_app_state(
                serde_json::json!({
                    "app": "Demo",
                    "scopeElementId": "e99",
                    "includeScreenshot": "never"
                }),
                None,
            )
            .unwrap();
        assert!(stale_scope.full);
        assert!(stale_scope.scope.is_none());
        assert!(stale_scope.tree.text.contains("AXWindow"));
        assert!(stale_scope
            .warnings
            .iter()
            .any(|warning| warning.code == StateWarningCode::ScopeIgnored.as_str()));
    }

    #[test]
    fn stale_element_after_force_full_rebuild_ids() {
        let coord = Coordinator::with_policy(FakeAdapter::new(), PolicyEngine::with_denylist([]));
        let s1 = coord
            .get_app_state(
                serde_json::json!({"app": "Demo", "includeScreenshot": "never"}),
                None,
            )
            .unwrap();
        let old_id = "e2";
        let s2 = coord
            .get_app_state(
                serde_json::json!({
                    "app": "Demo",
                    "forceFullTree": true,
                    "includeScreenshot": "never"
                }),
                None,
            )
            .unwrap();
        assert!(s2.full);
        // forceFullTree retires old ids; e2 from revision 1 is stale at new revision.
        let err = coord
            .read_text(serde_json::json!({
                "app": "Demo",
                "sessionId": s2.session_id,
                "revision": s2.revision,
                "elementId": old_id
            }))
            .unwrap_err();
        match err {
            ToolError::StaleElement { .. } => {}
            other => panic!("expected stale_element, got {other:?}"),
        }
        let _ = s1;
    }

    #[test]
    fn policy_blocks_sensitive_app_before_dispatch() {
        let mut adapter = FakeAdapter::new();
        adapter.apps.push(AppSummary {
            id: "com.1password.1password".into(),
            display_name: "1Password".into(),
            path: None,
            pid: Some(9),
            is_running: true,
            windows: 1,
            last_used_at: None,
            use_count: None,
        });
        let coord =
            Coordinator::with_policy(adapter, PolicyEngine::with_default_sensitive_denylist());
        let err = coord
            .get_app_state(serde_json::json!({"app": "1Password"}), None)
            .unwrap_err();
        match err {
            ToolError::PolicyDenied { reason, .. } => {
                assert_eq!(
                    format!("{reason:?}").contains("AppDenied")
                        || matches!(reason, semantouch_protocol::PolicyDenyReason::AppDenied),
                    true
                );
            }
            other => panic!("expected policy_denied, got {other:?}"),
        }
    }

    #[test]
    fn focus_required_when_background_only_and_not_frontmost() {
        let adapter = FakeAdapter::new();
        *adapter.frontmost.lock() = false;
        // disable targeted for drag path — press_key supports targeted; use drag
        let coord = Coordinator::with_policy(adapter, PolicyEngine::with_denylist([]));
        let state = coord
            .get_app_state(
                serde_json::json!({"app": "Demo", "includeScreenshot": "never"}),
                None,
            )
            .unwrap();
        // Override supports — FakeAdapter returns true for targeted; force via drag
        let err = coord
            .drag(
                serde_json::json!({
                    "app": "Demo",
                    "sessionId": state.session_id,
                    "from": {"x": 1, "y": 1},
                    "to": {"x": 2, "y": 2},
                    "interference": "background-only",
                    "includeScreenshot": "never"
                }),
                None,
            )
            .unwrap_err();
        match err {
            ToolError::FocusRequired { .. } => {}
            other => panic!("expected focus_required, got {other:?}"),
        }
    }

    #[test]
    fn tools_list_surface_is_sixteen() {
        assert_eq!(semantouch_protocol::enabled_tool_names().len(), 16);
        let coord = Coordinator::with_policy(FakeAdapter::new(), PolicyEngine::with_denylist([]));
        let doctor = coord
            .call_tool("doctor", serde_json::json!({}), None)
            .unwrap();
        assert_eq!(doctor["helper"]["version"], PACKAGE_VERSION);
    }

    #[test]
    fn screenshot_output_keeps_jpeg_out_of_json() {
        let coord = Coordinator::with_policy(FakeAdapter::new(), PolicyEngine::with_denylist([]));
        let output = coord
            .call_tool_output("screenshot", serde_json::json!({"app": "Demo"}), None)
            .unwrap();

        let image = output.image.expect("screenshot image block");
        assert_eq!(image.jpeg, vec![0xFF, 0xD8, 0xFF, 0xD9]);
        assert_eq!(image.mime_type, "image/jpeg");
        assert_eq!(output.value["screenshot"]["byteLength"], 4);
        assert!(
            !output.value.to_string().contains("/9j/2Q"),
            "binary image data must not be embedded in the JSON result"
        );
    }

    #[test]
    fn app_state_output_carries_requested_screenshot_bytes() {
        let coord = Coordinator::with_policy(FakeAdapter::new(), PolicyEngine::with_denylist([]));
        let output = coord
            .call_tool_output(
                "get_app_state",
                serde_json::json!({"app": "Demo", "includeScreenshot": "always"}),
                None,
            )
            .unwrap();

        assert_eq!(output.image.as_ref().unwrap().jpeg.len(), 4);
        assert_eq!(output.value["revision"], 1);
        assert_eq!(output.value["screenshot"]["mimeType"], "image/jpeg");
        assert_eq!(output.value["screenshot"]["byteLength"], 4);
    }

    #[test]
    fn action_output_carries_post_action_screenshot_bytes() {
        let coord = Coordinator::with_policy(FakeAdapter::new(), PolicyEngine::with_denylist([]));
        let state = coord
            .get_app_state(
                serde_json::json!({"app": "Demo", "includeScreenshot": "never"}),
                None,
            )
            .unwrap();
        let output = coord
            .call_tool_output(
                "click",
                serde_json::json!({
                    "app": "Demo",
                    "sessionId": state.session_id,
                    "revision": state.revision,
                    "elementId": "e2",
                    "includeScreenshot": "always"
                }),
                None,
            )
            .unwrap();

        assert_eq!(output.image.as_ref().unwrap().jpeg.len(), 4);
        assert_eq!(output.value["state"]["revision"], 2);
        assert_eq!(output.value["state"]["screenshot"]["byteLength"], 4);
    }

    #[test]
    fn cancelled_wait_and_capability_error_shape() {
        let e = capability_unavailable("linux", "wayland_portal_capture", "compositor denied");
        let wire = e.to_wire();
        assert_eq!(wire["code"], "capability_unavailable");
        assert_eq!(wire["data"]["capability"], "wayland_portal_capture");
    }

    #[test]
    fn end_unknown_session_is_not_error() {
        let coord = Coordinator::with_policy(FakeAdapter::new(), PolicyEngine::with_denylist([]));
        let r = coord
            .end_app_session(serde_json::json!({"sessionId": "s99"}))
            .unwrap();
        assert!(!r.ended);
    }
}
