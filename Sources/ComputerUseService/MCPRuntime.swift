import Foundation
import Dispatch
import MCPServer
import CursorOverlay
#if canImport(AppKit)
import AppKit
#endif

/// Entry point for the MCP serve loop: build the Phase 1 registry over a fresh
/// `ServiceContext` and serve newline-delimited JSON-RPC over an injected
/// input/output pair (default: stdio) until EOF (§1).
///
/// The transport owns the output handle; this function writes nothing to it itself.
/// It blocks the calling thread until the input closes, then returns for a clean
/// shutdown.
///
/// Hosted connections (app host socket) inject socket-backed `FileHandle`s so each
/// MCP connection gets an isolated runtime/context without sharing revisions or
/// stable element ids across peers or restarts.
///
/// ## Threading model (persistent-cursor task)
/// The virtual cursor overlay is a live `NSPanel`, and PUBLIC AppKit requires a main-thread run
/// loop to host and draw a window. The plain headless server has no such loop — its main thread
/// parks on a semaphore — which is exactly why Stage H could only prove the overlay through a
/// separate GUI harness. So the runtime picks ONE of two shapes up front, from a pure decision
/// (`shouldHostOverlay`):
///
/// - **Hosted** (cursor ENABLED via `SEMANTOUCH_CURSOR != off` AND a GUI session is available):
///   run an `NSApplication` on the MAIN thread with activation policy `.accessory`
///   (LSUIElement-style: no Dock tile, no menu bar, never auto-activates), and drive the MCP
///   read/serve loop on a BACKGROUND thread. The live `AppKitCursorPresenter` already marshals
///   every presentation onto `DispatchQueue.main`, which the hosted run loop drains — so the
///   overlay actually draws. The `NSApplication` never calls `activate()` and never writes to
///   stdout; the panel is `orderFront` + `ignoresMouseEvents` only, so it never becomes
///   key/main and never steals focus.
///
/// - **Headless** (cursor DISABLED, or NO GUI session — CI, over-SSH, locked login window):
///   EXACTLY the historical behavior — no `NSApplication`, no window, the main thread serves as
///   before. This preserves the Stage H headless-safe proof (the `mcp` server creates zero
///   windows).
///
/// Either way, input EOF and `SIGTERM` tear down the overlay and stop cleanly (bounded drain of
/// in-flight work, no truncated final output line), then exit — no hang.
public enum MCPRuntime {
    /// Run the server to completion (returns on input EOF).
    ///
    /// - Parameters:
    ///   - context: Optional pre-built context. When `nil`, a **fresh** `ServiceContext`
    ///     is created for this call (live cursor overlay controller). Never reuse a
    ///     context across connections.
    ///   - input: Byte source for newline-delimited JSON-RPC (default: stdin).
    ///   - output: Sink for framed replies (default: stdout).
    ///
    /// Default arguments preserve the historical stdio entrypoint:
    /// `MCPRuntime.run()` is source-compatible with the previous signature.
    public static func run(
        context: ServiceContext? = nil,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        // Fresh ServiceContext per call when none is injected — never share revisions
        // / element tables / session state across MCP connections.
        let context = context ?? ServiceContext(cursorController: .system())
        // Start the passive user-interruption tap (Phase 4). Degrades gracefully if the tap
        // cannot be created (logged warning + per-action StateWarning), never a crash.
        context.startInterruptionMonitor()
        defer { context.stopInterruptionMonitor() }
        // Phase 5 (task step 1): tear down the persistent cursor overlay when the connection
        // closes (input EOF returns from the serve loop below). Best-effort and inert when no
        // overlay was ever shown or when headless. The SIGTERM path (below) tears down too.
        defer { context.cursorController.shutdown() }
        // v1.5 (§18.1): on shutdown, reset (to false) the web-AX attributes this server flipped
        // across every session, so a Chromium/Electron app is not left announced. Best-effort;
        // never touches an attribute that was already true before the server flipped it.
        defer { context.resetAllWebContentAccessibility() }
        let registry = ToolHandlers.registry(context: context)
        // `notifications/turn-ended` is decorative only: hide/disarm the cursor overlay
        // without ending app sessions. Cancellation stays fully inside MCPServer.
        let transport = StdioTransport(input: input, output: output)
        let server = MCPServer(transport: transport, registry: registry, onNotification: { method, _ in
            guard method == "notifications/turn-ended" else { return }
            context.cursorController.endTurn()
        })

        // Process-level shutdown (PROTOCOL v1.4 §17): on SIGTERM, cancel any in-flight
        // capture/tree-build work so nothing is orphaned, then exit cleanly. Input EOF is
        // handled inside the serve loop (it cancels in-flight tokens and drains). Ignore the
        // default SIGTERM disposition and observe it on a dispatch source instead (the raw
        // signal handler context is too restricted to do this work).
        //
        // Only install SIGTERM for the process-default stdio path. Host-socket connections
        // share the process with other sessions and must not exit the whole host.
        let isProcessStdio =
            input.fileDescriptor == FileHandle.standardInput.fileDescriptor
            && output.fileDescriptor == FileHandle.standardOutput.fileDescriptor
        var sigterm: DispatchSourceSignal?
        if isProcessStdio {
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            source.setEventHandler {
                StdioTransport.log("semantouch: SIGTERM received; cancelling in-flight work")
                server.cancelAllInFlight(reason: "sigterm")
                // Server shutdown (task step 1): tear down the persistent cursor overlay.
                context.cursorController.shutdown()
                // v1.5 (§18.1): reset the web-AX attributes this server flipped across all sessions.
                context.resetAllWebContentAccessibility()
                // Briefly drain (bounded) so an in-flight handler can unwind and finish its
                // `writeLine` before we exit — avoiding a truncated final stdout line (§17.4).
                // A stuck handler cannot delay shutdown past the deadline. Same bound as the EOF
                // drain in `MCPServer.run()` (symmetric shutdown, §17.4).
                server.drainInFlight(deadline: .now() + .milliseconds(MCPServer.shutdownDrainMilliseconds))
                exit(0)
            }
            source.resume()
            sigterm = source
        }
        defer { sigterm?.cancel() }

        // Decide the runtime shape from the cursor preference + GUI availability. The decision
        // is a pure function (unit-tested over a fake environment); only the branch it selects
        // touches AppKit.
        //
        // Host-socket connections always take the headless serve path: the host process already
        // owns the main AppKit run loop (status/onboarding UI). Overlay presentation still works
        // because AppKitCursorPresenter marshals onto the main queue drained by the host.
        if isProcessStdio,
           shouldHostOverlay(
            environment: ProcessInfo.processInfo.environment,
            guiSessionAvailable: GUISession.isAvailable
           ) {
            runHosted(server: server, context: context)
        } else {
            // Headless / host-socket: serve on the calling thread, no NSApp takeover.
            // Returns on input EOF after the bounded in-flight drain.
            server.run()
        }
    }

    /// The pure host/no-host decision (task: enabled + GUI → host; disabled/headless → no host).
    ///
    /// Hosting an AppKit run loop is warranted iff the cursor overlay is ENABLED
    /// (`SEMANTOUCH_CURSOR != off`) AND a GUI/windowing session is available. Split out from `run()`
    /// with injected inputs so it is deterministically unit-testable without a real environment
    /// or display; the run-loop hosting itself is exercised only in a live GUI session (Stage H).
    static func shouldHostOverlay(environment: [String: String], guiSessionAvailable: Bool) -> Bool {
        CursorPreference.fromEnvironment(environment) != .off && guiSessionAvailable
    }

    // MARK: - Hosted (main-thread AppKit run loop)

    #if canImport(AppKit)
    /// Host an accessory `NSApplication` on the MAIN thread and drive the MCP serve loop on a
    /// BACKGROUND thread. Called ONLY when `shouldHostOverlay` is true, so a GUI session is
    /// guaranteed present; the panel presenter still self-guards on `canPresent`.
    private static func runHosted(server: MCPServer, context: ServiceContext) {
        // `NSApplication.shared` must be created/driven on the main thread; `run()` runs on main.
        let app = NSApplication.shared
        // `.accessory` (LSUIElement): NO Dock tile, NO menu bar, can host panels, and — crucially
        // — the process is NOT forced to the foreground. We NEVER call `app.activate()`; the panel
        // is `orderFront` + `ignoresMouseEvents` only, so it never becomes key/main or steals
        // focus. `NSApplication` writes nothing to stdout (diagnostics, if any, go to stderr).
        app.setActivationPolicy(.accessory)

        // Serve the MCP protocol off the main thread so the main run loop is free to host + draw
        // the overlay. `server.run()` blocks until input EOF, cancelling in-flight tokens and
        // performing its own bounded drain before returning.
        let serveThread = Thread {
            server.run()
            // Connection closed (input EOF): tear down the overlay, then stop the main run loop
            // so `app.run()` returns and the process exits cleanly. Teardown is best-effort and
            // idempotent (the `run()` defers call `shutdown()` again after `app.run()` returns).
            context.cursorController.shutdown()
            DispatchQueue.main.async {
                // `stop(_:)` sets a flag the run loop checks after the next event; an idle loop
                // may have no such event, so post a no-op event to wake it and let it exit.
                NSApp.stop(nil)
                if let wake = NSEvent.otherEvent(
                    with: .applicationDefined,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    subtype: 0,
                    data1: 0,
                    data2: 0
                ) {
                    NSApp.postEvent(wake, atStart: true)
                }
                // Belt-and-suspenders: if `NSEvent.otherEvent` ever returns nil (so no wake event
                // is posted) `NSApp.stop(nil)` alone might not be observed by an idle loop. Stop the
                // underlying CFRunLoop directly so `app.run()` is guaranteed to return.
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        serveThread.name = "dev.watzon.semantouch.mcp-serve"
        serveThread.stackSize = 4 << 20
        serveThread.start()

        // Host the main run loop. Blocks the main thread, draining the main queue (which is where
        // the presenter marshals every overlay update) until the serve thread stops it on EOF.
        app.run()
    }
    #else
    /// No AppKit on this platform: hosting degrades to the headless serve loop.
    private static func runHosted(server: MCPServer, context: ServiceContext) {
        server.run()
    }
    #endif
}
