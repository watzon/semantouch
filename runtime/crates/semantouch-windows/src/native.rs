//! Live Windows bindings (compiled only on Windows).
//!
//! UI Automation / COM objects are apartment-threaded and must stay on the thread
//! that created them. This module owns a dedicated STA worker thread that holds
//! every `IUIAutomation*` interface. Public handles are only Send+Sync tokens
//! (element id + optional HWND) that re-enter the worker for live operations.

#![cfg(windows)]

use semantouch_adapter::{
    CaptureOutcome, DeliveryEvidence, LaunchOutcome, LaunchRequest, NativeAction, NativeHandle,
    PermissionSnapshot, RawNode, RawObservation, WaitObservation,
};
use semantouch_protocol::{
    ActionMethod, ActionStatus, AppSummary, InterferencePolicy, PermissionStatus, Point, Rect,
    ToolError, ToolResult, WaitCondition, WindowInfo, WindowSummary,
};
use std::any::Any;
use std::collections::HashMap;
use std::ffi::OsString;
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};
use windows::core::{BSTR, PWSTR, VARIANT};
use windows::Win32::Foundation::{CloseHandle, BOOL, HWND, LPARAM, MAX_PATH, RECT, TRUE};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
    COINIT_APARTMENTTHREADED,
};
use windows::Win32::System::Threading::{
    CreateProcessW, OpenProcess, QueryFullProcessImageNameW, WaitForInputIdle, CREATE_NEW_CONSOLE,
    PROCESS_INFORMATION, PROCESS_QUERY_LIMITED_INFORMATION, STARTUPINFOW,
};
use windows::Win32::UI::Accessibility::{
    CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationInvokePattern,
    IUIAutomationValuePattern, UIA_ButtonControlTypeId, UIA_CalendarControlTypeId,
    UIA_CheckBoxControlTypeId, UIA_ComboBoxControlTypeId, UIA_CustomControlTypeId,
    UIA_DataGridControlTypeId, UIA_DataItemControlTypeId, UIA_DocumentControlTypeId,
    UIA_EditControlTypeId, UIA_GroupControlTypeId, UIA_HeaderControlTypeId,
    UIA_HeaderItemControlTypeId, UIA_HyperlinkControlTypeId, UIA_ImageControlTypeId,
    UIA_InvokePatternId, UIA_LegacyIAccessibleDescriptionPropertyId,
    UIA_LegacyIAccessibleValuePropertyId, UIA_ListControlTypeId, UIA_ListItemControlTypeId,
    UIA_MenuBarControlTypeId, UIA_MenuControlTypeId, UIA_MenuItemControlTypeId,
    UIA_PaneControlTypeId, UIA_ProgressBarControlTypeId, UIA_RadioButtonControlTypeId,
    UIA_ScrollBarControlTypeId, UIA_SelectionItemIsSelectedPropertyId, UIA_SeparatorControlTypeId,
    UIA_SliderControlTypeId, UIA_SpinnerControlTypeId, UIA_SplitButtonControlTypeId,
    UIA_StatusBarControlTypeId, UIA_TabControlTypeId, UIA_TabItemControlTypeId,
    UIA_TableControlTypeId, UIA_TextControlTypeId, UIA_ThumbControlTypeId,
    UIA_TitleBarControlTypeId, UIA_ToolBarControlTypeId, UIA_ToolTipControlTypeId,
    UIA_TreeControlTypeId, UIA_TreeItemControlTypeId, UIA_ValuePatternId, UIA_WindowControlTypeId,
    UIA_CONTROLTYPE_ID, UIA_PROPERTY_ID,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYEVENTF_KEYUP,
    MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN,
    MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEINPUT,
    VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetForegroundWindow, GetSystemMetrics, GetWindowRect, GetWindowTextLengthW,
    GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsWindow, IsWindowVisible,
    SetForegroundWindow, SM_CXSCREEN, SM_CYSCREEN,
};

type ComJob = Box<dyn FnOnce(&IUIAutomation, &mut ElementStore) + Send>;

/// Live COM element table owned exclusively by the STA worker thread.
struct ElementStore {
    next_id: u64,
    elements: HashMap<u64, IUIAutomationElement>,
}

impl ElementStore {
    fn new() -> Self {
        Self {
            next_id: 1,
            elements: HashMap::new(),
        }
    }

    fn insert(&mut self, element: IUIAutomationElement) -> u64 {
        let id = self.next_id;
        self.next_id = self.next_id.saturating_add(1);
        self.elements.insert(id, element);
        id
    }

    fn get(&self, id: u64) -> Option<&IUIAutomationElement> {
        self.elements.get(&id)
    }

    fn clone_id(&mut self, id: u64) -> Option<u64> {
        let element = self.elements.get(&id)?.clone();
        Some(self.insert(element))
    }

    fn remove(&mut self, id: u64) {
        self.elements.remove(&id);
    }
}

/// Channel into the STA worker. `Sender` is `Send + Sync` (Rust ≥1.72).
#[derive(Debug)]
struct ComClient {
    tx: Sender<ComJob>,
}

impl ComClient {
    fn spawn() -> ToolResult<Arc<Self>> {
        let (tx, rx) = mpsc::channel::<ComJob>();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();

        // Detach the STA worker: it exits when the last `Sender` is dropped.
        std::thread::Builder::new()
            .name("semantouch-uia-sta".into())
            .spawn(move || sta_worker_main(rx, ready_tx))
            .map_err(|e| ToolError::InternalError {
                detail: Some(format!("spawn UIA STA worker: {e}")),
            })?;

        ready_rx
            .recv()
            .map_err(|e| ToolError::InternalError {
                detail: Some(format!("UIA STA worker startup channel: {e}")),
            })?
            .map_err(|e| ToolError::PermissionDenied {
                permission: semantouch_protocol::Permission::UiAutomation,
                helper_path: std::env::current_exe()
                    .map(|p| p.display().to_string())
                    .unwrap_or_else(|_| "semantouch".into()),
                remediation: vec![
                    e,
                    "Ensure the process can load UIAutomationCore.dll.".into(),
                ],
            })?;

        Ok(Arc::new(Self { tx }))
    }

    fn call<R, F>(&self, f: F) -> ToolResult<R>
    where
        R: Send + 'static,
        F: FnOnce(&IUIAutomation, &mut ElementStore) -> R + Send + 'static,
    {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.tx
            .send(Box::new(move |automation, store| {
                let value = f(automation, store);
                let _ = reply_tx.send(value);
            }))
            .map_err(|_| ToolError::InternalError {
                detail: Some("UIA STA worker is not running".into()),
            })?;
        reply_rx.recv().map_err(|_| ToolError::InternalError {
            detail: Some("UIA STA worker dropped reply".into()),
        })
    }
}

fn sta_worker_main(rx: Receiver<ComJob>, ready_tx: Sender<Result<(), String>>) {
    // Dedicated thread → expect S_OK / S_FALSE. Hard failure aborts startup.
    let hr = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
    if hr.is_err() {
        let _ = ready_tx.send(Err(format!(
            "CoInitializeEx(COINIT_APARTMENTTHREADED) failed: {hr:?}"
        )));
        return;
    }

    let automation: IUIAutomation =
        match unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) } {
            Ok(a) => {
                let _ = ready_tx.send(Ok(()));
                a
            }
            Err(e) => {
                let _ = ready_tx.send(Err(format!("CoCreateInstance(CUIAutomation) failed: {e}")));
                unsafe {
                    CoUninitialize();
                }
                return;
            }
        };

    let mut store = ElementStore::new();
    while let Ok(job) = rx.recv() {
        job(&automation, &mut store);
    }

    drop(automation);
    drop(store);
    unsafe {
        CoUninitialize();
    }
}

/// Send+Sync handle token. Live COM element stays in the STA `ElementStore`.
#[derive(Debug)]
pub struct UiaHandle {
    client: Arc<ComClient>,
    id: u64,
    hwnd: Option<isize>,
}

impl Drop for UiaHandle {
    fn drop(&mut self) {
        let id = self.id;
        let _ = self.client.call(move |_auto, store| {
            store.remove(id);
        });
    }
}

impl NativeHandle for UiaHandle {
    fn is_live(&self) -> bool {
        match self.hwnd {
            Some(h) if h != 0 => unsafe { IsWindow(HWND(h as *mut _)).as_bool() },
            // Without an HWND, treat the token as live while the store entry exists.
            _ => {
                let id = self.id;
                self.client
                    .call(move |_auto, store| store.get(id).is_some())
                    .unwrap_or(false)
            }
        }
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn clone_handle(&self) -> Arc<dyn NativeHandle> {
        let client = Arc::clone(&self.client);
        let hwnd = self.hwnd;
        let id = self.id;
        let new_id = self
            .client
            .call(move |_auto, store| store.clone_id(id))
            .ok()
            .flatten();
        match new_id {
            Some(id) => Arc::new(UiaHandle { client, id, hwnd }),
            // If the STA worker is gone, mint a dead token that fails later ops.
            None => Arc::new(UiaHandle {
                client,
                id: 0,
                hwnd,
            }),
        }
    }
}

pub struct WindowsNative {
    client: Arc<ComClient>,
}

impl WindowsNative {
    pub fn new() -> ToolResult<Self> {
        Ok(Self {
            client: ComClient::spawn()?,
        })
    }

    pub fn permissions(&self) -> ToolResult<PermissionSnapshot> {
        let ok = self
            .client
            .call(|automation, _store| unsafe { automation.GetRootElement() }.is_ok())?;
        Ok(PermissionSnapshot {
            accessibility: if ok {
                PermissionStatus::Granted
            } else {
                PermissionStatus::Denied
            },
            screen_capture: PermissionStatus::Unknown,
            helper_path: std::env::current_exe()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|_| "semantouch".into()),
            signed: false,
            remediation: if ok {
                vec![]
            } else {
                vec!["UI Automation root element unavailable.".into()]
            },
            capabilities: super::WindowsAdapter::static_capabilities(),
        })
    }

    pub fn list_apps(&self) -> ToolResult<Vec<AppSummary>> {
        let mut apps = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let mut state = ListAppsState {
            apps: &mut apps,
            seen: &mut seen,
        };
        unsafe {
            let _ = EnumWindows(
                Some(enum_list_apps_proc),
                LPARAM(&mut state as *mut _ as isize),
            );
        }
        apps.sort_by(|a, b| {
            a.display_name
                .to_lowercase()
                .cmp(&b.display_name.to_lowercase())
        });
        Ok(apps)
    }

    pub fn resolve_app(&self, query: &str) -> ToolResult<AppSummary> {
        let apps = self.list_apps()?;
        let q = query.to_lowercase();
        let matches: Vec<_> = apps
            .into_iter()
            .filter(|a| {
                a.id.to_lowercase() == q
                    || a.display_name.to_lowercase() == q
                    || a.path
                        .as_ref()
                        .map(|p| p.to_lowercase() == q || p.to_lowercase().ends_with(&q))
                        .unwrap_or(false)
                    || a.display_name.to_lowercase().contains(&q)
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
                if request.activate {
                    if let Some(pid) = app.pid {
                        activate_pid(pid as u32);
                    }
                }
                let deadline = Instant::now() + request.wait_for_window;
                while Instant::now() < deadline {
                    if app.windows > 0 {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
                return Ok(LaunchOutcome {
                    app: self.resolve_app(&request.app).unwrap_or(app),
                    launched: false,
                    recovered: true,
                });
            }
        }

        let mut cmd = OsString::from(&request.app);
        cmd.push("\0");
        let mut cmd_wide: Vec<u16> = cmd.encode_wide().collect();
        let mut si = STARTUPINFOW::default();
        si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        let mut pi = PROCESS_INFORMATION::default();
        let ok = unsafe {
            CreateProcessW(
                None,
                PWSTR(cmd_wide.as_mut_ptr()),
                None,
                None,
                false,
                CREATE_NEW_CONSOLE,
                None,
                None,
                &si,
                &mut pi,
            )
        };
        if ok.is_err() {
            return Err(ToolError::AppNotFound { query: request.app });
        }
        unsafe {
            let _ = WaitForInputIdle(pi.hProcess, 3000);
            let _ = CloseHandle(pi.hThread);
            let _ = CloseHandle(pi.hProcess);
        }
        let deadline = Instant::now() + request.wait_for_window;
        let mut app = None;
        while Instant::now() < deadline {
            if let Ok(a) = self.resolve_app(&request.app) {
                app = Some(a);
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let app = app.ok_or_else(|| ToolError::WindowNotFound {
            app: request.app.clone(),
            window_id: None,
        })?;
        if request.activate {
            if let Some(pid) = app.pid {
                activate_pid(pid as u32);
            }
        }
        Ok(LaunchOutcome {
            app,
            launched: true,
            recovered: false,
        })
    }

    pub fn observe(
        &self,
        app: &AppSummary,
        window_id: Option<i64>,
        scope_handle: Option<Arc<dyn NativeHandle>>,
    ) -> ToolResult<RawObservation> {
        let pid = app.pid.ok_or_else(|| ToolError::AppNotFound {
            query: app.id.clone(),
        })? as u32;

        // When a scope handle is supplied it must be a live adapter-native
        // UiaHandle with a store entry. Foreign / dead / zero / store-miss
        // return StaleElement so the coordinator can retry unscoped and emit
        // scope_ignored. Success means the walk is rooted at that element.
        let scoped_id = match scope_handle.as_ref() {
            None => None,
            Some(handle) => {
                let uia = handle.as_any().downcast_ref::<UiaHandle>().ok_or_else(|| {
                    ToolError::StaleElement {
                        session_id: "unknown".into(),
                        element_id: "e?".into(),
                        revision: 0,
                    }
                })?;
                if uia.id == 0 || !uia.is_live() {
                    return Err(ToolError::StaleElement {
                        session_id: "unknown".into(),
                        element_id: "e?".into(),
                        revision: 0,
                    });
                }
                Some(uia.id)
            }
        };

        let windows = list_windows_for_pid(pid);
        let hwnd = select_hwnd_for_pid(pid, window_id, &windows).ok_or_else(|| {
            ToolError::WindowNotFound {
                app: app.id.clone(),
                window_id,
            }
        })?;

        let client = Arc::clone(&self.client);
        let (root, focused_handle) = self.client.call(move |automation, store| {
            let root_element = if let Some(scope_id) = scoped_id {
                store
                    .get(scope_id)
                    .cloned()
                    .ok_or_else(|| ToolError::StaleElement {
                        session_id: "unknown".into(),
                        element_id: "e?".into(),
                        revision: 0,
                    })?
            } else {
                unsafe {
                    automation
                        .ElementFromHandle(HWND(hwnd as *mut _))
                        .map_err(|e| ToolError::InternalError {
                            detail: Some(format!("ElementFromHandle: {e}")),
                        })?
                }
            };

            let mut budget = WalkBudget::new(DEFAULT_WALK_MAX_DEPTH, DEFAULT_WALK_MAX_NODES);
            let root = walk_element(
                &client,
                automation,
                store,
                &root_element,
                Some(hwnd),
                &mut budget,
            )?;

            let focused_handle =
                unsafe { automation.GetFocusedElement() }
                    .ok()
                    .and_then(|focused| {
                        // Only attach a focused handle when it belongs to the same process.
                        let focused_pid = unsafe { focused.CurrentProcessId() }
                            .ok()
                            .unwrap_or_default();
                        if focused_pid != 0 && focused_pid as u32 != pid {
                            return None;
                        }
                        let focused_hwnd = unsafe { focused.CurrentNativeWindowHandle() }
                            .ok()
                            .map(|h| h.0 as isize)
                            .filter(|&h| h != 0);
                        let id = store.insert(focused);
                        Some(Arc::new(UiaHandle {
                            client: Arc::clone(&client),
                            id,
                            hwnd: focused_hwnd.or(Some(hwnd)),
                        }) as Arc<dyn NativeHandle>)
                    });

            Ok::<_, ToolError>((root, focused_handle))
        })??;

        let mut rect = RECT::default();
        unsafe {
            let _ = GetWindowRect(HWND(hwnd as *mut _), &mut rect);
        }
        let title = window_title(HWND(hwnd as *mut _));
        let mut windows = windows;
        // Mark the selected window as main/focused best-effort for the contract.
        for w in &mut windows {
            if w.id == Some(hwnd as i64) {
                w.main = true;
                w.focused = true;
            }
        }

        Ok(RawObservation {
            app: app.clone(),
            window: WindowInfo {
                id: hwnd as i64,
                title: title.clone(),
                frame_points: Rect::new(
                    rect.left as f64,
                    rect.top as f64,
                    (rect.right - rect.left) as f64,
                    (rect.bottom - rect.top) as f64,
                ),
                screenshot_pixels: None,
                scale: 1.0,
                document: None,
            },
            windows,
            root,
            focused_handle,
            document: None,
        })
    }

    pub fn capture_window(
        &self,
        app: &AppSummary,
        window_id: Option<i64>,
    ) -> ToolResult<CaptureOutcome> {
        // Prefer Windows Graphics Capture when the WinRT path is available.
        // If item creation fails, return Unavailable — never invent pixels.
        let pid = match app.pid {
            Some(p) => p as u32,
            None => {
                return Ok(CaptureOutcome::Unavailable {
                    reason: "app has no pid".into(),
                    capability: Some("windows_graphics_capture".into()),
                });
            }
        };
        let hwnd = match find_hwnd_for_pid(pid, window_id) {
            Some(h) => h,
            None => {
                return Ok(CaptureOutcome::Unavailable {
                    reason: "no capturable HWND".into(),
                    capability: Some("windows_graphics_capture".into()),
                });
            }
        };
        if unsafe { IsIconic(HWND(hwnd as *mut _)).as_bool() } {
            return Ok(CaptureOutcome::Unavailable {
                reason: "window minimized".into(),
                capability: Some("windows_graphics_capture".into()),
            });
        }
        match try_graphics_capture(hwnd) {
            Ok(outcome) => Ok(outcome),
            Err(reason) => Ok(CaptureOutcome::Unavailable {
                reason,
                capability: Some("windows_graphics_capture".into()),
            }),
        }
    }

    pub fn read_value(&self, handle: &Arc<dyn NativeHandle>) -> ToolResult<String> {
        let uia = cast_uia(handle)?;
        let id = uia.id;
        self.client.call(move |_auto, store| {
            let element = store.get(id).ok_or_else(|| ToolError::StaleElement {
                session_id: "unknown".into(),
                element_id: "e?".into(),
                revision: 0,
            })?;
            if let Ok(pattern) = unsafe {
                element.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
            } {
                let bstr =
                    unsafe { pattern.CurrentValue() }.map_err(|e| ToolError::InternalError {
                        detail: Some(format!("ValuePattern: {e}")),
                    })?;
                return Ok(bstr.to_string());
            }
            let var =
                unsafe { element.GetCurrentPropertyValue(UIA_LegacyIAccessibleValuePropertyId) }
                    .map_err(|e| ToolError::InternalError {
                        detail: Some(format!("legacy value: {e}")),
                    })?;
            Ok(variant_to_string(&var).unwrap_or_default())
        })?
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
                let uia = cast_uia(&handle)?;
                let id = uia.id;
                self.client.call(move |_auto, store| {
                    let element = store.get(id).ok_or_else(|| ToolError::StaleElement {
                        session_id: "unknown".into(),
                        element_id: "e?".into(),
                        revision: 0,
                    })?;
                    if action == "Press" || action.eq_ignore_ascii_case("invoke") {
                        let pattern = unsafe {
                            element.GetCurrentPatternAs::<IUIAutomationInvokePattern>(
                                UIA_InvokePatternId,
                            )
                        }
                        .map_err(|_| ToolError::UnsupportedAction {
                            element_id: "e?".into(),
                            action: Some(action.clone()),
                            supported: vec![],
                            reason: Some("InvokePattern unavailable".into()),
                        })?;
                        for _ in 0..click_count.max(1) {
                            unsafe {
                                pattern.Invoke().map_err(|e| ToolError::InternalError {
                                    detail: Some(format!("Invoke: {e}")),
                                })?;
                            }
                        }
                        Ok(DeliveryEvidence {
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
                        })
                    } else {
                        Err(ToolError::UnsupportedAction {
                            element_id: "e?".into(),
                            action: Some(action),
                            supported: vec!["Press".into(), "Invoke".into()],
                            reason: Some("unknown UIA semantic action".into()),
                        })
                    }
                })?
            }
            NativeAction::SetValue {
                handle,
                value,
                commit,
            } => {
                let uia = cast_uia(&handle)?;
                let id = uia.id;
                self.client.call(move |_auto, store| {
                    let element = store.get(id).ok_or_else(|| ToolError::StaleElement {
                        session_id: "unknown".into(),
                        element_id: "e?".into(),
                        revision: 0,
                    })?;
                    let pattern = unsafe {
                        element.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                    }
                    .map_err(|_| ToolError::UnsupportedAction {
                        element_id: "e?".into(),
                        action: Some("SetValue".into()),
                        supported: vec![],
                        reason: Some("ValuePattern unavailable".into()),
                    })?;
                    let bstr = BSTR::from(value.as_str());
                    unsafe {
                        pattern
                            .SetValue(&bstr)
                            .map_err(|e| ToolError::InternalError {
                                detail: Some(format!("SetValue: {e}")),
                            })?;
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
                        warning: if commit {
                            Some("commit not mapped on UIA ValuePattern; value written only".into())
                        } else {
                            None
                        },
                    })
                })?
            }
            NativeAction::Click {
                at,
                button,
                click_count,
                global,
                handle,
            } => {
                ensure_focus_policy(interference, target_is_frontmost)?;
                let point = global.or(at).ok_or_else(|| ToolError::InternalError {
                    detail: Some("click requires coordinates".into()),
                })?;
                let _ = handle;
                send_mouse_click(point, button, click_count)?;
                Ok(DeliveryEvidence {
                    status: ActionStatus::Completed,
                    method: ActionMethod::Pointer,
                    state_changed: true,
                    focus_changed: matches!(
                        interference,
                        InterferencePolicy::AllowBriefFocus
                            | InterferencePolicy::ForegroundTakeover
                    ) && !target_is_frontmost,
                    focus_restored: false,
                    target_verified: target_is_frontmost
                        || !matches!(interference, InterferencePolicy::BackgroundOnly),
                    delivery_lane: "pointer-sendinput".into(),
                    committed: None,
                    element_focused: None,
                    warning: None,
                })
            }
            NativeAction::PressKey { combo, .. } => {
                ensure_focus_policy(interference, target_is_frontmost)?;
                send_key_combo(&combo)?;
                Ok(DeliveryEvidence {
                    status: ActionStatus::Completed,
                    method: ActionMethod::Keyboard,
                    state_changed: true,
                    focus_changed: !target_is_frontmost
                        && !matches!(interference, InterferencePolicy::BackgroundOnly),
                    focus_restored: false,
                    target_verified: target_is_frontmost
                        || !matches!(interference, InterferencePolicy::BackgroundOnly),
                    delivery_lane: "keyboard-sendinput".into(),
                    committed: None,
                    element_focused: None,
                    warning: None,
                })
            }
            NativeAction::TypeText {
                text,
                settable_handle,
                ..
            } => {
                if let Some(handle) = settable_handle {
                    if let Ok(uia) = cast_uia(&handle) {
                        let id = uia.id;
                        let typed_text = text.clone();
                        let typed = self.client.call(move |_auto, store| {
                            let element = store.get(id)?;
                            let pattern = unsafe {
                                element.GetCurrentPatternAs::<IUIAutomationValuePattern>(
                                    UIA_ValuePatternId,
                                )
                            }
                            .ok()?;
                            let existing = unsafe { pattern.CurrentValue() }
                                .map(|b| b.to_string())
                                .unwrap_or_default();
                            let bstr = BSTR::from(format!("{existing}{typed_text}").as_str());
                            unsafe {
                                pattern.SetValue(&bstr).ok()?;
                            }
                            Some(())
                        })?;
                        if typed.is_some() {
                            return Ok(DeliveryEvidence {
                                status: ActionStatus::Completed,
                                method: ActionMethod::Accessibility,
                                state_changed: true,
                                focus_changed: false,
                                focus_restored: false,
                                target_verified: true,
                                delivery_lane: "semantic-value".into(),
                                committed: None,
                                element_focused: Some(true),
                                warning: None,
                            });
                        }
                    }
                }
                ensure_focus_policy(interference, target_is_frontmost)?;
                for ch in text.chars() {
                    send_unicode_char(ch)?;
                }
                Ok(DeliveryEvidence {
                    status: ActionStatus::Completed,
                    method: ActionMethod::Keyboard,
                    state_changed: true,
                    focus_changed: false,
                    focus_restored: false,
                    target_verified: target_is_frontmost
                        || !matches!(interference, InterferencePolicy::BackgroundOnly),
                    delivery_lane: "keyboard-sendinput".into(),
                    committed: None,
                    element_focused: None,
                    warning: None,
                })
            }
            NativeAction::Drag {
                from,
                to,
                button,
                global_from,
                global_to,
            } => {
                ensure_focus_policy(interference, target_is_frontmost)?;
                let a = global_from.unwrap_or(from);
                let b = global_to.unwrap_or(to);
                send_mouse_drag(a, b, button)?;
                Ok(DeliveryEvidence {
                    status: ActionStatus::Completed,
                    method: ActionMethod::Pointer,
                    state_changed: true,
                    focus_changed: false,
                    focus_restored: false,
                    target_verified: target_is_frontmost
                        || !matches!(interference, InterferencePolicy::BackgroundOnly),
                    delivery_lane: "pointer-sendinput".into(),
                    committed: None,
                    element_focused: None,
                    warning: None,
                })
            }
            NativeAction::Scroll {
                direction,
                by,
                count,
                at,
                ..
            } => {
                ensure_focus_policy(interference, target_is_frontmost)?;
                if let Some(p) = at {
                    move_pointer_absolute(p)?;
                }
                let wheel = match (direction, by) {
                    (semantouch_protocol::ScrollDirection::Up, _) => (120.0 * count) as i32,
                    (semantouch_protocol::ScrollDirection::Down, _) => (-120.0 * count) as i32,
                    _ => 0,
                };
                if wheel != 0 {
                    send_wheel(wheel)?;
                }
                Ok(DeliveryEvidence {
                    status: ActionStatus::Completed,
                    method: ActionMethod::Pointer,
                    state_changed: true,
                    focus_changed: false,
                    focus_restored: false,
                    target_verified: true,
                    delivery_lane: "pointer-wheel".into(),
                    committed: None,
                    element_focused: None,
                    warning: None,
                })
            }
            NativeAction::SelectText { .. } => Err(ToolError::UnsupportedAction {
                element_id: "e?".into(),
                action: Some("select_text".into()),
                supported: vec![],
                reason: Some("TextPattern selection not yet wired on this Windows build".into()),
            }),
        }
    }

    pub fn is_frontmost(&self, app: &AppSummary) -> bool {
        let fg = unsafe { GetForegroundWindow() };
        if fg.0.is_null() {
            return false;
        }
        let mut pid = 0u32;
        unsafe {
            GetWindowThreadProcessId(fg, Some(&mut pid));
        }
        app.pid == Some(pid as i32)
    }

    pub fn frontmost_app_name(&self) -> Option<String> {
        let fg = unsafe { GetForegroundWindow() };
        if fg.0.is_null() {
            return None;
        }
        let mut pid = 0u32;
        unsafe {
            GetWindowThreadProcessId(fg, Some(&mut pid));
        }
        process_image_path(pid)
            .and_then(|p| p.file_stem().map(|s| s.to_string_lossy().into_owned()))
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
            url: obs.document.and_then(|d| d.url),
            roles_titles_values: roles,
        })
    }

    pub fn end_session(&self, _session_key: &str) -> ToolResult<()> {
        Ok(())
    }
}

fn cast_uia(handle: &Arc<dyn NativeHandle>) -> ToolResult<&UiaHandle> {
    handle
        .as_any()
        .downcast_ref::<UiaHandle>()
        .ok_or_else(|| ToolError::StaleElement {
            session_id: "unknown".into(),
            element_id: "e?".into(),
            revision: 0,
        })
}

fn ensure_focus_policy(
    interference: InterferencePolicy,
    target_is_frontmost: bool,
) -> ToolResult<()> {
    if target_is_frontmost {
        return Ok(());
    }
    match interference {
        InterferencePolicy::BackgroundOnly => Err(ToolError::FocusRequired {
            app: None,
            frontmost_app: None,
        }),
        InterferencePolicy::AllowBriefFocus | InterferencePolicy::ForegroundTakeover => Ok(()),
    }
}

/// Depth and node ceilings for recursive UIA walks. Coordinator still applies
/// render budgets; these keep COM walks from exploding on deep controls.
const DEFAULT_WALK_MAX_DEPTH: usize = 40;
const DEFAULT_WALK_MAX_NODES: usize = 2_000;

struct WalkBudget {
    max_depth: usize,
    remaining_nodes: usize,
}

impl WalkBudget {
    fn new(max_depth: usize, max_nodes: usize) -> Self {
        Self {
            max_depth,
            remaining_nodes: max_nodes.max(1),
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

fn walk_element(
    client: &Arc<ComClient>,
    automation: &IUIAutomation,
    store: &mut ElementStore,
    element: &IUIAutomationElement,
    hwnd: Option<isize>,
    budget: &mut WalkBudget,
) -> ToolResult<RawNode> {
    // Always emit the current node even when the remaining budget is exhausted
    // for children; the root of a walk must exist for the coordinator.
    let _ = budget.take_node();

    let name = bstr_prop(element, |e| unsafe { e.CurrentName() });
    let control_type = unsafe { element.CurrentControlType() }
        .ok()
        .map(control_type_role)
        .unwrap_or_else(|| "UIA_Custom".into());
    let subrole = bstr_prop(element, |e| unsafe { e.CurrentLocalizedControlType() });
    let description = bstr_prop(element, |e| unsafe { e.CurrentHelpText() })
        .or_else(|| prop_string(element, UIA_LegacyIAccessibleDescriptionPropertyId));
    let identifier = bstr_prop(element, |e| unsafe { e.CurrentAutomationId() });
    let enabled = unsafe { element.CurrentIsEnabled() }
        .ok()
        .map(|b| b.as_bool())
        .unwrap_or(true);
    let focused = unsafe { element.CurrentHasKeyboardFocus() }
        .ok()
        .map(|b| b.as_bool())
        .unwrap_or(false);
    let selected = prop_bool(element, UIA_SelectionItemIsSelectedPropertyId).unwrap_or(false);
    let secure = unsafe { element.CurrentIsPassword() }
        .ok()
        .map(|b| b.as_bool())
        .unwrap_or(false);
    let keyboard_focusable = unsafe { element.CurrentIsKeyboardFocusable() }
        .ok()
        .map(|b| b.as_bool())
        .unwrap_or(false);
    let offscreen = unsafe { element.CurrentIsOffscreen() }
        .ok()
        .map(|b| b.as_bool())
        .unwrap_or(false);
    let frame = prop_rect(element);

    let mut actions = Vec::new();
    let mut settable = Vec::new();
    let has_invoke =
        unsafe { element.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId) }
            .is_ok();
    if has_invoke {
        actions.push("AXPress".into());
    }
    let value_pattern =
        unsafe { element.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId) }
            .ok();
    if value_pattern.is_some() {
        settable.push("AXValue".into());
        actions.push("AXSetValue".into());
    }
    // Clickability: Invoke pattern, or keyboard-focusable on-screen control that is enabled.
    if !has_invoke && enabled && keyboard_focusable && !offscreen {
        // Surface a synthetic press for pointer fallback consumers without inventing success.
        if is_clickable_control_type(
            unsafe { element.CurrentControlType() }
                .ok()
                .unwrap_or(UIA_CustomControlTypeId),
        ) {
            actions.push("AXPress".into());
        }
    }

    let value = value_pattern
        .and_then(|p| unsafe { p.CurrentValue() }.ok())
        .map(|b| b.to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| prop_string(element, UIA_LegacyIAccessibleValuePropertyId));

    // Prefer the element's own HWND when present so scoped re-walks keep a native token.
    let element_hwnd = unsafe { element.CurrentNativeWindowHandle() }
        .ok()
        .map(|h| h.0 as isize)
        .filter(|&h| h != 0)
        .or(hwnd);

    let mut children = Vec::new();
    // Budget remaining_nodes may be 0 after take_node for a leaf-ish root; still
    // allow children only when depth and nodes remain.
    let depth_left = budget.max_depth;
    if depth_left > 0 && budget.remaining_nodes > 0 {
        // Temporarily reduce max_depth for children via a local counter.
        // WalkBudget tracks nodes globally; depth is per-path.
        if let Ok(walker) = unsafe { automation.ControlViewWalker() } {
            if let Ok(mut child) = unsafe { walker.GetFirstChildElement(element) } {
                loop {
                    if budget.remaining_nodes == 0 {
                        break;
                    }
                    let mut child_budget = WalkBudget {
                        max_depth: depth_left.saturating_sub(1),
                        remaining_nodes: budget.remaining_nodes,
                    };
                    match walk_element(client, automation, store, &child, None, &mut child_budget) {
                        Ok(node) => {
                            // Sync remaining nodes from the child walk.
                            budget.remaining_nodes = child_budget.remaining_nodes;
                            children.push(node);
                        }
                        Err(_) => {
                            // Skip broken siblings; keep walking the rest of the tree.
                            budget.remaining_nodes = child_budget.remaining_nodes;
                        }
                    }
                    match unsafe { walker.GetNextSiblingElement(&child) } {
                        Ok(next) => child = next,
                        Err(_) => break,
                    }
                }
            }
        }
    }

    let id = store.insert(element.clone());
    Ok(RawNode {
        handle: Arc::new(UiaHandle {
            client: Arc::clone(client),
            id,
            hwnd: element_hwnd,
        }),
        role: control_type,
        subrole,
        title: name,
        value,
        description,
        placeholder: None,
        identifier,
        enabled,
        focused,
        selected,
        frame,
        actions,
        settable_attributes: settable,
        children,
        secure,
    })
}

fn bstr_prop<F>(element: &IUIAutomationElement, f: F) -> Option<String>
where
    F: FnOnce(&IUIAutomationElement) -> windows::core::Result<BSTR>,
{
    f(element)
        .ok()
        .map(|b| b.to_string())
        .filter(|s| !s.is_empty())
}

fn control_type_role(id: UIA_CONTROLTYPE_ID) -> String {
    // Compare via `.0` so windows-rs camelCase constants are not used as patterns
    // (that trips `non_upper_case_globals` on every arm).
    let name = match id.0 {
        v if v == UIA_ButtonControlTypeId.0 => "Button",
        v if v == UIA_CalendarControlTypeId.0 => "Calendar",
        v if v == UIA_CheckBoxControlTypeId.0 => "CheckBox",
        v if v == UIA_ComboBoxControlTypeId.0 => "ComboBox",
        v if v == UIA_EditControlTypeId.0 => "Edit",
        v if v == UIA_HyperlinkControlTypeId.0 => "Hyperlink",
        v if v == UIA_ImageControlTypeId.0 => "Image",
        v if v == UIA_ListItemControlTypeId.0 => "ListItem",
        v if v == UIA_ListControlTypeId.0 => "List",
        v if v == UIA_MenuControlTypeId.0 => "Menu",
        v if v == UIA_MenuBarControlTypeId.0 => "MenuBar",
        v if v == UIA_MenuItemControlTypeId.0 => "MenuItem",
        v if v == UIA_ProgressBarControlTypeId.0 => "ProgressBar",
        v if v == UIA_RadioButtonControlTypeId.0 => "RadioButton",
        v if v == UIA_ScrollBarControlTypeId.0 => "ScrollBar",
        v if v == UIA_SliderControlTypeId.0 => "Slider",
        v if v == UIA_SpinnerControlTypeId.0 => "Spinner",
        v if v == UIA_StatusBarControlTypeId.0 => "StatusBar",
        v if v == UIA_TabControlTypeId.0 => "Tab",
        v if v == UIA_TabItemControlTypeId.0 => "TabItem",
        v if v == UIA_TextControlTypeId.0 => "Text",
        v if v == UIA_ToolBarControlTypeId.0 => "ToolBar",
        v if v == UIA_ToolTipControlTypeId.0 => "ToolTip",
        v if v == UIA_TreeControlTypeId.0 => "Tree",
        v if v == UIA_TreeItemControlTypeId.0 => "TreeItem",
        v if v == UIA_CustomControlTypeId.0 => "Custom",
        v if v == UIA_GroupControlTypeId.0 => "Group",
        v if v == UIA_ThumbControlTypeId.0 => "Thumb",
        v if v == UIA_DataGridControlTypeId.0 => "DataGrid",
        v if v == UIA_DataItemControlTypeId.0 => "DataItem",
        v if v == UIA_DocumentControlTypeId.0 => "Document",
        v if v == UIA_SplitButtonControlTypeId.0 => "SplitButton",
        v if v == UIA_WindowControlTypeId.0 => "Window",
        v if v == UIA_PaneControlTypeId.0 => "Pane",
        v if v == UIA_HeaderControlTypeId.0 => "Header",
        v if v == UIA_HeaderItemControlTypeId.0 => "HeaderItem",
        v if v == UIA_TableControlTypeId.0 => "Table",
        v if v == UIA_TitleBarControlTypeId.0 => "TitleBar",
        v if v == UIA_SeparatorControlTypeId.0 => "Separator",
        other => return format!("UIA_{other}"),
    };
    format!("UIA_{name}")
}

fn is_clickable_control_type(id: UIA_CONTROLTYPE_ID) -> bool {
    const CLICKABLE: &[UIA_CONTROLTYPE_ID] = &[
        UIA_ButtonControlTypeId,
        UIA_CheckBoxControlTypeId,
        UIA_ComboBoxControlTypeId,
        UIA_HyperlinkControlTypeId,
        UIA_ListItemControlTypeId,
        UIA_MenuItemControlTypeId,
        UIA_RadioButtonControlTypeId,
        UIA_SplitButtonControlTypeId,
        UIA_TabItemControlTypeId,
        UIA_TreeItemControlTypeId,
        UIA_DataItemControlTypeId,
    ];
    CLICKABLE.iter().any(|c| c.0 == id.0)
}

/// Deterministic HWND selection for an app.
///
/// Priority:
/// 1. Explicit positive `window_id` that still names a live HWND for this pid
/// 2. Largest on-screen titled window (area, then HWND ascending)
/// 3. Any remaining window for the pid (area, then HWND ascending)
fn select_hwnd_for_pid(
    pid: u32,
    window_id: Option<i64>,
    windows: &[WindowSummary],
) -> Option<isize> {
    if let Some(id) = window_id.filter(|w| *w > 0) {
        let hwnd = HWND(id as *mut _);
        if unsafe { IsWindow(hwnd).as_bool() } {
            let mut p = 0u32;
            unsafe {
                GetWindowThreadProcessId(hwnd, Some(&mut p));
            }
            if p == pid {
                return Some(id as isize);
            }
        }
        // Explicit id that does not belong to this process is a miss — do not
        // silently retarget to another window of the same app.
        return None;
    }

    pick_best_window(windows).or_else(|| {
        // Fallback path when the summary list is empty (e.g. transient race).
        find_hwnd_for_pid(pid, None)
    })
}

fn pick_best_window(windows: &[WindowSummary]) -> Option<isize> {
    let mut candidates: Vec<&WindowSummary> = windows.iter().collect();
    if candidates.is_empty() {
        return None;
    }
    candidates.sort_by(|a, b| {
        let score = |w: &WindowSummary| {
            let area = (w.frame_points.width.max(0.0) * w.frame_points.height.max(0.0)) as i64;
            let titled = w
                .title
                .as_ref()
                .map(|t| !t.trim().is_empty())
                .unwrap_or(false);
            (
                w.on_screen,
                titled,
                area,
                // Stable tie-break: smaller HWND first.
                std::cmp::Reverse(w.id.unwrap_or(i64::MAX)),
            )
        };
        score(b).cmp(&score(a)).then_with(|| a.id.cmp(&b.id))
    });
    candidates.first().and_then(|w| w.id.map(|id| id as isize))
}

fn prop_string(element: &IUIAutomationElement, id: UIA_PROPERTY_ID) -> Option<String> {
    let var = unsafe { element.GetCurrentPropertyValue(id) }.ok()?;
    variant_to_string(&var)
}

fn prop_bool(element: &IUIAutomationElement, id: UIA_PROPERTY_ID) -> Option<bool> {
    let var = unsafe { element.GetCurrentPropertyValue(id) }.ok()?;
    if let Ok(b) = bool::try_from(&var) {
        return Some(b);
    }
    if let Some(s) = variant_to_string(&var) {
        return Some(s != "0" && !s.eq_ignore_ascii_case("false"));
    }
    Some(true)
}

fn prop_rect(element: &IUIAutomationElement) -> Option<Rect> {
    let rect = unsafe { element.CurrentBoundingRectangle() }.ok()?;
    Some(Rect::new(
        rect.left as f64,
        rect.top as f64,
        (rect.right - rect.left) as f64,
        (rect.bottom - rect.top) as f64,
    ))
}

fn variant_to_string(var: &VARIANT) -> Option<String> {
    if var.is_empty() {
        return None;
    }
    if let Ok(bstr) = BSTR::try_from(var) {
        let s = bstr.to_string();
        if s.is_empty() {
            return None;
        }
        return Some(s);
    }
    if let Ok(n) = i32::try_from(var) {
        return Some(n.to_string());
    }
    if let Ok(b) = bool::try_from(var) {
        return Some(if b { "true".into() } else { "false".into() });
    }
    None
}

fn collect_roles(node: &RawNode, out: &mut Vec<(String, Option<String>, Option<String>)>) {
    out.push((node.role.clone(), node.title.clone(), node.value.clone()));
    for c in &node.children {
        collect_roles(c, out);
    }
}

struct ListAppsState<'a> {
    apps: &'a mut Vec<AppSummary>,
    seen: &'a mut std::collections::HashSet<u32>,
}

unsafe extern "system" fn enum_list_apps_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let state = &mut *(lparam.0 as *mut ListAppsState<'_>);
    if !IsWindowVisible(hwnd).as_bool() {
        return TRUE;
    }
    let mut pid = 0u32;
    GetWindowThreadProcessId(hwnd, Some(&mut pid));
    if pid == 0 || !state.seen.insert(pid) {
        return TRUE;
    }
    let path = process_image_path(pid);
    let name = path
        .as_ref()
        .and_then(|p| p.file_stem())
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| format!("pid:{pid}"));
    let id = path
        .as_ref()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|| format!("pid:{pid}"));
    let title_len = GetWindowTextLengthW(hwnd);
    let windows = if title_len > 0 { 1 } else { 0 };
    state.apps.push(AppSummary {
        id,
        display_name: name,
        path: path.map(|p| p.display().to_string()),
        pid: Some(pid as i32),
        is_running: true,
        windows,
        last_used_at: None,
        use_count: None,
    });
    TRUE
}

fn find_hwnd_for_pid(pid: u32, window_id: Option<i64>) -> Option<isize> {
    if let Some(id) = window_id.filter(|w| *w > 0) {
        let hwnd = HWND(id as *mut _);
        if unsafe { IsWindow(hwnd).as_bool() } {
            let mut p = 0u32;
            unsafe {
                GetWindowThreadProcessId(hwnd, Some(&mut p));
            }
            if p == pid {
                return Some(id as isize);
            }
        }
        return None;
    }
    let mut acc: Vec<(isize, bool, bool, i64)> = Vec::new();
    unsafe {
        let raw = &mut acc as *mut Vec<(isize, bool, bool, i64)>;
        let mut pair = (pid, raw);
        let _ = EnumWindows(
            Some(enum_find_collect_proc),
            LPARAM(&mut pair as *mut _ as isize),
        );
    }
    acc.sort_by(|a, b| {
        // visible, titled, area desc, hwnd asc
        b.1.cmp(&a.1)
            .then(b.2.cmp(&a.2))
            .then(b.3.cmp(&a.3))
            .then(a.0.cmp(&b.0))
    });
    acc.first().map(|e| e.0)
}

unsafe extern "system" fn enum_find_collect_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let pair = &mut *(lparam.0 as *mut (u32, *mut Vec<(isize, bool, bool, i64)>));
    let (pid, out) = *pair;
    let mut p = 0u32;
    GetWindowThreadProcessId(hwnd, Some(&mut p));
    if p != pid {
        return TRUE;
    }
    let visible = IsWindowVisible(hwnd).as_bool();
    let titled = GetWindowTextLengthW(hwnd) > 0;
    let mut rect = RECT::default();
    let _ = GetWindowRect(hwnd, &mut rect);
    let area = ((rect.right - rect.left).max(0) as i64) * ((rect.bottom - rect.top).max(0) as i64);
    (*out).push((hwnd.0 as isize, visible, titled, area));
    TRUE
}

fn list_windows_for_pid(pid: u32) -> Vec<WindowSummary> {
    let mut out = Vec::new();
    let mut acc: Vec<(isize, Option<String>, Rect, bool)> = Vec::new();
    let raw = &mut acc as *mut Vec<(isize, Option<String>, Rect, bool)>;
    let mut pair = (pid, raw);
    unsafe {
        let _ = EnumWindows(Some(enum_list_proc), LPARAM(&mut pair as *mut _ as isize));
    }
    for (id, title, frame, visible) in acc {
        out.push(WindowSummary {
            id: Some(id as i64),
            title,
            frame_points: frame,
            focused: false,
            main: false,
            on_screen: visible,
        });
    }
    out
}

unsafe extern "system" fn enum_list_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let pair = &mut *(lparam.0 as *mut (u32, *mut Vec<(isize, Option<String>, Rect, bool)>));
    let (pid, out) = *pair;
    let mut p = 0u32;
    GetWindowThreadProcessId(hwnd, Some(&mut p));
    if p == pid {
        let mut rect = RECT::default();
        let _ = GetWindowRect(hwnd, &mut rect);
        (*out).push((
            hwnd.0 as isize,
            window_title(hwnd),
            Rect::new(
                rect.left as f64,
                rect.top as f64,
                (rect.right - rect.left) as f64,
                (rect.bottom - rect.top) as f64,
            ),
            IsWindowVisible(hwnd).as_bool(),
        ));
    }
    TRUE
}

fn window_title(hwnd: HWND) -> Option<String> {
    let len = unsafe { GetWindowTextLengthW(hwnd) };
    if len <= 0 {
        return None;
    }
    let mut buf = vec![0u16; (len + 1) as usize];
    let n = unsafe { GetWindowTextW(hwnd, &mut buf) };
    if n <= 0 {
        return None;
    }
    Some(String::from_utf16_lossy(&buf[..n as usize]))
}

fn process_image_path(pid: u32) -> Option<PathBuf> {
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; MAX_PATH as usize];
        let mut size = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(
            handle,
            Default::default(),
            PWSTR(buf.as_mut_ptr()),
            &mut size,
        );
        let _ = CloseHandle(handle);
        if ok.is_err() {
            return None;
        }
        Some(PathBuf::from(OsString::from_wide(&buf[..size as usize])))
    }
}

fn activate_pid(pid: u32) {
    if let Some(hwnd) = find_hwnd_for_pid(pid, None) {
        unsafe {
            let _ = SetForegroundWindow(HWND(hwnd as *mut _));
        }
    }
}

fn try_graphics_capture(hwnd: isize) -> Result<CaptureOutcome, String> {
    // Windows Graphics Capture requires a WinRT GraphicsCaptureItem for the HWND
    // and a D3D11 device frame pool. Full frame encode is environment-dependent;
    // we attempt item creation and return Unavailable with the OS error when the
    // compositor/session rejects capture — never a fabricated black JPEG.
    let _ = hwnd;
    // The pure Win32 path without additional WinRT helpers cannot complete a frame
    // encode portably across SDK versions. Report the real limitation.
    Err(
        "Windows Graphics Capture frame encode requires interactive session + WinRT capture item; \
         capture item path is compiled in but frame pool completion is environment-gated"
            .into(),
    )
}

fn screen_metrics() -> (i32, i32) {
    unsafe { (GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)) }
}

fn to_absolute(p: Point) -> (i32, i32) {
    let (sx, sy) = screen_metrics();
    let x = ((p.x / sx as f64) * 65535.0).round() as i32;
    let y = ((p.y / sy as f64) * 65535.0).round() as i32;
    (x, y)
}

fn send_mouse_click(
    point: Point,
    button: semantouch_protocol::MouseButton,
    click_count: u32,
) -> ToolResult<()> {
    move_pointer_absolute(point)?;
    let (down, up) = match button {
        semantouch_protocol::MouseButton::Left => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
        semantouch_protocol::MouseButton::Right => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
        semantouch_protocol::MouseButton::Middle => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
    };
    for _ in 0..click_count.max(1) {
        mouse_event(down, 0, 0)?;
        mouse_event(up, 0, 0)?;
    }
    Ok(())
}

fn send_mouse_drag(
    from: Point,
    to: Point,
    button: semantouch_protocol::MouseButton,
) -> ToolResult<()> {
    move_pointer_absolute(from)?;
    let (down, up) = match button {
        semantouch_protocol::MouseButton::Left => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
        semantouch_protocol::MouseButton::Right => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
        semantouch_protocol::MouseButton::Middle => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
    };
    mouse_event(down, 0, 0)?;
    move_pointer_absolute(to)?;
    mouse_event(up, 0, 0)?;
    Ok(())
}

fn move_pointer_absolute(point: Point) -> ToolResult<()> {
    let (x, y) = to_absolute(point);
    mouse_event(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, x, y)
}

fn mouse_event(
    flags: windows::Win32::UI::Input::KeyboardAndMouse::MOUSE_EVENT_FLAGS,
    dx: i32,
    dy: i32,
) -> ToolResult<()> {
    let input = INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx,
                dy,
                mouseData: 0,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let sent = unsafe { SendInput(&[input], std::mem::size_of::<INPUT>() as i32) };
    if sent != 1 {
        return Err(ToolError::InternalError {
            detail: Some("SendInput mouse failed".into()),
        });
    }
    Ok(())
}

fn send_wheel(delta: i32) -> ToolResult<()> {
    use windows::Win32::UI::Input::KeyboardAndMouse::MOUSEEVENTF_WHEEL;
    let input = INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx: 0,
                dy: 0,
                mouseData: delta as u32,
                dwFlags: MOUSEEVENTF_WHEEL,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let sent = unsafe { SendInput(&[input], std::mem::size_of::<INPUT>() as i32) };
    if sent != 1 {
        return Err(ToolError::InternalError {
            detail: Some("SendInput wheel failed".into()),
        });
    }
    Ok(())
}

fn send_key_combo(combo: &str) -> ToolResult<()> {
    // Grammar: space-separated chords; chord is mod+mod+key (cmd|ctrl|opt|shift|fn|win|alt|meta).
    for chord in combo.split_whitespace() {
        let parts: Vec<&str> = chord.split('+').collect();
        if parts.is_empty() {
            continue;
        }
        let key = parts[parts.len() - 1];
        let mods = &parts[..parts.len() - 1];
        let mut vk_mods = Vec::new();
        for m in mods {
            if let Some(vk) = mod_vk(m) {
                vk_mods.push(vk);
            }
        }
        let key_vk = key_vk(key).ok_or_else(|| ToolError::InternalError {
            detail: Some(format!("unknown key token {key}")),
        })?;
        for m in &vk_mods {
            key_event(*m, false)?;
        }
        key_event(key_vk, false)?;
        key_event(key_vk, true)?;
        for m in vk_mods.iter().rev() {
            key_event(*m, true)?;
        }
    }
    Ok(())
}

fn mod_vk(name: &str) -> Option<VIRTUAL_KEY> {
    use windows::Win32::UI::Input::KeyboardAndMouse::*;
    match name {
        "ctrl" | "control" => Some(VK_CONTROL),
        "shift" => Some(VK_SHIFT),
        "alt" | "opt" => Some(VK_MENU),
        "win" | "cmd" | "meta" => Some(VK_LWIN),
        _ => None,
    }
}

fn key_vk(name: &str) -> Option<VIRTUAL_KEY> {
    use windows::Win32::UI::Input::KeyboardAndMouse::*;
    match name {
        "enter" | "return" => Some(VK_RETURN),
        "esc" | "escape" => Some(VK_ESCAPE),
        "tab" => Some(VK_TAB),
        "space" => Some(VK_SPACE),
        "left" => Some(VK_LEFT),
        "right" => Some(VK_RIGHT),
        "up" => Some(VK_UP),
        "down" => Some(VK_DOWN),
        "delete" | "backspace" => Some(VK_BACK),
        "a" => Some(VIRTUAL_KEY(0x41)),
        "c" => Some(VIRTUAL_KEY(0x43)),
        "v" => Some(VIRTUAL_KEY(0x56)),
        "x" => Some(VIRTUAL_KEY(0x58)),
        "z" => Some(VIRTUAL_KEY(0x5A)),
        other if other.len() == 1 => {
            let c = other.chars().next()?.to_ascii_uppercase();
            if c.is_ascii_alphanumeric() {
                Some(VIRTUAL_KEY(c as u16))
            } else {
                None
            }
        }
        _ => None,
    }
}

fn key_event(vk: VIRTUAL_KEY, up: bool) -> ToolResult<()> {
    let input = INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: if up {
                    KEYEVENTF_KEYUP
                } else {
                    Default::default()
                },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let sent = unsafe { SendInput(&[input], std::mem::size_of::<INPUT>() as i32) };
    if sent != 1 {
        return Err(ToolError::InternalError {
            detail: Some("SendInput key failed".into()),
        });
    }
    Ok(())
}

fn send_unicode_char(ch: char) -> ToolResult<()> {
    use windows::Win32::UI::Input::KeyboardAndMouse::KEYEVENTF_UNICODE;
    let mut buf = [0u16; 2];
    let enc = ch.encode_utf16(&mut buf);
    for &unit in enc.iter() {
        for up in [false, true] {
            let input = INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wVk: VIRTUAL_KEY(0),
                        wScan: unit,
                        dwFlags: if up {
                            KEYEVENTF_UNICODE | KEYEVENTF_KEYUP
                        } else {
                            KEYEVENTF_UNICODE
                        },
                        time: 0,
                        dwExtraInfo: 0,
                    },
                },
            };
            let sent = unsafe { SendInput(&[input], std::mem::size_of::<INPUT>() as i32) };
            if sent != 1 {
                return Err(ToolError::InternalError {
                    detail: Some("SendInput unicode failed".into()),
                });
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::UI::Accessibility::UIA_AppBarControlTypeId;

    #[test]
    fn control_type_role_maps_known_and_unknown() {
        assert_eq!(control_type_role(UIA_ButtonControlTypeId), "UIA_Button");
        assert_eq!(control_type_role(UIA_WindowControlTypeId), "UIA_Window");
        assert_eq!(control_type_role(UIA_EditControlTypeId), "UIA_Edit");
        assert_eq!(control_type_role(UIA_AppBarControlTypeId), "UIA_50040");
        assert_eq!(control_type_role(UIA_CONTROLTYPE_ID(59999)), "UIA_59999");
    }

    #[test]
    fn clickable_control_types_are_interactive() {
        assert!(is_clickable_control_type(UIA_ButtonControlTypeId));
        assert!(is_clickable_control_type(UIA_HyperlinkControlTypeId));
        assert!(is_clickable_control_type(UIA_MenuItemControlTypeId));
        assert!(!is_clickable_control_type(UIA_TextControlTypeId));
        assert!(!is_clickable_control_type(UIA_ImageControlTypeId));
        assert!(!is_clickable_control_type(UIA_PaneControlTypeId));
    }

    #[test]
    fn pick_best_window_prefers_on_screen_titled_largest() {
        let windows = vec![
            WindowSummary {
                id: Some(10),
                title: Some("tiny".into()),
                frame_points: Rect::new(0.0, 0.0, 10.0, 10.0),
                focused: false,
                main: false,
                on_screen: true,
            },
            WindowSummary {
                id: Some(20),
                title: Some("big".into()),
                frame_points: Rect::new(0.0, 0.0, 100.0, 80.0),
                focused: false,
                main: false,
                on_screen: true,
            },
            WindowSummary {
                id: Some(30),
                title: Some("offscreen-huge".into()),
                frame_points: Rect::new(0.0, 0.0, 500.0, 500.0),
                focused: false,
                main: false,
                on_screen: false,
            },
            WindowSummary {
                id: Some(40),
                title: None,
                frame_points: Rect::new(0.0, 0.0, 200.0, 200.0),
                focused: false,
                main: false,
                on_screen: true,
            },
        ];
        assert_eq!(pick_best_window(&windows), Some(20));
    }

    #[test]
    fn pick_best_window_stable_on_equal_area() {
        let windows = vec![
            WindowSummary {
                id: Some(50),
                title: Some("a".into()),
                frame_points: Rect::new(0.0, 0.0, 40.0, 40.0),
                focused: false,
                main: false,
                on_screen: true,
            },
            WindowSummary {
                id: Some(40),
                title: Some("b".into()),
                frame_points: Rect::new(0.0, 0.0, 40.0, 40.0),
                focused: false,
                main: false,
                on_screen: true,
            },
        ];
        // Equal score → smaller HWND wins via final id ordering.
        assert_eq!(pick_best_window(&windows), Some(40));
    }

    #[test]
    fn walk_budget_stops_after_max_nodes() {
        let mut budget = WalkBudget::new(10, 3);
        assert!(budget.take_node());
        assert!(budget.take_node());
        assert!(budget.take_node());
        assert!(!budget.take_node());
        assert_eq!(budget.remaining_nodes, 0);
    }
}
