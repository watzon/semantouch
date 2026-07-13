import XCTest
@testable import MCPServer

/// Parser/serializer behavior for the hand-rolled `JSONValue` (section 1). Covers the
/// int/double/bool distinction, deterministic sorted-key output, string escaping,
/// unicode escapes (incl. surrogate pairs), fragments, and malformed input.
final class JSONValueTests: XCTestCase {
    // MARK: Parsing scalars

    func testParsesIntegersAsInt() throws {
        XCTAssertEqual(try JSONValue.parse("123"), .int(123))
        XCTAssertEqual(try JSONValue.parse("-7"), .int(-7))
        XCTAssertEqual(try JSONValue.parse("0"), .int(0))
    }

    func testParsesDecimalsAndExponentsAsDouble() throws {
        XCTAssertEqual(try JSONValue.parse("12.5"), .double(12.5))
        XCTAssertEqual(try JSONValue.parse("2.0"), .double(2.0))
        XCTAssertEqual(try JSONValue.parse("1e3"), .double(1000))
    }

    func testIntAndDoubleAreDistinct() throws {
        // The whole-number source 2.0 stays a double, distinct from 2.
        XCTAssertNotEqual(try JSONValue.parse("2.0"), .int(2))
        XCTAssertEqual(try JSONValue.parse("[1, 2.0]"), .array([.int(1), .double(2.0)]))
    }

    func testParsesBoolAndNull() throws {
        XCTAssertEqual(try JSONValue.parse("true"), .bool(true))
        XCTAssertEqual(try JSONValue.parse("false"), .bool(false))
        XCTAssertEqual(try JSONValue.parse("null"), .null)
    }

    func testBoolIsNotParsedAsNumber() throws {
        // Regression guard: true must never become an int/double.
        guard case .bool = try JSONValue.parse("true") else {
            return XCTFail("true should parse as bool")
        }
    }

    // MARK: Strings & escapes

    func testParsesStringEscapes() throws {
        XCTAssertEqual(try JSONValue.parse(#""a\"b\\c\nd\te""#), .string("a\"b\\c\nd\te"))
        XCTAssertEqual(try JSONValue.parse(#""A""#), .string("A"))
    }

    func testParsesSurrogatePair() throws {
        // U+1F600 GRINNING FACE via a UTF-16 surrogate pair.
        XCTAssertEqual(try JSONValue.parse(#""😀""#), .string("\u{1F600}"))
    }

    func testSerializeEscapesControlCharacters() {
        let value = JSONValue.string("x\u{01}y")
        // Expected serialized form: quote, x, backslash-u-0001, y, quote. The escape
        // is built by concatenation to avoid embedding a raw control byte in source.
        let expected = "\"x" + "\\u0001" + "y\""
        XCTAssertEqual(value.serialized(), expected)
    }

    func testSerializeEscapesQuotesBackslashesAndWhitespace() {
        let value = JSONValue.string("a\"b\\c\nd\te\rf")
        XCTAssertEqual(value.serialized(), #""a\"b\\c\nd\te\rf""#)
    }

    func testSlashesAreNotEscaped() {
        XCTAssertEqual(JSONValue.string("a/b").serialized(), #""a/b""#)
    }

    // MARK: Determinism

    func testObjectKeysAreSortedDeterministically() {
        let a: JSONValue = ["b": 1, "a": 2, "c": 3]
        let b: JSONValue = ["c": 3, "a": 2, "b": 1]
        XCTAssertEqual(a.serialized(), #"{"a":2,"b":1,"c":3}"#)
        XCTAssertEqual(a.serialized(), b.serialized())
    }

    func testNestedSerializationIsCanonical() {
        let value: JSONValue = [
            "z": ["nested": true],
            "a": [1, 2, 3],
        ]
        XCTAssertEqual(value.serialized(), #"{"a":[1,2,3],"z":{"nested":true}}"#)
    }

    func testRoundTripThroughParseAndSerialize() throws {
        let source = #"{"app":"Finder","ok":true,"count":3,"ratio":0.5,"items":["x","y"],"none":null}"#
        let parsed = try JSONValue.parse(source)
        // Serialization is canonical (sorted); re-parsing must yield the same value.
        XCTAssertEqual(try JSONValue.parse(parsed.serialized()), parsed)
    }

    // MARK: Fragments and errors

    func testTopLevelFragmentsAreAccepted() throws {
        XCTAssertEqual(try JSONValue.parse("  42  "), .int(42))
        XCTAssertEqual(try JSONValue.parse("\"hi\""), .string("hi"))
    }

    func testTrailingContentIsRejected() {
        XCTAssertThrowsError(try JSONValue.parse("1 2"))
        XCTAssertThrowsError(try JSONValue.parse("{} garbage"))
    }

    func testMalformedInputThrows() {
        XCTAssertThrowsError(try JSONValue.parse("{"))
        XCTAssertThrowsError(try JSONValue.parse(""))
        XCTAssertThrowsError(try JSONValue.parse("{\"a\":}"))
        XCTAssertThrowsError(try JSONValue.parse("[1,]"))
        XCTAssertThrowsError(try JSONValue.parse("tru"))
    }

    func testEmptyContainers() throws {
        XCTAssertEqual(try JSONValue.parse("{}"), .object([:]))
        XCTAssertEqual(try JSONValue.parse("[]"), .array([]))
        XCTAssertEqual(JSONValue.object([:]).serialized(), "{}")
        XCTAssertEqual(JSONValue.array([]).serialized(), "[]")
    }

    // MARK: Accessors

    func testAccessors() throws {
        let value = try JSONValue.parse(#"{"s":"hi","i":5,"b":true,"a":[1],"n":null}"#)
        XCTAssertEqual(value["s"]?.stringValue, "hi")
        XCTAssertEqual(value["i"]?.intValue, 5)
        XCTAssertEqual(value["b"]?.boolValue, true)
        XCTAssertEqual(value["a"]?.arrayValue?.count, 1)
        XCTAssertEqual(value["n"]?.isNull, true)
        XCTAssertNil(value["missing"])
    }

    // MARK: Codable interop

    func testCodableRoundTrip() throws {
        let value: JSONValue = ["a": 1, "b": ["c": true, "d": [1, 2]], "e": "s"]
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }
}
