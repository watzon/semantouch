//! Newline-delimited stdio transport and concurrent MCP run loop.
//!
//! - Reader thread splits on `\n` (CRLF tolerated) and classifies lines.
//! - Notifications (including `notifications/cancelled`) run on the reader thread.
//! - Requests execute on a serial worker so replies stay ordered.
//! - Cancellation tokens for `tools/call` are registered on the reader thread
//!   **before** enqueue, so a later cancel for a still-queued request latches.
//! - Stdout writes are complete lines under a mutex; diagnostics only on stderr.

use crate::jsonrpc::serialize_line;
use crate::server::{DispatchOutcome, McpServer, SHUTDOWN_DRAIN_MILLISECONDS};
use semantouch_adapter::PlatformAdapter;
use semantouch_core::CancellationToken;
use std::io::{self, BufRead, Write};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

/// Write a diagnostic line to **stderr** (never stdout).
pub fn log_stderr(message: impl AsRef<str>) {
    let mut err = io::stderr().lock();
    let _ = writeln!(err, "{}", message.as_ref());
    let _ = err.flush();
}

/// Line-oriented writer that serializes complete JSON lines to an output sink.
pub struct LineWriter<W: Write> {
    inner: Mutex<W>,
}

impl<W: Write> LineWriter<W> {
    pub fn new(writer: W) -> Self {
        Self {
            inner: Mutex::new(writer),
        }
    }

    /// Write one complete line (payload + `\n`) under the lock.
    pub fn write_line(&self, line: &str) -> io::Result<()> {
        let mut guard = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.write_all(line.as_bytes())?;
        guard.write_all(b"\n")?;
        guard.flush()
    }
}

/// Split a byte buffer into complete lines. CRLF tolerated; blank lines skipped.
/// When `flush` is true, emit any final unterminated remainder.
pub fn extract_lines(buffer: &mut Vec<u8>, flush: bool) -> Vec<String> {
    let mut lines = Vec::new();
    let mut start = 0usize;
    let mut index = 0usize;
    while index < buffer.len() {
        if buffer[index] == b'\n' {
            append_line(&buffer[start..index], &mut lines);
            start = index + 1;
        }
        index += 1;
    }
    if flush {
        if start < buffer.len() {
            append_line(&buffer[start..], &mut lines);
        }
        buffer.clear();
    } else if start > 0 {
        buffer.drain(..start);
    }
    lines
}

fn append_line(slice: &[u8], lines: &mut Vec<String>) {
    let mut end = slice.len();
    if end > 0 && slice[end - 1] == b'\r' {
        end -= 1;
    }
    if end == 0 {
        return;
    }
    lines.push(String::from_utf8_lossy(&slice[..end]).into_owned());
}

/// Work item for the serial execution queue.
enum WorkItem {
    /// Execute a request with a pre-registered token (may be default for non-call).
    Request {
        request: crate::jsonrpc::RpcRequest,
        token: CancellationToken,
        is_tools_call: bool,
    },
    /// Write a pre-built reply (parse/invalid) through the same queue for order.
    Reply(serde_json::Value),
}

/// Run the MCP server until `input` reaches EOF.
///
/// Cancels in-flight work on EOF and drains the execution queue with a bounded wait.
pub fn run_server_stdio<A, R, W>(server: Arc<McpServer<A>>, mut input: R, output: W)
where
    A: PlatformAdapter + 'static,
    R: BufRead,
    W: Write + Send + 'static,
{
    let writer = Arc::new(LineWriter::new(output));
    let (tx, rx): (Sender<WorkItem>, Receiver<WorkItem>) = mpsc::channel();
    let in_flight = Arc::new(AtomicUsize::new(0));
    let worker_done = Arc::new(AtomicBool::new(false));

    // Serial execution worker.
    let worker_server = Arc::clone(&server);
    let worker_writer = Arc::clone(&writer);
    let worker_in_flight = Arc::clone(&in_flight);
    let worker_done_flag = Arc::clone(&worker_done);
    let worker = thread::Builder::new()
        .name("semantouch-mcp-exec".into())
        .spawn(move || {
            while let Ok(item) = rx.recv() {
                match item {
                    WorkItem::Reply(value) => {
                        let line = serialize_line(&value);
                        if let Err(err) = worker_writer.write_line(&line) {
                            log_stderr(format!("semantouch: stdout write failed: {err}"));
                        }
                        worker_in_flight.fetch_sub(1, Ordering::SeqCst);
                    }
                    WorkItem::Request {
                        request,
                        token,
                        is_tools_call,
                    } => {
                        let response = worker_server.handle_request(&request, &token);
                        let line = serialize_line(&response);
                        if let Err(err) = worker_writer.write_line(&line) {
                            log_stderr(format!("semantouch: stdout write failed: {err}"));
                        }
                        if is_tools_call {
                            worker_server
                                .cancellation()
                                .deregister(&request.id, &token);
                        }
                        worker_in_flight.fetch_sub(1, Ordering::SeqCst);
                    }
                }
            }
            worker_done_flag.store(true, Ordering::SeqCst);
        })
        .expect("spawn mcp execution worker");

    // Reader loop on this thread (caller blocks until EOF).
    let mut buffer = String::new();
    loop {
        buffer.clear();
        match input.read_line(&mut buffer) {
            Ok(0) => break, // EOF
            Ok(_) => {
                // read_line keeps the delimiter; strip trailing \n / \r\n.
                let line = buffer.trim_end_matches(['\r', '\n']);
                if line.is_empty() {
                    continue;
                }
                dispatch_line_to_queue(&server, &tx, &in_flight, line);
            }
            Err(err) => {
                log_stderr(format!("semantouch: stdin read failed: {err}"));
                break;
            }
        }
    }

    log_stderr("semantouch: stdin closed; shutting down");
    server.cancellation().cancel_all("shutdown");
    // Drop sender so the worker exits after draining.
    drop(tx);

    // Bounded drain: wait for in-flight work / worker exit.
    let deadline = std::time::Instant::now() + Duration::from_millis(SHUTDOWN_DRAIN_MILLISECONDS);
    while !worker_done.load(Ordering::SeqCst) && std::time::Instant::now() < deadline {
        if in_flight.load(Ordering::SeqCst) == 0 {
            thread::sleep(Duration::from_millis(5));
            if worker_done.load(Ordering::SeqCst) {
                break;
            }
        } else {
            thread::sleep(Duration::from_millis(5));
        }
    }
    let _ = worker.join();
}

fn dispatch_line_to_queue<A: PlatformAdapter>(
    server: &McpServer<A>,
    tx: &Sender<WorkItem>,
    in_flight: &AtomicUsize,
    line: &str,
) {
    match server.dispatch_line(line) {
        DispatchOutcome::Ignore => {}
        DispatchOutcome::Notification(note) => {
            // Inline on the reader thread so cancel is prompt.
            server.handle_notification(&note);
        }
        DispatchOutcome::Reply(value) => {
            in_flight.fetch_add(1, Ordering::SeqCst);
            let _ = tx.send(WorkItem::Reply(value));
        }
        DispatchOutcome::Request(request) => {
            let is_tools_call = request.method == "tools/call";
            // Register on the reader thread BEFORE enqueue (§17).
            let token = if is_tools_call {
                server.cancellation().register(&request.id)
            } else {
                CancellationToken::new()
            };
            in_flight.fetch_add(1, Ordering::SeqCst);
            let _ = tx.send(WorkItem::Request {
                request,
                token,
                is_tools_call,
            });
        }
    }
}

/// Process a sequence of lines synchronously (no threads). Useful for tests that
/// do not need concurrent cancellation.
pub fn process_lines_sync<A: PlatformAdapter>(
    server: &McpServer<A>,
    lines: impl IntoIterator<Item = impl AsRef<str>>,
) -> Vec<String> {
    let mut out = Vec::new();
    for line in lines {
        if let Some(reply) = server.process(line.as_ref()) {
            out.push(reply);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_lines_handles_crlf_and_flush() {
        let mut buf = b"a\r\nb\nc".to_vec();
        let lines = extract_lines(&mut buf, false);
        assert_eq!(lines, vec!["a".to_string(), "b".to_string()]);
        assert_eq!(buf, b"c");
        let rest = extract_lines(&mut buf, true);
        assert_eq!(rest, vec!["c".to_string()]);
        assert!(buf.is_empty());
    }

    #[test]
    fn extract_lines_skips_blank() {
        let mut buf = b"\n\r\nx\n".to_vec();
        let lines = extract_lines(&mut buf, false);
        assert_eq!(lines, vec!["x".to_string()]);
    }
}
