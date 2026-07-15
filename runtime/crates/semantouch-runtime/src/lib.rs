//! Host-facing Semantouch cross-platform runtime facade.
//!
//! One public coordinator contract for every platform. macOS remains the Swift
//! reference implementation; this crate wires the Rust coordinator to Windows or
//! Linux adapters when built for those targets and exposes a newline-delimited
//! MCP stdio server for the shared 16-tool catalog.

pub use semantouch_adapter as adapter;
pub use semantouch_core as core;
pub use semantouch_protocol as protocol;

mod jsonrpc;
mod server;
mod stdio;


#[cfg(test)]
mod mcp_tests;
pub use jsonrpc::{
    classify, error_code, error_response, id_key, serialize_line, success_response,
    RpcClassification, RpcIncoming, RpcNotification, RpcRequest, VERSION as JSONRPC_VERSION,
};
pub use server::{
    base64_encode, core_tool_output_to_envelope, image_from_jpeg, tool_call_output_result_to_envelope,
    tool_error_to_envelope, tool_output_to_envelope, tool_result_to_envelope, DispatchOutcome,
    McpServer, RequestCancellationRegistry, ToolImageContent, HANDLED_METHODS,
    IMAGE_CONTENT_LIMITATION, SHUTDOWN_DRAIN_MILLISECONDS,
};
pub use semantouch_core::{ToolCallOutput, ToolImageBytes};
pub use stdio::{extract_lines, log_stderr, process_lines_sync, run_server_stdio, LineWriter};

use semantouch_adapter::PlatformAdapter;
use semantouch_core::{CancellationToken, Coordinator, PolicyEngine};
use semantouch_protocol::{
    enabled_tool_names, tools_list_payload, CapabilityReport, PlatformKind, ToolResult,
    INITIALIZE_INSTRUCTIONS, MCP_PROTOCOL_VERSION, PACKAGE_VERSION, PROTOCOL_VERSION, TOOL_COUNT,
};
#[cfg(any(test, not(any(target_os = "windows", target_os = "linux"))))]
use semantouch_protocol::ToolError;
use serde_json::Value;

/// Build-time platform identity for this binary.
pub fn host_platform() -> PlatformKind {
    #[cfg(target_os = "windows")]
    {
        PlatformKind::Windows
    }
    #[cfg(target_os = "linux")]
    {
        PlatformKind::Linux
    }
    #[cfg(target_os = "macos")]
    {
        PlatformKind::Macos
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
    {
        PlatformKind::Unknown
    }
}

/// Static capability report for the host without constructing a live adapter.
pub fn host_capability_report() -> CapabilityReport {
    #[cfg(target_os = "windows")]
    {
        return semantouch_windows::WindowsAdapter::static_capabilities();
    }
    #[cfg(target_os = "linux")]
    {
        return semantouch_linux::LinuxAdapter::static_capabilities();
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    {
        CapabilityReport {
            platform: host_platform(),
            entries: vec![],
            limitations: vec![
                "This Rust runtime targets Windows and Linux. macOS remains the Swift reference implementation."
                    .into(),
                "Shared coordinator semantics (sessions, stable IDs, diffs, policy, waits) are testable on this host."
                    .into(),
                IMAGE_CONTENT_LIMITATION.into(),
            ],
        }
    }
}

/// Try to construct the native adapter for this host.
pub fn try_native_adapter() -> ToolResult<Box<dyn PlatformAdapter>> {
    #[cfg(target_os = "windows")]
    {
        let a = semantouch_windows::WindowsAdapter::new()?;
        return Ok(Box::new(a));
    }
    #[cfg(target_os = "linux")]
    {
        let a = semantouch_linux::LinuxAdapter::new()?;
        return Ok(Box::new(a));
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    {
        Err(ToolError::CapabilityUnavailable {
            capability: "native_adapter".into(),
            platform: host_platform().as_str().into(),
            detail: Some(
                "no Windows/Linux adapter on this host; use Swift macOS runtime or cross-compile"
                    .into(),
            ),
        })
    }
}

/// Runtime handle owning a coordinator over a concrete adapter.
pub struct Runtime<A: PlatformAdapter> {
    coordinator: Coordinator<A>,
}

impl<A: PlatformAdapter> Runtime<A> {
    pub fn new(adapter: A) -> Self {
        Self {
            coordinator: Coordinator::new(adapter),
        }
    }

    pub fn with_policy(adapter: A, policy: PolicyEngine) -> Self {
        Self {
            coordinator: Coordinator::with_policy(adapter, policy),
        }
    }

    pub fn coordinator(&self) -> &Coordinator<A> {
        &self.coordinator
    }

    pub fn call_tool(
        &self,
        name: &str,
        args: Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<Value> {
        self.coordinator.call_tool(name, args, cancel)
    }

    /// Call a tool and render the MCP content envelope via `call_tool_output`.
    ///
    /// Optional JPEG bytes become a second content block after the text JSON.
    /// Image bytes are never invented when capture is unavailable.
    pub fn call_tool_envelope(
        &self,
        name: &str,
        args: Value,
        cancel: Option<&CancellationToken>,
    ) -> Value {
        match self.coordinator.call_tool_output(name, args, cancel) {
            Ok(output) => server::core_tool_output_to_envelope(&output),
            Err(err) => server::tool_error_to_envelope(&err),
        }
    }

    /// Richer coordinator path exposing optional image bytes.
    pub fn call_tool_output(
        &self,
        name: &str,
        args: Value,
        cancel: Option<&CancellationToken>,
    ) -> ToolResult<semantouch_core::ToolCallOutput> {
        self.coordinator.call_tool_output(name, args, cancel)
    }

    pub fn tools_list(&self) -> Value {
        tools_list_payload()
    }

    pub fn initialize_payload(&self) -> Value {
        serde_json::json!({
            "protocolVersion": MCP_PROTOCOL_VERSION,
            "capabilities": { "tools": {} },
            "serverInfo": {
                "name": "semantouch",
                "version": PACKAGE_VERSION,
            },
            "instructions": INITIALIZE_INSTRUCTIONS,
            "semantouch": {
                "protocol": PROTOCOL_VERSION,
                "platform": host_platform().as_str(),
                "toolCount": TOOL_COUNT,
            }
        })
    }
}

/// Public contract summary for docs/tests.
pub fn contract_summary() -> Value {
    serde_json::json!({
        "packageVersion": PACKAGE_VERSION,
        "protocolVersion": PROTOCOL_VERSION,
        "mcpProtocolVersion": MCP_PROTOCOL_VERSION,
        "toolCount": TOOL_COUNT,
        "tools": enabled_tool_names(),
        "hostPlatform": host_platform().as_str(),
        "capabilities": host_capability_report(),
        "ga": false,
        "notes": [
            "macOS reference implementation remains Swift.",
            "Windows/Linux share this coordinator contract.",
            "Wayland is capability-gated; unsupported portal ops fail closed.",
            "Not GA until interactive platform fixtures and release signing pass.",
            IMAGE_CONTENT_LIMITATION,
        ]
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use semantouch_protocol::TOOL_CATALOG;

    #[test]
    fn public_contract_is_sixteen_tools_not_ga() {
        let summary = contract_summary();
        assert_eq!(summary["toolCount"], 16);
        assert_eq!(summary["ga"], false);
        assert_eq!(TOOL_CATALOG.len(), 16);
        assert_eq!(summary["tools"].as_array().unwrap().len(), 16);
    }

    #[test]
    fn initialize_carries_instructions() {
        let payload = serde_json::json!({
            "instructions": INITIALIZE_INSTRUCTIONS,
        });
        assert!(payload["instructions"]
            .as_str()
            .unwrap()
            .contains("stale_revision"));
    }

    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    #[test]
    fn native_adapter_unavailable_on_macos_host() {
        match try_native_adapter() {
            Ok(_) => panic!("expected capability_unavailable on non-windows/linux host"),
            Err(ToolError::CapabilityUnavailable { .. }) => {}
            Err(other) => panic!("expected capability_unavailable, got {other:?}"),
        }
    }
}
