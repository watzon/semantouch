import Foundation
import Dispatch
import Darwin
import ComputerUseCore
import MCPServer
import SemantouchIPC
import SemantouchCLIKit

// Semantouch — nested stdio/control relay entrypoint.
//
// Subcommand routing is hand-rolled (no ArgumentParser dependency; the package has
// zero external dependencies).
//
// STDOUT DISCIPLINE (PROTOCOL §1): the `mcp` subcommand owns stdout for framed
// JSON-RPC and writes NOTHING else there. Every OTHER subcommand is an ordinary CLI
// command whose *result payload* (a doctor report, an app list, an AX tree, a probe
// confirmation) is written to stdout, while diagnostics and errors go to stderr.
// The two never mix: when `mcp` is running, no CLI command is.
//
// Architecture: this process is a trusted-peer relay. Doctor / list-apps / probe /
// update execute only inside SemantouchHost over the private control socket.
// `mcp` performs authenticated hello then OpaqueRelay of exact stdin/stdout bytes.
// After hello failure it exits; after established EOF it never reconnects/replays.

/// Write a line to standard error.
func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Write a line to standard output (CLI result payloads and usage only).
func printOut(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

let usage = """
    semantouch — native macOS computer-use MCP helper (\(MCPServer.contractVersion))

    USAGE:
      semantouch <subcommand> [options]

    SUBCOMMANDS:
      mcp                          Relay stdio MCP to the resident Semantouch.app host
                                   (stdout = JSON-RPC only).
      call <tool>|--calls …       Invoke one MCP tool or a sequence over one host
                                   session (see `semantouch call --help`).
      doctor [--json]              Report permissions and GitHub update availability.
      update [--json]              Install the latest verified whole-app release.
      list-apps [--json]           List running applications and window counts.
      config [options]             Print the OMP MCP server config (JSON) for this
                                   helper. Options:
                                     --path FILE   command path (default: this binary)
                                     --cwd DIR     working directory (default: omitted)
                                     --name KEY    mcpServers key (default: semantouch)
                                     --timeout MS  client timeout ms (default: 30000)
                                     --bare        emit just the server-config object
                                     --manifest    emit the plugin manifest instead
      probe <kind> [args...]       Low-level diagnostic drivers. <kind> is one of:
                                     capture   --app X --out FILE.png
                                     ax-tree   --app X
                                     press     --app X --identifier ID
                                     set-value --app X --identifier ID --value V
      --version, -v                Print the helper version.
      --help, -h                   Show this help.

    Server and library code write protocol traffic to stdout only; all logging goes
    to stderr. `config` emits generator JSON to stdout; `call` emits one tools/call
    result object per line to stdout. Doctor/list-apps/probe/update execute only
    inside the resident Semantouch.app host over a private control socket.
    """

// MARK: - Argument parsing

/// A minimal option bag. Supports `--flag value` and `--flag=value`; bare flags are
/// recorded with an empty value. Unknown-to-the-command flags are simply looked up
/// by name (missing → nil).
struct Options {
    private var values: [String: String] = [:]
    private(set) var flags: Set<String> = []

    init(_ arguments: ArraySlice<String>) {
        let pending: [String] = Array(arguments)
        var index = 0
        while index < pending.count {
            let token = pending[index]
            guard token.hasPrefix("--") else { index += 1; continue }
            let name = String(token.dropFirst(2))
            if let equals = name.firstIndex(of: "=") {
                let key = String(name[name.startIndex..<equals])
                let value = String(name[name.index(after: equals)...])
                values[key] = value
                flags.insert(key)
                index += 1
            } else if index + 1 < pending.count, !pending[index + 1].hasPrefix("--") {
                values[name] = pending[index + 1]
                flags.insert(name)
                index += 2
            } else {
                flags.insert(name)
                index += 1
            }
        }
    }

    subscript(_ key: String) -> String? { values[key] }
    func has(_ key: String) -> Bool { flags.contains(key) }
}

// MARK: - Host client helpers

private func makeHostClient() throws -> HostClient {
    let location = try SocketLocation.resolve()
    return HostClient(
        location: location,
        policy: .relayAcceptsHost(hostExecutablePath: nil),
        clientVersion: MCPServer.serverVersion
    )
}

/// Connect with bounded pre-hello retry. On the first retry, launch the selected
/// Semantouch.app via `/usr/bin/open -gj -a` once, then continue retrying. Never
/// launches before the first failure. After hello succeeds the session is sticky —
/// callers must not reconnect.
private func connectToHost(
    role: ConnectionRole,
    allowLaunch: Bool
) throws -> HostSession {
    let client = try makeHostClient()
    var didLaunch = false
    return try client.connect(
        role: role,
        retry: .default,
        onRetry: { attempt, error in
            // Launch only on retry (after first failure), and only once.
            guard allowLaunch, !didLaunch, attempt >= 1 else { return }
            guard error.isPreHelloRetryable else { return }
            didLaunch = true
            if let appPath = selectedSemantouchAppPath() {
                launchHostApp(at: appPath)
            } else {
                printError("semantouch: host not reachable and no Semantouch.app found to launch")
            }
        }
    )
}

/// Prefer nested-bundle parent, then /Applications, then ~/Applications.
private func selectedSemantouchAppPath() -> String? {
    // Nested: …/Semantouch.app/Contents/MacOS/semantouch → Semantouch.app
    if let exe = Bundle.main.executableURL
        ?? CommandLine.arguments.first.map({ URL(fileURLWithPath: $0) }) {
        var url = exe.resolvingSymlinksInPath().standardizedFileURL
        // Walk up looking for *.app
        for _ in 0..<6 {
            if url.pathExtension == "app", url.lastPathComponent == Packaging.appBundleName {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
    }

    let system = Packaging.systemAppPath
    if FileManager.default.fileExists(atPath: system) {
        return system
    }
    let user = Packaging.userAppPath
    if FileManager.default.fileExists(atPath: user) {
        return user
    }
    return nil
}

/// Launch the host app without activating (`-gj`). Fixed argv only — no shell.
private func launchHostApp(at appPath: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-gj", "-a", appPath]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        printError("semantouch: failed to launch host app: \(error)")
    }
}

/// Send one control request and return the response.
private func sendControl(
    method: ControlMethod,
    params: [String: SemantouchIPC.JSONValue]? = nil
) throws -> ControlResponse {
    let session = try connectToHost(role: .control, allowLaunch: true)
    defer { session.close() }
    let request = ControlRequest(method: method.rawValue, params: params)
    return try session.sendControl(request)
}

// MARK: - Error rendering

/// Render a thrown error to a one-line stderr message.
func report(_ error: Error) {
    if let ipc = error as? IPCError {
        printError("error: \(ipc)")
    } else if let cuError = error as? CUError {
        printError("error: \(cuError.code.rawValue): \(cuError.message)")
    } else {
        printError("error: \(error)")
    }
}

// MARK: - doctor

func runDoctor(_ options: Options) -> Int32 {
    let response: ControlResponse
    do {
        response = try sendControl(method: .doctor, params: ["requestOnboarding": .bool(false)])
    } catch {
        report(error)
        return 1
    }

    guard response.ok, let result = response.result else {
        let message = response.error?.message ?? "doctor failed"
        printError("doctor: \(message)")
        return 1
    }

    if options.has("json") {
        do {
            let data = try HostCodec.encode(result)
            if let json = String(data: data, encoding: .utf8) {
                printOut(json)
                return 0
            }
            printError("doctor: failed to encode result")
            return 1
        } catch {
            printError("doctor: failed to encode result: \(error)")
            return 1
        }
    }

    // Best-effort human rendering from IPC JSON.
    if let obj = result.objectValue {
        if let helper = obj["helper"]?.objectValue {
            let path = helper["path"]?.stringValue ?? "?"
            let signed = helper["signed"]?.boolValue.map { String(describing: $0) } ?? "?"
            let version = helper["version"]?.stringValue ?? "?"
            printOut("helper:          \(path)")
            printOut("  signed:        \(signed)")
            printOut("  version:       \(version)")
        }
        if let accessibility = obj["accessibility"]?.stringValue {
            printOut("accessibility:   \(accessibility)")
        }
        if let screenRecording = obj["screenRecording"]?.stringValue {
            printOut("screenRecording: \(screenRecording)")
        }
        if let ready = obj["ready"]?.boolValue {
            printOut("ready:           \(ready)")
        }
        if let update = obj["update"]?.objectValue {
            let status = update["status"]?.stringValue ?? "unknown"
            let current = update["currentVersion"]?.stringValue ?? "?"
            let latest = update["latestVersion"]?.stringValue
            let message = update["message"]?.stringValue
            switch status {
            case "available":
                printOut("update:          available (v\(latest ?? "unknown"); run `semantouch update`)")
            case "up_to_date":
                printOut("update:          up to date (v\(current))")
            default:
                printOut("update:          unknown (\(message ?? "GitHub check failed"))")
            }
        }
        if let remediation = obj["remediation"]?.arrayValue {
            let steps = remediation.compactMap { $0.stringValue }
            if steps.isEmpty {
                printOut("remediation:     (none)")
            } else {
                printOut("remediation:")
                for step in steps { printOut("  - \(step)") }
            }
        }
        if obj["ready"]?.boolValue == true {
            printOut("next:            run `semantouch config` to generate an MCP server config.")
        }
    } else {
        if let data = try? HostCodec.encode(result),
           let json = String(data: data, encoding: .utf8) {
            printOut(json)
        }
    }
    return 0
}

// MARK: - list-apps

func runListApps(_ options: Options) -> Int32 {
    let response: ControlResponse
    do {
        response = try sendControl(method: .listApps)
    } catch {
        report(error)
        return 1
    }

    guard response.ok, let result = response.result else {
        printError("list-apps: \(response.error?.message ?? "failed")")
        return 1
    }

    if options.has("json") {
        do {
            let data = try HostCodec.encode(result)
            if let json = String(data: data, encoding: .utf8) {
                printOut(json)
                return 0
            }
            printError("list-apps: failed to encode result")
            return 1
        } catch {
            printError("list-apps: failed to encode result: \(error)")
            return 1
        }
    }

    printOut("PID      WINDOWS  NAME (ID)")
    if let apps = result.objectValue?["apps"]?.arrayValue {
        for appValue in apps {
            guard let app = appValue.objectValue else { continue }
            let pid: String
            if let number = app["pid"]?.numberValue {
                pid = String(Int(number))
            } else {
                pid = "-"
            }
            let windows: String
            if let number = app["windows"]?.numberValue {
                windows = String(Int(number))
            } else {
                windows = "0"
            }
            let name = app["displayName"]?.stringValue ?? "?"
            let id = app["id"]?.stringValue ?? "?"
            printOut("\(pid.padding(toLength: 8, withPad: " ", startingAt: 0)) \(windows.padding(toLength: 8, withPad: " ", startingAt: 0)) \(name) (\(id))")
        }
    }
    return 0
}

// MARK: - config (OMP MCP server config / plugin manifest generator)

/// Resolve a helper command path to an absolute, symlink-resolved path. With no
/// override this is the running binary; with `--path` it is the caller-supplied
/// location. Deterministic for a fixed install location.
func resolvedHelperPath(_ override: String?) -> String {
    let raw: String
    if let override, !override.isEmpty {
        raw = override
    } else if let exe = Bundle.main.executablePath {
        raw = exe
    } else if let first = CommandLine.arguments.first {
        raw = first
    } else {
        raw = "semantouch"
    }
    return URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path
}

func runConfig(_ options: Options) -> Int32 {
    let command = resolvedHelperPath(options["path"])
    let cwd = options["cwd"] // nil → the `cwd` field is omitted from the output
    let key = options["name"] ?? Packaging.defaultServerKey
    let timeout = options["timeout"].flatMap { Int($0) } ?? Packaging.defaultTimeoutMs

    do {
        let json: String
        if options.has("manifest") {
            json = try Packaging.manifestJSON(command: command)
        } else if options.has("bare") {
            json = try Packaging.serverConfigJSON(command: command, cwd: cwd, timeoutMs: timeout)
        } else {
            json = try Packaging.serversConfigJSON(key: key, command: command, cwd: cwd, timeoutMs: timeout)
        }
        printOut(json)
        return 0
    } catch {
        printError("config: failed to encode result: \(error)")
        return 1
    }
}

// MARK: - update

func runUpdate(_ options: Options) -> Int32 {
    if !options.has("json") {
        printError("update: checking GitHub for the latest release...")
    }

    let response: ControlResponse
    do {
        response = try sendControl(method: .installUpdate)
    } catch {
        report(error)
        return 1
    }

    guard response.ok, let result = response.result else {
        printError("update: \(response.error?.message ?? "failed")")
        return 1
    }

    if options.has("json") {
        do {
            let data = try HostCodec.encode(result)
            if let json = String(data: data, encoding: .utf8) {
                printOut(json)
                return 0
            }
            printError("update: failed to encode result")
            return 1
        } catch {
            printError("update: failed to encode result: \(error)")
            return 1
        }
    }

    let obj = result.objectValue
    let previous = obj?["previousVersion"]?.stringValue ?? "?"
    let version = obj?["version"]?.stringValue ?? "?"
    let path = obj?["path"]?.stringValue ?? "?"
    let updated = obj?["updated"]?.boolValue ?? false
    let deferred = obj?["deferred"]?.boolValue ?? false

    if updated {
        printOut("updated:         v\(previous) → v\(version)")
        printOut("app:             \(path)")
        printOut("next:            restart clients that are running Semantouch.")
    } else if deferred {
        printOut("update:          staged v\(version) (deferred until host is idle)")
        printOut("app:             \(path)")
    } else {
        printOut("update:          already up to date (v\(version))")
        printOut("app:             \(path)")
    }
    return 0
}

// MARK: - version

func runVersion() -> Int32 {
    printOut("\(MCPServer.serverName) \(MCPServer.serverVersion) (contract \(MCPServer.contractVersion), MCP \(MCPServer.mcpProtocolVersion))")
    return 0
}

// MARK: - probe

func runProbe(_ rest: ArraySlice<String>) -> Int32 {
    guard let kind = rest.first else {
        printError("probe: expected one of capture|ax-tree|press|set-value")
        return 64 // EX_USAGE
    }
    let options = Options(rest.dropFirst())

    guard let app = options["app"] else {
        printError("probe \(kind): --app is required")
        return 64
    }

    var params: [String: SemantouchIPC.JSONValue] = [
        "kind": .string(kind),
        "app": .string(app),
    ]
    if let out = options["out"] { params["out"] = .string(out) }
    if let identifier = options["identifier"] { params["identifier"] = .string(identifier) }
    if let value = options["value"] { params["value"] = .string(value) }

    // Local arg validation mirrors previous CLI UX before hitting the host.
    switch kind {
    case "capture":
        if options["out"] == nil {
            printError("probe capture: --out FILE.png is required")
            return 64
        }
    case "press":
        if options["identifier"] == nil {
            printError("probe press: --identifier ID is required")
            return 64
        }
    case "set-value":
        if options["identifier"] == nil {
            printError("probe set-value: --identifier ID is required")
            return 64
        }
        if options["value"] == nil {
            printError("probe set-value: --value V is required")
            return 64
        }
    case "ax-tree":
        break
    default:
        printError("probe: unknown kind \"\(kind)\"; expected capture|ax-tree|press|set-value")
        return 64
    }

    let response: ControlResponse
    do {
        response = try sendControl(method: .probe, params: params)
    } catch {
        report(error)
        return 1
    }

    guard response.ok, let result = response.result else {
        printError("probe: \(response.error?.message ?? "failed")")
        return 1
    }

    switch kind {
    case "capture":
        let obj = result.objectValue
        let bytes = obj?["byteCount"]?.numberValue.map { Int($0) } ?? 0
        let width = obj?["width"]?.numberValue.map { Int($0) } ?? 0
        let height = obj?["height"]?.numberValue.map { Int($0) } ?? 0
        let window = obj?["windowNumber"]?.numberValue.map { Int($0) } ?? 0
        let path = obj?["path"]?.stringValue ?? options["out"] ?? "?"
        printOut("wrote \(bytes) bytes (\(width)x\(height), window \(window)) to \(path)")
        return 0
    case "ax-tree":
        if let tree = result.objectValue?["tree"]?.stringValue {
            printOut(tree)
        } else if case let .string(tree) = result {
            printOut(tree)
        } else if let data = try? HostCodec.encode(result),
                  let json = String(data: data, encoding: .utf8) {
            printOut(json)
        }
        return 0
    case "press":
        let identifier = result.objectValue?["pressed"]?.stringValue ?? options["identifier"] ?? "?"
        printOut("pressed \(identifier)")
        return 0
    case "set-value":
        let identifier = result.objectValue?["identifier"]?.stringValue ?? options["identifier"] ?? "?"
        let value = result.objectValue?["value"]?.stringValue ?? options["value"] ?? "?"
        printOut("set \(identifier) = \(value)")
        return 0
    default:
        return 0
    }
}

// MARK: - mcp (opaque relay)

/// Connect as MCP, then pump exact stdin/stdout bytes. Never reconnects after hello.
/// Host crash → socket EOF → relay completes; clean EOF exits 0.
func runMCP() -> Int32 {
    let session: HostSession
    do {
        session = try connectToHost(role: .mcp, allowLaunch: true)
    } catch {
        // Hello / connect failure: exit, do not replay.
        printError("semantouch mcp: host connection failed: \(error)")
        return 1
    }

    // Established: opaque byte pump. Never reconnect or replay after this point.
    let relay = OpaqueRelay()
    let result = relay.run(
        stdin: .standardInput,
        stdout: .standardOutput,
        socketFD: session.fd
    )
    session.close()

    if let errorDescription = result.errorDescription {
        printError("semantouch mcp: relay error: \(errorDescription)")
        return 1
    }
    if result.aEOF || result.bEOF {
        return 0
    }
    return 1
}

// MARK: - call (stateful MCP tools/call client)

/// One authenticated MCP host session; initialize once; tools/call IDs in order.
/// Never reconnects or replays after hello. Stdout = canonical result lines only.
func runCall(_ arguments: ArraySlice<String>) -> Int32 {
    let argv = Array(arguments)
    if argv.count == 1, argv[0] == "--help" || argv[0] == "-h" {
        printOut(CallCommand.helpText)
        return CallExitCode.success
    }

    var session: HostSession?
    defer { session?.close() }

    return CallRunner.run(
        arguments: argv,
        io: CallIO(
            stdout: { printOut($0) },
            stderr: { printError($0) }
        ),
        connect: {
            // connectToHost is invoked at most once by CallRunner.
            do {
                let connected = try connectToHost(role: .mcp, allowLaunch: true)
                session = connected
                return CallHostTransport.make(fd: connected.fd)
            } catch {
                throw CallRuntimeError("host connection failed: \(error)")
            }
        }
    )
}



// MARK: - JSONValue helpers (IPC)

private extension SemantouchIPC.JSONValue {
    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    var arrayValue: [SemantouchIPC.JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var objectValue: [String: SemantouchIPC.JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }
}

// MARK: - Dispatch

/// Parse and dispatch. Returns a process exit code.
func run(_ arguments: [String]) -> Int32 {
    guard let subcommand = arguments.first else {
        printOut(usage)
        return 0
    }

    let rest = arguments.dropFirst()

    switch subcommand {
    case "--help", "-h", "help":
        printOut(usage)
        return 0

    case "--version", "-v", "version":
        return runVersion()

    case "config":
        return runConfig(Options(rest))

    case "mcp":
        // Opaque relay takes over stdin/stdout after authenticated hello.
        // Never reconnects after hello success or failure.
        return runMCP()

    case "call":
        return runCall(rest)


    case "doctor":
        return runDoctor(Options(rest))

    case "update":
        return runUpdate(Options(rest))

    case "list-apps":
        return runListApps(Options(rest))

    case "probe":
        return runProbe(rest)

    default:
        printError("unknown subcommand \"\(subcommand)\"; run `semantouch --help`")
        return 64
    }
}

exit(run(Array(CommandLine.arguments.dropFirst())))
