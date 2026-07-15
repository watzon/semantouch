import Foundation
import Darwin
import MCPServer

// MARK: - Exit codes

/// CLI exit codes for `semantouch call`.
///
/// - `success` (0): every attempted tools/call succeeded (`isError` false).
/// - `failure` (1): host connect, JSON-RPC/protocol/EOF/mismatched response, or a
///   tool result with `isError: true` (after printing that result).
/// - `usage` (64 / EX_USAGE): invalid argv, inline/file JSON, schema, or
///   placeholder resolution **before** any tools/call is sent.
public enum CallExitCode {
    public static let success: Int32 = 0
    public static let failure: Int32 = 1
    public static let usage: Int32 = 64
}

// MARK: - Errors

/// Pre-send parse/schema/ref failures → usage (64).
public struct CallUsageError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Post-connect protocol / transport / tool-isError failures → failure (1).
public struct CallRuntimeError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let isToolError: Bool

    public init(_ message: String, isToolError: Bool = false) {
        self.message = message
        self.isToolError = isToolError
    }

    public var description: String { message }
}

// MARK: - Invocation model

/// One tools/call to execute (single mode or one sequence record).
public struct CallRecord: Equatable, Sendable {
    public var tool: String
    public var args: JSONValue
    public var asName: String?

    public init(tool: String, args: JSONValue = .object([:]), asName: String? = nil) {
        self.tool = tool
        self.args = args
        self.asName = asName
    }
}

/// Parsed `semantouch call` invocation.
public enum CallInvocation: Equatable, Sendable {
    /// `semantouch call <tool> [--args JSON|--args-file path]`
    case single(CallRecord)
    /// `semantouch call --calls JSON|--calls-file path [--sleep seconds]`
    case sequence(calls: [CallRecord], sleepSeconds: Double)
}

// MARK: - Help / parse

public enum CallCommand {
    /// Documented usage for `semantouch call --help` / top-level help listing.
    public static let helpText = """
        semantouch call — invoke one MCP tool or a sequence over one host session

        USAGE:
          semantouch call <tool> [--args JSON | --args-file PATH]
          semantouch call --calls JSON | --calls-file PATH [--sleep SECONDS]
          semantouch call --help

        OPTIONS:
          --args JSON           Tool arguments object (default: {}).
          --args-file PATH      Read tool arguments JSON object from a UTF-8 file.
          --calls JSON          Nonempty JSON array of call records.
          --calls-file PATH     Read the call-record array from a UTF-8 file.
          --sleep SECONDS       Nonnegative finite delay between sequence calls.
          --help, -h            Show this help and exit 0.

        CALL RECORD:
          { "tool": "<name>", "args": {…}?, "as": "<binding>"? }

        REFERENCES:
          In sequence mode, later records may reference earlier bound results with
          ${name} or ${name.path.to.value} (object keys and array indices). A value
          that is exactly one whole placeholder keeps the native JSON type. Embedded
          placeholders inside a string interpolate scalar values only.

        EXAMPLES:
          semantouch call list_apps --args '{}'
          semantouch call get_app_state --args '{"app":"Finder"}'
          semantouch call --args-file /tmp/args.json get_app_state
          semantouch call --calls '[
            {"tool":"get_app_state","args":{"app":"Finder"},"as":"state"},
            {"tool":"press_key","args":{"app":"Finder","sessionId":"${state.sessionId}","combo":"cmd+l"}}
          ]'
          semantouch call --calls-file ./sequence.json --sleep 0.25

        OUTPUT:
          One canonical JSON line per tools/call result object on stdout
          (the MCP tools/call `result` envelope). Diagnostics on stderr.
          Stops after the first isError:true result (exit 1). Invalid
          argv/JSON/refs before send exit 64 (EX_USAGE).
        """

    /// Parse `call` subcommand argv (everything after `call`). Throws `CallUsageError`.
    public static func parse(_ arguments: [String]) throws -> CallInvocation {
        if arguments.isEmpty {
            throw CallUsageError("missing tool name or --calls; run `semantouch call --help`")
        }

        var tool: String?
        var argsJSON: String?
        var argsFile: String?
        var callsJSON: String?
        var callsFile: String?
        var sleepText: String?
        var sawSleep = false

        var index = 0
        while index < arguments.count {
            let token = arguments[index]

            if token == "--help" || token == "-h" {
                throw CallUsageError("unexpected --help mixed with call arguments")
            }

            if token.hasPrefix("--") {
                let (flag, inlineValue) = splitFlag(token)
                switch flag {
                case "args":
                    if argsJSON != nil {
                        throw CallUsageError("duplicate flag --args")
                    }
                    if argsFile != nil {
                        throw CallUsageError("--args and --args-file are mutually exclusive")
                    }
                    argsJSON = try takeValue(
                        flag: flag,
                        inline: inlineValue,
                        arguments: arguments,
                        index: &index
                    )
                case "args-file":
                    if argsFile != nil {
                        throw CallUsageError("duplicate flag --args-file")
                    }
                    if argsJSON != nil {
                        throw CallUsageError("--args and --args-file are mutually exclusive")
                    }
                    argsFile = try takeValue(
                        flag: flag,
                        inline: inlineValue,
                        arguments: arguments,
                        index: &index
                    )
                case "calls":
                    if callsJSON != nil {
                        throw CallUsageError("duplicate flag --calls")
                    }
                    if callsFile != nil {
                        throw CallUsageError("--calls and --calls-file are mutually exclusive")
                    }
                    callsJSON = try takeValue(
                        flag: flag,
                        inline: inlineValue,
                        arguments: arguments,
                        index: &index
                    )
                case "calls-file":
                    if callsFile != nil {
                        throw CallUsageError("duplicate flag --calls-file")
                    }
                    if callsJSON != nil {
                        throw CallUsageError("--calls and --calls-file are mutually exclusive")
                    }
                    callsFile = try takeValue(
                        flag: flag,
                        inline: inlineValue,
                        arguments: arguments,
                        index: &index
                    )
                case "sleep":
                    if sawSleep {
                        throw CallUsageError("duplicate flag --sleep")
                    }
                    sawSleep = true
                    sleepText = try takeValue(
                        flag: flag,
                        inline: inlineValue,
                        arguments: arguments,
                        index: &index
                    )
                default:
                    throw CallUsageError("unknown flag --\(flag)")
                }
                continue
            }

            // Positional tool name (single mode only).
            if tool != nil {
                throw CallUsageError("unexpected argument \"\(token)\"")
            }
            tool = token
            index += 1
        }

        let hasSequence = callsJSON != nil || callsFile != nil
        let hasArgs = argsJSON != nil || argsFile != nil

        if hasSequence {
            if tool != nil {
                throw CallUsageError("tool name cannot be combined with --calls/--calls-file")
            }
            if hasArgs {
                throw CallUsageError("--args/--args-file cannot be combined with --calls/--calls-file")
            }
            let raw: String
            if let callsJSON {
                raw = callsJSON
            } else if let callsFile {
                raw = try readUTF8File(callsFile, label: "--calls-file")
            } else {
                throw CallUsageError("internal: sequence mode without source")
            }
            let records = try parseCallRecords(raw)
            let sleep = try parseSleep(sleepText, required: sawSleep)
            return .sequence(calls: records, sleepSeconds: sleep)
        }

        if sawSleep {
            throw CallUsageError("--sleep is only valid with --calls/--calls-file")
        }

        guard let toolName = tool, !toolName.isEmpty else {
            throw CallUsageError("missing tool name; run `semantouch call --help`")
        }
        if toolName.hasPrefix("-") {
            throw CallUsageError("invalid tool name \"\(toolName)\"")
        }

        let args: JSONValue
        if let argsJSON {
            args = try parseArgsObject(argsJSON, label: "--args")
        } else if let argsFile {
            let text = try readUTF8File(argsFile, label: "--args-file")
            args = try parseArgsObject(text, label: "--args-file")
        } else {
            args = .object([:])
        }

        return .single(CallRecord(tool: toolName, args: args))
    }

    // MARK: - Flag helpers

    private static func splitFlag(_ token: String) -> (String, String?) {
        let body = String(token.dropFirst(2))
        if let eq = body.firstIndex(of: "=") {
            let name = String(body[body.startIndex..<eq])
            let value = String(body[body.index(after: eq)...])
            return (name, value)
        }
        return (body, nil)
    }

    private static func takeValue(
        flag: String,
        inline: String?,
        arguments: [String],
        index: inout Int
    ) throws -> String {
        if let inline {
            index += 1
            return inline
        }
        let next = index + 1
        guard next < arguments.count else {
            throw CallUsageError("flag --\(flag) requires a value")
        }
        let value = arguments[next]
        if value.hasPrefix("--") {
            throw CallUsageError("flag --\(flag) requires a value")
        }
        index = next + 1
        return value
    }

    private static func parseSleep(_ text: String?, required: Bool) throws -> Double {
        guard let text else {
            if required {
                throw CallUsageError("flag --sleep requires a value")
            }
            return 0
        }
        guard let value = Double(text), value.isFinite, value >= 0 else {
            throw CallUsageError("--sleep must be a nonnegative finite number of seconds")
        }
        return value
    }

    private static func parseArgsObject(_ text: String, label: String) throws -> JSONValue {
        let value: JSONValue
        do {
            value = try JSONValue.parse(text)
        } catch {
            throw CallUsageError("\(label) is not valid JSON: \(errorMessage(error))")
        }
        guard case .object = value else {
            throw CallUsageError("\(label) must be a JSON object")
        }
        return value
    }

    private static func parseCallRecords(_ text: String) throws -> [CallRecord] {
        let value: JSONValue
        do {
            value = try JSONValue.parse(text)
        } catch {
            throw CallUsageError("--calls is not valid JSON: \(errorMessage(error))")
        }
        guard case let .array(items) = value else {
            throw CallUsageError("--calls must be a nonempty JSON array of call records")
        }
        if items.isEmpty {
            throw CallUsageError("--calls must be a nonempty JSON array of call records")
        }

        var records: [CallRecord] = []
        records.reserveCapacity(items.count)
        var seenBindings = Set<String>()
        for (offset, item) in items.enumerated() {
            guard case let .object(object) = item else {
                throw CallUsageError("call record at index \(offset) must be an object")
            }
            for key in object.keys {
                switch key {
                case "tool", "args", "as":
                    continue
                default:
                    throw CallUsageError(
                        "call record at index \(offset) has unknown key \"\(key)\""
                    )
                }
            }
            guard let toolValue = object["tool"] else {
                throw CallUsageError("call record at index \(offset) is missing \"tool\"")
            }
            guard case let .string(tool) = toolValue, !tool.isEmpty else {
                throw CallUsageError(
                    "call record at index \(offset) \"tool\" must be a nonempty string"
                )
            }
            let args: JSONValue
            if let provided = object["args"] {
                guard case .object = provided else {
                    throw CallUsageError(
                        "call record at index \(offset) \"args\" must be an object"
                    )
                }
                args = provided
            } else {
                args = .object([:])
            }
            let asName: String?
            if let provided = object["as"] {
                guard case let .string(name) = provided, !name.isEmpty else {
                    throw CallUsageError(
                        "call record at index \(offset) \"as\" must be a nonempty string"
                    )
                }
                if name.contains(".") || name.contains("[") || name.contains("]")
                    || name.contains("$") || name.contains("{") || name.contains("}")
                    || name.contains(" ")
                {
                    throw CallUsageError(
                        "call record at index \(offset) \"as\" binding name is invalid"
                    )
                }
                if seenBindings.contains(name) {
                    throw CallUsageError("duplicate binding name \"\(name)\"")
                }
                seenBindings.insert(name)
                asName = name
            } else {
                asName = nil
            }
            records.append(CallRecord(tool: tool, args: args, asName: asName))
        }
        return records
    }

    public static func readUTF8File(_ path: String, label: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CallUsageError("\(label) could not read \"\(path)\": \(error.localizedDescription)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CallUsageError("\(label) \"\(path)\" is not valid UTF-8")
        }
        return text
    }

    static func errorMessage(_ error: Error) -> String {
        if let parse = error as? JSONParseError {
            return parse.message
        }
        return String(describing: error)
    }
}

// MARK: - Placeholder resolution

public enum CallReferenceResolver {
    /// Resolve `${name.path}` placeholders in `value` against `bindings`.
    ///
    /// - Whole-value placeholder (string equal to exactly one `${…}`) → native JSON type.
    /// - Embedded placeholders inside strings → scalar string interpolation only.
    /// - Unresolved names/paths and non-scalar embedded refs → `CallUsageError`.
    public static func resolve(_ value: JSONValue, bindings: [String: JSONValue]) throws -> JSONValue {
        switch value {
        case .null, .bool, .int, .double:
            return value
        case let .string(text):
            return try resolveString(text, bindings: bindings)
        case let .array(items):
            return .array(try items.map { try resolve($0, bindings: bindings) })
        case let .object(object):
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(object.count)
            for (key, child) in object {
                out[key] = try resolve(child, bindings: bindings)
            }
            return .object(out)
        }
    }

    private static func resolveString(_ text: String, bindings: [String: JSONValue]) throws -> JSONValue {
        if let whole = wholePlaceholder(text) {
            return try lookup(whole, bindings: bindings)
        }

        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "$",
               text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "{"
            {
                guard let close = text[index...].firstIndex(of: "}") else {
                    throw CallUsageError("unterminated placeholder in \"\(text)\"")
                }
                let refStart = text.index(index, offsetBy: 2)
                let ref = String(text[refStart..<close])
                if ref.isEmpty {
                    throw CallUsageError("empty placeholder in \"\(text)\"")
                }
                let resolved = try lookup(ref, bindings: bindings)
                guard let scalar = scalarString(resolved) else {
                    throw CallUsageError(
                        "embedded placeholder ${\(ref)} must resolve to a scalar (string/number/bool/null)"
                    )
                }
                result += scalar
                index = text.index(after: close)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return .string(result)
    }

    /// Returns the inner ref if `text` is exactly `${ref}` with no extra characters.
    private static func wholePlaceholder(_ text: String) -> String? {
        guard text.count >= 3, text.first == "$", text.dropFirst().first == "{", text.last == "}" else {
            return nil
        }
        let inner = String(text.dropFirst(2).dropLast())
        if inner.isEmpty || inner.contains("{") || inner.contains("}") || inner.contains("$") {
            return nil
        }
        if text.filter({ $0 == "{" }).count != 1 || text.filter({ $0 == "}" }).count != 1 {
            return nil
        }
        return inner
    }

    private static func lookup(_ path: String, bindings: [String: JSONValue]) throws -> JSONValue {
        let parts = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let head = parts.first, !head.isEmpty else {
            throw CallUsageError("invalid placeholder path \"\(path)\"")
        }
        guard var current = bindings[head] else {
            throw CallUsageError("unresolved reference \"\(path)\"")
        }
        if parts.count == 1 {
            return current
        }
        for part in parts.dropFirst() {
            if part.isEmpty {
                throw CallUsageError("invalid placeholder path \"\(path)\"")
            }
            if case let .object(object) = current {
                guard let next = object[part] else {
                    throw CallUsageError("unresolved reference \"\(path)\"")
                }
                current = next
                continue
            }
            if case let .array(items) = current {
                guard let index = Int(part), index >= 0, index < items.count else {
                    throw CallUsageError("unresolved reference \"\(path)\"")
                }
                current = items[index]
                continue
            }
            throw CallUsageError("unresolved reference \"\(path)\"")
        }
        return current
    }

    private static func scalarString(_ value: JSONValue) -> String? {
        switch value {
        case .null:
            return "null"
        case let .bool(flag):
            return flag ? "true" : "false"
        case let .int(number):
            return String(number)
        case let .double(number):
            if number.isNaN || number.isInfinite { return nil }
            return String(number)
        case let .string(text):
            return text
        case .array, .object:
            return nil
        }
    }
}

// MARK: - Line transport

/// Newline-delimited JSON-RPC over injected read/write closures.
///
/// - `writeLine` must append a single `\n` after the payload.
/// - `readLine` returns the next complete line **without** the trailing newline,
///   or `nil` on EOF.
public struct CallTransport {
    public var writeLine: (String) throws -> Void
    public var readLine: () throws -> String?

    public init(
        writeLine: @escaping (String) throws -> Void,
        readLine: @escaping () throws -> String?
    ) {
        self.writeLine = writeLine
        self.readLine = readLine
    }
}

// MARK: - JSON-RPC call client

/// Stateful MCP tools/call client over one transport. Initializes once; no reconnect.
public final class CallClient {
    private let transport: CallTransport
    private var nextID: Int
    private var didInitialize = false
    private var bindings: [String: JSONValue] = [:]
    /// True after any tools/call has been attempted (for no-replay assertions).
    private(set) public var toolsCallCount = 0
    /// Captured outbound lines (without trailing newline) for tests.
    private(set) public var writtenLines: [String] = []
    private let recordWrites: Bool

    public init(transport: CallTransport, startingID: Int = 1, recordWrites: Bool = false) {
        self.transport = transport
        self.nextID = startingID
        self.recordWrites = recordWrites
    }

    public var currentBindings: [String: JSONValue] { bindings }

    /// Perform initialize + notifications/initialized exactly once.
    public func ensureInitialized() throws {
        if didInitialize { return }

        let id = allocateID()
        let params: JSONValue = [
            "protocolVersion": .string(MCPServer.mcpProtocolVersion),
            "capabilities": .object([:]),
            "clientInfo": [
                "name": .string("semantouch-call"),
                "version": .string(MCPServer.serverVersion),
            ],
        ]
        let request: JSONValue = [
            "jsonrpc": .string(JSONRPC.version),
            "id": .int(id),
            "method": .string("initialize"),
            "params": params,
        ]
        try send(request)

        let response = try readResponse(expectedID: .int(id), method: "initialize")
        if response["error"] != nil {
            let message = response["error"]?["message"]?.stringValue ?? "initialize failed"
            throw CallRuntimeError("initialize error: \(message)")
        }
        guard response["result"] != nil else {
            throw CallRuntimeError("initialize response missing result")
        }

        let notification: JSONValue = [
            "jsonrpc": .string(JSONRPC.version),
            "method": .string("notifications/initialized"),
        ]
        try send(notification)
        didInitialize = true
    }

    /// Execute one tools/call after resolving placeholders. Returns the `result` object.
    public func callTool(_ record: CallRecord) throws -> JSONValue {
        try ensureInitialized()

        let resolvedArgs = try CallReferenceResolver.resolve(record.args, bindings: bindings)
        guard case .object = resolvedArgs else {
            throw CallUsageError("resolved arguments must be a JSON object")
        }

        let id = allocateID()
        let params: JSONValue = [
            "name": .string(record.tool),
            "arguments": resolvedArgs,
        ]
        let request: JSONValue = [
            "jsonrpc": .string(JSONRPC.version),
            "id": .int(id),
            "method": .string("tools/call"),
            "params": params,
        ]
        toolsCallCount += 1
        try send(request)

        let response = try readResponse(expectedID: .int(id), method: "tools/call")
        if let error = response["error"] {
            let message = error["message"]?.stringValue ?? error.serialized()
            throw CallRuntimeError("tools/call JSON-RPC error: \(message)")
        }
        guard let result = response["result"] else {
            throw CallRuntimeError("tools/call response missing result")
        }
        guard case .object = result else {
            throw CallRuntimeError("tools/call result must be an object")
        }

        if let asName = record.asName {
            if bindings[asName] != nil {
                throw CallUsageError("duplicate binding name \"\(asName)\"")
            }
            let stored = try extractStoredValue(from: result)
            bindings[asName] = stored
        }

        return result
    }

    private func extractStoredValue(from result: JSONValue) throws -> JSONValue {
        if let content = result["content"]?.arrayValue,
           let first = content.first,
           let text = first["text"]?.stringValue
        {
            do {
                return try JSONValue.parse(text)
            } catch {
                return .string(text)
            }
        }
        return result
    }

    private func allocateID() -> Int {
        let id = nextID
        nextID += 1
        return id
    }

    private func send(_ value: JSONValue) throws {
        let line = value.serialized()
        if recordWrites {
            writtenLines.append(line)
        }
        try transport.writeLine(line)
    }

    private func readResponse(expectedID: JSONValue, method: String) throws -> JSONValue {
        while true {
            guard let line = try transport.readLine() else {
                throw CallRuntimeError("unexpected EOF while waiting for \(method) response")
            }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            let value: JSONValue
            do {
                value = try JSONValue.parse(line)
            } catch {
                throw CallRuntimeError(
                    "malformed JSON-RPC response: \(CallCommand.errorMessage(error))"
                )
            }
            guard case .object = value else {
                throw CallRuntimeError("JSON-RPC response must be an object")
            }
            if value["id"] == nil {
                continue
            }
            guard value["id"] == expectedID else {
                throw CallRuntimeError("mismatched JSON-RPC response id for \(method)")
            }
            return value
        }
    }
}

// MARK: - Runner


public struct CallIO {
    public var stdout: (String) -> Void
    public var stderr: (String) -> Void
    public var sleep: (Double) -> Void

    public init(
        stdout: @escaping (String) -> Void,
        stderr: @escaping (String) -> Void,
        sleep: @escaping (Double) -> Void = { seconds in
            if seconds > 0 {
                let micros = seconds * 1_000_000.0
                let clamped = min(max(micros, 0), Double(UInt32.max))
                usleep(useconds_t(clamped))
            }
        }
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.sleep = sleep
    }

    public static let standard = CallIO(
        stdout: { message in
            FileHandle.standardOutput.write(Data((message + "\n").utf8))
        },
        stderr: { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    )
}

public enum CallRunner {
    /// Execute a fully-parsed invocation against an already-built client.
    public static func run(
        _ invocation: CallInvocation,
        client: CallClient,
        io: CallIO
    ) -> Int32 {
        do {
            try client.ensureInitialized()
        } catch let error as CallUsageError {
            io.stderr("error: \(error.message)")
            return CallExitCode.usage
        } catch let error as CallRuntimeError {
            io.stderr("error: \(error.message)")
            return CallExitCode.failure
        } catch {
            io.stderr("error: \(error)")
            return CallExitCode.failure
        }

        switch invocation {
        case let .single(record):
            return runRecords([record], sleepSeconds: 0, client: client, io: io)
        case let .sequence(calls, sleepSeconds):
            return runRecords(calls, sleepSeconds: sleepSeconds, client: client, io: io)
        }
    }

    private static func runRecords(
        _ records: [CallRecord],
        sleepSeconds: Double,
        client: CallClient,
        io: CallIO
    ) -> Int32 {
        for (offset, record) in records.enumerated() {
            if offset > 0, sleepSeconds > 0 {
                io.sleep(sleepSeconds)
            }
            let result: JSONValue
            do {
                result = try client.callTool(record)
            } catch let error as CallUsageError {
                io.stderr("error: \(error.message)")
                return CallExitCode.usage
            } catch let error as CallRuntimeError {
                io.stderr("error: \(error.message)")
                return CallExitCode.failure
            } catch {
                io.stderr("error: \(error)")
                return CallExitCode.failure
            }

            // Always print the tools/call result object (including isError:true).
            io.stdout(result.serialized())

            if result["isError"]?.boolValue == true {
                io.stderr("error: tool \(record.tool) returned isError:true")
                return CallExitCode.failure
            }
        }
        return CallExitCode.success
    }

    /// Parse argv and run with a transport factory. `connect` is invoked at most once.
    public static func run(
        arguments: [String],
        io: CallIO = .standard,
        connect: () throws -> CallTransport
    ) -> Int32 {
        if arguments.count == 1, arguments[0] == "--help" || arguments[0] == "-h" {
            io.stdout(CallCommand.helpText)
            return CallExitCode.success
        }

        let invocation: CallInvocation
        do {
            invocation = try CallCommand.parse(arguments)
        } catch let error as CallUsageError {
            io.stderr("error: \(error.message)")
            return CallExitCode.usage
        } catch {
            io.stderr("error: \(error)")
            return CallExitCode.usage
        }

        let transport: CallTransport
        do {
            transport = try connect()
        } catch let error as CallUsageError {
            io.stderr("error: \(error.message)")
            return CallExitCode.usage
        } catch {
            io.stderr("error: \(error)")
            return CallExitCode.failure
        }

        let client = CallClient(transport: transport)
        return run(invocation, client: client, io: io)
    }
}
