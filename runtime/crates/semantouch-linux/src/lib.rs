//! Linux platform adapter.
//!
//! On `cfg(target_os = "linux")` this crate uses real AT-SPI (via `atspi`/`zbus`),
//! X11 capture/input (`x11rb`), and capability-gated Wayland portal paths (`ashpd`).
//! On other hosts it still compiles for capability inspection; live construction is
//! Linux-only and fails closed with typed capability errors.

use semantouch_adapter::{
    CaptureOutcome, DeliveryEvidence, LaunchOutcome, LaunchRequest, NativeAction, NativeHandle,
    PermissionSnapshot, PlatformAdapter, RawObservation, WaitObservation,
};
#[cfg(not(target_os = "linux"))]
use semantouch_adapter::capability_unavailable;
use semantouch_protocol::{
    AppSummary, CapabilityEntry, CapabilityKey, CapabilityReport, CapabilityStatus,
    InterferencePolicy, PlatformKind, ToolResult, WaitCondition,
};
#[cfg(not(target_os = "linux"))]
use semantouch_protocol::PermissionStatus;
#[cfg(test)]
use semantouch_protocol::ToolError;
use std::sync::Arc;

#[cfg(target_os = "linux")]
mod native;

/// Detected Linux session kind for capture/input routing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinuxSessionKind {
    X11,
    Wayland,
    Unknown,
}

impl LinuxSessionKind {
    pub fn detect() -> Self {
        if std::env::var_os("WAYLAND_DISPLAY").is_some() {
            Self::Wayland
        } else if std::env::var_os("DISPLAY").is_some() {
            Self::X11
        } else {
            Self::Unknown
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::X11 => "x11",
            Self::Wayland => "wayland",
            Self::Unknown => "unknown",
        }
    }
}

pub struct LinuxAdapter {
    #[cfg(target_os = "linux")]
    inner: native::LinuxNative,
    #[cfg(not(target_os = "linux"))]
    _private: (),
}

impl LinuxAdapter {
    pub fn new() -> ToolResult<Self> {
        #[cfg(target_os = "linux")]
        {
            Ok(Self {
                inner: native::LinuxNative::new()?,
            })
        }
        #[cfg(not(target_os = "linux"))]
        {
            Err(capability_unavailable(
                "linux",
                "at_spi",
                "LinuxAdapter::new requires cfg(target_os=\"linux\")",
            ))
        }
    }

    pub fn static_capabilities() -> CapabilityReport {
        let session = LinuxSessionKind::detect();
        let mut entries = vec![
            CapabilityEntry::available(CapabilityKey::AtSpi),
            CapabilityEntry::available(CapabilityKey::AccessibilityTree),
            CapabilityEntry::available(CapabilityKey::StableElementIds),
            CapabilityEntry::available(CapabilityKey::IncrementalDiff),
            CapabilityEntry::available(CapabilityKey::SemanticActions),
            CapabilityEntry::available(CapabilityKey::AppList),
            CapabilityEntry::available(CapabilityKey::AppLaunch),
            CapabilityEntry::available(CapabilityKey::WaitFor),
            CapabilityEntry::available(CapabilityKey::ReadText),
        ];
        match session {
            LinuxSessionKind::X11 => {
                entries.push(CapabilityEntry::available(CapabilityKey::X11Capture));
                entries.push(CapabilityEntry::available(CapabilityKey::X11Input));
                entries.push(CapabilityEntry::available(CapabilityKey::WindowCapture));
                entries.push(CapabilityEntry::available(CapabilityKey::PointerInput));
                entries.push(CapabilityEntry::available(CapabilityKey::KeyboardInput));
                entries.push(CapabilityEntry::unavailable(
                    CapabilityKey::WaylandPortalCapture,
                    "session is X11; Wayland portal path idle",
                ));
                entries.push(CapabilityEntry::unavailable(
                    CapabilityKey::WaylandPortalInput,
                    "session is X11; Wayland portal path idle",
                ));
            }
            LinuxSessionKind::Wayland => {
                entries.push(CapabilityEntry {
                    key: CapabilityKey::WaylandPortalCapture,
                    status: CapabilityStatus::RequiresPermission,
                    detail: Some(
                        "XDG Desktop Portal screencast/screenshot; compositor-dependent".into(),
                    ),
                });
                entries.push(CapabilityEntry {
                    key: CapabilityKey::WaylandPortalInput,
                    status: CapabilityStatus::RequiresSession,
                    detail: Some(
                        "RemoteDesktop portal input; not claimed available without live portal grant"
                            .into(),
                    ),
                });
                entries.push(CapabilityEntry::unavailable(
                    CapabilityKey::X11Capture,
                    "session is Wayland; X11 capture path not used",
                ));
                entries.push(CapabilityEntry::unavailable(
                    CapabilityKey::X11Input,
                    "session is Wayland; X11 input path not used",
                ));
                entries.push(CapabilityEntry {
                    key: CapabilityKey::WindowCapture,
                    status: CapabilityStatus::RequiresPermission,
                    detail: Some("delegates to portal capture".into()),
                });
                entries.push(CapabilityEntry {
                    key: CapabilityKey::PointerInput,
                    status: CapabilityStatus::RequiresSession,
                    detail: Some("delegates to portal RemoteDesktop when granted".into()),
                });
                entries.push(CapabilityEntry {
                    key: CapabilityKey::KeyboardInput,
                    status: CapabilityStatus::RequiresSession,
                    detail: Some("delegates to portal RemoteDesktop when granted".into()),
                });
            }
            LinuxSessionKind::Unknown => {
                entries.push(CapabilityEntry::unavailable(
                    CapabilityKey::WindowCapture,
                    "no DISPLAY/WAYLAND_DISPLAY",
                ));
                entries.push(CapabilityEntry::unavailable(
                    CapabilityKey::PointerInput,
                    "no interactive session detected",
                ));
                entries.push(CapabilityEntry::unavailable(
                    CapabilityKey::KeyboardInput,
                    "no interactive session detected",
                ));
            }
        }
        entries.push(CapabilityEntry {
            key: CapabilityKey::OccludedWindowCapture,
            status: CapabilityStatus::Unavailable,
            detail: Some("not guaranteed on Linux compositors".into()),
        });
        entries.push(CapabilityEntry {
            key: CapabilityKey::ProcessTargetedInput,
            status: CapabilityStatus::Unavailable,
            detail: Some("no portable pid-targeted input on Linux public APIs".into()),
        });

        CapabilityReport {
            platform: PlatformKind::Linux,
            entries,
            limitations: vec![
                format!("Session kind: {}", session.as_str()),
                "Not GA: Linux GA requires named desktop/session matrix and interactive fixtures."
                    .into(),
                "Wayland capture/input remain compositor/portal capability-gated; unsupported operations return typed unavailable results."
                    .into(),
                "AT-SPI tree quality depends on application accessibility support."
                    .into(),
            ],
        }
    }

    pub fn session_kind() -> LinuxSessionKind {
        LinuxSessionKind::detect()
    }
}

impl PlatformAdapter for LinuxAdapter {
    fn platform_name(&self) -> &'static str {
        "linux"
    }

    fn permissions(&self) -> ToolResult<PermissionSnapshot> {
        #[cfg(target_os = "linux")]
        {
            self.inner.permissions()
        }
        #[cfg(not(target_os = "linux"))]
        {
            Ok(PermissionSnapshot {
                accessibility: PermissionStatus::Unknown,
                screen_capture: PermissionStatus::Unknown,
                helper_path: std::env::current_exe()
                    .map(|p| p.display().to_string())
                    .unwrap_or_else(|_| "semantouch".into()),
                signed: false,
                remediation: vec![
                    "Build and run on Linux with AT-SPI bus access.".into(),
                ],
                capabilities: Self::static_capabilities(),
            })
        }
    }

    fn list_apps(&self) -> ToolResult<Vec<AppSummary>> {
        #[cfg(target_os = "linux")]
        {
            self.inner.list_apps()
        }
        #[cfg(not(target_os = "linux"))]
        {
            Err(capability_unavailable(
                "linux",
                "app_list",
                "list_apps requires a live Linux session",
            ))
        }
    }

    fn launch_app(&self, request: LaunchRequest) -> ToolResult<LaunchOutcome> {
        #[cfg(target_os = "linux")]
        {
            self.inner.launch_app(request)
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = request;
            Err(capability_unavailable(
                "linux",
                "app_launch",
                "launch_app requires a live Linux session",
            ))
        }
    }

    fn resolve_app(&self, query: &str) -> ToolResult<AppSummary> {
        #[cfg(target_os = "linux")]
        {
            self.inner.resolve_app(query)
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = query;
            Err(capability_unavailable(
                "linux",
                "app_list",
                "resolve_app requires a live Linux session",
            ))
        }
    }

    fn observe(
        &self,
        app: &AppSummary,
        window_id: Option<i64>,
        scope_handle: Option<Arc<dyn NativeHandle>>,
    ) -> ToolResult<RawObservation> {
        #[cfg(target_os = "linux")]
        {
            self.inner.observe(app, window_id, scope_handle)
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = (app, window_id, scope_handle);
            Err(capability_unavailable(
                "linux",
                "at_spi",
                "observe requires a live Linux AT-SPI session",
            ))
        }
    }

    fn capture_window(
        &self,
        app: &AppSummary,
        window_id: Option<i64>,
    ) -> ToolResult<CaptureOutcome> {
        #[cfg(target_os = "linux")]
        {
            self.inner.capture_window(app, window_id)
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = (app, window_id);
            match LinuxSessionKind::detect() {
                LinuxSessionKind::Wayland => Ok(CaptureOutcome::Unavailable {
                    reason: "Wayland portal capture requires cfg(linux) + live portal grant".into(),
                    capability: Some("wayland_portal_capture".into()),
                }),
                LinuxSessionKind::X11 => Ok(CaptureOutcome::Unavailable {
                    reason: "X11 capture requires cfg(linux)".into(),
                    capability: Some("x11_capture".into()),
                }),
                LinuxSessionKind::Unknown => Ok(CaptureOutcome::Unavailable {
                    reason: "no interactive display session".into(),
                    capability: Some("window_capture".into()),
                }),
            }
        }
    }

    fn read_value(&self, handle: &Arc<dyn NativeHandle>) -> ToolResult<String> {
        #[cfg(target_os = "linux")]
        {
            self.inner.read_value(handle)
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = handle;
            Err(capability_unavailable(
                "linux",
                "read_text",
                "read_value requires a live Linux session",
            ))
        }
    }

    fn perform(
        &self,
        action: NativeAction,
        interference: InterferencePolicy,
        target_is_frontmost: bool,
    ) -> ToolResult<DeliveryEvidence> {
        #[cfg(target_os = "linux")]
        {
            self.inner
                .perform(action, interference, target_is_frontmost)
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = (action, interference, target_is_frontmost);
            Err(capability_unavailable(
                "linux",
                "semantic_actions",
                "perform requires a live Linux session",
            ))
        }
    }

    fn is_frontmost(&self, app: &AppSummary) -> bool {
        #[cfg(target_os = "linux")]
        {
            self.inner.is_frontmost(app)
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = app;
            false
        }
    }

    fn frontmost_app_name(&self) -> Option<String> {
        #[cfg(target_os = "linux")]
        {
            self.inner.frontmost_app_name()
        }
        #[cfg(not(target_os = "linux"))]
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
        #[cfg(target_os = "linux")]
        {
            self.inner.poll_wait(app, window_id, conditions)
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = (app, window_id, conditions);
            Err(capability_unavailable(
                "linux",
                "wait_for",
                "poll_wait requires a live Linux session",
            ))
        }
    }

    fn end_session(&self, session_key: &str) -> ToolResult<()> {
        #[cfg(target_os = "linux")]
        {
            self.inner.end_session(session_key)
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = session_key;
            Ok(())
        }
    }

    fn supports_process_targeted_input(&self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn static_capabilities_are_session_aware() {
        let report = LinuxAdapter::static_capabilities();
        assert_eq!(report.platform, PlatformKind::Linux);
        assert!(report.is_available(CapabilityKey::AtSpi));
        assert!(!report.limitations.is_empty());
    }

    #[cfg(not(target_os = "linux"))]
    #[test]
    fn non_linux_new_is_typed_unavailable() {
        match LinuxAdapter::new() {
            Ok(_) => panic!("expected capability_unavailable off Linux"),
            Err(ToolError::CapabilityUnavailable { capability, .. }) => {
                assert_eq!(capability, "at_spi");
            }
            Err(other) => panic!("expected capability_unavailable, got {other:?}"),
        }
    }

    #[test]
    fn wayland_capture_is_not_fake_success_off_linux() {
        let adapter_caps = LinuxAdapter::static_capabilities();
        // Regardless of host session env, off-linux perform paths fail closed.
        // Capability matrix must not claim unconditional Wayland input success.
        if LinuxSessionKind::detect() == LinuxSessionKind::Wayland {
            assert_ne!(
                adapter_caps.status_of(CapabilityKey::WaylandPortalInput),
                Some(CapabilityStatus::Available)
            );
        }
    }
}
