import XCTest
@testable import AccessibilityEngine

/// Permission-free coverage for the pure web-content accessibility enablement logic
/// (§18.1). The `WebAXAppElement` seam is faked, so no live app element or Accessibility
/// grant is required (mirrors the `WorkspaceControlling`/`SettleDetector` fake pattern).
final class WebContentAccessibilityTests: XCTestCase {
    private static let manual = "AXManualAccessibility"
    private static let enhanced = "AXEnhancedUserInterface"

    /// A fake app element: `values` are current attribute reads (nil = absent); `setResults`
    /// dictate each attribute's set outcome. A `.set` outcome reflects into `values` so a
    /// re-read would see the flip.
    private final class FakeWebAXElement: WebContentAccessibility.WebAXAppElement {
        var values: [String: Bool]
        var setResults: [String: WebContentAccessibility.SetOutcome]
        private(set) var sets: [(attribute: String, value: Bool)] = []

        init(
            values: [String: Bool] = [:],
            setResults: [String: WebContentAccessibility.SetOutcome] = [:]
        ) {
            self.values = values
            self.setResults = setResults
        }

        func currentBool(_ attribute: String) -> Bool? { values[attribute] }

        func setBool(_ attribute: String, _ value: Bool) -> WebContentAccessibility.SetOutcome {
            sets.append((attribute, value))
            let outcome = setResults[attribute] ?? .set
            if outcome == .set { values[attribute] = value }
            return outcome
        }
    }

    func testAttributesAreTheTwoPublicGates() {
        // Electron (`AXManualAccessibility`) first, Chromium (`AXEnhancedUserInterface`) next.
        XCTAssertEqual(WebContentAccessibility.attributes, [Self.manual, Self.enhanced])
    }

    func testEnableFlipsBothWhenAbsent() {
        let element = FakeWebAXElement()
        let result = WebContentAccessibility.enable(element)
        XCTAssertEqual(result.newlyEnabled, [Self.manual, Self.enhanced])
        XCTAssertTrue(result.alreadyEnabled.isEmpty)
        XCTAssertTrue(result.unsupported.isEmpty)
        XCTAssertFalse(result.faulted)
        XCTAssertTrue(result.didEnableAny)
        XCTAssertEqual(element.sets.map { $0.attribute }, [Self.manual, Self.enhanced])
        XCTAssertTrue(element.sets.allSatisfy { $0.value })
    }

    func testAlreadyEnabledIsNeverReflipped() {
        // VoiceOver already set the Electron gate; the server must not re-flip it (so it is
        // never reset later). The absent Chromium gate is still enabled.
        let element = FakeWebAXElement(values: [Self.manual: true])
        let result = WebContentAccessibility.enable(element)
        XCTAssertEqual(result.alreadyEnabled, [Self.manual])
        XCTAssertEqual(result.newlyEnabled, [Self.enhanced])
        XCTAssertEqual(element.sets.map { $0.attribute }, [Self.enhanced], "must not write an already-true attribute")
    }

    func testUnsupportedAttributesAreSilentAndNotAFault() {
        // A non-web app exposes neither gate: both writes report unsupported → a silent no-op.
        let element = FakeWebAXElement(setResults: [Self.manual: .unsupported, Self.enhanced: .unsupported])
        let result = WebContentAccessibility.enable(element)
        XCTAssertTrue(result.newlyEnabled.isEmpty)
        XCTAssertEqual(result.unsupported, [Self.manual, Self.enhanced])
        XCTAssertFalse(result.faulted)
        XCTAssertFalse(result.didEnableAny)
    }

    func testFaultIsReportedForRetry() {
        // A genuine AX fault on one write marks the whole attempt as faulted (retry next snapshot).
        let element = FakeWebAXElement(setResults: [Self.manual: .faulted])
        let result = WebContentAccessibility.enable(element)
        XCTAssertTrue(result.faulted)
        XCTAssertFalse(result.newlyEnabled.contains(Self.manual))
        // The second attribute is still attempted (and, here, flips).
        XCTAssertEqual(result.newlyEnabled, [Self.enhanced])
    }

    func testResetTouchesOnlyTheGivenFlippedAttributes() {
        // Only the server-flipped attribute is reset; a pre-existing true is never clobbered.
        let element = FakeWebAXElement(values: [Self.manual: true, Self.enhanced: true])
        WebContentAccessibility.reset(element, attributes: [Self.enhanced])
        XCTAssertEqual(element.sets.count, 1)
        XCTAssertEqual(element.sets.first?.attribute, Self.enhanced)
        XCTAssertEqual(element.sets.first?.value, false)
        XCTAssertEqual(element.values[Self.manual], true, "a non-flipped attribute is left untouched")
    }

    func testResetWithNoFlippedAttributesIsANoOp() {
        let element = FakeWebAXElement()
        WebContentAccessibility.reset(element, attributes: [])
        XCTAssertTrue(element.sets.isEmpty)
    }
}
