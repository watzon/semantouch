import Foundation

/// A small, self-contained JSON value model (§1). The MCP layer never depends on
/// `JSONSerialization` for wire work: it parses incoming lines with the hand-rolled
/// recursive-descent reader (`parse`) and serializes outgoing messages with the
/// deterministic writer (`serialized`), which sorts object keys lexicographically so
/// identical logical values always produce byte-for-byte identical output.
///
/// The distinction between `.int` and `.double` is preserved from the source text:
/// a number token without `.`/`e`/`E` becomes `.int` (falling back to `.double` only
/// when it does not fit `Int`), everything else becomes `.double`. This matters
/// because JSON Schema separates `integer` from `number` and the protocol emits
/// whole-number fields as integers.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Literal ergonomics (schema authoring)

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object = [String: JSONValue](minimumCapacity: elements.count)
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
}

// MARK: - Accessors

public extension JSONValue {
    var isNull: Bool { if case .null = self { return true } else { return false } }

    var stringValue: String? { if case let .string(value) = self { return value } else { return nil } }

    var boolValue: Bool? { if case let .bool(value) = self { return value } else { return nil } }

    /// Integer projection; a whole-valued `.double` is accepted.
    var intValue: Int? {
        switch self {
        case let .int(value): return value
        case let .double(value) where value.rounded() == value && abs(value) < 9.2e18:
            return Int(value)
        default: return nil
        }
    }

    /// Numeric projection as `Double` (accepts `.int`).
    var doubleValue: Double? {
        switch self {
        case let .double(value): return value
        case let .int(value): return Double(value)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? { if case let .array(value) = self { return value } else { return nil } }

    var objectValue: [String: JSONValue]? { if case let .object(value) = self { return value } else { return nil } }

    /// Member access for object values; `nil` for any non-object or missing key.
    subscript(_ key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] } else { return nil }
    }
}

// MARK: - Deterministic serialization

public extension JSONValue {
    /// Canonical single-line JSON: object keys sorted lexicographically, no
    /// insignificant whitespace, slashes left literal. Deterministic for equal input.
    func serialized() -> String {
        var out = ""
        out.reserveCapacity(64)
        write(into: &out)
        return out
    }

    /// Canonical JSON as UTF-8 bytes.
    func serializedData() -> Data { Data(serialized().utf8) }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case let .bool(value):
            out += value ? "true" : "false"
        case let .int(value):
            out += String(value)
        case let .double(value):
            out += JSONValue.formatDouble(value)
        case let .string(value):
            JSONValue.writeString(value, into: &out)
        case let .array(elements):
            out += "["
            var first = true
            for element in elements {
                if !first { out += "," }
                first = false
                element.write(into: &out)
            }
            out += "]"
        case let .object(object):
            out += "{"
            var first = true
            for key in object.keys.sorted() {
                if !first { out += "," }
                first = false
                JSONValue.writeString(key, into: &out)
                out += ":"
                object[key]!.write(into: &out)
            }
            out += "}"
        }
    }

    private static func formatDouble(_ value: Double) -> String {
        // JSON has no NaN/Infinity; emit a defensive null rather than invalid JSON.
        if value.isNaN || value.isInfinite { return "null" }
        return String(value)
    }

    private static func writeString(_ string: String, into out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

// MARK: - Hand-rolled parser

/// Thrown when a line is not parseable JSON. The server maps this to JSON-RPC
/// `-32700` (Parse error) with a null id.
public struct JSONParseError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public extension JSONValue {
    /// Parse one complete JSON document from `string`. Top-level fragments (a bare
    /// string/number/bool/null/array) are accepted so the caller can distinguish
    /// "valid JSON that is not a request" from "malformed JSON". Trailing
    /// non-whitespace after the value is an error.
    static func parse(_ string: String) throws -> JSONValue {
        var parser = Reader(Array(string.unicodeScalars))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        if !parser.isAtEnd {
            throw JSONParseError("unexpected trailing content")
        }
        return value
    }

    /// Parse from UTF-8 bytes.
    static func parse(_ data: Data) throws -> JSONValue {
        try parse(String(decoding: data, as: UTF8.self))
    }
}

private struct Reader {
    let scalars: [Unicode.Scalar]
    var index = 0

    init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

    var isAtEnd: Bool { index >= scalars.count }

    private func peek() -> Unicode.Scalar? { isAtEnd ? nil : scalars[index] }

    mutating func skipWhitespace() {
        while index < scalars.count {
            switch scalars[index] {
            case " ", "\t", "\n", "\r": index += 1
            default: return
            }
        }
    }

    mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard let scalar = peek() else { throw JSONParseError("unexpected end of input") }
        switch scalar {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t", "f": return .bool(try parseBool())
        case "n": try parseLiteral("null"); return .null
        case "-", "0"..."9": return try parseNumber()
        default: throw JSONParseError("unexpected character '\(scalar)'")
        }
    }

    private mutating func expect(_ scalar: Unicode.Scalar) throws {
        guard peek() == scalar else { throw JSONParseError("expected '\(scalar)'") }
        index += 1
    }

    private mutating func parseObject() throws -> JSONValue {
        try expect("{")
        var object: [String: JSONValue] = [:]
        skipWhitespace()
        if peek() == "}" { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard peek() == "\"" else { throw JSONParseError("expected string key in object") }
            let key = try parseString()
            skipWhitespace()
            try expect(":")
            let value = try parseValue()
            object[key] = value
            skipWhitespace()
            switch peek() {
            case ",": index += 1
            case "}": index += 1; return .object(object)
            default: throw JSONParseError("expected ',' or '}' in object")
            }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try expect("[")
        var array: [JSONValue] = []
        skipWhitespace()
        if peek() == "]" { index += 1; return .array(array) }
        while true {
            let value = try parseValue()
            array.append(value)
            skipWhitespace()
            switch peek() {
            case ",": index += 1
            case "]": index += 1; return .array(array)
            default: throw JSONParseError("expected ',' or ']' in array")
            }
        }
    }

    private mutating func parseBool() throws -> Bool {
        if peek() == "t" { try parseLiteral("true"); return true }
        try parseLiteral("false"); return false
    }

    private mutating func parseLiteral(_ literal: String) throws {
        for expected in literal.unicodeScalars {
            guard peek() == expected else { throw JSONParseError("invalid literal, expected '\(literal)'") }
            index += 1
        }
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        var isDouble = false
        if peek() == "-" { index += 1 }
        while let scalar = peek() {
            switch scalar {
            case "0"..."9": index += 1
            case ".", "e", "E", "+", "-": isDouble = true; index += 1
            default:
                return try makeNumber(from: start, isDouble: isDouble)
            }
        }
        return try makeNumber(from: start, isDouble: isDouble)
    }

    private func makeNumber(from start: Int, isDouble: Bool) throws -> JSONValue {
        let token = String(String.UnicodeScalarView(scalars[start..<index]))
        if !isDouble, let intValue = Int(token) {
            return .int(intValue)
        }
        if let doubleValue = Double(token) {
            return .double(doubleValue)
        }
        throw JSONParseError("invalid number '\(token)'")
    }

    private mutating func parseString() throws -> String {
        try expect("\"")
        var result = String.UnicodeScalarView()
        while let scalar = peek() {
            index += 1
            switch scalar {
            case "\"":
                return String(result)
            case "\\":
                guard let escape = peek() else { throw JSONParseError("unterminated escape") }
                index += 1
                switch escape {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u": result.append(try parseUnicodeEscape())
                default: throw JSONParseError("invalid escape '\\\(escape)'")
                }
            default:
                result.append(scalar)
            }
        }
        throw JSONParseError("unterminated string")
    }

    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let first = try readHex4()
        if first >= 0xD800 && first <= 0xDBFF {
            // High surrogate: a low surrogate must follow.
            guard peek() == "\\" else { throw JSONParseError("expected low surrogate") }
            index += 1
            guard peek() == "u" else { throw JSONParseError("expected low surrogate") }
            index += 1
            let second = try readHex4()
            guard second >= 0xDC00 && second <= 0xDFFF else {
                throw JSONParseError("invalid low surrogate")
            }
            let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            guard let scalar = Unicode.Scalar(combined) else {
                throw JSONParseError("invalid surrogate pair")
            }
            return scalar
        }
        if first >= 0xDC00 && first <= 0xDFFF {
            throw JSONParseError("unexpected low surrogate")
        }
        guard let scalar = Unicode.Scalar(first) else {
            throw JSONParseError("invalid unicode escape")
        }
        return scalar
    }

    private mutating func readHex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let scalar = peek(), let digit = hexDigit(scalar) else {
                throw JSONParseError("invalid \\u escape")
            }
            index += 1
            value = (value << 4) | digit
        }
        return value
    }

    private func hexDigit(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar {
        case "0"..."9": return scalar.value - 0x30
        case "a"..."f": return scalar.value - 0x61 + 10
        case "A"..."F": return scalar.value - 0x41 + 10
        default: return nil
        }
    }
}

// MARK: - Codable interop

extension JSONValue: Codable {
    /// Dynamic key used to encode/decode arbitrary object keys.
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }

    public init(from decoder: Decoder) throws {
        // Objects and arrays first; then scalars in bool → int → double → string order
        // so a JSON `true` never decodes as an integer.
        if let keyed = try? decoder.container(keyedBy: DynamicKey.self) {
            var object: [String: JSONValue] = [:]
            for key in keyed.allKeys {
                object[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var array: [JSONValue] = []
            while !unkeyed.isAtEnd {
                array.append(try unkeyed.decode(JSONValue.self))
            }
            self = .array(array)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let value = try? single.decode(Bool.self) { self = .bool(value); return }
        if let value = try? single.decode(Int.self) { self = .int(value); return }
        if let value = try? single.decode(Double.self) { self = .double(value); return }
        if let value = try? single.decode(String.self) { self = .string(value); return }
        throw DecodingError.dataCorruptedError(
            in: single, debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .int(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .double(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .array(elements):
            var container = encoder.unkeyedContainer()
            for element in elements { try container.encode(element) }
        case let .object(object):
            var container = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in object {
                try container.encode(value, forKey: DynamicKey(stringValue: key)!)
            }
        }
    }
}
