import XCTest
import ComputerUseCore
@testable import AccessibilityEngine

/// Placeholder suite. Real fixture-driven tests (tree fidelity, pruning,
/// deterministic rendering, stable element ids) land with the engine in Stage B.
final class AccessibilityEngineTests: XCTestCase {
    func testTreeFormatMatchesProtocol() {
        XCTAssertEqual(AccessibilityEngine.treeFormat, "semantouch-ax-tree-v1")
    }

    func testNodeCapsMatchProtocol() {
        // §7.5: default 600, hard ceiling 2000.
        XCTAssertEqual(AccessibilityEngine.defaultMaxNodes, 600)
        XCTAssertEqual(AccessibilityEngine.hardMaxNodes, 2000)
        XCTAssertLessThanOrEqual(AccessibilityEngine.defaultMaxNodes, AccessibilityEngine.hardMaxNodes)
    }

    // MARK: - Node budget (§18.2)

    func testNodeBudgetDefaultsWhenUnspecified() {
        XCTAssertEqual(AccessibilityEngine.nodeBudget(requested: nil), 600)
    }

    func testNodeBudgetPassesThroughInRange() {
        XCTAssertEqual(AccessibilityEngine.nodeBudget(requested: 1), 1)
        XCTAssertEqual(AccessibilityEngine.nodeBudget(requested: 42), 42)
        XCTAssertEqual(AccessibilityEngine.nodeBudget(requested: 2000), 2000)
    }

    func testNodeBudgetClampsToFrozenCeilingAndFloor() {
        // The §7.5 hard ceiling (2000) no configuration may exceed, and a positive floor.
        XCTAssertEqual(AccessibilityEngine.nodeBudget(requested: 5000), 2000)
        XCTAssertEqual(AccessibilityEngine.nodeBudget(requested: 0), 1)
        XCTAssertEqual(AccessibilityEngine.nodeBudget(requested: -10), 1)
    }
}
