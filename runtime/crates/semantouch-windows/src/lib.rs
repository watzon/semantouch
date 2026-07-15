//! Windows platform adapter.
//!
//! On `cfg(windows)` this crate talks to real UI Automation, Win32 input, and
//! Windows Graphics Capture APIs through the `windows` crate. On other hosts the
//! crate still compiles as a thin capability report so the workspace builds on
//! macOS CI, but construction of the live adapter is Windows-only.

use semantouch_adapter::{
    CaptureOutcome, DeliveryEvidence, LaunchOutcome, LaunchRequest, NativeAction, NativeHandle,
    PermissionSnapshot, PlatformAdapter, RawObservation, WaitObservation,
};
#[cfg(not(windows))]
use semantouch_adapter::capability_unavailable;
use semantouch_protocol::{
    AppSummary, CapabilityEntry, CapabilityKey, CapabilityReport, CapabilityStatus,
    InterferencePolicy, PlatformKind, ToolResult, WaitCondition,
};
#[cfg(not(windows))]
use semantouch_protocol::PermissionStatus;
#[cfg(test)]
use semantouch_protocol::ToolError;
use std::sync::Arc;

#[cfg(windows)]
mod native;

/// Windows adapter entry point.
pub struct WindowsAdapter {
    #[cfg(windows)]
    inner: native::WindowsNative,
    #[cfg(not(windows))]
    _private: (),
}

impl WindowsAdapter {
    /// Create a live Windows adapter. On non-Windows hosts this returns a typed
    /// capability error — never a silent mock success path.
    pub fn new() -> ToolResult<Self> {
        #[cfg(windows)]
        {
            Ok(Self {
                inner: native::WindowsNative::new()?,
            })
        }
        #[cfg(not(windows))]
        {
            Err(capability_unavailable(
                "windows",
                "ui_automation",
                "WindowsAdapter::new requires cfg(windows); host is not Windows",
            ))
        }
    }

    /// Capability matrix that can be inspected on any host.
    pub fn static_capabilities() -> CapabilityReport {
        CapabilityReport {
            platform: PlatformKind::Windows,
            entries: vec![
                CapabilityEntry::available(CapabilityKey::UiAutomation),
                CapabilityEntry::available(CapabilityKey::AccessibilityTree),
                CapabilityEntry::available(CapabilityKey::StableElementIds),
                CapabilityEntry::available(CapabilityKey::IncrementalDiff),
                CapabilityEntry::available(CapabilityKey::WindowsGraphicsCapture),
                CapabilityEntry::available(CapabilityKey::WindowCapture),
                CapabilityEntry {
                    key: CapabilityKey::OccludedWindowCapture,
                    status: CapabilityStatus::Degraded,
                    detail: Some(
                        "WGC can capture many occluded HWNDs; protected/fullscreen surfaces may fail"
                            .into(),
                    ),
                },
                CapabilityEntry::available(CapabilityKey::SemanticActions),
                CapabilityEntry::available(CapabilityKey::PointerInput),
                CapabilityEntry::available(CapabilityKey::KeyboardInput),
                CapabilityEntry {
                    key: CapabilityKey::ProcessTargetedInput,
                    status: CapabilityStatus::Unavailable,
                    detail: Some(
                        "Win32 SendInput is session-global; focus policy required for delivery"
                            .into(),
                    ),
                },
                CapabilityEntry::available(CapabilityKey::AppLaunch),
                CapabilityEntry::available(CapabilityKey::AppList),
                CapabilityEntry::available(CapabilityKey::WaitFor),
                CapabilityEntry::available(CapabilityKey::ReadText),
            ],
            limitations: vec![
                "Not GA: requires interactive Windows fixture proof and Authenticode release."
                    .into(),
                "UIA patterns map to semantic actions; unsupported patterns return unsupported_action."
                    .into(),
                "Graphics Capture failures return screenshot_unavailable / capability_unavailable — never a black frame."
                    .into(),
            ],
        }
    }
}

impl PlatformAdapter for WindowsAdapter {
    fn platform_name(&self) -> &'static str {
        "windows"
    }

    fn permissions(&self) -> ToolResult<PermissionSnapshot> {
        #[cfg(windows)]
        {
            self.inner.permissions()
        }
        #[cfg(not(windows))]
        {
            Ok(PermissionSnapshot {
                accessibility: PermissionStatus::Unknown,
                screen_capture: PermissionStatus::Unknown,
                helper_path: std::env::current_exe()
                    .map(|p| p.display().to_string())
                    .unwrap_or_else(|_| "semantouch".into()),
                signed: false,
                remediation: vec![
                    "Build and run on Windows to probe UI Automation and Graphics Capture."
                        .into(),
                ],
                capabilities: Self::static_capabilities(),
            })
        }
    }

    fn list_apps(&self) -> ToolResult<Vec<AppSummary>> {
        #[cfg(windows)]
        {
            self.inner.list_apps()
        }
        #[cfg(not(windows))]
        {
            Err(capability_unavailable(
                "windows",
                "app_list",
                "list_apps requires a live Windows session",
            ))
        }
    }

    fn launch_app(&self, request: LaunchRequest) -> ToolResult<LaunchOutcome> {
        #[cfg(windows)]
        {
            self.inner.launch_app(request)
        }
        #[cfg(not(windows))]
        {
            let _ = request;
            Err(capability_unavailable(
                "windows",
                "app_launch",
                "launch_app requires a live Windows session",
            ))
        }
    }

    fn resolve_app(&self, query: &str) -> ToolResult<AppSummary> {
        #[cfg(windows)]
        {
            self.inner.resolve_app(query)
        }
        #[cfg(not(windows))]
        {
            let _ = query;
            Err(capability_unavailable(
                "windows",
                "app_list",
                "resolve_app requires a live Windows session",
            ))
        }
    }

    fn observe(
        &self,
        app: &AppSummary,
        window_id: Option<i64>,
        scope_handle: Option<Arc<dyn NativeHandle>>,
    ) -> ToolResult<RawObservation> {
        #[cfg(windows)]
        {
            self.inner.observe(app, window_id, scope_handle)
        }
        #[cfg(not(windows))]
        {
            let _ = (app, window_id, scope_handle);
            Err(capability_unavailable(
                "windows",
                "ui_automation",
                "observe requires a live Windows session",
            ))
        }
    }

    fn capture_window(
        &self,
        app: &AppSummary,
        window_id: Option<i64>,
    ) -> ToolResult<CaptureOutcome> {
        #[cfg(windows)]
        {
            self.inner.capture_window(app, window_id)
        }
        #[cfg(not(windows))]
        {
            let _ = (app, window_id);
            Ok(CaptureOutcome::Unavailable {
                reason: "Windows Graphics Capture requires cfg(windows)".into(),
                capability: Some("windows_graphics_capture".into()),
            })
        }
    }

    fn read_value(&self, handle: &Arc<dyn NativeHandle>) -> ToolResult<String> {
        #[cfg(windows)]
        {
            self.inner.read_value(handle)
        }
        #[cfg(not(windows))]
        {
            let _ = handle;
            Err(capability_unavailable(
                "windows",
                "read_text",
                "read_value requires a live Windows session",
            ))
        }
    }

    fn perform(
        &self,
        action: NativeAction,
        interference: InterferencePolicy,
        target_is_frontmost: bool,
    ) -> ToolResult<DeliveryEvidence> {
        #[cfg(windows)]
        {
            self.inner
                .perform(action, interference, target_is_frontmost)
        }
        #[cfg(not(windows))]
        {
            let _ = (action, interference, target_is_frontmost);
            Err(capability_unavailable(
                "windows",
                "semantic_actions",
                "perform requires a live Windows session",
            ))
        }
    }

    fn is_frontmost(&self, app: &AppSummary) -> bool {
        #[cfg(windows)]
        {
            self.inner.is_frontmost(app)
        }
        #[cfg(not(windows))]
        {
            let _ = app;
            false
        }
    }

    fn frontmost_app_name(&self) -> Option<String> {
        #[cfg(windows)]
        {
            self.inner.frontmost_app_name()
        }
        #[cfg(not(windows))]
        {
            None
        }
    }

    fn poll_wait(
        &self,
        app: &AppSummary,
        window_id: Option<i64>,
        conditions: &[WaitCondition],
    ) -> ToolResult<WaitObservation> {
        #[cfg(windows)]
        {
            self.inner.poll_wait(app, window_id, conditions)
        }
        #[cfg(not(windows))]
        {
            let _ = (app, window_id, conditions);
            Err(capability_unavailable(
                "windows",
                "wait_for",
                "poll_wait requires a live Windows session",
            ))
        }
    }

    fn end_session(&self, session_key: &str) -> ToolResult<()> {
        #[cfg(windows)]
        {
            self.inner.end_session(session_key)
        }
        #[cfg(not(windows))]
        {
            let _ = session_key;
            Ok(())
        }
    }

    fn supports_process_targeted_input(&self) -> bool {
        // Win32 SendInput is not pid-targeted; focus policy is required.
        false
    }
}

/// Compile-time documentation of the Windows integration surface.
#[allow(dead_code)]
mod integration_notes {
    //! Real API surface (cfg(windows)):
    //! - `IUIAutomation` / `IUIAutomationElement` tree walk + Invoke/Value/Scroll patterns
    //! - `EnumWindows` + process snapshot for app/window discovery
    //! - `CreateProcessW` / `ShellExecuteExW` for launch
    //! - `SendInput` for pointer/keyboard fallback under interference policy
    //! - Windows Graphics Capture (`GraphicsCaptureItem` for HWND) for screenshots
    //!
    //! Fail-closed rules:
    //! - Missing UIA pattern → `unsupported_action`
    //! - Capture item creation failure → `CaptureOutcome::Unavailable`
    //! - Non-frontmost + background-only → coordinator returns `focus_required`
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn static_capabilities_name_windows_and_limitations() {
        let report = WindowsAdapter::static_capabilities();
        assert_eq!(report.platform, PlatformKind::Windows);
        assert!(report.is_available(CapabilityKey::UiAutomation));
        assert!(!report.limitations.is_empty());
        assert_eq!(
            report.status_of(CapabilityKey::ProcessTargetedInput),
            Some(CapabilityStatus::Unavailable)
        );
    }

    #[cfg(not(windows))]
    #[test]
    fn non_windows_new_is_typed_unavailable() {
        match WindowsAdapter::new() {
            Ok(_) => panic!("expected capability_unavailable off Windows"),
            Err(ToolError::CapabilityUnavailable { capability, .. }) => {
                assert_eq!(capability, "ui_automation");
            }
            Err(other) => panic!("expected capability_unavailable, got {other:?}"),
        }
    }
}
