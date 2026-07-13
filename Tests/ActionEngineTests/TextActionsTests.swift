import XCTest
import ComputerUseCore
@testable import ActionEngine

/// `set_value` and `select_text` semantics (§13.3): settable AX attributes only.
final class TextActionsTests: XCTestCase {
    // MARK: - set_value

    func testSetValueWritesAndReportsStateChanged() throws {
        let element = FakeActionElement(settable: [AXActionName.value], attributes: [AXActionName.value: "old"])
        let result = try TextActions.setValue(element, value: .string("new"), elementId: "e1")
        XCTAssertEqual(element.wroteValue, .string("new"))
        XCTAssertTrue(result.stateChanged, "old → new is a change")
        XCTAssertEqual(result.method, .accessibility)
        XCTAssertTrue(result.refreshRecommended)
    }

    func testSetValueNoChangeWhenSameValue() throws {
        let element = FakeActionElement(settable: [AXActionName.value], attributes: [AXActionName.value: "same"])
        let result = try TextActions.setValue(element, value: .string("same"), elementId: "e1")
        XCTAssertFalse(result.stateChanged)
    }

    func testSetValueAcceptsNumberAndBoolean() throws {
        let numeric = FakeActionElement(settable: [AXActionName.value], attributes: [AXActionName.value: "0"])
        _ = try TextActions.setValue(numeric, value: .number(3), elementId: "e1")
        XCTAssertEqual(numeric.wroteValue, .number(3))

        let toggle = FakeActionElement(settable: [AXActionName.value], attributes: [AXActionName.value: "0"])
        let result = try TextActions.setValue(toggle, value: .boolean(true), elementId: "e1")
        XCTAssertEqual(toggle.wroteValue, .boolean(true))
        XCTAssertTrue(result.stateChanged, "0 → 1")
    }

    // MARK: - set_value commit (§18.5)

    func testSetValueWithoutCommitOmitsCommittedField() throws {
        let element = FakeActionElement(settable: [AXActionName.value], attributes: [AXActionName.value: "old"])
        let result = try TextActions.setValue(element, value: .string("new"), commit: false, elementId: "e1")
        XCTAssertNil(result.committed, "committed is present only for a commit request (byte-compat)")
        XCTAssertEqual(element.focusRequests, 0, "no pre-focus without commit")
        XCTAssertTrue(element.performed.isEmpty, "no Confirm without commit")
    }

    func testSetValueCommitPerformsAdvertisedConfirmAndPreFocuses() throws {
        let element = FakeActionElement(
            actions: ["AXConfirm"],
            settable: [AXActionName.value, AXActionName.focused],
            attributes: [AXActionName.value: "old"]
        )
        let result = try TextActions.setValue(element, value: .string("https://example.com"), commit: true, elementId: "e9")
        XCTAssertEqual(result.committed, true, "AXConfirm advertised and performed → committed")
        XCTAssertEqual(element.performed, ["AXConfirm"])
        XCTAssertEqual(element.focusRequests, 1, "commit pre-focuses the field before the write")
        XCTAssertEqual(element.wroteValue, .string("https://example.com"))
        XCTAssertNil(result.warning)
    }

    func testSetValueCommitMatchesStrippedConfirmForm() throws {
        // A non-AX-prefixed "Confirm" action still matches per §13.3 stripping.
        let element = FakeActionElement(
            actions: ["Confirm"],
            settable: [AXActionName.value],
            attributes: [AXActionName.value: "old"]
        )
        let result = try TextActions.setValue(element, value: .string("x"), commit: true, elementId: "e9")
        XCTAssertEqual(result.committed, true)
        XCTAssertEqual(element.performed, ["Confirm"])
    }

    func testSetValueCommitWithoutConfirmIsCompletedFalseWithWarning() throws {
        let element = FakeActionElement(
            actions: ["AXPress"],
            settable: [AXActionName.value],
            attributes: [AXActionName.value: "old"]
        )
        let result = try TextActions.setValue(element, value: .string("x"), commit: true, elementId: "e9")
        XCTAssertEqual(result.status, .completed, "the value was written, so still completed")
        XCTAssertEqual(result.committed, false, "no Confirm advertised → not committed")
        XCTAssertTrue(element.performed.isEmpty, "never falls back to a synthesized keypress (§13.3)")
        XCTAssertNotNil(result.warning, "advises an element-targeted press_key enter")
        XCTAssertTrue(result.warning?.contains("press_key") ?? false)
    }

    func testSetValueCommitConfirmFaultIsCommittedFalse() throws {
        let element = FakeActionElement(
            actions: ["AXConfirm"],
            settable: [AXActionName.value],
            attributes: [AXActionName.value: "old"]
        )
        element.performError = CUError.internalError(detail: "confirm faulted")
        let result = try TextActions.setValue(element, value: .string("x"), commit: true, elementId: "e9")
        XCTAssertEqual(result.status, .completed, "the value write succeeded before the confirm attempt")
        XCTAssertEqual(result.committed, false, "an advertised-but-faulted Confirm is honestly not committed")
        XCTAssertNotNil(result.warning)
    }

    func testSetValueOnNonSettableIsUnsupported() {
        let element = FakeActionElement(actions: ["AXPress"]) // AXValue not settable
        XCTAssertThrowsError(try TextActions.setValue(element, value: .string("x"), elementId: "e3")) { error in
            guard case let CUError.unsupportedAction(elementId, action, _, reason) = error else {
                return XCTFail("expected unsupportedAction, got \(error)")
            }
            XCTAssertEqual(elementId, "e3")
            XCTAssertNil(action, "a not-settable attribute carries no action name")
            XCTAssertNotNil(reason, "a settability failure explains itself via data.reason")
        }
        XCTAssertNil(element.wroteValue)
    }

    // MARK: - select_text

    func testSelectTextSetsRangeOnTextElement() throws {
        let element = FakeActionElement(settable: [AXActionName.selectedTextRange])
        let result = try TextActions.selectText(element, start: 2, length: 4, elementId: "e1")
        XCTAssertEqual(element.wroteRange?.location, 2)
        XCTAssertEqual(element.wroteRange?.length, 4)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .accessibility)
    }

    func testSelectTextCaretUsesZeroLength() throws {
        let element = FakeActionElement(settable: [AXActionName.selectedTextRange])
        _ = try TextActions.selectText(element, start: 5, length: 0, elementId: "e1")
        XCTAssertEqual(element.wroteRange?.location, 5)
        XCTAssertEqual(element.wroteRange?.length, 0)
    }

    func testSelectTextOnNonTextElementIsUnsupported() {
        let element = FakeActionElement(actions: ["AXPress"]) // AXSelectedTextRange not settable
        XCTAssertThrowsError(try TextActions.selectText(element, start: 0, length: 1, elementId: "e7")) { error in
            guard case let CUError.unsupportedAction(elementId, _, _, reason) = error else {
                return XCTFail("expected unsupportedAction, got \(error)")
            }
            XCTAssertEqual(elementId, "e7")
            XCTAssertNotNil(reason)
        }
        XCTAssertNil(element.wroteRange)
    }
}
