import XCTest
import ComputerUseCore
@testable import AccessibilityEngine

/// Grammar golden + determinism tests for `AXTreeRenderer` (docs/PROTOCOL.md §7).
/// These are pure: hand-built `UINode` fixtures, no Accessibility permission.
///
/// Expected escaped `\u00XX` outputs are written with ordinary double-backslash
/// literals (e.g. `"\\u0007"`) so the six literal characters land unambiguously.
final class AXTreeRendererTests: XCTestCase {

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
        Rect(x: x, y: y, width: w, height: h)
    }

    private let ellipsis = "\u{2026}"

    // MARK: - §7.6 golden — full, untruncated

    /// Byte-for-byte reproduction of the frozen §7.6 worked example.
    func testGoldenSignInExample() {
        let tree = UINode(id: 1, role: "AXWindow", title: "Sign In", frame: rect(0, 0, 420, 300), children: [
            UINode(id: 2, role: "AXStaticText", title: "Email", frame: rect(24, 28, 60, 18)),
            UINode(id: 3, role: "AXTextField", value: "ada@example.com", focused: true,
                   frame: rect(92, 24, 304, 26), actions: ["AXConfirmText"]),
            UINode(id: 4, role: "AXStaticText", title: "Password", frame: rect(24, 66, 60, 18)),
            UINode(id: 5, role: "AXTextField", subrole: "AXSecureTextField", placeholder: "Required",
                   frame: rect(92, 62, 304, 26), actions: ["AXConfirmText"]),
            UINode(id: 6, role: "AXCheckBox", title: "Remember me", value: "0",
                   frame: rect(24, 104, 150, 22), actions: ["AXPress"]),
            UINode(id: 7, role: "AXButton", title: "Sign In", enabled: false,
                   frame: rect(92, 150, 120, 32), actions: ["AXPress"]),
            UINode(id: 8, role: "AXButton", title: "Cancel",
                   frame: rect(224, 150, 120, 32), actions: ["AXPress"]),
        ])

        let expected = """
        [e1] AXWindow "Sign In" frame=0,0,420,300
          [e2] AXStaticText "Email" frame=24,28,60,18
          [e3] AXTextField value="ada@example.com" focused=true frame=92,24,304,26 actions=[ConfirmText]
          [e4] AXStaticText "Password" frame=24,66,60,18
          [e5] AXTextField.AXSecureTextField placeholder="Required" frame=92,62,304,26 actions=[ConfirmText]
          [e6] AXCheckBox "Remember me" value="0" frame=24,104,150,22 actions=[Press]
          [e7] AXButton "Sign In" enabled=false frame=92,150,120,32 actions=[Press]
          [e8] AXButton "Cancel" frame=224,150,120,32 actions=[Press]
        """

        let result = AXTreeRenderer.render(tree)
        XCTAssertEqual(result.text, expected)
        XCTAssertEqual(result.nodeCount, 8)
        XCTAssertFalse(result.truncated)
        XCTAssertFalse(result.text.hasSuffix("\n"), "no trailing newline (§7.1)")
    }

    // MARK: - Key order + presence (§7.2)

    func testFixedKeyOrderAndFlagPresence() {
        let node = UINode(
            id: 9, role: "AXTextField", subrole: "AXSearchField",
            title: "T", value: "V", description: "D", placeholder: "P",
            enabled: false, focused: true, selected: true,
            frame: rect(1, 2, 3, 4), actions: ["AXConfirm", "AXShowMenu"]
        )
        let line = AXTreeRenderer.renderLine(depth: 0, node: node, options: .default)
        XCTAssertEqual(
            line,
            #"[e9] AXTextField.AXSearchField "T" value="V" placeholder="P" desc="D" enabled=false focused=true selected=true frame=1,2,3,4 actions=[Confirm,ShowMenu]"#
        )
    }

    func testOmitsAbsentFieldsAndDefaultFlags() {
        let node = UINode(id: 2, role: "AXGroup", frame: rect(0, 0, 10, 10))
        XCTAssertEqual(AXTreeRenderer.renderLine(depth: 0, node: node, options: .default),
                       "[e2] AXGroup frame=0,0,10,10")
    }

    func testEmptyStringFieldsAreOmitted() {
        let node = UINode(id: 3, role: "AXButton", title: "", value: "", description: "", placeholder: "",
                          frame: rect(0, 0, 1, 1))
        XCTAssertEqual(AXTreeRenderer.renderLine(depth: 0, node: node, options: .default),
                       "[e3] AXButton frame=0,0,1,1")
    }

    // MARK: - Frame rendering (§7.2.7)

    func testFrameRounding_nearestTiesAwayFromZero() {
        XCTAssertEqual(AXTreeRenderer.renderFrame(rect(0.5, 1.5, 2.4, 2.6)), "1,2,2,3")
        XCTAssertEqual(AXTreeRenderer.renderFrame(rect(-0.5, -1.5, 10.49, 10.51)), "-1,-2,10,11")
    }

    func testFrameSentinelWhenNil() {
        let node = UINode(id: 5, role: "AXButton", title: "X", frame: nil)
        XCTAssertEqual(AXTreeRenderer.renderLine(depth: 0, node: node, options: .default),
                       #"[e5] AXButton "X" frame=?"#)
    }

    // MARK: - Escaping (§7.3)

    func testEscapingAllSpecialsAndPassthrough() {
        // quote, backslash, newline, CR, tab, bell (C0 control), em-dash (passthrough).
        let raw = "a\"b\\c\nd\re\tf\u{07}g\u{2014}h"
        let escaped = AXTreeRenderer.renderField(raw, cap: 4096)
        let expected = "a\\\"b\\\\c\\nd\\re\\tf\\u0007g\u{2014}h"
        XCTAssertEqual(escaped, expected)
        XCTAssertTrue(escaped.contains("\u{2014}"), "em-dash survives unescaped")
        XCTAssertFalse(escaped.contains("\n"))
        XCTAssertFalse(escaped.contains("\r"))
        XCTAssertFalse(escaped.contains("\t"))
    }

    func testC0ControlHexIsLowercaseFourDigits() {
        // Other C0 controls become \u00XX, lowercase hex, zero-padded to four digits.
        XCTAssertEqual(AXTreeRenderer.renderField("\u{1F}", cap: 64), "\\u001f")
        XCTAssertEqual(AXTreeRenderer.renderField("\u{00}", cap: 64), "\\u0000")
        XCTAssertEqual(AXTreeRenderer.renderField("\u{07}", cap: 64), "\\u0007")
    }

    func testEscapingInsideRenderedLine() {
        let node = UINode(id: 7, role: "AXStaticText", value: "line1\nline2\t\"q\"", frame: rect(0, 0, 1, 1))
        XCTAssertEqual(AXTreeRenderer.renderLine(depth: 0, node: node, options: .default),
                       #"[e7] AXStaticText value="line1\nline2\t\"q\"" frame=0,0,1,1"#)
    }

    // MARK: - Per-field truncation (§7.5)

    func testFieldTruncationAscii_capIncludesEllipsis() {
        let value = String(repeating: "a", count: 300)
        let out = AXTreeRenderer.renderField(value, cap: 256)
        XCTAssertEqual(out.utf8.count, 256, "content + ellipsis fills exactly the cap")
        XCTAssertTrue(out.hasSuffix(ellipsis))
        XCTAssertEqual(out, String(repeating: "a", count: 253) + ellipsis)
    }

    func testFieldTruncationNeverSplitsMultibyteScalar() {
        // 'é' is 2 bytes; budget 253 fits 126 (252 bytes); the 127th would overflow.
        let value = String(repeating: "é", count: 200)
        let out = AXTreeRenderer.renderField(value, cap: 256)
        XCTAssertEqual(out, String(repeating: "é", count: 126) + ellipsis)
        XCTAssertEqual(out.utf8.count, 255)
        XCTAssertTrue(out.hasSuffix(ellipsis))
    }

    func testFieldTruncationNeverSplitsEscapeUnit() {
        // Each bell escapes to a 6-byte "" unit; budget 253 fits 42 whole
        // units (252 bytes); the 43rd would overflow, so we stop and append ellipsis.
        let value = String(repeating: "\u{07}", count: 60)
        let out = AXTreeRenderer.renderField(value, cap: 256)
        XCTAssertEqual(out, String(repeating: "\\u0007", count: 42) + ellipsis)
        XCTAssertEqual(out.utf8.count, 42 * 6 + 3)
        XCTAssertLessThanOrEqual(out.utf8.count, 256)
    }

    func testFieldNotTruncatedWhenExactlyAtCap() {
        let value = String(repeating: "a", count: 256)
        let out = AXTreeRenderer.renderField(value, cap: 256)
        XCTAssertEqual(out, value)
        XCTAssertFalse(out.hasSuffix(ellipsis))
    }

    // MARK: - Token sanitization + AX stripping (§7.1, §7.2)

    func testRoleAndSubroleSanitized() {
        let node = UINode(id: 1, role: "AX Custom[Role]", subrole: "Sub\"role", frame: rect(0, 0, 1, 1))
        XCTAssertEqual(AXTreeRenderer.renderLine(depth: 0, node: node, options: .default),
                       "[e1] AX_Custom_Role_.Sub_role frame=0,0,1,1")
    }

    func testActionAXStripAndSanitize() {
        XCTAssertEqual(AXTreeRenderer.stripAXPrefix("AXPress"), "Press")
        XCTAssertEqual(AXTreeRenderer.stripAXPrefix("AXShowMenu"), "ShowMenu")
        XCTAssertEqual(AXTreeRenderer.stripAXPrefix("customAction"), "customAction")
        let node = UINode(id: 1, role: "AXButton", frame: rect(0, 0, 1, 1),
                          actions: ["AXPress", "custom action]"])
        XCTAssertEqual(AXTreeRenderer.renderLine(depth: 0, node: node, options: .default),
                       "[e1] AXButton frame=0,0,1,1 actions=[Press,custom_action_]")
    }

    // MARK: - Duplicate titles

    func testDuplicateTitlesRenderIndependently() {
        let tree = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 40), children: [
            UINode(id: 2, role: "AXButton", title: "OK", frame: rect(0, 0, 40, 20), actions: ["AXPress"]),
            UINode(id: 3, role: "AXButton", title: "OK", frame: rect(50, 0, 40, 20), actions: ["AXPress"]),
        ])
        let result = AXTreeRenderer.render(tree)
        XCTAssertEqual(result.text, """
        [e1] AXWindow frame=0,0,100,40
          [e2] AXButton "OK" frame=0,0,40,20 actions=[Press]
          [e3] AXButton "OK" frame=50,0,40,20 actions=[Press]
        """)
    }

    // MARK: - Determinism

    func testByteForByteDeterminismAcrossRepeatedRenders() {
        let tree = UINode(id: 1, role: "AXWindow", title: "Docs — Safari", frame: rect(0, 0, 1200, 760), children: [
            UINode(id: 2, role: "AXToolbar", frame: rect(0, 0, 1200, 52), children: [
                UINode(id: 3, role: "AXButton", title: "Back", enabled: false, frame: rect(12, 12, 28, 28), actions: ["AXPress"]),
            ]),
            UINode(id: 4, role: "AXWebArea", title: "ScreenCaptureKit", frame: rect(0, 52, 1200, 708)),
        ])
        let a = AXTreeRenderer.render(tree)
        let b = AXTreeRenderer.render(tree)
        XCTAssertEqual(Array(a.text.utf8), Array(b.text.utf8))
        XCTAssertEqual(a.text, b.text)
        XCTAssertEqual(a.nodeCount, b.nodeCount)
        XCTAssertEqual(a.truncated, b.truncated)
    }

    // MARK: - Node-cap truncation (§7.5)

    func testNodeCapTruncationMarker() {
        var children: [UINode] = []
        for i in 2...6 {
            children.append(UINode(id: i, role: "AXButton", title: "B\(i)", frame: rect(0, 0, 10, 10)))
        }
        let tree = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: children)
        // total = 6 nodes; cap emits 3 element lines then one marker at depth 1.
        let result = AXTreeRenderer.render(tree, options: .init(maxNodes: 3))
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.nodeCount, 3)
        XCTAssertEqual(result.text, """
        [e1] AXWindow frame=0,0,100,100
          [e2] AXButton "B2" frame=0,0,10,10
          [e3] AXButton "B3" frame=0,0,10,10
          \(ellipsis) +3 nodes omitted
        """)
    }

    func testNoMarkerWhenExactlyAtNodeCap() {
        let tree = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 10, 10), children: [
            UINode(id: 2, role: "AXButton", title: "A", frame: rect(0, 0, 1, 1)),
        ])
        let result = AXTreeRenderer.render(tree, options: .init(maxNodes: 2))
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.nodeCount, 2)
        XCTAssertFalse(result.text.contains("omitted"))
    }

    // MARK: - Byte-cap truncation (§7.5)

    func testByteCapTruncationEmitsSingleMarkerWithinBudget() {
        var children: [UINode] = []
        for i in 2...30 {
            children.append(UINode(id: i, role: "AXButton", title: "Button number \(i)",
                                   frame: rect(0, 0, 100, 20), actions: ["AXPress"]))
        }
        let tree = UINode(id: 1, role: "AXWindow", title: "W", frame: rect(0, 0, 400, 400), children: children)
        let cap = 200
        let result = AXTreeRenderer.render(tree, options: .init(maxNodes: 10_000, maxBytes: cap))
        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.text.utf8.count, cap, "text + marker stays within the byte cap")

        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false)
        // Single marker, indented to the first omitted node's depth (a depth-1 child).
        XCTAssertEqual(String(lines.last!), "  \(ellipsis) +\(30 - result.nodeCount) nodes omitted")
        XCTAssertEqual(lines.filter { $0.contains("nodes omitted") }.count, 1)
        // Every non-marker line is a complete element line (never cut mid-element).
        for line in lines.dropLast() {
            XCTAssertTrue(line.contains("frame="), "line was cut mid-element: \(line)")
        }
    }
}
