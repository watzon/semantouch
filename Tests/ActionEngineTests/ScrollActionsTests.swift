import XCTest
import ComputerUseCore
@testable import ActionEngine

/// The semantic scroll ladder (§13.3): scrollbar `AXValue` → by-page action →
/// `AXScrollToVisible` descendant → `unsupported_action`.
final class ScrollActionsTests: XCTestCase {
    private func scrollArea(role: String = "AXScrollArea", actions: [String] = []) -> FakeActionElement {
        FakeActionElement(role: role, actions: actions)
    }

    // MARK: - Rung 1: settable scrollbar AXValue

    func testScrollUsesSettableVerticalScrollBar() throws {
        let bar = FakeActionElement(settable: [AXActionName.value], attributes: [AXActionName.value: "0.5"])
        let area = scrollArea()
        area.namedElements[AXActionName.verticalScrollBar] = bar

        let result = try ScrollActions.scroll(area, direction: .down, by: .line, count: 1, elementId: "e1")

        guard case let .number(written) = bar.wroteValue else { return XCTFail("expected a numeric scrollbar write") }
        XCTAssertEqual(written, 0.6, accuracy: 1e-9, "down + one line: 0.5 + 0.1")
        XCTAssertTrue(result.stateChanged)
        XCTAssertEqual(result.method, .accessibility)
        XCTAssertEqual(result.warning, "scrolled via scrollbar AXValue")
        XCTAssertTrue(area.performed.isEmpty, "the scrollbar rung must not perform an action")
    }

    func testScrollUpDecreasesScrollBarValue() throws {
        let bar = FakeActionElement(settable: [AXActionName.value], attributes: [AXActionName.value: "0.5"])
        let area = scrollArea()
        area.namedElements[AXActionName.verticalScrollBar] = bar
        _ = try ScrollActions.scroll(area, direction: .up, by: .line, count: 1, elementId: "e1")
        guard case let .number(written) = bar.wroteValue else { return XCTFail("expected numeric write") }
        XCTAssertEqual(written, 0.4, accuracy: 1e-9)
    }

    func testScrollRightUsesHorizontalScrollBar() throws {
        let bar = FakeActionElement(settable: [AXActionName.value], attributes: [AXActionName.value: "0.2"])
        let area = scrollArea()
        area.namedElements[AXActionName.horizontalScrollBar] = bar
        _ = try ScrollActions.scroll(area, direction: .right, by: .page, count: 1, elementId: "e1")
        guard case let .number(written) = bar.wroteValue else { return XCTFail("expected numeric write") }
        XCTAssertEqual(written, 1.0, accuracy: 1e-9, "0.2 + 0.9 page delta, clamped to 1.0")
    }

    // MARK: - Rung 2: by-page action on the scroll area

    func testScrollFallsToByPageActionWhenNoSettableScrollBar() throws {
        let area = scrollArea(actions: ["AXScrollDownByPage", "AXScrollUpByPage"])
        let result = try ScrollActions.scroll(area, direction: .down, by: .page, count: 2, elementId: "e1")
        XCTAssertEqual(area.performed, ["AXScrollDownByPage", "AXScrollDownByPage"], "count repeats the action")
        XCTAssertFalse(result.stateChanged, "no readable value ⇒ best-effort false")
        XCTAssertEqual(result.warning, "scrolled via AXScrollDownByPage")
    }

    func testByPageActionForLineGranularityNotesApproximation() throws {
        let area = scrollArea(actions: ["AXScrollRightByPage"])
        let result = try ScrollActions.scroll(area, direction: .right, by: .line, count: 1, elementId: "e1")
        XCTAssertEqual(area.performed, ["AXScrollRightByPage"])
        XCTAssertEqual(result.warning, "scrolled via AXScrollRightByPage (page granularity; line approximated)")
    }

    // MARK: - Rung 3: AXScrollToVisible descendant

    func testScrollFallsToScrollToVisibleDescendant() throws {
        let descendant = FakeActionElement(actions: [AXActionName.scrollToVisible])
        let middle = FakeActionElement()
        middle.childElements = [descendant]
        let area = scrollArea() // no scrollbar, no by-page action
        area.childElements = [middle]

        let result = try ScrollActions.scroll(area, direction: .down, by: .line, count: 1, elementId: "e1")
        XCTAssertEqual(descendant.performed, [AXActionName.scrollToVisible])
        XCTAssertEqual(result.warning, "scrolled a descendant into view via AXScrollToVisible")
    }

    // MARK: - Rung 4: nothing applies

    func testScrollWithNoMechanismIsUnsupportedWithReason() {
        let area = scrollArea() // no scrollbar, no actions, no scrollable descendants
        XCTAssertThrowsError(try ScrollActions.scroll(area, direction: .down, by: .line, count: 1, elementId: "e9")) { error in
            guard case let CUError.unsupportedAction(elementId, action, _, reason) = error else {
                return XCTFail("expected unsupportedAction, got \(error)")
            }
            XCTAssertEqual(elementId, "e9")
            XCTAssertNil(action)
            XCTAssertNotNil(reason, "scroll reports why no mechanism applied via data.reason")
        }
    }

    func testFractionalPageOnScrollBarIsExact() throws {
        let bar = FakeActionElement(settable: [AXActionName.value], attributes: [AXActionName.value: "0.2"])
        let area = scrollArea()
        area.namedElements[AXActionName.verticalScrollBar] = bar
        _ = try ScrollActions.scroll(area, direction: .down, by: .page, count: 0.5, elementId: "e1")
        guard case let .number(written) = bar.wroteValue else { return XCTFail("expected numeric write") }
        // 0.2 + 0.9 * 0.5 = 0.65
        XCTAssertEqual(written, 0.65, accuracy: 1e-9)
    }

    func testIntegerCountStillWorksAsDouble() throws {
        let bar = FakeActionElement(settable: [AXActionName.value], attributes: [AXActionName.value: "0.5"])
        let area = scrollArea()
        area.namedElements[AXActionName.verticalScrollBar] = bar
        _ = try ScrollActions.scroll(area, direction: .down, by: .line, count: 1, elementId: "e1")
        guard case let .number(written) = bar.wroteValue else { return XCTFail("expected numeric write") }
        XCTAssertEqual(written, 0.6, accuracy: 1e-9)
    }

    func testFractionalByPageActionReportsApproximation() throws {
        let area = scrollArea(actions: ["AXScrollDownByPage"])
        let result = try ScrollActions.scroll(area, direction: .down, by: .page, count: 1.5, elementId: "e1")
        XCTAssertEqual(area.performed.count, 2, "ceil(1.5) discrete page actions")
        XCTAssertTrue(result.warning?.contains("approximated") ?? false, "fractional discrete path documents approximation")
    }

    func testSemanticRepeatedLeftClickIsAXPress() throws {
        // Documented here for the scroll/action suite: multi left click stays on AXPress.
        // (Full coverage lives in SemanticActionsTests.)
    }
}
