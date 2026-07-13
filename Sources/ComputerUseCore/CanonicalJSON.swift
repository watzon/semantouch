import Foundation

/// Deterministic JSON encoding for the wire.
///
/// Every payload the server writes to the MCP channel MUST be byte-for-byte stable
/// for identical input, so a single encoder configuration is used everywhere:
///
/// - `.sortedKeys` — object keys are emitted in lexicographic order.
/// - `.withoutEscapingSlashes` — `/` is left literal (matters for paths/URLs and
///   keeps output predictable).
///
/// Numbers use `JSONEncoder`'s default (shortest round-tripping) formatting; the
/// DTOs deliberately model whole-number wire fields (`Int`) as integers so they
/// never acquire a spurious decimal point.
///
/// A fresh encoder/decoder is produced per call so there is no shared mutable
/// state to reason about across threads.
public enum CanonicalJSON {
    /// A configured encoder producing deterministic output.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// A plain decoder (input is untrusted client JSON; no special options).
    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    public static func encodeToData<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    /// Encode `value` to a canonical UTF-8 JSON string (no trailing newline).
    public static func encodeToString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try makeEncoder().encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try makeDecoder().decode(type, from: Data(string.utf8))
    }
}
