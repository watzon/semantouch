//! Neutral platform adapter contract.
//!
//! The coordinator owns sessions, revisions, stable IDs, diffs, policy, waits, and
//! wire encoding. Adapters only supply discovery, raw observation with live handles,
//! capture outcomes, resolved native actions, activity streams, and cleanup.

use semantouch_protocol::{
    ActionMethod, ActionResult, AppSummary, CapabilityReport, DocumentInfo, InterferencePolicy,
    MouseButton, PermissionStatus, Point, Rect, ScrollBy, ScrollDirection, ToolError, ToolResult,
    WaitCondition, WindowInfo, WindowSummary,
};
use std::any::Any;
use std::fmt;
use std::sync::Arc;
use std::time::Duration;

/// Opaque live native handle identity. Adapters box concrete handles behind this.
pub trait NativeHandle: Send + Sync + fmt::Debug {
    fn is_live(&self) -> bool;
    fn as_any(&self) -> &dyn Any;
    fn clone_handle(&self) -> Arc<dyn NativeHandle>;
}

/// A raw accessibility node before the coordinator assigns public element IDs.
#[derive(Clone, Debug)]
pub struct RawNode {
    pub handle: Arc<dyn NativeHandle>,
    pub role: String,
    pub subrole: Option<String>,
    pub title: Option<String>,
    pub value: Option<String>,
    pub description: Option<String>,
    pub placeholder: Option<String>,
    pub identifier: Option<String>,
    pub enabled: bool,
    pub focused: bool,
    pub selected: bool,
    pub frame: Option<Rect>,
    pub actions: Vec<String>,
    pub settable_attributes: Vec<String>,
    pub children: Vec<RawNode>,
    pub secure: bool,
}

impl RawNode {
    pub fn node_count(&self) -> usize {
        1 + self.children.iter().map(|c| c.node_count()).sum::<usize>()
    }
}

/// Raw observation produced by an adapter before ID assignment / diffing.
#[derive(Clone, Debug)]
pub struct RawObservation {
    pub app: AppSummary,
    pub window: WindowInfo,
    pub windows: Vec<WindowSummary>,
    pub root: RawNode,
    pub focused_handle: Option<Arc<dyn NativeHandle>>,
    pub document: Option<DocumentInfo>,
}

/// Capture outcome. Never invent a black image for an unsupported surface.
#[derive(Clone, Debug)]
pub enum CaptureOutcome {
    Image {
        jpeg: Vec<u8>,
        width: i32,
        height: i32,
        scale: f64,
    },
    Unavailable {
        reason: String,
        capability: Option<String>,
    },
    Omitted,
}

/// Resolved native action request from the coordinator to the adapter.
#[derive(Clone, Debug)]
pub enum NativeAction {
    Semantic {
        handle: Arc<dyn NativeHandle>,
        action: String,
        click_count: u32,
    },
    SetValue {
        handle: Arc<dyn NativeHandle>,
        value: String,
        commit: bool,
    },
    SelectText {
        handle: Arc<dyn NativeHandle>,
        start: u32,
        length: u32,
    },
    Scroll {
        handle: Option<Arc<dyn NativeHandle>>,
        direction: ScrollDirection,
        by: ScrollBy,
        count: f64,
        at: Option<Point>,
    },
    Click {
        handle: Option<Arc<dyn NativeHandle>>,
        at: Option<Point>,
        button: MouseButton,
        click_count: u32,
        global: Option<Point>,
    },
    PressKey {
        combo: String,
        target_pid: Option<i32>,
        focus_handle: Option<Arc<dyn NativeHandle>>,
    },
    TypeText {
        text: String,
        target_pid: Option<i32>,
        focus_handle: Option<Arc<dyn NativeHandle>>,
        settable_handle: Option<Arc<dyn NativeHandle>>,
    },
    Drag {
        from: Point,
        to: Point,
        button: MouseButton,
        global_from: Option<Point>,
        global_to: Option<Point>,
    },
}

/// Evidence returned by the adapter after attempting delivery.
#[derive(Clone, Debug)]
pub struct DeliveryEvidence {
    pub status: semantouch_protocol::ActionStatus,
    pub method: ActionMethod,
    pub state_changed: bool,
    pub focus_changed: bool,
    pub focus_restored: bool,
    pub target_verified: bool,
    pub delivery_lane: String,
    pub committed: Option<bool>,
    pub element_focused: Option<bool>,
    pub warning: Option<String>,
}

impl DeliveryEvidence {
    pub fn into_action_result(self) -> ActionResult {
        ActionResult {
            status: self.status,
            method: self.method,
            state_changed: self.state_changed,
            refresh_recommended: matches!(
                self.status,
                semantouch_protocol::ActionStatus::Completed
                    | semantouch_protocol::ActionStatus::Interrupted
            ),
            warning: self.warning,
            focus_changed: Some(self.focus_changed),
            focus_restored: Some(self.focus_restored),
            target_verified: Some(self.target_verified),
            committed: self.committed,
            element_focused: self.element_focused,
            delivery_lane: Some(self.delivery_lane),
            state: None,
        }
    }
}

/// Launch request.
#[derive(Clone, Debug)]
pub struct LaunchRequest {
    pub app: String,
    pub activate: bool,
    pub wait_for_window: Duration,
}

/// Launch outcome.
#[derive(Clone, Debug)]
pub struct LaunchOutcome {
    pub app: AppSummary,
    pub launched: bool,
    pub recovered: bool,
}

/// Lightweight observation for wait_for polling (no ID mutation).
#[derive(Clone, Debug, Default)]
pub struct WaitObservation {
    pub window_title: Option<String>,
    pub url: Option<String>,
    pub roles_titles_values: Vec<(String, Option<String>, Option<String>)>,
}

/// Doctor / permission snapshot from the adapter.
#[derive(Clone, Debug)]
pub struct PermissionSnapshot {
    pub accessibility: PermissionStatus,
    pub screen_capture: PermissionStatus,
    pub helper_path: String,
    pub signed: bool,
    pub remediation: Vec<String>,
    pub capabilities: CapabilityReport,
}

/// Platform adapter: one implementation per OS family.
pub trait PlatformAdapter: Send + Sync {
    fn platform_name(&self) -> &'static str;

    fn permissions(&self) -> ToolResult<PermissionSnapshot>;

    fn list_apps(&self) -> ToolResult<Vec<AppSummary>>;

    fn launch_app(&self, request: LaunchRequest) -> ToolResult<LaunchOutcome>;

    /// Resolve the app query to a single summary or typed error.
    fn resolve_app(&self, query: &str) -> ToolResult<AppSummary>;

    /// Capture a raw accessibility tree for the resolved app/window.
    fn observe(
        &self,
        app: &AppSummary,
        window_id: Option<i64>,
        scope_handle: Option<Arc<dyn NativeHandle>>,
    ) -> ToolResult<RawObservation>;

    fn capture_window(
        &self,
        app: &AppSummary,
        window_id: Option<i64>,
    ) -> ToolResult<CaptureOutcome>;

    fn read_value(&self, handle: &Arc<dyn NativeHandle>) -> ToolResult<String>;

    fn perform(
        &self,
        action: NativeAction,
        interference: InterferencePolicy,
        target_is_frontmost: bool,
    ) -> ToolResult<DeliveryEvidence>;

    fn is_frontmost(&self, app: &AppSummary) -> bool;

    fn frontmost_app_name(&self) -> Option<String>;

    /// Cheap poll used by wait_for — must not mint/retire IDs.
    fn poll_wait(
        &self,
        app: &AppSummary,
        window_id: Option<i64>,
        conditions: &[WaitCondition],
    ) -> ToolResult<WaitObservation>;

    /// Release any adapter-side resources for a session.
    fn end_session(&self, session_key: &str) -> ToolResult<()>;

    /// Map a coordinator ElementId numeric handle lookup key used during a pass.
    /// Default: adapters don't need this; coordinator stores Arc handles itself.
    fn supports_process_targeted_input(&self) -> bool {
        false
    }
}

/// Helper: map missing capability into a typed tool error.
pub fn capability_unavailable(
    platform: &str,
    capability: &str,
    detail: impl Into<String>,
) -> ToolError {
    ToolError::CapabilityUnavailable {
        capability: capability.into(),
        platform: platform.into(),
        detail: Some(detail.into()),
    }
}

/// Test double handle.
#[derive(Debug)]
pub struct FakeHandle {
    pub id: u64,
    pub live: std::sync::atomic::AtomicBool,
}

impl FakeHandle {
    pub fn new(id: u64) -> Arc<Self> {
        Arc::new(Self {
            id,
            live: std::sync::atomic::AtomicBool::new(true),
        })
    }

    pub fn kill(&self) {
        self.live.store(false, std::sync::atomic::Ordering::SeqCst);
    }
}

impl NativeHandle for FakeHandle {
    fn is_live(&self) -> bool {
        self.live.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn clone_handle(&self) -> Arc<dyn NativeHandle> {
        // Can't Arc::clone through &self without knowing Arc; use new shared state.
        // For tests, identity is the id + live flag on the same allocation when
        // constructed via Arc. Callers should Arc::clone the Arc itself.
        FakeHandle::new(self.id)
    }
}

/// Convenience: cast Arc to FakeHandle id in tests.
pub fn fake_id(handle: &Arc<dyn NativeHandle>) -> Option<u64> {
    handle.as_any().downcast_ref::<FakeHandle>().map(|h| h.id)
}
