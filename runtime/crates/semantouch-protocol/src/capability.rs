//! Typed platform capabilities and limitations.
//!
//! Adapters report what they can actually do. The coordinator never invents success for
//! an unavailable portal, compositor, capture, or input path.

use serde::{Deserialize, Serialize};

/// High-level platform identity for capability reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlatformKind {
    Macos,
    Windows,
    Linux,
    Unknown,
}

impl PlatformKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Macos => "macos",
            Self::Windows => "windows",
            Self::Linux => "linux",
            Self::Unknown => "unknown",
        }
    }
}

/// Discrete capability keys adapters may expose.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CapabilityKey {
    AccessibilityTree,
    StableElementIds,
    IncrementalDiff,
    WindowCapture,
    OccludedWindowCapture,
    SemanticActions,
    PointerInput,
    KeyboardInput,
    ProcessTargetedInput,
    AppLaunch,
    AppList,
    WaitFor,
    ReadText,
    X11Capture,
    X11Input,
    WaylandPortalCapture,
    WaylandPortalInput,
    UiAutomation,
    WindowsGraphicsCapture,
    AtSpi,
}

impl CapabilityKey {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AccessibilityTree => "accessibility_tree",
            Self::StableElementIds => "stable_element_ids",
            Self::IncrementalDiff => "incremental_diff",
            Self::WindowCapture => "window_capture",
            Self::OccludedWindowCapture => "occluded_window_capture",
            Self::SemanticActions => "semantic_actions",
            Self::PointerInput => "pointer_input",
            Self::KeyboardInput => "keyboard_input",
            Self::ProcessTargetedInput => "process_targeted_input",
            Self::AppLaunch => "app_launch",
            Self::AppList => "app_list",
            Self::WaitFor => "wait_for",
            Self::ReadText => "read_text",
            Self::X11Capture => "x11_capture",
            Self::X11Input => "x11_input",
            Self::WaylandPortalCapture => "wayland_portal_capture",
            Self::WaylandPortalInput => "wayland_portal_input",
            Self::UiAutomation => "ui_automation",
            Self::WindowsGraphicsCapture => "windows_graphics_capture",
            Self::AtSpi => "at_spi",
        }
    }
}

/// Availability of one capability.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CapabilityStatus {
    Available,
    Unavailable,
    RequiresPermission,
    RequiresSession,
    Degraded,
}

/// One capability row in doctor / capability probes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityEntry {
    pub key: CapabilityKey,
    pub status: CapabilityStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl CapabilityEntry {
    pub fn available(key: CapabilityKey) -> Self {
        Self {
            key,
            status: CapabilityStatus::Available,
            detail: None,
        }
    }

    pub fn unavailable(key: CapabilityKey, detail: impl Into<String>) -> Self {
        Self {
            key,
            status: CapabilityStatus::Unavailable,
            detail: Some(detail.into()),
        }
    }

    pub fn requires_permission(key: CapabilityKey, detail: impl Into<String>) -> Self {
        Self {
            key,
            status: CapabilityStatus::RequiresPermission,
            detail: Some(detail.into()),
        }
    }
}

/// Aggregate platform capability report.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityReport {
    pub platform: PlatformKind,
    pub entries: Vec<CapabilityEntry>,
    /// Free-form limitations the coordinator should surface (never silent).
    pub limitations: Vec<String>,
}

impl CapabilityReport {
    pub fn is_available(&self, key: CapabilityKey) -> bool {
        self.entries
            .iter()
            .any(|e| e.key == key && e.status == CapabilityStatus::Available)
    }

    pub fn status_of(&self, key: CapabilityKey) -> Option<CapabilityStatus> {
        self.entries.iter().find(|e| e.key == key).map(|e| e.status)
    }
}
