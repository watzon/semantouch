//! Semantouch cross-platform MCP stdio binary (Windows/Linux).
//!
//! Stdout is reserved for newline-delimited JSON-RPC only. Diagnostics and
//! startup failures go to stderr with a non-zero exit code.

use semantouch_runtime::{
    host_platform, log_stderr, run_server_stdio, try_native_adapter, McpServer, Runtime,
};
use std::io::{self, BufReader};
use std::process::ExitCode;
use std::sync::Arc;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(code) => code,
    }
}

fn run() -> Result<(), ExitCode> {
    // Fail closed on unsupported hosts before touching stdout.
    let adapter = match try_native_adapter() {
        Ok(adapter) => adapter,
        Err(err) => {
            let platform = host_platform().as_str();
            log_stderr(format!(
                "semantouch-runtime: native adapter unavailable on host platform '{platform}': {err}"
            ));
            log_stderr(
                "semantouch-runtime: this binary targets Windows and Linux; macOS remains the Swift reference implementation.",
            );
            return Err(ExitCode::from(1));
        }
    };

    // Runtime over a boxed adapter requires a concrete type. Re-construct via
    // platform-specific path so Runtime<A> stays monomorphized for native adapters.
    run_native(adapter)
}

#[cfg(target_os = "windows")]
fn run_native(
    _adapter: Box<dyn semantouch_adapter::PlatformAdapter>,
) -> Result<(), ExitCode> {
    // try_native_adapter already succeeded; rebuild a typed adapter for Runtime.
    let adapter = match semantouch_windows::WindowsAdapter::new() {
        Ok(a) => a,
        Err(err) => {
            log_stderr(format!(
                "semantouch-runtime: failed to construct Windows adapter: {err}"
            ));
            return Err(ExitCode::from(1));
        }
    };
    serve(Runtime::new(adapter))
}

#[cfg(target_os = "linux")]
fn run_native(
    _adapter: Box<dyn semantouch_adapter::PlatformAdapter>,
) -> Result<(), ExitCode> {
    let adapter = match semantouch_linux::LinuxAdapter::new() {
        Ok(a) => a,
        Err(err) => {
            log_stderr(format!(
                "semantouch-runtime: failed to construct Linux adapter: {err}"
            ));
            return Err(ExitCode::from(1));
        }
    };
    serve(Runtime::new(adapter))
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
fn run_native(
    _adapter: Box<dyn semantouch_adapter::PlatformAdapter>,
) -> Result<(), ExitCode> {
    // try_native_adapter should have failed already on this cfg.
    log_stderr(
        "semantouch-runtime: unsupported host; no Windows/Linux adapter linked into this binary.",
    );
    Err(ExitCode::from(1))
}

#[allow(dead_code)] // used on windows/linux; retained for type-check on other hosts
fn serve<A: semantouch_adapter::PlatformAdapter + 'static>(
    runtime: Runtime<A>,
) -> Result<(), ExitCode> {
    let server = Arc::new(McpServer::new(runtime));
    let stdin = BufReader::new(io::stdin());
    let stdout = io::stdout();
    run_server_stdio(server, stdin, stdout);
    Ok(())
}
