import XCTest
import ComputerUseCore
@testable import AccessibilityEngine

/// Diff reconstruction equivalence + wire-grammar goldens for `AXTreeDiff`
/// (docs/PROTOCOL.md §15). Pure: hand-built `UINode` snapshots, no Accessibility.
final class AXTreeDiffTests: XCTestCase {

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
        Rect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Reconstruction equivalence (the correctness proof)

    /// `apply(compute(prev, next), prev)` reconstructs `next` exactly — structurally
    /// (value equality) and by re-rendered text (§15).
    private func assertRoundtrip(
        _ prev: UINode, _ next: UINode,
        base: Int = 1, revision: Int = 2,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let diff = AXTreeDiff.compute(previous: prev, current: next, baseRevision: base, revision: revision)
        let reconstructed = AXTreeDiff.apply(diff, to: prev)
        XCTAssertEqual(reconstructed, next, "structural reconstruction", file: file, line: line)
        XCTAssertEqual(
            AXTreeRenderer.render(reconstructed).text,
            AXTreeRenderer.render(next).text,
            "re-rendered text reconstruction",
            file: file, line: line
        )
    }

    func testReconstructIdenticalTreesYieldsEmptyDiff() {
        let tree = UINode(id: 1, role: "AXWindow", title: "App", frame: rect(0, 0, 400, 300), children: [
            UINode(id: 2, role: "AXButton", title: "Run", frame: rect(10, 10, 80, 30), actions: ["AXPress"]),
        ])
        let diff = AXTreeDiff.compute(previous: tree, current: tree, baseRevision: 1, revision: 2)
        XCTAssertTrue(diff.isEmpty)
        assertRoundtrip(tree, tree)
    }

    func testReconstructAttributeChangeOnly() {
        let prev = UINode(id: 1, role: "AXWindow", title: "App", frame: rect(0, 0, 400, 300), children: [
            UINode(id: 2, role: "AXButton", title: "Run", enabled: false, frame: rect(10, 10, 80, 30), actions: ["AXPress"]),
            UINode(id: 3, role: "AXStaticText", value: "Idle", frame: rect(10, 50, 200, 20)),
        ])
        let next = UINode(id: 1, role: "AXWindow", title: "App", frame: rect(0, 0, 400, 300), children: [
            UINode(id: 2, role: "AXButton", title: "Run", enabled: true, frame: rect(10, 10, 80, 30), actions: ["AXPress"]),
            UINode(id: 3, role: "AXStaticText", value: "Building", frame: rect(10, 50, 200, 20)),
        ])
        assertRoundtrip(prev, next)
    }

    func testReconstructAppendChild() {
        let prev = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXStaticText", value: "Row 1", frame: rect(0, 0, 100, 20)),
        ])
        let next = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXStaticText", value: "Row 1", frame: rect(0, 0, 100, 20)),
            UINode(id: 5, role: "AXStaticText", value: "Row 2", frame: rect(0, 20, 100, 20)),
        ])
        assertRoundtrip(prev, next)
    }

    func testReconstructRemoveChild() {
        let prev = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXStaticText", value: "A", frame: rect(0, 0, 100, 20)),
            UINode(id: 3, role: "AXStaticText", value: "B", frame: rect(0, 20, 100, 20)),
        ])
        let next = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXStaticText", value: "A", frame: rect(0, 0, 100, 20)),
        ])
        assertRoundtrip(prev, next)
    }

    func testReconstructMiddleInsertShiftsSiblings() {
        // Inserting in the middle shifts the following sibling's index — it becomes a
        // remove+add of the same id. Reconstruction must still be exact.
        let prev = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXButton", title: "A", frame: rect(0, 0, 40, 20), actions: ["AXPress"]),
            UINode(id: 3, role: "AXButton", title: "C", frame: rect(0, 40, 40, 20), actions: ["AXPress"]),
        ])
        let next = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXButton", title: "A", frame: rect(0, 0, 40, 20), actions: ["AXPress"]),
            UINode(id: 7, role: "AXButton", title: "B", frame: rect(0, 20, 40, 20), actions: ["AXPress"]),
            UINode(id: 3, role: "AXButton", title: "C", frame: rect(0, 40, 40, 20), actions: ["AXPress"]),
        ])
        assertRoundtrip(prev, next)
    }

    func testReconstructReparentMove() {
        // e5 moves from under e2 to under e3 (same id → represented as remove+add).
        let prev = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 200, 200), children: [
            UINode(id: 2, role: "AXGroup", frame: rect(0, 0, 100, 200), children: [
                UINode(id: 5, role: "AXStaticText", value: "X", frame: rect(0, 0, 40, 20)),
            ]),
            UINode(id: 3, role: "AXGroup", frame: rect(100, 0, 100, 200)),
        ])
        let next = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 200, 200), children: [
            UINode(id: 2, role: "AXGroup", frame: rect(0, 0, 100, 200)),
            UINode(id: 3, role: "AXGroup", frame: rect(100, 0, 100, 200), children: [
                UINode(id: 5, role: "AXStaticText", value: "X", frame: rect(0, 0, 40, 20)),
            ]),
        ])
        assertRoundtrip(prev, next)
    }

    func testReconstructNestedSubtreeAddAndRemove() {
        let prev = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 300, 300), children: [
            UINode(id: 2, role: "AXGroup", frame: rect(0, 0, 300, 150), children: [
                UINode(id: 3, role: "AXStaticText", value: "old", frame: rect(0, 0, 100, 20)),
            ]),
        ])
        let next = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 300, 300), children: [
            UINode(id: 4, role: "AXGroup", frame: rect(0, 150, 300, 150), children: [
                UINode(id: 5, role: "AXStaticText", value: "new-a", frame: rect(0, 0, 100, 20)),
                UINode(id: 6, role: "AXButton", title: "Go", frame: rect(0, 20, 100, 20), actions: ["AXPress"]),
            ]),
        ])
        assertRoundtrip(prev, next)
    }

    func testReconstructMixedBurst() {
        // Simultaneous add + change + remove + focus/selection flips.
        let prev = UINode(id: 1, role: "AXWindow", title: "W", frame: rect(0, 0, 400, 400), children: [
            UINode(id: 2, role: "AXTextField", value: "hello", focused: true, frame: rect(0, 0, 200, 24), actions: ["AXConfirmText"]),
            UINode(id: 3, role: "AXCheckBox", title: "On", value: "0", frame: rect(0, 30, 100, 20), actions: ["AXPress"]),
            UINode(id: 4, role: "AXStaticText", value: "to-remove", frame: rect(0, 60, 200, 20)),
        ])
        let next = UINode(id: 1, role: "AXWindow", title: "W", frame: rect(0, 0, 400, 400), children: [
            UINode(id: 2, role: "AXTextField", value: "hello world", focused: false, frame: rect(0, 0, 200, 24), actions: ["AXConfirmText"]),
            UINode(id: 3, role: "AXCheckBox", title: "On", value: "1", selected: true, frame: rect(0, 30, 100, 20), actions: ["AXPress"]),
            UINode(id: 8, role: "AXStaticText", value: "added", frame: rect(0, 60, 200, 20)),
        ])
        assertRoundtrip(prev, next)
    }

    func testReconstructValueDisappears() {
        // value present → absent (nil); focus gained. Exercises the "attribute went
        // absent" delta path.
        let prev = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXTextField", value: "draft", frame: rect(0, 0, 100, 20)),
        ])
        let next = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXTextField", focused: true, frame: rect(0, 0, 100, 20)),
        ])
        assertRoundtrip(prev, next)
    }

    // MARK: - Wire grammar goldens (§15)

    func testGoldenChangedAddedGrammar() {
        let prev = UINode(id: 1, role: "AXWindow", title: "App", frame: rect(0, 0, 400, 300), children: [
            UINode(id: 2, role: "AXButton", title: "Run", enabled: false, frame: rect(10, 10, 80, 30), actions: ["AXPress"]),
            UINode(id: 3, role: "AXStaticText", value: "Idle", frame: rect(10, 50, 200, 20)),
        ])
        let next = UINode(id: 1, role: "AXWindow", title: "App", frame: rect(0, 0, 400, 300), children: [
            UINode(id: 2, role: "AXButton", title: "Run", enabled: true, frame: rect(10, 10, 80, 30), actions: ["AXPress"]),
            UINode(id: 3, role: "AXStaticText", value: "Building", frame: rect(10, 50, 200, 20)),
            UINode(id: 4, role: "AXStaticText", value: "Done", frame: rect(10, 80, 200, 20)),
        ])
        let diff = AXTreeDiff.compute(previous: prev, current: next, baseRevision: 1, revision: 2)
        let expected = """
        UI revision 2, based on 1
        ~ [e2] AXButton "Run" enabled=false → enabled=true
        ~ [e3] AXStaticText value="Idle" → value="Building"
        + [e4] AXStaticText value="Done" frame=10,80,200,20 @e1:2
        """
        XCTAssertEqual(AXTreeDiff.render(diff), expected)
    }

    func testGoldenRemovedLineRangeCollapsing() {
        // A parent with a contiguous run of rows plus scattered ids, all removed.
        var children: [UINode] = []
        for id in [3, 51, 52, 53, 54, 55] {
            children.append(UINode(id: id, role: "AXStaticText", value: "r\(id)", frame: rect(0, 0, 10, 10)))
        }
        let prev = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: children)
        let next = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100))
        let diff = AXTreeDiff.compute(previous: prev, current: next, baseRevision: 4, revision: 5)
        let expected = """
        UI revision 5, based on 4
        - [e3,e51..e55]
        """
        XCTAssertEqual(AXTreeDiff.render(diff), expected)
    }

    func testGoldenAddedPlacementParentAndOrdinal() {
        // A node added as the second child (index 1) of e2 — placement is unambiguous.
        let prev = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXGroup", frame: rect(0, 0, 100, 100), children: [
                UINode(id: 3, role: "AXStaticText", value: "first", frame: rect(0, 0, 100, 20)),
            ]),
        ])
        let next = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXGroup", frame: rect(0, 0, 100, 100), children: [
                UINode(id: 3, role: "AXStaticText", value: "first", frame: rect(0, 0, 100, 20)),
                UINode(id: 9, role: "AXButton", title: "Second", frame: rect(0, 20, 100, 20), actions: ["AXPress"]),
            ]),
        ])
        let diff = AXTreeDiff.compute(previous: prev, current: next, baseRevision: 1, revision: 2)
        let expected = """
        UI revision 2, based on 1
        + [e9] AXButton "Second" frame=0,20,100,20 actions=[Press] @e2:1
        """
        XCTAssertEqual(AXTreeDiff.render(diff), expected)
    }

    func testCollapseRemovedRuns() {
        XCTAssertEqual(AXTreeDiff.collapseRemoved([3, 51, 52, 53, 54, 55]), "e3,e51..e55")
        XCTAssertEqual(AXTreeDiff.collapseRemoved([5, 6]), "e5,e6")           // run of 2 not collapsed
        XCTAssertEqual(AXTreeDiff.collapseRemoved([5, 6, 7]), "e5..e7")        // run of 3 collapsed
        XCTAssertEqual(AXTreeDiff.collapseRemoved([1, 2, 4, 5, 6, 9]), "e1,e2,e4..e6,e9")
        XCTAssertEqual(AXTreeDiff.collapseRemoved([42]), "e42")
        XCTAssertEqual(AXTreeDiff.collapseRemoved([]), "")
    }

    func testEmptyDiffRendersHeaderOnly() {
        let tree = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 10, 10))
        let diff = AXTreeDiff.compute(previous: tree, current: tree, baseRevision: 7, revision: 8)
        XCTAssertEqual(AXTreeDiff.render(diff), "UI revision 8, based on 7")
    }

    func testChangedEntryShowsBothSidesForToggle() {
        // A focus/selection toggle shows the actual boolean on each side,
        // even though the full-tree grammar omits `focused=false`.
        let prev = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXTextField", value: "x", frame: rect(0, 0, 100, 20)),
        ])
        let next = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXTextField", value: "x", focused: true, frame: rect(0, 0, 100, 20)),
        ])
        let diff = AXTreeDiff.compute(previous: prev, current: next, baseRevision: 1, revision: 2)
        XCTAssertEqual(AXTreeDiff.render(diff), """
        UI revision 2, based on 1
        ~ [e2] AXTextField focused=false → focused=true
        """)
    }

    // MARK: - Fingerprint/id semantics reflected in the diff

    // MARK: - Reused-id / wire-disjointness conflict (§15.2/§15.3)

    /// A still-live id whose ABSOLUTE child index shifts (a different-role sibling appears
    /// above a kept element) keeps its id under the §15.2 fingerprint but flips the diff's
    /// placement — landing the SAME id in both `removed` and `added`. That is wire-invalid
    /// (§15.3: `-` ids are retired), so `compute` flags `reusedIdConflict` and the caller
    /// falls back to a full tree. Reconstruction stays exact regardless.
    func testReusedIdConflictOnIndexShiftFromOtherRoleSibling() {
        // e5 (a kept button) sits at child index 0; a status label appears above it,
        // shifting it to index 1 while its like-role ordinal (0 among buttons) is unchanged.
        let prev = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 200, 200), children: [
            UINode(id: 5, role: "AXButton", title: "Sign In", frame: rect(0, 20, 80, 24), actions: ["AXPress"]),
        ])
        let next = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 200, 200), children: [
            UINode(id: 9, role: "AXStaticText", value: "Invalid password", frame: rect(0, 0, 160, 18)),
            UINode(id: 5, role: "AXButton", title: "Sign In", frame: rect(0, 20, 80, 24), actions: ["AXPress"]),
        ])
        let diff = AXTreeDiff.compute(previous: prev, current: next, baseRevision: 1, revision: 2)
        XCTAssertTrue(diff.reusedIdConflict, "a reused id whose child index shifted must flag a conflict")
        // The hazard the flag guards: e5 is in BOTH sides — never render this to the wire.
        XCTAssertTrue(diff.removed.contains(5))
        XCTAssertTrue(diff.added.contains { $0.node.id == 5 })
        // apply() is still exact even for a conflict diff (only the wire render is unsafe).
        assertRoundtrip(prev, next)
    }

    /// A case/whitespace-only title change survives the normalized-title fingerprint (id
    /// reused) but flips the diff's raw-title identity, again putting the same id in both
    /// sides. Must flag a conflict.
    func testReusedIdConflictOnRawTitleOnlyChange() {
        let prev = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXButton", title: "Save", frame: rect(0, 0, 80, 20), actions: ["AXPress"]),
        ])
        let next = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXButton", title: "save", frame: rect(0, 0, 80, 20), actions: ["AXPress"]),
        ])
        let diff = AXTreeDiff.compute(previous: prev, current: next, baseRevision: 1, revision: 2)
        XCTAssertTrue(diff.reusedIdConflict)
        XCTAssertTrue(diff.removed.contains(2) && diff.added.contains { $0.node.id == 2 })
    }

    /// Ordinary add / change / remove (no reused id in both sides) must NOT flag a
    /// conflict, so the diff is rendered normally.
    func testNoReusedIdConflictForOrdinaryChanges() {
        let prev = UINode(id: 1, role: "AXWindow", title: "App", frame: rect(0, 0, 400, 300), children: [
            UINode(id: 2, role: "AXButton", title: "Run", enabled: false, frame: rect(10, 10, 80, 30), actions: ["AXPress"]),
            UINode(id: 3, role: "AXStaticText", value: "Idle", frame: rect(10, 50, 200, 20)),
        ])
        let next = UINode(id: 1, role: "AXWindow", title: "App", frame: rect(0, 0, 400, 300), children: [
            UINode(id: 2, role: "AXButton", title: "Run", enabled: true, frame: rect(10, 10, 80, 30), actions: ["AXPress"]),
            UINode(id: 4, role: "AXStaticText", value: "Done", frame: rect(10, 50, 200, 20)),
        ])
        let diff = AXTreeDiff.compute(previous: prev, current: next, baseRevision: 1, revision: 2)
        XCTAssertFalse(diff.reusedIdConflict)
    }

    // MARK: - Changed-entry present-only token elision (§7.2 / §15.3)

    /// A present-only attribute that went absent/empty emits NO token on that side (not
    /// `value=""`/`actions=[]`, which §7.2 never emits): the side is elided per §15.3.
    func testChangedEntryElidesAbsentPresentOnlyTokens() {
        // value present -> absent: new side elided, bare arrow.
        let clearPrev = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXTextField", value: "draft", frame: rect(0, 0, 100, 20)),
        ])
        let clearNext = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXTextField", frame: rect(0, 0, 100, 20)),
        ])
        XCTAssertEqual(
            AXTreeDiff.render(AXTreeDiff.compute(previous: clearPrev, current: clearNext, baseRevision: 1, revision: 2)),
            """
            UI revision 2, based on 1
            ~ [e2] AXTextField value="draft" →
            """
        )

        // value absent -> present: old side elided.
        XCTAssertEqual(
            AXTreeDiff.render(AXTreeDiff.compute(previous: clearNext, current: clearPrev, baseRevision: 2, revision: 3)),
            """
            UI revision 3, based on 2
            ~ [e2] AXTextField → value="draft"
            """
        )

        // actions present -> empty: new side elided (no `actions=[]`).
        let actPrev = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXButton", title: "Go", frame: rect(0, 0, 80, 20), actions: ["AXPress"]),
        ])
        let actNext = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXButton", title: "Go", frame: rect(0, 0, 80, 20)),
        ])
        XCTAssertEqual(
            AXTreeDiff.render(AXTreeDiff.compute(previous: actPrev, current: actNext, baseRevision: 5, revision: 6)),
            """
            UI revision 6, based on 5
            ~ [e2] AXButton "Go" actions=[Press] →
            """
        )
    }

    func testRetiredIdBecomesRemovedNewElementBecomesAdded() {
        // Mirrors StableElementTable behavior: a replaced element gets a NEW id, so the
        // old id shows as removed and the new id as added (never a `changed` delta).
        let prev = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 2, role: "AXButton", title: "Save", frame: rect(0, 0, 80, 20), actions: ["AXPress"]),
        ])
        let next = UINode(id: 1, role: "AXWindow", frame: rect(0, 0, 100, 100), children: [
            UINode(id: 3, role: "AXButton", title: "Delete", frame: rect(0, 0, 80, 20), actions: ["AXPress"]),
        ])
        let diff = AXTreeDiff.compute(previous: prev, current: next, baseRevision: 1, revision: 2)
        XCTAssertEqual(diff.removed, [2])
        XCTAssertEqual(diff.added.map(\.node.id), [3])
        XCTAssertTrue(diff.changed.isEmpty, "a replaced element is remove+add, never a changed delta")
        assertRoundtrip(prev, next)
    }
}
