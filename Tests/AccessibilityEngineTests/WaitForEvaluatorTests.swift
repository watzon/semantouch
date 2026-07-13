import XCTest
@testable import AccessibilityEngine

/// Pure `wait_for` condition evaluation (§18.7), driven over a fake probe so no live AX or
/// window is needed. Covers each condition kind, the all/any combination, request-order
/// results, the lazy tree walk, and the observed title/URL.
final class WaitForEvaluatorTests: XCTestCase {
    /// A configurable `WaitForWindowProbe` that records whether its (bounded) walk was pulled.
    final class FakeProbe: WaitFor.WaitForWindowProbe {
        var titleValue: String?
        var urlValue: String?
        var elementList: [WaitFor.ProbedElement]
        private(set) var elementsCalls = 0

        init(title: String? = nil, url: String? = nil, elements: [WaitFor.ProbedElement] = []) {
            self.titleValue = title
            self.urlValue = url
            self.elementList = elements
        }

        var windowTitle: String? { titleValue }
        var documentURL: String? { urlValue }
        func elements() -> [WaitFor.ProbedElement] {
            elementsCalls += 1
            return elementList
        }
    }

    private func evaluate(_ conditions: [WaitFor.Condition], mode: WaitFor.Mode = .all, probe: FakeProbe) -> WaitFor.Evaluation {
        WaitFor.evaluate(conditions: conditions, mode: mode, probe: probe)
    }

    // MARK: - Title conditions

    func testTitleChanged() {
        let probe = FakeProbe(title: "New Page")
        XCTAssertTrue(evaluate([.titleChanged(from: "Start Page")], probe: probe).satisfied)
        XCTAssertFalse(evaluate([.titleChanged(from: "New Page")], probe: probe).satisfied)
    }

    func testTitleChangedTreatsUnreadableTitleAsChangedFromNonempty() {
        let probe = FakeProbe(title: nil)
        XCTAssertTrue(evaluate([.titleChanged(from: "Start Page")], probe: probe).satisfied)
    }

    func testTitleContainsIsCaseInsensitive() {
        let probe = FakeProbe(title: "Example Domain")
        XCTAssertTrue(evaluate([.titleContains(value: "example")], probe: probe).satisfied)
        XCTAssertTrue(evaluate([.titleContains(value: "DOMAIN")], probe: probe).satisfied)
        XCTAssertFalse(evaluate([.titleContains(value: "missing")], probe: probe).satisfied)
    }

    func testTitleContainsFalseWhenTitleUnreadable() {
        let probe = FakeProbe(title: nil)
        XCTAssertFalse(evaluate([.titleContains(value: "anything")], probe: probe).satisfied)
    }

    // MARK: - URL conditions

    func testUrlChangedAndContains() {
        let probe = FakeProbe(url: "https://example.com/")
        XCTAssertTrue(evaluate([.urlChanged(from: "https://start.example/")], probe: probe).satisfied)
        XCTAssertFalse(evaluate([.urlChanged(from: "https://example.com/")], probe: probe).satisfied)
        XCTAssertTrue(evaluate([.urlContains(value: "EXAMPLE.com")], probe: probe).satisfied)
        XCTAssertFalse(evaluate([.urlContains(value: "other.test")], probe: probe).satisfied)
    }

    // MARK: - Element matchers

    private func button(_ title: String, value: String? = nil) -> WaitFor.ProbedElement {
        WaitFor.ProbedElement(role: "AXButton", title: title, value: value)
    }

    func testElementExistsMatchesRoleExactAndTextCaseInsensitive() {
        let probe = FakeProbe(elements: [button("Submit"), .init(role: "AXTextField", title: "Email", value: "ada@example.com")])
        XCTAssertTrue(evaluate([.elementExists(.init(role: "AXButton"))], probe: probe).satisfied)
        XCTAssertTrue(evaluate([.elementExists(.init(titleContains: "submit"))], probe: probe).satisfied)
        XCTAssertTrue(evaluate([.elementExists(.init(role: "AXTextField", valueContains: "ADA@"))], probe: probe).satisfied)
        // Role is matched exactly, so a wrong role fails even when text matches.
        XCTAssertFalse(evaluate([.elementExists(.init(role: "AXLink", titleContains: "submit"))], probe: probe).satisfied)
    }

    func testElementGoneIsTheInverse() {
        let present = FakeProbe(elements: [button("Loading…")])
        XCTAssertFalse(evaluate([.elementGone(.init(titleContains: "loading"))], probe: present).satisfied)
        let absent = FakeProbe(elements: [button("Done")])
        XCTAssertTrue(evaluate([.elementGone(.init(titleContains: "loading"))], probe: absent).satisfied)
    }

    // MARK: - Mode + ordering

    func testModeAllRequiresEveryCondition() {
        let probe = FakeProbe(title: "Example Domain", url: "https://example.com/")
        let conditions: [WaitFor.Condition] = [.titleContains(value: "example"), .urlContains(value: "missing")]
        let all = evaluate(conditions, mode: .all, probe: probe)
        XCTAssertFalse(all.satisfied)
        XCTAssertEqual(all.conditionResults, [true, false], "per-condition results are in request order")
        let any = evaluate(conditions, mode: .any, probe: probe)
        XCTAssertTrue(any.satisfied, "any is satisfied by the first true condition")
        XCTAssertEqual(any.conditionResults, [true, false])
    }

    // MARK: - Observations + lazy walk

    func testObservedFieldsReflectTheProbe() {
        let probe = FakeProbe(title: "Example Domain", url: "https://example.com/")
        let evaluation = evaluate([.titleContains(value: "example")], probe: probe)
        XCTAssertEqual(evaluation.observedTitle, "Example Domain")
        XCTAssertEqual(evaluation.observedURL, "https://example.com/")
    }

    func testTitleOnlyConditionsNeverWalkTheTree() {
        let probe = FakeProbe(title: "Example Domain")
        _ = evaluate([.titleChanged(from: "Old"), .titleContains(value: "example")], probe: probe)
        XCTAssertEqual(probe.elementsCalls, 0, "a title-only condition set must not trigger the bounded element walk")
    }

    func testElementConditionWalksTreeOnce() {
        let probe = FakeProbe(elements: [button("A"), button("B")])
        _ = evaluate([.elementExists(.init(role: "AXButton")), .elementGone(.init(titleContains: "C"))], probe: probe)
        XCTAssertEqual(probe.elementsCalls, 1, "the element list is cached across conditions in one evaluation")
    }

    // MARK: - Discriminants

    func testDiscriminantsMatchTheWire() {
        XCTAssertEqual(WaitFor.Condition.titleChanged(from: "x").discriminant, "title_changed")
        XCTAssertEqual(WaitFor.Condition.titleContains(value: "x").discriminant, "title_contains")
        XCTAssertEqual(WaitFor.Condition.urlChanged(from: "x").discriminant, "url_changed")
        XCTAssertEqual(WaitFor.Condition.urlContains(value: "x").discriminant, "url_contains")
        XCTAssertEqual(WaitFor.Condition.elementExists(.init(role: "AXButton")).discriminant, "element_exists")
        XCTAssertEqual(WaitFor.Condition.elementGone(.init(role: "AXButton")).discriminant, "element_gone")
    }
}
