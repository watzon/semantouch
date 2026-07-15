//! Tool-level error codes (§6). Delivered inside a successful `tools/call` with
//! `isError: true`, never as JSON-RPC layer errors.

use crate::dto::{AppSummary, WindowRef};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Frozen tool-level error codes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    PermissionDenied,
    AppNotFound,
    AmbiguousApp,
    WindowNotFound,
    AmbiguousWindow,
    UncorrelatedWindow,
    UncapturableWindow,
    StaleRevision,
    StaleElement,
    UnsupportedAction,
    FocusRequired,
    UserInterrupted,
    PolicyDenied,
    Timeout,
    Cancelled,
    InternalError,
    /// Capability not available on this platform/session (typed, not a silent no-op).
    CapabilityUnavailable,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PermissionDenied => "permission_denied",
            Self::AppNotFound => "app_not_found",
            Self::AmbiguousApp => "ambiguous_app",
            Self::WindowNotFound => "window_not_found",
            Self::AmbiguousWindow => "ambiguous_window",
            Self::UncorrelatedWindow => "uncorrelated_window",
            Self::UncapturableWindow => "uncapturable_window",
            Self::StaleRevision => "stale_revision",
            Self::StaleElement => "stale_element",
            Self::UnsupportedAction => "unsupported_action",
            Self::FocusRequired => "focus_required",
            Self::UserInterrupted => "user_interrupted",
            Self::PolicyDenied => "policy_denied",
            Self::Timeout => "timeout",
            Self::Cancelled => "cancelled",
            Self::InternalError => "internal_error",
            Self::CapabilityUnavailable => "capability_unavailable",
        }
    }
}

/// Permission names used in `permission_denied`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Permission {
    Accessibility,
    ScreenRecording,
    /// Windows UI Automation / accessibility access.
    UiAutomation,
    /// Linux AT-SPI bus access.
    AtSpi,
    /// Portal / capture permission.
    ScreenCapture,
}

impl Permission {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Accessibility => "accessibility",
            Self::ScreenRecording => "screenRecording",
            Self::UiAutomation => "uiAutomation",
            Self::AtSpi => "atSpi",
            Self::ScreenCapture => "screenCapture",
        }
    }
}

/// `uncapturable_window.data.reason`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UncapturableReason {
    Minimized,
    Offscreen,
    Protected,
    Stale,
    UnsupportedSurface,
}

/// `policy_denied.data.reason`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PolicyDenyReason {
    ToolDisabled,
    AppDenied,
    RecursiveControl,
    ActionConfirmationRequired,
}

/// Structured tool failure.
#[derive(Clone, Debug, PartialEq, Error)]
pub enum ToolError {
    #[error("permission denied: {permission:?}")]
    PermissionDenied {
        permission: Permission,
        helper_path: String,
        remediation: Vec<String>,
    },
    #[error("app not found: {query}")]
    AppNotFound { query: String },
    #[error("ambiguous app: {query}")]
    AmbiguousApp {
        query: String,
        candidates: Vec<AppSummary>,
    },
    #[error("window not found for {app}")]
    WindowNotFound { app: String, window_id: Option<i64> },
    #[error("ambiguous window for {app}")]
    AmbiguousWindow {
        app: String,
        candidates: Vec<WindowRef>,
    },
    #[error("uncorrelated window for {app}")]
    UncorrelatedWindow {
        app: String,
        ax: Option<WindowRef>,
        sc: Option<WindowRef>,
        signals_tried: Vec<String>,
    },
    #[error("uncapturable window {window_id} for {app}")]
    UncapturableWindow {
        app: String,
        window_id: i64,
        reason: UncapturableReason,
    },
    #[error("stale revision for {session_id}: provided {provided}, current {current:?}")]
    StaleRevision {
        session_id: String,
        provided: i64,
        current: Option<i64>,
    },
    #[error("stale element {element_id} in {session_id}@{revision}")]
    StaleElement {
        session_id: String,
        element_id: String,
        revision: i64,
    },
    #[error("unsupported action on {element_id}")]
    UnsupportedAction {
        element_id: String,
        action: Option<String>,
        supported: Vec<String>,
        reason: Option<String>,
    },
    #[error("focus required for fallback input")]
    FocusRequired {
        app: Option<String>,
        frontmost_app: Option<String>,
    },
    #[error("user interrupted")]
    UserInterrupted { at: Option<String> },
    #[error("policy denied: {reason:?}")]
    PolicyDenied {
        reason: PolicyDenyReason,
        app: Option<String>,
        tool: Option<String>,
    },
    #[error("timeout: {operation}")]
    Timeout { operation: String, deadline_ms: i64 },
    #[error("cancelled")]
    Cancelled { reason: Option<String> },
    #[error("internal error: {detail:?}")]
    InternalError { detail: Option<String> },
    #[error("capability unavailable: {capability}")]
    CapabilityUnavailable {
        capability: String,
        platform: String,
        detail: Option<String>,
    },
}

impl ToolError {
    pub fn code(&self) -> ErrorCode {
        match self {
            Self::PermissionDenied { .. } => ErrorCode::PermissionDenied,
            Self::AppNotFound { .. } => ErrorCode::AppNotFound,
            Self::AmbiguousApp { .. } => ErrorCode::AmbiguousApp,
            Self::WindowNotFound { .. } => ErrorCode::WindowNotFound,
            Self::AmbiguousWindow { .. } => ErrorCode::AmbiguousWindow,
            Self::UncorrelatedWindow { .. } => ErrorCode::UncorrelatedWindow,
            Self::UncapturableWindow { .. } => ErrorCode::UncapturableWindow,
            Self::StaleRevision { .. } => ErrorCode::StaleRevision,
            Self::StaleElement { .. } => ErrorCode::StaleElement,
            Self::UnsupportedAction { .. } => ErrorCode::UnsupportedAction,
            Self::FocusRequired { .. } => ErrorCode::FocusRequired,
            Self::UserInterrupted { .. } => ErrorCode::UserInterrupted,
            Self::PolicyDenied { .. } => ErrorCode::PolicyDenied,
            Self::Timeout { .. } => ErrorCode::Timeout,
            Self::Cancelled { .. } => ErrorCode::Cancelled,
            Self::InternalError { .. } => ErrorCode::InternalError,
            Self::CapabilityUnavailable { .. } => ErrorCode::CapabilityUnavailable,
        }
    }

    pub fn message(&self) -> String {
        self.to_string()
    }

    /// Wire payload `{ code, message, data? }`.
    pub fn to_wire(&self) -> serde_json::Value {
        let mut obj = serde_json::json!({
            "code": self.code().as_str(),
            "message": self.message(),
        });
        if let Some(data) = self.data_value() {
            obj["data"] = data;
        }
        obj
    }

    fn data_value(&self) -> Option<serde_json::Value> {
        match self {
            Self::PermissionDenied {
                permission,
                helper_path,
                remediation,
            } => Some(serde_json::json!({
                "permission": permission.as_str(),
                "helperPath": helper_path,
                "remediation": remediation,
            })),
            Self::AppNotFound { query } => Some(serde_json::json!({ "query": query })),
            Self::AmbiguousApp { query, candidates } => Some(serde_json::json!({
                "query": query,
                "candidates": candidates,
            })),
            Self::WindowNotFound { app, window_id } => {
                let mut m = serde_json::Map::new();
                m.insert("app".into(), serde_json::Value::String(app.clone()));
                if let Some(id) = window_id {
                    m.insert("windowId".into(), serde_json::json!(id));
                }
                Some(serde_json::Value::Object(m))
            }
            Self::AmbiguousWindow { app, candidates } => Some(serde_json::json!({
                "app": app,
                "candidates": candidates,
            })),
            Self::StaleRevision {
                session_id,
                provided,
                current,
            } => Some(serde_json::json!({
                "sessionId": session_id,
                "provided": provided,
                "current": current,
            })),
            Self::StaleElement {
                session_id,
                element_id,
                revision,
            } => Some(serde_json::json!({
                "sessionId": session_id,
                "elementId": element_id,
                "revision": revision,
            })),
            Self::UnsupportedAction {
                element_id,
                action,
                supported,
                reason,
            } => {
                let mut m = serde_json::Map::new();
                m.insert(
                    "elementId".into(),
                    serde_json::Value::String(element_id.clone()),
                );
                if let Some(a) = action {
                    m.insert("action".into(), serde_json::Value::String(a.clone()));
                }
                m.insert("supported".into(), serde_json::json!(supported));
                if let Some(r) = reason {
                    m.insert("reason".into(), serde_json::Value::String(r.clone()));
                }
                Some(serde_json::Value::Object(m))
            }
            Self::FocusRequired {
                app,
                frontmost_app,
            } => {
                let mut m = serde_json::Map::new();
                if let Some(a) = app {
                    m.insert("app".into(), serde_json::Value::String(a.clone()));
                }
                if let Some(f) = frontmost_app {
                    m.insert("frontmostApp".into(), serde_json::Value::String(f.clone()));
                }
                if m.is_empty() {
                    None
                } else {
                    Some(serde_json::Value::Object(m))
                }
            }
            Self::UserInterrupted { at } => {
                at.as_ref()
                    .map(|a| serde_json::json!({ "at": a }))
            }
            Self::PolicyDenied {
                reason,
                app,
                tool,
            } => {
                let mut m = serde_json::Map::new();
                m.insert(
                    "reason".into(),
                    serde_json::Value::String(match reason {
                        PolicyDenyReason::ToolDisabled => "tool_disabled".into(),
                        PolicyDenyReason::AppDenied => "app_denied".into(),
                        PolicyDenyReason::RecursiveControl => "recursive_control".into(),
                        PolicyDenyReason::ActionConfirmationRequired => {
                            "action_confirmation_required".into()
                        }
                    }),
                );
                if let Some(a) = app {
                    m.insert("app".into(), serde_json::Value::String(a.clone()));
                }
                if let Some(t) = tool {
                    m.insert("tool".into(), serde_json::Value::String(t.clone()));
                }
                Some(serde_json::Value::Object(m))
            }
            Self::Timeout {
                operation,
                deadline_ms,
            } => Some(serde_json::json!({
                "operation": operation,
                "deadlineMs": deadline_ms,
            })),
            Self::Cancelled { reason } => reason
                .as_ref()
                .map(|r| serde_json::json!({ "reason": r })),
            Self::InternalError { detail } => detail
                .as_ref()
                .map(|d| serde_json::json!({ "detail": d })),
            Self::CapabilityUnavailable {
                capability,
                platform,
                detail,
            } => {
                let mut m = serde_json::Map::new();
                m.insert(
                    "capability".into(),
                    serde_json::Value::String(capability.clone()),
                );
                m.insert(
                    "platform".into(),
                    serde_json::Value::String(platform.clone()),
                );
                if let Some(d) = detail {
                    m.insert("detail".into(), serde_json::Value::String(d.clone()));
                }
                Some(serde_json::Value::Object(m))
            }
            Self::UncapturableWindow {
                app,
                window_id,
                reason,
            } => Some(serde_json::json!({
                "app": app,
                "windowId": window_id,
                "reason": match reason {
                    UncapturableReason::Minimized => "minimized",
                    UncapturableReason::Offscreen => "offscreen",
                    UncapturableReason::Protected => "protected",
                    UncapturableReason::Stale => "stale",
                    UncapturableReason::UnsupportedSurface => "unsupported_surface",
                },
            })),
            Self::UncorrelatedWindow {
                app,
                ax,
                sc,
                signals_tried,
            } => Some(serde_json::json!({
                "app": app,
                "ax": ax,
                "sc": sc,
                "signalsTried": signals_tried,
            })),
        }
    }
}

pub type ToolResult<T> = Result<T, ToolError>;
