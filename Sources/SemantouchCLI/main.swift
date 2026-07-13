import Foundation
import Dispatch
import ComputerUseCore
import MCPServer
import ComputerUseService

// Semantouch — command-line entrypoint.
//
// Subcommand routing is hand-rolled (no ArgumentParser dependency; the package has
// zero external dependencies).
//
// STDOUT DISCIPLINE (PROTOCOL §1): the `mcp` subcommand owns stdout for framed
// JSON-RPC and writes NOTHING else there. Every OTHER subcommand is an ordinary CLI
// command whose *result payload* (a doctor report, an app list, an AX tree, a probe
// confirmation) is written to stdout, while diagnostics and errors go to stderr.
// The two never mix: when `mcp` is running, no CLI command is.

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
      mcp                          Run the stdio MCP server (stdout = JSON-RPC only).
      doctor [--json]              Report Accessibility / Screen Recording status.
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
    to stderr. `config` is the one CLI generator whose JSON result is written to
    stdout by design (it is not the MCP channel).
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

// MARK: - Async bridge

/// A one-shot reference box so an awaited result can cross the semaphore boundary.
private final class ResultBox<U>: @unchecked Sendable {
    var value: Result<U, Error>!
}

/// Run an async operation to completion from synchronous CLI code. The main thread
/// parks on a semaphore; the operation runs on the cooperative pool.
func blockOn<T>(_ operation: @escaping @Sendable () async -> Result<T, Error>) -> Result<T, Error> {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        box.value = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value
}

// MARK: - Error rendering

/// Render a thrown error to a one-line stderr message. `CUError` reports its wire
/// code; other errors report their description.
func report(_ error: Error) {
    if let cuError = error as? CUError {
        printError("error: \(cuError.code.rawValue): \(cuError.message)")
    } else {
        printError("error: \(error)")
    }
}

// MARK: - doctor

func runDoctor(_ options: Options) -> Int32 {
    let result = DoctorService.run(requestOnboarding: false)
    if options.has("json") {
        if let json = try? CanonicalJSON.encodeToString(result) {
            printOut(json)
        } else {
            printError("doctor: failed to encode result")
            return 1
        }
        return 0
    }
    printOut("helper:          \(result.helper.path)")
    printOut("  signed:        \(result.helper.signed)")
    printOut("  version:       \(result.helper.version)")
    printOut("accessibility:   \(result.accessibility.rawValue)")
    printOut("screenRecording: \(result.screenRecording.rawValue)")
    printOut("ready:           \(result.ready)")
    if result.remediation.isEmpty {
        printOut("remediation:     (none)")
    } else {
        printOut("remediation:")
        for step in result.remediation { printOut("  - \(step)") }
    }
    if result.ready {
        printOut("next:            run `semantouch config` to generate an MCP server config.")
    }
    return 0
}

// MARK: - list-apps

func runListApps(_ options: Options) -> Int32 {
    let apps = AppLister.listApps()
    if options.has("json") {
        if let json = try? CanonicalJSON.encodeToString(ListAppsResult(apps: apps)) {
            printOut(json)
        } else {
            printError("list-apps: failed to encode result")
            return 1
        }
        return 0
    }
    printOut("PID      WINDOWS  NAME (ID)")
    for app in apps {
        let pid = app.pid.map(String.init) ?? "-"
        printOut("\(pid.padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(app.windows).padding(toLength: 8, withPad: " ", startingAt: 0)) \(app.displayName) (\(app.id))")
    }
    return 0
}

// MARK: - config (OMP MCP server config / plugin manifest generator)

/// Resolve a helper command path to an absolute, symlink-resolved path. With no
/// override this is the running binary (`DoctorService.helperPath()`); with `--path`
/// it is the caller-supplied location. Deterministic for a fixed install location.
func resolvedHelperPath(_ override: String?) -> String {
    let raw = (override?.isEmpty == false ? override! : DoctorService.helperPath())
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
    let context = ServiceContext()

    guard let app = options["app"] else {
        printError("probe \(kind): --app is required")
        return 64
    }

    switch kind {
    case "capture":
        guard let out = options["out"] else {
            printError("probe capture: --out FILE.png is required")
            return 64
        }
        let result = blockOn { () -> Result<Probe.CaptureResult, Error> in
            do { return .success(try await Probe.capture(app: app, outPath: out, context: context)) }
            catch { return .failure(error) }
        }
        switch result {
        case let .success(capture):
            printOut("wrote \(capture.byteCount) bytes (\(capture.width)x\(capture.height), window \(capture.windowNumber)) to \(capture.path)")
            return 0
        case let .failure(error):
            report(error)
            return 1
        }

    case "ax-tree":
        do {
            let tree = try Probe.axTree(app: app, context: context)
            printOut(tree)
            return 0
        } catch {
            report(error)
            return 1
        }

    case "press":
        guard let identifier = options["identifier"] else {
            printError("probe press: --identifier ID is required")
            return 64
        }
        do {
            try Probe.press(app: app, identifier: identifier, context: context)
            printOut("pressed \(identifier)")
            return 0
        } catch {
            report(error)
            return 1
        }

    case "set-value":
        guard let identifier = options["identifier"] else {
            printError("probe set-value: --identifier ID is required")
            return 64
        }
        guard let value = options["value"] else {
            printError("probe set-value: --value V is required")
            return 64
        }
        do {
            try Probe.setValue(app: app, identifier: identifier, value: value, context: context)
            printOut("set \(identifier) = \(value)")
            return 0
        } catch {
            report(error)
            return 1
        }

    default:
        printError("probe: unknown kind \"\(kind)\"; expected capture|ax-tree|press|set-value")
        return 64
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
        // The server takes over stdin/stdout and blocks until stdin closes.
        MCPRuntime.run()
        return 0

    case "doctor":
        return runDoctor(Options(rest))

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
