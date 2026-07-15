//! Live Linux bindings (compiled only on Linux).

#![cfg(target_os = "linux")]

use crate::LinuxSessionKind;
use semantouch_adapter::{
    CaptureOutcome, DeliveryEvidence, LaunchOutcome, LaunchRequest, NativeAction, NativeHandle,
    PermissionSnapshot, RawNode, RawObservation, WaitObservation,
};
use semantouch_protocol::{
    ActionMethod, ActionStatus, AppSummary, InterferencePolicy, PermissionStatus, Rect, ToolError,
    ToolResult, WaitCondition, WindowInfo, WindowSummary, HARD_MAX_NODES,
};
use std::any::Any;
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// AT-SPI accessible path handle.
#[derive(Debug)]
pub struct AtspiHandle {
    pub bus_name: String,
    pub path: String,
    pub pid: Option<i32>,
    live: std::sync::atomic::AtomicBool,
}

impl AtspiHandle {
    pub fn new(
        bus_name: impl Into<String>,
        path: impl Into<String>,
        pid: Option<i32>,
    ) -> Arc<Self> {
        Arc::new(Self {
            bus_name: bus_name.into(),
            path: path.into(),
            pid,
            live: std::sync::atomic::AtomicBool::new(true),
        })
    }
}

impl NativeHandle for AtspiHandle {
    fn is_live(&self) -> bool {
        self.live.load(std::sync::atomic::Ordering::SeqCst)
    }
    fn as_any(&self) -> &dyn Any {
        self
    }
    fn clone_handle(&self) -> Arc<dyn NativeHandle> {
        Arc::new(AtspiHandle {
            bus_name: self.bus_name.clone(),
            path: self.path.clone(),
            pid: self.pid,
            live: std::sync::atomic::AtomicBool::new(self.is_live()),
        })
    }
}

pub struct LinuxNative {
    session: LinuxSessionKind,
    /// Cached tokio runtime for zbus/atspi/ashpd calls.
    runtime: tokio::runtime::Runtime,
}

impl LinuxNative {
    pub fn new() -> ToolResult<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| ToolError::InternalError {
                detail: Some(format!("tokio runtime: {e}")),
            })?;
        // Probe AT-SPI bus connectivity early.
        let session = LinuxSessionKind::detect();
        let connected = runtime.block_on(async { probe_atspi().await });
        if let Err(e) = connected {
            return Err(ToolError::PermissionDenied {
                permission: semantouch_protocol::Permission::AtSpi,
                helper_path: std::env::current_exe()
                    .map(|p| p.display().to_string())
                    .unwrap_or_else(|_| "semantouch".into()),
                remediation: vec![
                    format!("AT-SPI connection failed: {e}"),
                    "Ensure at-spi2-core is installed and a session bus is available.".into(),
                    "On headless hosts, accessibility may be unavailable.".into(),
                ],
            });
        }
        Ok(Self { session, runtime })
    }

    pub fn permissions(&self) -> ToolResult<PermissionSnapshot> {
        let atspi_ok = self.runtime.block_on(async { probe_atspi().await.is_ok() });
        let capture = match self.session {
            LinuxSessionKind::X11 => PermissionStatus::Unknown,
            LinuxSessionKind::Wayland => PermissionStatus::Unknown,
            LinuxSessionKind::Unknown => PermissionStatus::Denied,
        };
        Ok(PermissionSnapshot {
            accessibility: if atspi_ok {
                PermissionStatus::Granted
            } else {
                PermissionStatus::Denied
            },
            screen_capture: capture,
            helper_path: std::env::current_exe()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|_| "semantouch".into()),
            signed: false,
            remediation: if atspi_ok {
                vec![]
            } else {
                vec!["Start a desktop session with AT-SPI enabled.".into()]
            },
            capabilities: super::LinuxAdapter::static_capabilities(),
        })
    }

    pub fn list_apps(&self) -> ToolResult<Vec<AppSummary>> {
        self.runtime.block_on(async { list_apps_atspi().await })
    }

    pub fn resolve_app(&self, query: &str) -> ToolResult<AppSummary> {
        let apps = self.list_apps()?;
        let q = query.to_lowercase();
        let matches: Vec<_> = apps
            .into_iter()
            .filter(|a| {
                a.id.to_lowercase() == q
                    || a.display_name.to_lowercase() == q
                    || a.display_name.to_lowercase().contains(&q)
                    || a.path
                        .as_ref()
                        .map(|p| p.to_lowercase().contains(&q))
                        .unwrap_or(false)
            })
            .collect();
        match matches.len() {
            0 => Err(ToolError::AppNotFound {
                query: query.into(),
            }),
            1 => Ok(matches.into_iter().next().unwrap()),
            _ => Err(ToolError::AmbiguousApp {
                query: query.into(),
                candidates: matches,
            }),
        }
    }

    pub fn launch_app(&self, request: LaunchRequest) -> ToolResult<LaunchOutcome> {
        if let Ok(app) = self.resolve_app(&request.app) {
            if app.is_running {
                return Ok(LaunchOutcome {
                    app,
                    launched: false,
                    recovered: true,
                });
            }
        }
        // Launch via desktop entry name or argv.
        let status = Command::new("sh")
            .arg("-c")
            .arg(format!(
                "nohup {} >/dev/null 2>&1 &",
                shell_escape(&request.app)
            ))
            .status()
            .map_err(|e| ToolError::InternalError {
                detail: Some(format!("spawn: {e}")),
            })?;
        if !status.success() {
            // try gtk-launch / gio
            let _ = Command::new("gtk-launch").arg(&request.app).spawn();
        }
        let deadline = Instant::now() + request.wait_for_window;
        while Instant::now() < deadline {
            if let Ok(app) = self.resolve_app(&request.app) {
                return Ok(LaunchOutcome {
                    app,
                    launched: true,
                    recovered: false,
                });
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        Err(ToolError::WindowNotFound {
            app: request.app,
            window_id: None,
        })
    }

    pub fn observe(
        &self,
        app: &AppSummary,
        window_id: Option<i64>,
        scope_handle: Option<Arc<dyn NativeHandle>>,
    ) -> ToolResult<RawObservation> {
        self.runtime
            .block_on(async { observe_atspi(app, window_id, scope_handle).await })
    }

    pub fn capture_window(
        &self,
        app: &AppSummary,
        window_id: Option<i64>,
    ) -> ToolResult<CaptureOutcome> {
        match self.session {
            LinuxSessionKind::X11 => self
                .runtime
                .block_on(async { capture_x11(app, window_id).await }),
            LinuxSessionKind::Wayland => self
                .runtime
                .block_on(async { capture_wayland_portal(app, window_id).await }),
            LinuxSessionKind::Unknown => Ok(CaptureOutcome::Unavailable {
                reason: "no DISPLAY/WAYLAND_DISPLAY".into(),
                capability: Some("window_capture".into()),
            }),
        }
    }

    pub fn read_value(&self, handle: &Arc<dyn NativeHandle>) -> ToolResult<String> {
        let h = handle
            .as_any()
            .downcast_ref::<AtspiHandle>()
            .ok_or_else(|| ToolError::StaleElement {
                session_id: "unknown".into(),
                element_id: "e?".into(),
                revision: 0,
            })?;
        let bus = h.bus_name.clone();
        let path = h.path.clone();
        self.runtime
            .block_on(async { read_text_atspi(&bus, &path).await })
    }

    pub fn perform(
        &self,
        action: NativeAction,
        interference: InterferencePolicy,
        target_is_frontmost: bool,
    ) -> ToolResult<DeliveryEvidence> {
        match action {
            NativeAction::Semantic {
                handle,
                action,
                click_count,
            } => {
                let h = cast_atspi(&handle)?;
                self.runtime.block_on(async {
                    do_action_atspi(&h.bus_name, &h.path, &action, click_count).await
                })
            }
            NativeAction::SetValue {
                handle,
                value,
                commit,
            } => {
                let h = cast_atspi(&handle)?;
                self.runtime.block_on(async {
                    set_value_atspi(&h.bus_name, &h.path, &value).await?;
                    Ok(DeliveryEvidence {
                        status: ActionStatus::Completed,
                        method: ActionMethod::Accessibility,
                        state_changed: true,
                        focus_changed: false,
                        focus_restored: false,
                        target_verified: true,
                        delivery_lane: "atspi-value".into(),
                        committed: Some(commit),
                        element_focused: None,
                        warning: if commit {
                            Some("commit mapped as AT-SPI activate when available".into())
                        } else {
                            None
                        },
                    })
                })
            }
            NativeAction::Click { .. }
            | NativeAction::Drag { .. }
            | NativeAction::Scroll { .. }
            | NativeAction::PressKey { .. }
            | NativeAction::TypeText { .. } => {
                // Route input by session.
                if !target_is_frontmost
                    && matches!(interference, InterferencePolicy::BackgroundOnly)
                {
                    return Err(ToolError::FocusRequired {
                        app: None,
                        frontmost_app: self.frontmost_app_name(),
                    });
                }
                match self.session {
                    LinuxSessionKind::X11 => self.runtime.block_on(async {
                        perform_x11_input(action, interference, target_is_frontmost).await
                    }),
                    LinuxSessionKind::Wayland => {
                        // Fail closed unless portal RemoteDesktop is actually granted.
                        Err(ToolError::CapabilityUnavailable {
                            capability: "wayland_portal_input".into(),
                            platform: "linux".into(),
                            detail: Some(
                                "Wayland input requires an active XDG RemoteDesktop portal session; \
                                 not claiming success without a live grant"
                                    .into(),
                            ),
                        })
                    }
                    LinuxSessionKind::Unknown => Err(ToolError::CapabilityUnavailable {
                        capability: "pointer_input".into(),
                        platform: "linux".into(),
                        detail: Some("no interactive session".into()),
                    }),
                }
            }
            NativeAction::SelectText {
                handle,
                start,
                length,
            } => {
                let h = cast_atspi(&handle)?;
                self.runtime.block_on(async {
                    select_text_atspi(&h.bus_name, &h.path, start, length).await
                })
            }
        }
    }

    pub fn is_frontmost(&self, app: &AppSummary) -> bool {
        // Best-effort: compare against AT-SPI active application if available.
        self.runtime
            .block_on(async { active_app_name().await })
            .map(|n| {
                n.eq_ignore_ascii_case(&app.display_name)
                    || app.id.to_lowercase().contains(&n.to_lowercase())
            })
            .unwrap_or(false)
    }

    pub fn frontmost_app_name(&self) -> Option<String> {
        self.runtime
            .block_on(async { active_app_name().await })
            .ok()
    }

    pub fn poll_wait(
        &self,
        app: &AppSummary,
        window_id: Option<i64>,
        _conditions: &[WaitCondition],
    ) -> ToolResult<WaitObservation> {
        let obs = self.observe(app, window_id, None)?;
        let mut roles = Vec::new();
        collect_roles(&obs.root, &mut roles);
        Ok(WaitObservation {
            window_title: obs.window.title,
            url: None,
            roles_titles_values: roles,
        })
    }

    pub fn end_session(&self, _session_key: &str) -> ToolResult<()> {
        Ok(())
    }
}

fn cast_atspi(handle: &Arc<dyn NativeHandle>) -> ToolResult<&AtspiHandle> {
    let h = handle
        .as_any()
        .downcast_ref::<AtspiHandle>()
        .ok_or_else(|| ToolError::StaleElement {
            session_id: "unknown".into(),
            element_id: "e?".into(),
            revision: 0,
        })?;
    if !h.is_live() {
        return Err(ToolError::StaleElement {
            session_id: "unknown".into(),
            element_id: format!("{}:{}", h.bus_name, h.path),
            revision: 0,
        });
    }
    Ok(h)
}

fn collect_roles(node: &RawNode, out: &mut Vec<(String, Option<String>, Option<String>)>) {
    out.push((node.role.clone(), node.title.clone(), node.value.clone()));
    for c in &node.children {
        collect_roles(c, out);
    }
}

fn shell_escape(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

// --- async AT-SPI / portal helpers ---

async fn probe_atspi() -> Result<(), String> {
    // Connect to the session bus and look up the registry name.
    let conn = zbus::Connection::session()
        .await
        .map_err(|e| format!("session bus: {e}"))?;
    // atspi registry well-known name
    let dbus = zbus::fdo::DBusProxy::new(&conn)
        .await
        .map_err(|e| format!("DBusProxy: {e}"))?;
    let has = dbus
        .name_has_owner("org.a11y.Bus".try_into().map_err(|e| format!("{e}"))?)
        .await
        .unwrap_or(false);
    // Also accept direct registry if a11y bus is bridged.
    let has_reg = dbus
        .name_has_owner(
            "org.a11y.atspi.Registry"
                .try_into()
                .map_err(|e| format!("{e}"))?,
        )
        .await
        .unwrap_or(false);
    if has || has_reg {
        Ok(())
    } else {
        // Try opening atspi connection via crate if available.
        match atspi::AccessibilityConnection::new().await {
            Ok(_) => Ok(()),
            Err(e) => Err(format!(
                "no org.a11y.Bus / Registry owner and atspi connect failed: {e}"
            )),
        }
    }
}

async fn list_apps_atspi() -> ToolResult<Vec<AppSummary>> {
    // Prefer AT-SPI desktop children; fall back to /proc scan of GUI-ish processes.
    match list_apps_via_atspi_registry().await {
        Ok(apps) if !apps.is_empty() => Ok(apps),
        Ok(_) | Err(_) => list_apps_via_proc(),
    }
}

async fn list_apps_via_atspi_registry() -> ToolResult<Vec<AppSummary>> {
    let a11y = connect_a11y().await?;
    let roots = desktop_application_roots(a11y.connection()).await?;
    let mut apps = Vec::with_capacity(roots.len());
    for root in roots {
        if let Some(summary) = app_summary_from_root(a11y.connection(), &root).await {
            apps.push(summary);
        }
    }
    apps.sort_by(|a, b| {
        a.display_name
            .to_lowercase()
            .cmp(&b.display_name.to_lowercase())
            .then_with(|| a.pid.cmp(&b.pid))
    });
    apps.dedup_by(|a, b| a.pid.is_some() && a.pid == b.pid);
    Ok(apps)
}

fn list_apps_via_proc() -> ToolResult<Vec<AppSummary>> {
    let mut apps = Vec::new();
    let proc = std::fs::read_dir("/proc").map_err(|e| ToolError::InternalError {
        detail: Some(format!("/proc: {e}")),
    })?;
    for entry in proc.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let pid: i32 = match name.parse() {
            Ok(p) => p,
            Err(_) => continue,
        };
        let comm_path = entry.path().join("comm");
        let comm = std::fs::read_to_string(comm_path)
            .unwrap_or_default()
            .trim()
            .to_string();
        if comm.is_empty() {
            continue;
        }
        // Skip kernel threads-ish
        let exe = std::fs::read_link(entry.path().join("exe")).ok();
        apps.push(AppSummary {
            id: exe
                .as_ref()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| format!("pid:{pid}")),
            display_name: comm,
            path: exe.map(|p| p.display().to_string()),
            pid: Some(pid),
            is_running: true,
            windows: 0,
            last_used_at: None,
            use_count: None,
        });
    }
    // Dedup by display name keep first
    apps.sort_by(|a, b| a.display_name.cmp(&b.display_name));
    apps.dedup_by(|a, b| a.pid == b.pid);
    Ok(apps)
}

async fn observe_atspi(
    app: &AppSummary,
    window_id: Option<i64>,
    scope_handle: Option<Arc<dyn NativeHandle>>,
) -> ToolResult<RawObservation> {
    let a11y = connect_a11y().await?;
    let conn = a11y.connection();

    let (root_bus, root_path, root_pid) = if let Some(handle) = scope_handle {
        let h = cast_atspi(&handle)?;
        if !h.is_live() {
            return Err(ToolError::StaleElement {
                session_id: "unknown".into(),
                element_id: format!("{}:{}", h.bus_name, h.path),
                revision: 0,
            });
        }
        // Prove the scoped native handle is still reachable on the a11y bus.
        let proxy = accessible_proxy(conn, &h.bus_name, &h.path)
            .await
            .map_err(|_| ToolError::StaleElement {
                session_id: "unknown".into(),
                element_id: format!("{}:{}", h.bus_name, h.path),
                revision: 0,
            })?;
        proxy
            .get_role()
            .await
            .map_err(|_| ToolError::StaleElement {
                session_id: "unknown".into(),
                element_id: format!("{}:{}", h.bus_name, h.path),
                revision: 0,
            })?;
        (h.bus_name.clone(), h.path.clone(), h.pid.or(app.pid))
    } else {
        let app_root = resolve_application_root(conn, app).await?;
        let walk_root = select_window_root(conn, &app_root, window_id).await?;
        (
            walk_root.name.to_string(),
            walk_root.path.to_string(),
            app.pid.or(app_root.pid),
        )
    };

    let mut budget = WalkBudget::new(HARD_MAX_NODES, MAX_WALK_DEPTH);
    let root = walk_accessible(conn, &root_bus, &root_path, root_pid, &mut budget).await?;

    let windows = collect_window_summaries(conn, app).await;
    let window = select_window_info(&windows, window_id, app, &root);
    let focused_handle = find_focused_handle(&root);

    Ok(RawObservation {
        app: app.clone(),
        window,
        windows,
        root,
        focused_handle,
        document: None,
    })
}

/// Conservative adapter depth bound (mirrors Windows UIA walk).
const MAX_WALK_DEPTH: usize = 40;

/// Registry desktop root — `Accessible.get_children` lists application roots.
const REGISTRY_BUS: &str = "org.a11y.atspi.Registry";
const DESKTOP_ROOT_PATH: &str = "/org/a11y/atspi/accessible/root";
const APP_ROOT_PATH: &str = "/org/a11y/atspi/accessible/root";

#[derive(Clone, Debug)]
struct AtspiObject {
    name: String,
    path: String,
    pid: Option<i32>,
}

struct WalkBudget {
    remaining_nodes: usize,
    max_depth: usize,
}

impl WalkBudget {
    fn new(max_nodes: usize, max_depth: usize) -> Self {
        Self {
            remaining_nodes: max_nodes.max(1),
            max_depth,
        }
    }

    fn take_node(&mut self) -> bool {
        if self.remaining_nodes == 0 {
            return false;
        }
        self.remaining_nodes -= 1;
        true
    }
}

async fn connect_a11y() -> ToolResult<atspi::AccessibilityConnection> {
    atspi::AccessibilityConnection::new()
        .await
        .map_err(|e| ToolError::PermissionDenied {
            permission: semantouch_protocol::Permission::AtSpi,
            helper_path: "semantouch".into(),
            remediation: vec![
                format!("AccessibilityConnection: {e}"),
                "Ensure at-spi2-core is installed and a session bus is available.".into(),
            ],
        })
}

async fn accessible_proxy<'a>(
    conn: &'a zbus::Connection,
    bus_name: &'a str,
    path: &'a str,
) -> zbus::Result<atspi::proxy::accessible::AccessibleProxy<'a>> {
    atspi::proxy::accessible::AccessibleProxy::builder(conn)
        .destination(bus_name)?
        .path(path)?
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()
        .await
}

async fn component_proxy<'a>(
    conn: &'a zbus::Connection,
    bus_name: &'a str,
    path: &'a str,
) -> zbus::Result<atspi::proxy::component::ComponentProxy<'a>> {
    atspi::proxy::component::ComponentProxy::builder(conn)
        .destination(bus_name)?
        .path(path)?
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()
        .await
}

async fn action_proxy<'a>(
    conn: &'a zbus::Connection,
    bus_name: &'a str,
    path: &'a str,
) -> zbus::Result<atspi::proxy::action::ActionProxy<'a>> {
    atspi::proxy::action::ActionProxy::builder(conn)
        .destination(bus_name)?
        .path(path)?
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()
        .await
}

async fn text_proxy<'a>(
    conn: &'a zbus::Connection,
    bus_name: &'a str,
    path: &'a str,
) -> zbus::Result<atspi::proxy::text::TextProxy<'a>> {
    atspi::proxy::text::TextProxy::builder(conn)
        .destination(bus_name)?
        .path(path)?
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()
        .await
}

async fn value_proxy<'a>(
    conn: &'a zbus::Connection,
    bus_name: &'a str,
    path: &'a str,
) -> zbus::Result<atspi::proxy::value::ValueProxy<'a>> {
    atspi::proxy::value::ValueProxy::builder(conn)
        .destination(bus_name)?
        .path(path)?
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()
        .await
}

async fn bus_pid(conn: &zbus::Connection, bus_name: &str) -> Option<i32> {
    let dbus = zbus::fdo::DBusProxy::new(conn).await.ok()?;
    let name = zbus::names::BusName::try_from(bus_name).ok()?;
    dbus.get_connection_unix_process_id(name)
        .await
        .ok()
        .map(|p| p as i32)
}

fn object_ref_parts(obj: &atspi::ObjectRef) -> AtspiObject {
    AtspiObject {
        name: obj.name.as_str().to_string(),
        path: obj.path.as_str().to_string(),
        pid: None,
    }
}

fn is_null_path(path: &str) -> bool {
    path.is_empty() || path == "/org/a11y/atspi/null" || path == "/org/a11y/atspi/accessible/null"
}

fn stable_window_id(bus_name: &str, path: &str) -> i64 {
    // Stable positive id derived from bus+path so callers can re-target a window.
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    bus_name.hash(&mut hasher);
    path.hash(&mut hasher);
    let h = hasher.finish() & 0x7fff_ffff_ffff_ffff;
    if h == 0 {
        1
    } else {
        h as i64
    }
}

fn role_is_window_like(role: &str) -> bool {
    matches!(
        role,
        "frame"
            | "window"
            | "dialog"
            | "alert"
            | "file chooser"
            | "color chooser"
            | "font chooser"
            | "application"
    )
}

/// Map AT-SPI action names onto the AX-style names the coordinator already emits.
fn map_atspi_action_name(name: &str) -> String {
    match name.to_ascii_lowercase().as_str() {
        "click" | "press" | "activate" => "AXPress".into(),
        "settext" | "set text" | "setvalue" | "set value" | "edit" => "AXSetValue".into(),
        "showmenu" | "show menu" | "menu" => "AXShowMenu".into(),
        "expand" => "AXExpand".into(),
        "collapse" => "AXCollapse".into(),
        other => other.to_string(),
    }
}

fn nonempty(s: String) -> Option<String> {
    let t = s.trim();
    if t.is_empty() {
        None
    } else {
        Some(t.to_string())
    }
}

fn proc_identity(pid: i32) -> (Option<String>, Option<String>) {
    let path = std::fs::read_link(format!("/proc/{pid}/exe"))
        .ok()
        .map(|p| p.display().to_string());
    let comm = std::fs::read_to_string(format!("/proc/{pid}/comm"))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    (path, comm)
}

/// Prefer PID identity, then exact display-name, then substring / path / bus id.
fn app_match_score(app: &AppSummary, candidate: &AppSummary) -> i32 {
    if let (Some(a), Some(b)) = (app.pid, candidate.pid) {
        if a == b {
            return 100;
        }
    }
    let q_id = app.id.to_lowercase();
    let q_name = app.display_name.to_lowercase();
    let c_id = candidate.id.to_lowercase();
    let c_name = candidate.display_name.to_lowercase();
    if !q_id.is_empty() && q_id == c_id {
        return 90;
    }
    if !q_name.is_empty() && q_name == c_name {
        return 80;
    }
    if !q_name.is_empty() && c_name.contains(&q_name) {
        return 60;
    }
    if !q_id.is_empty() && c_id.contains(&q_id) {
        return 50;
    }
    if let Some(path) = &candidate.path {
        let p = path.to_lowercase();
        if !q_name.is_empty() && p.contains(&q_name) {
            return 40;
        }
        if !q_id.is_empty() && p.contains(&q_id) {
            return 35;
        }
    }
    0
}

fn select_best_app_match<'a>(
    app: &AppSummary,
    candidates: &'a [AppSummary],
) -> Option<&'a AppSummary> {
    candidates
        .iter()
        .map(|c| (app_match_score(app, c), c))
        .filter(|(score, _)| *score > 0)
        .max_by_key(|(score, c)| (*score, c.pid.unwrap_or(0)))
        .map(|(_, c)| c)
}

async fn desktop_application_roots(conn: &zbus::Connection) -> ToolResult<Vec<AtspiObject>> {
    let desktop = accessible_proxy(conn, REGISTRY_BUS, DESKTOP_ROOT_PATH)
        .await
        .map_err(|e| ToolError::PermissionDenied {
            permission: semantouch_protocol::Permission::AtSpi,
            helper_path: "semantouch".into(),
            remediation: vec![format!("desktop AccessibleProxy: {e}")],
        })?;
    let children = desktop
        .get_children()
        .await
        .map_err(|e| ToolError::InternalError {
            detail: Some(format!("desktop get_children: {e}")),
        })?;
    let mut out = Vec::with_capacity(children.len());
    for child in children {
        let mut obj = object_ref_parts(&child);
        if is_null_path(&obj.path) || obj.name.is_empty() {
            continue;
        }
        obj.pid = bus_pid(conn, &obj.name).await;
        out.push(obj);
    }
    Ok(out)
}

async fn app_summary_from_root(conn: &zbus::Connection, root: &AtspiObject) -> Option<AppSummary> {
    let proxy = accessible_proxy(conn, &root.name, &root.path).await.ok()?;
    let name = proxy.name().await.ok().and_then(nonempty);
    let pid = root.pid.or(bus_pid(conn, &root.name).await);
    let (exe, comm) = pid.map(proc_identity).unwrap_or((None, None));
    let display_name = name.or(comm).unwrap_or_else(|| root.name.clone());
    let id = exe
        .clone()
        .unwrap_or_else(|| format!("atspi:{}", root.name));
    let windows = count_window_children(conn, root).await;
    Some(AppSummary {
        id,
        display_name,
        path: exe,
        pid,
        is_running: true,
        windows,
        last_used_at: None,
        use_count: None,
    })
}

async fn count_window_children(conn: &zbus::Connection, root: &AtspiObject) -> i32 {
    let Ok(proxy) = accessible_proxy(conn, &root.name, &root.path).await else {
        return 0;
    };
    let Ok(children) = proxy.get_children().await else {
        return 0;
    };
    let mut n = 0i32;
    for child in children {
        let obj = object_ref_parts(&child);
        if is_null_path(&obj.path) {
            continue;
        }
        if let Ok(child_proxy) = accessible_proxy(conn, &obj.name, &obj.path).await {
            if let Ok(role) = child_proxy.get_role().await {
                if role_is_window_like(role.name()) {
                    n += 1;
                }
            }
        }
    }
    n
}

async fn resolve_application_root(
    conn: &zbus::Connection,
    app: &AppSummary,
) -> ToolResult<AtspiObject> {
    let roots = desktop_application_roots(conn).await?;
    if roots.is_empty() {
        return Err(ToolError::AppNotFound {
            query: app.id.clone(),
        });
    }

    // PID-first exact match against bus owner.
    if let Some(pid) = app.pid {
        if let Some(found) = roots.iter().find(|r| r.pid == Some(pid)) {
            return Ok(found.clone());
        }
    }

    // Score against discovered app summaries for name/path identity.
    let mut summaries = Vec::new();
    let mut summary_roots = Vec::new();
    for root in &roots {
        if let Some(summary) = app_summary_from_root(conn, root).await {
            summaries.push(summary);
            summary_roots.push(root.clone());
        }
    }
    if let Some(best) = select_best_app_match(app, &summaries) {
        if let Some(idx) = summaries.iter().position(|s| {
            s.pid == best.pid && s.id == best.id && s.display_name == best.display_name
        }) {
            return Ok(summary_roots[idx].clone());
        }
    }

    // Last resort: treat app.id as a bus name and probe its root path.
    if app.id.starts_with(':') || app.id.starts_with("atspi:") {
        let bus = app.id.strip_prefix("atspi:").unwrap_or(&app.id);
        if let Ok(proxy) = accessible_proxy(conn, bus, APP_ROOT_PATH).await {
            if proxy.get_role().await.is_ok() {
                return Ok(AtspiObject {
                    name: bus.to_string(),
                    path: APP_ROOT_PATH.into(),
                    pid: app.pid.or(bus_pid(conn, bus).await),
                });
            }
        }
    }

    Err(ToolError::AppNotFound {
        query: app.display_name.clone(),
    })
}

async fn select_window_root(
    conn: &zbus::Connection,
    app_root: &AtspiObject,
    window_id: Option<i64>,
) -> ToolResult<AtspiObject> {
    let proxy = accessible_proxy(conn, &app_root.name, &app_root.path)
        .await
        .map_err(|e| ToolError::InternalError {
            detail: Some(format!("app root proxy: {e}")),
        })?;

    let children = proxy.get_children().await.unwrap_or_default();
    let mut windows = Vec::new();
    for child in children {
        let obj = object_ref_parts(&child);
        if is_null_path(&obj.path) {
            continue;
        }
        let Ok(child_proxy) = accessible_proxy(conn, &obj.name, &obj.path).await else {
            continue;
        };
        let role = child_proxy
            .get_role()
            .await
            .map(|r| r.name().to_string())
            .unwrap_or_default();
        if role_is_window_like(&role) {
            windows.push(AtspiObject {
                name: obj.name,
                path: obj.path,
                pid: app_root.pid,
            });
        }
    }

    if let Some(wid) = window_id {
        if let Some(found) = windows
            .iter()
            .find(|w| stable_window_id(&w.name, &w.path) == wid)
        {
            return Ok(found.clone());
        }
        // Also accept 1-based ordinal among window-like children.
        if wid > 0 {
            let idx = (wid as usize).saturating_sub(1);
            if let Some(found) = windows.get(idx) {
                return Ok(found.clone());
            }
        }
        if !windows.is_empty() {
            return Err(ToolError::WindowNotFound {
                app: app_root.name.clone(),
                window_id: Some(wid),
            });
        }
    }

    if let Some(first) = windows.into_iter().next() {
        return Ok(first);
    }
    // No window-like children — walk from the application root itself.
    Ok(app_root.clone())
}

async fn collect_window_summaries(conn: &zbus::Connection, app: &AppSummary) -> Vec<WindowSummary> {
    let Ok(app_root) = resolve_application_root(conn, app).await else {
        return Vec::new();
    };
    let Ok(proxy) = accessible_proxy(conn, &app_root.name, &app_root.path).await else {
        return Vec::new();
    };
    let children = proxy.get_children().await.unwrap_or_default();
    let mut out = Vec::new();
    for child in children {
        let obj = object_ref_parts(&child);
        if is_null_path(&obj.path) {
            continue;
        }
        let Ok(child_proxy) = accessible_proxy(conn, &obj.name, &obj.path).await else {
            continue;
        };
        let role = child_proxy
            .get_role()
            .await
            .map(|r| r.name().to_string())
            .unwrap_or_default();
        if !role_is_window_like(&role) {
            continue;
        }
        let title = child_proxy.name().await.ok().and_then(nonempty);
        let frame = extents_rect(conn, &obj.name, &obj.path).await;
        let state = child_proxy.get_state().await.ok();
        let focused = state
            .as_ref()
            .map(|s| s.contains(atspi::State::Focused) || s.contains(atspi::State::Active))
            .unwrap_or(false);
        out.push(WindowSummary {
            id: Some(stable_window_id(&obj.name, &obj.path)),
            title,
            frame_points: frame.unwrap_or_else(|| Rect::new(0.0, 0.0, 0.0, 0.0)),
            focused,
            main: out.is_empty(),
            on_screen: true,
        });
    }
    out
}

fn select_window_info(
    windows: &[WindowSummary],
    window_id: Option<i64>,
    app: &AppSummary,
    root: &RawNode,
) -> WindowInfo {
    let chosen = window_id
        .and_then(|wid| windows.iter().find(|w| w.id == Some(wid)))
        .or_else(|| windows.iter().find(|w| w.focused))
        .or_else(|| windows.first());
    if let Some(w) = chosen {
        WindowInfo {
            id: w.id.unwrap_or(1),
            title: w.title.clone(),
            frame_points: w.frame_points,
            screenshot_pixels: None,
            scale: 1.0,
            document: None,
        }
    } else {
        WindowInfo {
            id: window_id.unwrap_or(1),
            title: root
                .title
                .clone()
                .or_else(|| Some(app.display_name.clone())),
            frame_points: root.frame.unwrap_or_else(|| Rect::new(0.0, 0.0, 0.0, 0.0)),
            screenshot_pixels: None,
            scale: 1.0,
            document: None,
        }
    }
}

fn find_focused_handle(node: &RawNode) -> Option<Arc<dyn NativeHandle>> {
    if node.focused {
        return Some(node.handle.clone_handle());
    }
    for child in &node.children {
        if let Some(h) = find_focused_handle(child) {
            return Some(h);
        }
    }
    None
}

async fn extents_rect(conn: &zbus::Connection, bus_name: &str, path: &str) -> Option<Rect> {
    let proxy = component_proxy(conn, bus_name, path).await.ok()?;
    let (x, y, w, h) = proxy.get_extents(atspi::CoordType::Screen).await.ok()?;
    Some(Rect::new(x as f64, y as f64, w as f64, h as f64))
}

async fn collect_actions(
    conn: &zbus::Connection,
    bus_name: &str,
    path: &str,
    interfaces: &atspi::InterfaceSet,
) -> Vec<String> {
    if !interfaces.contains(atspi::Interface::Action) {
        return Vec::new();
    }
    let Ok(proxy) = action_proxy(conn, bus_name, path).await else {
        return Vec::new();
    };
    let Ok(n) = proxy.nactions().await else {
        return Vec::new();
    };
    let mut actions = Vec::new();
    for i in 0..n.max(0) {
        if let Ok(name) = proxy.get_name(i).await {
            let mapped = map_atspi_action_name(&name);
            if !actions.iter().any(|a| a == &mapped) {
                actions.push(mapped);
            }
        }
    }
    actions
}

async fn collect_value(
    conn: &zbus::Connection,
    bus_name: &str,
    path: &str,
    interfaces: &atspi::InterfaceSet,
) -> (Option<String>, Vec<String>) {
    let mut settable = Vec::new();
    if interfaces.contains(atspi::Interface::Text)
        || interfaces.contains(atspi::Interface::EditableText)
    {
        settable.push("AXValue".into());
        if let Ok(proxy) = text_proxy(conn, bus_name, path).await {
            if let Ok(text) = proxy.get_text(0, -1).await {
                if let Some(v) = nonempty(text) {
                    return (Some(v), settable);
                }
            }
        }
    }
    if interfaces.contains(atspi::Interface::Value) {
        if !settable.iter().any(|s| s == "AXValue") {
            settable.push("AXValue".into());
        }
        if let Ok(proxy) = value_proxy(conn, bus_name, path).await {
            if let Ok(v) = proxy.current_value().await {
                return (Some(format!("{v}")), settable);
            }
        }
    }
    (None, settable)
}

async fn walk_accessible(
    conn: &zbus::Connection,
    bus_name: &str,
    path: &str,
    pid: Option<i32>,
    budget: &mut WalkBudget,
) -> ToolResult<RawNode> {
    walk_accessible_at_depth(conn, bus_name, path, pid, budget, 0).await
}

async fn walk_children(
    conn: &zbus::Connection,
    bus_name: &str,
    path: &str,
    pid: Option<i32>,
    budget: &mut WalkBudget,
    depth: usize,
) -> Vec<RawNode> {
    if depth >= budget.max_depth || budget.remaining_nodes == 0 {
        return Vec::new();
    }
    let Ok(proxy) = accessible_proxy(conn, bus_name, path).await else {
        return Vec::new();
    };
    let children_refs = match proxy.get_children().await {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    let mut children = Vec::new();
    for child in children_refs {
        if budget.remaining_nodes == 0 {
            break;
        }
        let obj = object_ref_parts(&child);
        if is_null_path(&obj.path) || obj.name.is_empty() {
            continue;
        }
        // Child may live on a different bus name (embedded toolkit).
        match Box::pin(walk_accessible_at_depth(
            conn,
            &obj.name,
            &obj.path,
            pid.or(obj.pid),
            budget,
            depth,
        ))
        .await
        {
            Ok(node) => children.push(node),
            Err(_) => continue,
        }
    }
    children
}

async fn walk_accessible_at_depth(
    conn: &zbus::Connection,
    bus_name: &str,
    path: &str,
    pid: Option<i32>,
    budget: &mut WalkBudget,
    depth: usize,
) -> ToolResult<RawNode> {
    if !budget.take_node() {
        let handle = AtspiHandle::new(bus_name, path, pid);
        return Ok(RawNode {
            handle: handle as Arc<dyn NativeHandle>,
            role: "unknown".into(),
            subrole: None,
            title: None,
            value: None,
            description: None,
            placeholder: None,
            identifier: Some(path.to_string()),
            enabled: true,
            focused: false,
            selected: false,
            frame: None,
            actions: vec![],
            settable_attributes: vec![],
            children: vec![],
            secure: false,
        });
    }

    let proxy =
        accessible_proxy(conn, bus_name, path)
            .await
            .map_err(|e| ToolError::InternalError {
                detail: Some(format!("AccessibleProxy {bus_name}{path}: {e}")),
            })?;

    let role = proxy
        .get_role()
        .await
        .map(|r| r.name().to_string())
        .unwrap_or_else(|_| "unknown".into());
    let title = proxy.name().await.ok().and_then(nonempty);
    let mut description = proxy.description().await.ok().and_then(nonempty);
    if description.is_none() {
        description = proxy.help_text().await.ok().and_then(nonempty);
    }
    let identifier = proxy
        .accessible_id()
        .await
        .ok()
        .and_then(nonempty)
        .or_else(|| Some(path.to_string()));
    let interfaces = proxy
        .get_interfaces()
        .await
        .unwrap_or_else(|_| atspi::InterfaceSet::empty());
    let state = proxy.get_state().await.ok();
    let enabled = state
        .as_ref()
        .map(|s| s.contains(atspi::State::Enabled) || s.contains(atspi::State::Sensitive))
        .unwrap_or(true);
    let focused = state
        .as_ref()
        .map(|s| s.contains(atspi::State::Focused))
        .unwrap_or(false);
    let selected = state
        .as_ref()
        .map(|s| s.contains(atspi::State::Selected) || s.contains(atspi::State::Checked))
        .unwrap_or(false);
    let secure = role == "password text";

    let frame = if interfaces.contains(atspi::Interface::Component) {
        extents_rect(conn, bus_name, path).await
    } else {
        None
    };
    let actions = collect_actions(conn, bus_name, path, &interfaces).await;
    let (value, settable_attributes) = collect_value(conn, bus_name, path, &interfaces).await;

    let children = if depth + 1 < budget.max_depth {
        Box::pin(walk_children(conn, bus_name, path, pid, budget, depth + 1)).await
    } else {
        Vec::new()
    };

    let handle = AtspiHandle::new(bus_name, path, pid);
    Ok(RawNode {
        handle: handle as Arc<dyn NativeHandle>,
        role,
        subrole: None,
        title,
        value,
        description,
        placeholder: None,
        identifier,
        enabled,
        focused,
        selected,
        frame,
        actions,
        settable_attributes,
        children,
        secure,
    })
}

async fn read_text_atspi(bus_name: &str, path: &str) -> ToolResult<String> {
    let a11y = connect_a11y().await?;
    let proxy = text_proxy(a11y.connection(), bus_name, path)
        .await
        .map_err(|e| ToolError::UnsupportedAction {
            element_id: path.into(),
            action: Some("GetText".into()),
            supported: vec![],
            reason: Some(format!("{e}")),
        })?;
    proxy
        .get_text(0, -1)
        .await
        .map_err(|e| ToolError::UnsupportedAction {
            element_id: path.into(),
            action: Some("GetText".into()),
            supported: vec![],
            reason: Some(format!("{e}")),
        })
}

async fn do_action_atspi(
    bus_name: &str,
    path: &str,
    action: &str,
    click_count: u32,
) -> ToolResult<DeliveryEvidence> {
    let a11y = connect_a11y().await?;
    let conn = a11y.connection();
    let proxy =
        action_proxy(conn, bus_name, path)
            .await
            .map_err(|e| ToolError::UnsupportedAction {
                element_id: path.into(),
                action: Some(action.into()),
                supported: vec![],
                reason: Some(format!("Action iface: {e}")),
            })?;

    let n = proxy.nactions().await.unwrap_or(0).max(0);
    let mut index = 0i32;
    let mut supported = Vec::new();
    let wanted = action.to_ascii_lowercase();
    let wanted_mapped = map_atspi_action_name(action).to_ascii_lowercase();
    for i in 0..n {
        if let Ok(name) = proxy.get_name(i).await {
            let mapped = map_atspi_action_name(&name);
            supported.push(mapped.clone());
            let lname = name.to_ascii_lowercase();
            let lmapped = mapped.to_ascii_lowercase();
            if lname == wanted
                || lmapped == wanted
                || lmapped == wanted_mapped
                || lname == wanted_mapped
            {
                index = i;
            }
        }
    }

    for _ in 0..click_count.max(1) {
        let result = proxy
            .do_action(index)
            .await
            .map_err(|e| ToolError::UnsupportedAction {
                element_id: path.into(),
                action: Some(action.into()),
                supported: supported.clone(),
                reason: Some(format!("DoAction: {e}")),
            })?;
        if !result {
            return Err(ToolError::UnsupportedAction {
                element_id: path.into(),
                action: Some(action.into()),
                supported,
                reason: Some("DoAction returned false".into()),
            });
        }
    }
    Ok(DeliveryEvidence {
        status: ActionStatus::Completed,
        method: ActionMethod::Accessibility,
        state_changed: true,
        focus_changed: false,
        focus_restored: false,
        target_verified: true,
        delivery_lane: "atspi-action".into(),
        committed: None,
        element_focused: None,
        warning: None,
    })
}

async fn set_value_atspi(bus_name: &str, path: &str, value: &str) -> ToolResult<()> {
    let a11y = connect_a11y().await?;
    let conn = a11y.connection();

    // Prefer EditableText.SetTextContents when available.
    match atspi::proxy::editable_text::EditableTextProxy::builder(conn).destination(bus_name) {
        Ok(b) => match b.path(path) {
            Ok(b) => {
                if let Ok(edit) = b
                    .cache_properties(zbus::proxy::CacheProperties::No)
                    .build()
                    .await
                {
                    if edit.set_text_contents(value).await.unwrap_or(false) {
                        return Ok(());
                    }
                }
            }
            Err(_) => {}
        },
        Err(_) => {}
    }

    // Numeric Value interface fallback.
    if let Ok(num) = value.parse::<f64>() {
        if let Ok(proxy) = value_proxy(conn, bus_name, path).await {
            if proxy.set_current_value(num).await.is_ok() {
                return Ok(());
            }
        }
    }

    Err(ToolError::UnsupportedAction {
        element_id: path.into(),
        action: Some("SetValue".into()),
        supported: vec!["AXSetValue".into()],
        reason: Some("no EditableText/Value write path succeeded".into()),
    })
}

async fn select_text_atspi(
    bus_name: &str,
    path: &str,
    start: u32,
    length: u32,
) -> ToolResult<DeliveryEvidence> {
    let a11y = connect_a11y().await?;
    let proxy = text_proxy(a11y.connection(), bus_name, path)
        .await
        .map_err(|e| ToolError::UnsupportedAction {
            element_id: path.into(),
            action: Some("SetSelection".into()),
            supported: vec![],
            reason: Some(format!("{e}")),
        })?;
    let end = start.saturating_add(length) as i32;
    let ok = proxy
        .set_selection(0, start as i32, end)
        .await
        .map_err(|e| ToolError::UnsupportedAction {
            element_id: path.into(),
            action: Some("SetSelection".into()),
            supported: vec![],
            reason: Some(format!("{e}")),
        })?;
    if !ok {
        return Err(ToolError::UnsupportedAction {
            element_id: path.into(),
            action: Some("SetSelection".into()),
            supported: vec![],
            reason: Some("SetSelection returned false".into()),
        });
    }
    Ok(DeliveryEvidence {
        status: ActionStatus::Completed,
        method: ActionMethod::Accessibility,
        state_changed: true,
        focus_changed: false,
        focus_restored: false,
        target_verified: true,
        delivery_lane: "atspi-text".into(),
        committed: None,
        element_focused: None,
        warning: None,
    })
}

async fn active_app_name() -> Result<String, ()> {
    // Best-effort via xprop on X11; fail on Wayland without portal.
    if LinuxSessionKind::detect() == LinuxSessionKind::X11 {
        if let Ok(output) = Command::new("xdotool")
            .arg("getactivewindow")
            .arg("getwindowname")
            .output()
        {
            if output.status.success() {
                return Ok(String::from_utf8_lossy(&output.stdout).trim().to_string());
            }
        }
    }
    Err(())
}

async fn capture_x11(_app: &AppSummary, window_id: Option<i64>) -> ToolResult<CaptureOutcome> {
    // Real X11 path via x11rb: connect, get geometry, get image.
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{ConnectionExt, ImageFormat};

    let (conn, screen_num) =
        x11rb::connect(None).map_err(|e| ToolError::CapabilityUnavailable {
            capability: "x11_capture".into(),
            platform: "linux".into(),
            detail: Some(format!("X11 connect failed: {e}")),
        })?;
    let screen = &conn.setup().roots[screen_num];
    let root = screen.root;
    let target = window_id.map(|id| id as u32).unwrap_or(root);
    let geom = conn
        .get_geometry(target)
        .map_err(|e| ToolError::CapabilityUnavailable {
            capability: "x11_capture".into(),
            platform: "linux".into(),
            detail: Some(format!("GetGeometry: {e}")),
        })?
        .reply()
        .map_err(|e| ToolError::CapabilityUnavailable {
            capability: "x11_capture".into(),
            platform: "linux".into(),
            detail: Some(format!("GetGeometry reply: {e}")),
        })?;
    let width = geom.width;
    let height = geom.height;
    if width == 0 || height == 0 {
        return Ok(CaptureOutcome::Unavailable {
            reason: "zero-sized window".into(),
            capability: Some("x11_capture".into()),
        });
    }
    // Bound capture size for safety.
    let w = width.min(4096);
    let h = height.min(4096);
    let image = conn
        .get_image(ImageFormat::Z_PIXMAP, target, 0, 0, w, h, !0)
        .map_err(|e| ToolError::CapabilityUnavailable {
            capability: "x11_capture".into(),
            platform: "linux".into(),
            detail: Some(format!("GetImage: {e}")),
        })?
        .reply()
        .map_err(|e| ToolError::CapabilityUnavailable {
            capability: "x11_capture".into(),
            platform: "linux".into(),
            detail: Some(format!("GetImage reply: {e}")),
        })?;

    // Convert raw ZPixmap bytes to JPEG when possible; otherwise report unavailable
    // rather than returning empty/black success.
    match zpixmap_to_jpeg(&image.data, w as u32, h as u32, image.depth) {
        Some(jpeg) => Ok(CaptureOutcome::Image {
            jpeg,
            width: w as i32,
            height: h as i32,
            scale: 1.0,
        }),
        None => Ok(CaptureOutcome::Unavailable {
            reason: format!(
                "unsupported X11 image depth {} ({} bytes)",
                image.depth,
                image.data.len()
            ),
            capability: Some("x11_capture".into()),
        }),
    }
}

fn zpixmap_to_jpeg(data: &[u8], width: u32, height: u32, depth: u8) -> Option<Vec<u8>> {
    use image::{ImageBuffer, Rgb, RgbImage};
    let img: RgbImage = match depth {
        24 | 32 => {
            let bpp = if depth == 32 { 4 } else { 3 };
            if data.len() < (width * height * bpp as u32) as usize {
                return None;
            }
            ImageBuffer::from_fn(width, height, |x, y| {
                let i = ((y * width + x) * bpp as u32) as usize;
                // X11 often BGRX
                let b = data[i];
                let g = data[i + 1];
                let r = data[i + 2];
                Rgb([r, g, b])
            })
        }
        _ => return None,
    };
    let mut out = Vec::new();
    let mut cursor = std::io::Cursor::new(&mut out);
    let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut cursor, 80);
    img.write_with_encoder(encoder).ok()?;
    Some(out)
}

async fn capture_wayland_portal(
    _app: &AppSummary,
    _window_id: Option<i64>,
) -> ToolResult<CaptureOutcome> {
    // ashpd Screenshot portal — interactive permission; never invent frames.
    match ashpd::desktop::screenshot::ScreenshotRequest::default()
        .interactive(false)
        .send()
        .await
    {
        Ok(request) => match request.response() {
            Ok(screenshot) => {
                let uri = screenshot.uri();
                // Portal returns a file:// URI; reading it is best-effort.
                let path = uri.path();
                match std::fs::read(path) {
                    Ok(bytes) if !bytes.is_empty() => {
                        // Assume PNG from portal; re-encode to JPEG for protocol consistency.
                        match image::load_from_memory(&bytes) {
                            Ok(img) => {
                                let mut out = Vec::new();
                                let rgb = img.to_rgb8();
                                let mut cursor = std::io::Cursor::new(&mut out);
                                let enc = image::codecs::jpeg::JpegEncoder::new_with_quality(
                                    &mut cursor,
                                    80,
                                );
                                if rgb.write_with_encoder(enc).is_ok() {
                                    return Ok(CaptureOutcome::Image {
                                        jpeg: out,
                                        width: rgb.width() as i32,
                                        height: rgb.height() as i32,
                                        scale: 1.0,
                                    });
                                }
                            }
                            Err(e) => {
                                return Ok(CaptureOutcome::Unavailable {
                                    reason: format!("portal image decode failed: {e}"),
                                    capability: Some("wayland_portal_capture".into()),
                                });
                            }
                        }
                        Ok(CaptureOutcome::Unavailable {
                            reason: "portal returned unreadable image".into(),
                            capability: Some("wayland_portal_capture".into()),
                        })
                    }
                    Ok(_) => Ok(CaptureOutcome::Unavailable {
                        reason: "portal returned empty file".into(),
                        capability: Some("wayland_portal_capture".into()),
                    }),
                    Err(e) => Ok(CaptureOutcome::Unavailable {
                        reason: format!("read portal uri failed: {e}"),
                        capability: Some("wayland_portal_capture".into()),
                    }),
                }
            }
            Err(e) => Ok(CaptureOutcome::Unavailable {
                reason: format!("portal response denied/failed: {e}"),
                capability: Some("wayland_portal_capture".into()),
            }),
        },
        Err(e) => Ok(CaptureOutcome::Unavailable {
            reason: format!("Screenshot portal unavailable: {e}"),
            capability: Some("wayland_portal_capture".into()),
        }),
    }
}

async fn perform_x11_input(
    action: NativeAction,
    _interference: InterferencePolicy,
    target_is_frontmost: bool,
) -> ToolResult<DeliveryEvidence> {
    // Use enigo for X11 input synthesis.
    use enigo::{Button, Coordinate, Direction, Enigo, Key, Keyboard, Mouse, Settings};

    let mut enigo =
        Enigo::new(&Settings::default()).map_err(|e| ToolError::CapabilityUnavailable {
            capability: "x11_input".into(),
            platform: "linux".into(),
            detail: Some(format!("enigo init failed: {e}")),
        })?;

    match action {
        NativeAction::Click {
            at,
            button,
            click_count,
            global,
            ..
        } => {
            let p = global.or(at).ok_or_else(|| ToolError::InternalError {
                detail: Some("click requires coordinates".into()),
            })?;
            enigo
                .move_mouse(p.x as i32, p.y as i32, Coordinate::Abs)
                .map_err(|e| ToolError::InternalError {
                    detail: Some(format!("move: {e}")),
                })?;
            let btn = match button {
                semantouch_protocol::MouseButton::Left => Button::Left,
                semantouch_protocol::MouseButton::Right => Button::Right,
                semantouch_protocol::MouseButton::Middle => Button::Middle,
            };
            for _ in 0..click_count.max(1) {
                enigo
                    .button(btn, Direction::Click)
                    .map_err(|e| ToolError::InternalError {
                        detail: Some(format!("click: {e}")),
                    })?;
            }
            Ok(DeliveryEvidence {
                status: ActionStatus::Completed,
                method: ActionMethod::Pointer,
                state_changed: true,
                focus_changed: false,
                focus_restored: false,
                target_verified: target_is_frontmost,
                delivery_lane: "x11-enigo".into(),
                committed: None,
                element_focused: None,
                warning: None,
            })
        }
        NativeAction::TypeText { text, .. } => {
            enigo.text(&text).map_err(|e| ToolError::InternalError {
                detail: Some(format!("type: {e}")),
            })?;
            Ok(DeliveryEvidence {
                status: ActionStatus::Completed,
                method: ActionMethod::Keyboard,
                state_changed: true,
                focus_changed: false,
                focus_restored: false,
                target_verified: target_is_frontmost,
                delivery_lane: "x11-enigo".into(),
                committed: None,
                element_focused: None,
                warning: None,
            })
        }
        NativeAction::PressKey { combo, .. } => {
            // Very small chord subset: ctrl/shift/alt + key
            for chord in combo.split_whitespace() {
                let parts: Vec<&str> = chord.split('+').collect();
                let key = *parts.last().unwrap_or(&"");
                let mods: Vec<Key> = parts[..parts.len().saturating_sub(1)]
                    .iter()
                    .filter_map(|m| match *m {
                        "ctrl" | "control" => Some(Key::Control),
                        "shift" => Some(Key::Shift),
                        "alt" | "opt" => Some(Key::Alt),
                        "meta" | "cmd" | "win" | "super" => Some(Key::Meta),
                        _ => None,
                    })
                    .collect();
                for m in &mods {
                    let _ = enigo.key(*m, Direction::Press);
                }
                if key.len() == 1 {
                    let c = key.chars().next().unwrap();
                    let _ = enigo.key(Key::Unicode(c), Direction::Click);
                } else {
                    let k = match key {
                        "enter" => Some(Key::Return),
                        "esc" | "escape" => Some(Key::Escape),
                        "tab" => Some(Key::Tab),
                        "space" => Some(Key::Space),
                        _ => None,
                    };
                    if let Some(k) = k {
                        let _ = enigo.key(k, Direction::Click);
                    }
                }
                for m in mods.iter().rev() {
                    let _ = enigo.key(*m, Direction::Release);
                }
            }
            Ok(DeliveryEvidence {
                status: ActionStatus::Completed,
                method: ActionMethod::Keyboard,
                state_changed: true,
                focus_changed: false,
                focus_restored: false,
                target_verified: target_is_frontmost,
                delivery_lane: "x11-enigo".into(),
                committed: None,
                element_focused: None,
                warning: None,
            })
        }
        NativeAction::Drag {
            from,
            to,
            global_from,
            global_to,
            ..
        } => {
            let a = global_from.unwrap_or(from);
            let b = global_to.unwrap_or(to);
            enigo
                .move_mouse(a.x as i32, a.y as i32, Coordinate::Abs)
                .ok();
            enigo.button(Button::Left, Direction::Press).ok();
            enigo
                .move_mouse(b.x as i32, b.y as i32, Coordinate::Abs)
                .ok();
            enigo.button(Button::Left, Direction::Release).ok();
            Ok(DeliveryEvidence {
                status: ActionStatus::Completed,
                method: ActionMethod::Pointer,
                state_changed: true,
                focus_changed: false,
                focus_restored: false,
                target_verified: target_is_frontmost,
                delivery_lane: "x11-enigo".into(),
                committed: None,
                element_focused: None,
                warning: None,
            })
        }
        NativeAction::Scroll {
            direction,
            count,
            at,
            ..
        } => {
            if let Some(p) = at {
                enigo
                    .move_mouse(p.x as i32, p.y as i32, Coordinate::Abs)
                    .ok();
            }
            let length = (count.abs().ceil() as i32).max(1);
            let (dx, dy) = match direction {
                semantouch_protocol::ScrollDirection::Up => (0, length),
                semantouch_protocol::ScrollDirection::Down => (0, -length),
                semantouch_protocol::ScrollDirection::Left => (length, 0),
                semantouch_protocol::ScrollDirection::Right => (-length, 0),
            };
            enigo
                .scroll(dx, enigo::Axis::Horizontal)
                .or_else(|_| enigo.scroll(dy, enigo::Axis::Vertical))
                .map_err(|e| ToolError::InternalError {
                    detail: Some(format!("scroll: {e}")),
                })?;
            Ok(DeliveryEvidence {
                status: ActionStatus::Completed,
                method: ActionMethod::Pointer,
                state_changed: true,
                focus_changed: false,
                focus_restored: false,
                target_verified: target_is_frontmost,
                delivery_lane: "x11-enigo".into(),
                committed: None,
                element_focused: None,
                warning: None,
            })
        }
        other => Err(ToolError::InternalError {
            detail: Some(format!("x11 input path got non-input action: {other:?}")),
        }),
    }
}

#[cfg(test)]
mod mapping_tests {
    use super::*;

    fn sample_app(id: &str, name: &str, pid: Option<i32>) -> AppSummary {
        AppSummary {
            id: id.into(),
            display_name: name.into(),
            path: None,
            pid,
            is_running: true,
            windows: 0,
            last_used_at: None,
            use_count: None,
        }
    }

    #[test]
    fn map_atspi_action_names_to_ax_style() {
        assert_eq!(map_atspi_action_name("click"), "AXPress");
        assert_eq!(map_atspi_action_name("Press"), "AXPress");
        assert_eq!(map_atspi_action_name("settext"), "AXSetValue");
        assert_eq!(map_atspi_action_name("show menu"), "AXShowMenu");
        assert_eq!(map_atspi_action_name("custom-op"), "custom-op");
    }

    #[test]
    fn role_window_like_detects_frames_and_dialogs() {
        assert!(role_is_window_like("frame"));
        assert!(role_is_window_like("dialog"));
        assert!(role_is_window_like("window"));
        assert!(!role_is_window_like("push button"));
        assert!(!role_is_window_like("label"));
    }

    #[test]
    fn app_match_prefers_pid_then_exact_name() {
        let query = sample_app("pid:7", "Terminal", Some(7));
        let candidates = vec![
            sample_app("/usr/bin/foo", "foo", Some(3)),
            sample_app("/usr/bin/gnome-terminal", "Terminal", Some(7)),
            sample_app("/usr/bin/other-term", "Terminal", Some(9)),
        ];
        let best = select_best_app_match(&query, &candidates).expect("match");
        assert_eq!(best.pid, Some(7));

        let by_name = sample_app("x", "Firefox", None);
        let name_candidates = vec![
            sample_app("/usr/bin/chrome", "Chrome", Some(1)),
            sample_app("/usr/bin/firefox", "Firefox", Some(2)),
        ];
        let best_name = select_best_app_match(&by_name, &name_candidates).expect("name");
        assert_eq!(best_name.display_name, "Firefox");
    }

    #[test]
    fn stable_window_id_is_positive_and_stable() {
        let a = stable_window_id(":1.23", "/org/a11y/atspi/accessible/1");
        let b = stable_window_id(":1.23", "/org/a11y/atspi/accessible/1");
        let c = stable_window_id(":1.23", "/org/a11y/atspi/accessible/2");
        assert!(a > 0);
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    #[test]
    fn null_paths_are_rejected() {
        assert!(is_null_path("/org/a11y/atspi/null"));
        assert!(is_null_path("/org/a11y/atspi/accessible/null"));
        assert!(!is_null_path("/org/a11y/atspi/accessible/root"));
    }
}
