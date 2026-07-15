import Foundation
import ComputerUseCore

/// One content block of a `tools/call` result (§5). Text carries the canonical JSON
/// payload for the tool; an image carries base64 bytes with a MIME type (the
/// screenshot path for `get_app_state`).
public enum ToolContent: Equatable, Sendable {
    case text(String)
    case image(base64: String, mimeType: String)
}

/// The value a tool handler returns. `isError` distinguishes a normal result from a
/// tool-level failure; both are delivered as a *successful* JSON-RPC response (§5).
public struct ToolResult: Equatable, Sendable {
    public var content: [ToolContent]
    public var isError: Bool

    public init(content: [ToolContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    /// Convenience for a single text block.
    public static func text(_ text: String, isError: Bool = false) -> ToolResult {
        ToolResult(content: [.text(text)], isError: isError)
    }

    /// Render to the `{ content: [...], isError }` result envelope (§5).
    public func toJSONValue() -> JSONValue {
        let blocks: [JSONValue] = content.map { block in
            switch block {
            case let .text(text):
                return ["type": "text", "text": .string(text)]
            case let .image(base64, mimeType):
                return ["type": "image", "data": .string(base64), "mimeType": .string(mimeType)]
            }
        }
        return ["content": .array(blocks), "isError": .bool(isError)]
    }
}

/// Thrown by a handler when its arguments are structurally invalid in a way that
/// should surface as a JSON-RPC `-32602` (Invalid params) rather than a tool-level
/// error. Central schema validation (see `SchemaValidator`) covers the common cases;
/// this exists for handler-specific checks.
public struct ToolInvalidArguments: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// A handler receives the tool's `arguments` object (`.object`, possibly empty) and
/// returns a `ToolResult`. Throwing a `CUError` yields a tool-level error result
/// (`isError: true`); throwing `ToolInvalidArguments` yields `-32602`; any other
/// throw becomes a tool-level `internal_error`.
public typealias ToolHandler = @Sendable (JSONValue) async throws -> ToolResult

/// Conservative MCP behavior hints emitted with every tool descriptor.
///
/// These are client-facing scheduling and approval hints, not an authorization
/// boundary. Semantouch still enforces policy and revision checks server-side.
struct ToolAnnotations: Sendable {
    let readOnly: Bool
    let destructive: Bool
    let idempotent: Bool
    let openWorld: Bool

    var json: JSONValue {
        [
            "readOnlyHint": .bool(readOnly),
            "destructiveHint": .bool(destructive),
            "idempotentHint": .bool(idempotent),
            "openWorldHint": .bool(openWorld),
        ]
    }

    static func forTool(named name: String) -> ToolAnnotations {
        switch name {
        case "list_apps", "get_app_state", "read_text", "screenshot", "wait_for":
            return ToolAnnotations(
                readOnly: true,
                destructive: false,
                idempotent: true,
                openWorld: true
            )
        case "doctor":
            // requestOnboarding can show an OS permission prompt, so the tool as
            // a whole cannot honestly claim to be read-only.
            return ToolAnnotations(
                readOnly: false,
                destructive: false,
                idempotent: true,
                openWorld: true
            )
        case "end_app_session":
            return ToolAnnotations(
                readOnly: false,
                destructive: false,
                idempotent: true,
                openWorld: false
            )
        default:
            // UI mutations can trigger arbitrary effects in the target app.
            return ToolAnnotations(
                readOnly: false,
                destructive: true,
                idempotent: false,
                openWorld: true
            )
        }
    }
}

/// A registered tool: its identity, frozen JSON Schema (§4), and handler.
public struct Tool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let handler: ToolHandler

    public init(name: String, description: String, inputSchema: JSONValue, handler: @escaping ToolHandler) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.handler = handler
    }

    /// The `{ name, description, inputSchema, annotations }` descriptor emitted by
    /// `tools/list` (§2). Annotations are conservative client hints; policy remains
    /// server-enforced.
    public var descriptor: JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": ToolAnnotations.forTool(named: name).json,
        ]
    }
}

/// The set of tools the server knows about, plus which are enabled in the current
/// phase (§4). `tools/list` shows only enabled tools; a defined-but-disabled tool
/// answers a tool-level `policy_denied` / `tool_disabled` error; a tool absent from
/// the registry is an unknown tool (`-32602`).
public final class ToolRegistry: @unchecked Sendable {
    private let toolsByName: [String: Tool]
    private let order: [String]
    private let enabledNames: Set<String>

    /// - Parameters:
    ///   - tools: every defined tool, in the order they should appear in `tools/list`.
    ///   - enabled: the subset of tool names enabled in this build.
    public init(tools: [Tool], enabled: Set<String>) {
        var map: [String: Tool] = [:]
        var order: [String] = []
        for tool in tools {
            map[tool.name] = tool
            order.append(tool.name)
        }
        self.toolsByName = map
        self.order = order
        self.enabledNames = enabled
    }

    /// Whether a tool with this name exists at all (defined in any phase).
    public func isDefined(_ name: String) -> Bool { toolsByName[name] != nil }

    /// Whether a defined tool is enabled in the current build.
    public func isEnabled(_ name: String) -> Bool {
        enabledNames.contains(name) && toolsByName[name] != nil
    }

    /// Look up a defined tool.
    public func tool(named name: String) -> Tool? { toolsByName[name] }

    /// Descriptors for `tools/list`: enabled tools only, in registration order.
    public func enabledDescriptors() -> [JSONValue] {
        order.compactMap { name in isEnabled(name) ? toolsByName[name]?.descriptor : nil }
    }

    /// Enabled tool names, in registration order (diagnostics/tests).
    public var enabledToolNames: [String] {
        order.filter { isEnabled($0) }
    }
}

public extension ToolRegistry {
    /// Build the full tool registry from `ToolSchemas`, defaulting to the currently
    /// enabled set. Real handlers are injected by name; any tool without an injected
    /// handler gets a placeholder that throws `internal_error` (never reached for a
    /// disabled tool, which short-circuits to `policy_denied` before dispatch).
    static func standard(
        enabled: Set<String> = Set(ToolCatalog.enabledNames),
        handlers: [String: ToolHandler] = [:]
    ) -> ToolRegistry {
        let tools = ToolSchemas.all.map { spec -> Tool in
            let handler: ToolHandler = handlers[spec.name] ?? { _ in
                throw CUError.internalError(detail: "tool \"\(spec.name)\" has no handler wired in this build")
            }
            return Tool(
                name: spec.name,
                description: spec.description,
                inputSchema: spec.schema,
                handler: handler
            )
        }
        return ToolRegistry(tools: tools, enabled: enabled)
    }
}

// MARK: - Minimal JSON Schema validation

/// A focused validator for the JSON Schema subset the tool schemas use (§4): `type`
/// (single or union), `enum`, `minimum`, `maximum`, `pattern`, `oneOf` (exactly one
/// alternative must match — used by `read_text.limit`), for objects `required`,
/// `additionalProperties: false`, and recursion into declared `properties`, and for
/// arrays recursion into the declared `items` subschema. Returns `nil` when valid,
/// else a human-readable reason. This is intentionally not a full JSON Schema
/// implementation — only what the frozen contract needs.
public enum SchemaValidator {
    /// Validate `value` against `schema`; `nil` means valid.
    public static func validate(_ value: JSONValue, schema: JSONValue) -> String? {
        guard case let .object(schemaObject) = schema else { return nil }

        // `oneOf`: exactly one alternative must accept the value. Checked before a
        // sibling `type` so a pure union schema (e.g. read_text.limit) is not
        // short-circuited by an absent outer type. Other keywords still apply when
        // present alongside `oneOf`.
        if let oneOfNode = schemaObject["oneOf"], case let .array(alternatives) = oneOfNode {
            if let reason = validateOneOf(value, alternatives: alternatives) {
                return reason
            }
        }

        if let typeNode = schemaObject["type"], !matchesType(value, typeNode) {
            return "expected type \(describeType(typeNode))"
        }

        if let enumNode = schemaObject["enum"], case let .array(options) = enumNode,
           !options.contains(value) {
            return "value is not one of the allowed options"
        }

        if let minimumNode = schemaObject["minimum"], let minimum = minimumNode.doubleValue,
           let number = value.doubleValue, number < minimum {
            return "value is below the minimum of \(minimumNode.serialized())"
        }

        if let maximumNode = schemaObject["maximum"], let maximum = maximumNode.doubleValue,
           let number = value.doubleValue, number > maximum {
            return "value is above the maximum of \(maximumNode.serialized())"
        }

        if let patternNode = schemaObject["pattern"], let pattern = patternNode.stringValue,
           case let .string(string) = value, !regexMatches(string, pattern: pattern) {
            return "value does not match required pattern \(pattern)"
        }

        if case let .object(object) = value {
            return validateObject(object, schemaObject: schemaObject)
        }

        if case let .array(elements) = value {
            return validateArray(elements, schemaObject: schemaObject)
        }

        return nil
    }

    /// JSON Schema `oneOf`: the value must match **exactly one** alternative.
    private static func validateOneOf(_ value: JSONValue, alternatives: [JSONValue]) -> String? {
        var matchCount = 0
        for alternative in alternatives {
            if validate(value, schema: alternative) == nil {
                matchCount += 1
            }
        }
        if matchCount == 1 { return nil }
        if matchCount == 0 {
            return "value does not match any oneOf alternative"
        }
        return "value matches more than one oneOf alternative"
    }

    /// Validate an array's length bounds (`minItems`/`maxItems`, used by `wait_for.conditions`,
    /// §18.7) and each element against the schema's `items` subschema, if one is declared
    /// (returning the first failure). The other array-with-items field in the frozen contract is
    /// `modifiers` (`{ type: array, items: { enum: [cmd|ctrl|opt|shift|fn] } }` on
    /// `click`/`drag`); without item validation an out-of-enum entry would be accepted here and
    /// then silently dropped by the handler instead of yielding a clean `-32602` that matches the
    /// declared schema.
    private static func validateArray(
        _ elements: [JSONValue],
        schemaObject: [String: JSONValue]
    ) -> String? {
        if let minItems = schemaObject["minItems"]?.intValue, elements.count < minItems {
            return "array has fewer than the minimum of \(minItems) items"
        }
        if let maxItems = schemaObject["maxItems"]?.intValue, elements.count > maxItems {
            return "array has more than the maximum of \(maxItems) items"
        }
        guard let itemsSchema = schemaObject["items"] else { return nil }
        for (index, element) in elements.enumerated() {
            if let reason = validate(element, schema: itemsSchema) {
                return "item \(index): \(reason)"
            }
        }
        return nil
    }

    private static func validateObject(
        _ object: [String: JSONValue],
        schemaObject: [String: JSONValue]
    ) -> String? {
        var properties: [String: JSONValue] = [:]
        if let propertiesNode = schemaObject["properties"], case let .object(declared) = propertiesNode {
            properties = declared
        }

        if let requiredNode = schemaObject["required"], case let .array(required) = requiredNode {
            for entry in required {
                if case let .string(key) = entry, object[key] == nil {
                    return "missing required property \"\(key)\""
                }
            }
        }

        let additionalAllowed: Bool
        if let node = schemaObject["additionalProperties"], case let .bool(flag) = node {
            additionalAllowed = flag
        } else {
            additionalAllowed = true
        }
        if !additionalAllowed {
            for key in object.keys where properties[key] == nil {
                return "unexpected property \"\(key)\""
            }
        }

        for (key, subschema) in properties {
            if let subvalue = object[key], let reason = validate(subvalue, schema: subschema) {
                return "property \"\(key)\": \(reason)"
            }
        }

        return nil
    }

    private static func matchesType(_ value: JSONValue, _ typeNode: JSONValue) -> Bool {
        switch typeNode {
        case let .string(type):
            return matchesSingleType(value, type)
        case let .array(types):
            return types.contains { entry in
                if case let .string(type) = entry { return matchesSingleType(value, type) }
                return false
            }
        default:
            return true
        }
    }

    private static func matchesSingleType(_ value: JSONValue, _ type: String) -> Bool {
        switch type {
        case "object": if case .object = value { return true }; return false
        case "array": if case .array = value { return true }; return false
        case "string": if case .string = value { return true }; return false
        case "boolean": if case .bool = value { return true }; return false
        case "null": if case .null = value { return true }; return false
        case "integer":
            if case .int = value { return true }
            if case let .double(number) = value, number.rounded() == number { return true }
            return false
        case "number":
            if case .int = value { return true }
            if case .double = value { return true }
            return false
        default:
            return true
        }
    }

    private static func regexMatches(_ string: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return true }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        // Require the match to span the WHOLE string. `firstMatch(...) != nil` is not
        // enough: ICU anchors `$` before a trailing line terminator, so a `^…$` pattern
        // like the frozen `^s[0-9]+$` / `^e[0-9]+$` session/element ids would otherwise
        // accept a value with a trailing newline (e.g. "s1\n"). Comparing the matched
        // range to the full range rejects any leftover characters, newline included.
        return regex.firstMatch(in: string, range: range)?.range == range
    }

    private static func describeType(_ typeNode: JSONValue) -> String {
        switch typeNode {
        case let .string(type):
            return type
        case let .array(types):
            let names = types.compactMap { $0.stringValue }
            return names.joined(separator: "|")
        default:
            return "value"
        }
    }
}
