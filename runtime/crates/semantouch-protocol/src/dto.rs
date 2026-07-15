//! Shared wire DTOs matching ComputerUseCore.

use crate::geometry::{Point, Rect, Size};
use crate::ids::{ElementId, SessionId};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Permission grant state for doctor.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PermissionStatus {
    Granted,
    Denied,
    Unknown,
}

/// Screenshot inclusion mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScreenshotMode {
    Auto,
    Always,
    Never,
}

impl Default for ScreenshotMode {
    fn default() -> Self {
        Self::Auto
    }
}

/// Action result status.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionStatus {
    Completed,
    Rejected,
    Interrupted,
}

/// Action delivery method.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionMethod {
    Accessibility,
    Keyboard,
    Pointer,
}

/// Window correlation source.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WindowSource {
    Ax,
    Screencapturekit,
    Uia,
    Atspi,
    X11,
    Wayland,
}

/// Interference policy for fallback input.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum InterferencePolicy {
    #[serde(rename = "background-only")]
    BackgroundOnly,
    #[serde(rename = "allow-brief-focus")]
    AllowBriefFocus,
    #[serde(rename = "foreground-takeover")]
    ForegroundTakeover,
}

impl Default for InterferencePolicy {
    fn default() -> Self {
        Self::BackgroundOnly
    }
}

/// Frozen state warning codes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum StateWarningCode {
    #[serde(rename = "truncated_tree")]
    TruncatedTree,
    #[serde(rename = "screenshot_omitted")]
    ScreenshotOmitted,
    #[serde(rename = "screenshot_unavailable")]
    ScreenshotUnavailable,
    #[serde(rename = "possibly_unsettled")]
    PossiblyUnsettled,
    #[serde(rename = "low_correlation_confidence")]
    LowCorrelationConfidence,
    #[serde(rename = "diff_reset")]
    DiffReset,
    #[serde(rename = "web_content_enabled")]
    WebContentEnabled,
    #[serde(rename = "scope_ignored")]
    ScopeIgnored,
    #[serde(rename = "capability_limited")]
    CapabilityLimited,
}

impl StateWarningCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::TruncatedTree => "truncated_tree",
            Self::ScreenshotOmitted => "screenshot_omitted",
            Self::ScreenshotUnavailable => "screenshot_unavailable",
            Self::PossiblyUnsettled => "possibly_unsettled",
            Self::LowCorrelationConfidence => "low_correlation_confidence",
            Self::DiffReset => "diff_reset",
            Self::WebContentEnabled => "web_content_enabled",
            Self::ScopeIgnored => "scope_ignored",
            Self::CapabilityLimited => "capability_limited",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StateWarning {
    pub code: String,
    pub message: String,
}

impl StateWarning {
    pub fn new(code: StateWarningCode, message: impl Into<String>) -> Self {
        Self {
            code: code.as_str().to_string(),
            message: message.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSummary {
    pub id: String,
    pub display_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<i32>,
    pub is_running: bool,
    pub windows: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_used_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub use_count: Option<i32>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListAppsResult {
    pub apps: Vec<AppSummary>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchAppResult {
    pub app: AppSummary,
    pub launched: bool,
    pub recovered: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EndSessionResult {
    pub session_id: String,
    pub ended: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HelperInfo {
    pub path: String,
    pub signed: bool,
    pub version: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DoctorResult {
    pub helper: HelperInfo,
    pub accessibility: PermissionStatus,
    pub screen_recording: PermissionStatus,
    pub ready: bool,
    pub remediation: Vec<String>,
    /// Platform-neutral capability matrix (additive).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<crate::CapabilityReport>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotOptions {
    #[serde(default)]
    pub force_full_tree: bool,
    #[serde(default)]
    pub disable_diff: bool,
    #[serde(default)]
    pub include_screenshot: ScreenshotMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope_element_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_nodes: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_id: Option<i64>,
}

impl Default for SnapshotOptions {
    fn default() -> Self {
        Self {
            force_full_tree: false,
            disable_diff: false,
            include_screenshot: ScreenshotMode::Auto,
            scope_element_id: None,
            max_nodes: None,
            window_id: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowInfo {
    pub id: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub frame_points: Rect,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screenshot_pixels: Option<Size>,
    pub scale: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub document: Option<DocumentInfo>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowSummary {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub frame_points: Rect,
    pub focused: bool,
    pub main: bool,
    pub on_screen: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TreeInfo {
    pub format: String,
    pub text: String,
    pub node_count: usize,
    pub truncated: bool,
}

impl TreeInfo {
    pub fn full(text: String, node_count: usize, truncated: bool) -> Self {
        Self {
            format: crate::TREE_FORMAT.to_string(),
            text,
            node_count,
            truncated,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenshotMeta {
    pub mime_type: String,
    pub width: i32,
    pub height: i32,
    pub byte_length: usize,
}

impl Default for ScreenshotMeta {
    fn default() -> Self {
        Self {
            mime_type: "image/jpeg".into(),
            width: 0,
            height: 0,
            byte_length: 0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppState {
    pub session_id: String,
    pub app: AppSummary,
    pub window: WindowInfo,
    pub revision: i64,
    pub full: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_revision: Option<i64>,
    pub tree: TreeInfo,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screenshot: Option<ScreenshotMeta>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub focused_element_id: Option<String>,
    pub warnings: Vec<StateWarning>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub windows: Option<Vec<WindowSummary>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scope: Option<ScopeInfo>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScopeInfo {
    pub element_id: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ElementTarget {
    pub app: String,
    pub session_id: String,
    pub revision: i64,
    pub element_id: String,
}

impl ElementTarget {
    pub fn session(&self) -> Option<SessionId> {
        SessionId::parse_checked(&self.session_id)
    }

    pub fn element(&self) -> Option<ElementId> {
        ElementId::parse_checked(&self.element_id)
    }
}

/// Action evidence attached to mutating results.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionResult {
    pub status: ActionStatus,
    pub method: ActionMethod,
    pub state_changed: bool,
    pub refresh_recommended: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub warning: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub focus_changed: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub focus_restored: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_verified: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub committed: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub element_focused: Option<bool>,
    /// Delivery lane actually used (semantic / global / process-targeted).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delivery_lane: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<AppState>,
}

impl ActionResult {
    pub fn completed(method: ActionMethod, state_changed: bool) -> Self {
        Self {
            status: ActionStatus::Completed,
            method,
            state_changed,
            refresh_recommended: true,
            warning: None,
            focus_changed: None,
            focus_restored: None,
            target_verified: None,
            committed: None,
            element_focused: None,
            delivery_lane: None,
            state: None,
        }
    }

    pub fn rejected(method: ActionMethod, warning: impl Into<String>) -> Self {
        Self {
            status: ActionStatus::Rejected,
            method,
            state_changed: false,
            refresh_recommended: false,
            warning: Some(warning.into()),
            focus_changed: None,
            focus_restored: None,
            target_verified: Some(false),
            committed: None,
            element_focused: None,
            delivery_lane: None,
            state: None,
        }
    }

    pub fn interrupted(method: ActionMethod) -> Self {
        Self {
            status: ActionStatus::Interrupted,
            method,
            state_changed: true,
            refresh_recommended: true,
            warning: Some("user_interrupted".into()),
            focus_changed: None,
            focus_restored: None,
            target_verified: Some(false),
            committed: None,
            element_focused: None,
            delivery_lane: None,
            state: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WaitConditionResult {
    pub kind: String,
    pub satisfied: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WaitObserved {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WaitForResult {
    pub satisfied: bool,
    pub elapsed_ms: i64,
    pub conditions: Vec<WaitConditionResult>,
    pub observed: WaitObserved,
    pub refresh_recommended: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadTextResult {
    pub text: String,
    pub total_bytes: usize,
    pub returned_bytes: usize,
    pub truncated: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenshotResult {
    pub window: WindowInfo,
    pub screenshot: ScreenshotMeta,
    pub warnings: Vec<StateWarning>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowRef {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frame_points: Option<Rect>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<i32>,
    pub source: WindowSource,
}

/// Pure UI node used by the coordinator (platform-neutral).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UiNode {
    pub id: u64,
    pub role: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subrole: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub placeholder: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ax_identifier: Option<String>,
    pub enabled: bool,
    pub focused: bool,
    pub selected: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frame: Option<Rect>,
    pub actions: Vec<String>,
    pub settable_attributes: Vec<String>,
    pub children: Vec<UiNode>,
}

impl UiNode {
    pub fn shell(&self) -> Self {
        let mut n = self.clone();
        n.children.clear();
        n
    }

    pub fn node_count(&self) -> usize {
        1 + self.children.iter().map(|c| c.node_count()).sum::<usize>()
    }

    pub fn find(&self, id: u64) -> Option<&UiNode> {
        if self.id == id {
            return Some(self);
        }
        for child in &self.children {
            if let Some(n) = child.find(id) {
                return Some(n);
            }
        }
        None
    }
}

/// Pointer button.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MouseButton {
    Left,
    Middle,
    Right,
}

impl Default for MouseButton {
    fn default() -> Self {
        Self::Left
    }
}

/// Coordinate space for pointer actions.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CoordinateSpace {
    Window,
    Screenshot,
}

impl Default for CoordinateSpace {
    fn default() -> Self {
        Self::Window
    }
}

/// Scroll direction.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScrollDirection {
    Up,
    Down,
    Left,
    Right,
}

/// Scroll unit.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScrollBy {
    Line,
    Page,
}

impl Default for ScrollBy {
    fn default() -> Self {
        Self::Line
    }
}

/// Wait mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WaitMode {
    All,
    Any,
}

impl Default for WaitMode {
    fn default() -> Self {
        Self::All
    }
}

/// One wait_for condition (discriminated by `kind`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WaitCondition {
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title_contains: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value_contains: Option<String>,
}

/// Opaque JSON helper for tool argument passthrough in tests.
pub type JsonObject = Value;

/// A point used by coordinate actions.
pub type ActionPoint = Point;
