import XCTest
import ComputerUseCore
@testable import ActionEngine

/// `click` and `perform_action` semantics (§13.3).
final class SemanticActionsTests: XCTestCase {
    // MARK: - click

    func testClickPerformsAXPress() throws {
        let element = FakeActionElement(actions: [AXActionName.press])
        let result = try SemanticActions.click(element, elementId: "e1")
        XCTAssertEqual(element.performed, [AXActionName.press])
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .accessibility)
        XCTAssertTrue(result.refreshRecommended)
    }

    func testClickReportsStateChangedFromValueReRead() throws {
        let element = FakeActionElement(actions: [AXActionName.press], attributes: [AXActionName.value: "0"])
        element.onPerform = { [weak element] _ in element?.attributes[AXActionName.value] = "1" }
        let result = try SemanticActions.click(element, elementId: "e1")
        XCTAssertTrue(result.stateChanged, "AXValue 0 → 1 across the press is a state change")
    }

    func testClickReportsNoStateChangeWhenValueUnchanged() throws {
        let element = FakeActionElement(actions: [AXActionName.press], attributes: [AXActionName.value: "7"])
        let result = try SemanticActions.click(element, elementId: "e1")
        XCTAssertFalse(result.stateChanged)
    }

    func testClickWithoutAXPressIsUnsupported() {
        let element = FakeActionElement(actions: ["AXShowMenu"])
        XCTAssertThrowsError(try SemanticActions.click(element, elementId: "e5")) { error in
            guard case let CUError.unsupportedAction(elementId, action, supported, _) = error else {
                return XCTFail("expected unsupportedAction, got \(error)")
            }
            XCTAssertEqual(elementId, "e5")
            XCTAssertEqual(action, AXActionName.press)
            XCTAssertEqual(supported, ["AXShowMenu"], "supported lists the raw AX action names")
        }
        XCTAssertTrue(element.performed.isEmpty)
    }

    // MARK: - perform_action

    func testPerformActionMatchesStrippedTreeName() throws {
        let element = FakeActionElement(actions: ["AXShowMenu"])
        _ = try SemanticActions.performNamed(element, name: "ShowMenu", elementId: "e1")
        XCTAssertEqual(element.performed, ["AXShowMenu"], "the AX-stripped name resolves to the raw action")
    }

    func testPerformActionMatchesRawName() throws {
        let element = FakeActionElement(actions: ["AXShowMenu"])
        _ = try SemanticActions.performNamed(element, name: "AXShowMenu", elementId: "e1")
        XCTAssertEqual(element.performed, ["AXShowMenu"])
    }

    func testPerformActionUnknownNameIsUnsupported() {
        let element = FakeActionElement(actions: ["AXPress", "AXShowMenu"])
        XCTAssertThrowsError(try SemanticActions.performNamed(element, name: "Confirm", elementId: "e2")) { error in
            guard case let CUError.unsupportedAction(elementId, action, supported, _) = error else {
                return XCTFail("expected unsupportedAction, got \(error)")
            }
            XCTAssertEqual(elementId, "e2")
            XCTAssertEqual(action, "Confirm")
            XCTAssertEqual(supported, ["AXPress", "AXShowMenu"])
        }
        XCTAssertTrue(element.performed.isEmpty)
    }
}
