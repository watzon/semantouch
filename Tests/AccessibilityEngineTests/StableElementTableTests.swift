import XCTest
import ComputerUseCore
@testable import AccessibilityEngine

/// Identity / reuse / stale coverage for `StableElementTable` (§11). Uses fake
/// handles — no Accessibility permission required.
final class StableElementTableTests: XCTestCase {

    /// A test double for `ElementHandle` whose liveness is toggleable.
    private final class FakeHandle: ElementHandle {
        var live: Bool
        init(live: Bool = true) { self.live = live }
        var isLive: Bool { live }
    }

    private func fingerprint(
        role: String = "AXButton",
        subrole: String? = nil,
        axIdentifier: String? = nil,
        parentHash: Int = ElementFingerprint.rootParentHash,
        ordinal: Int = 0,
        title: String? = nil
    ) -> ElementFingerprint {
        ElementFingerprint(
            role: role, subrole: subrole, axIdentifier: axIdentifier,
            parentHash: parentHash, siblingOrdinal: ordinal,
            normalizedTitle: ElementFingerprint.normalizeTitle(title)
        )
    }

    // MARK: - Minting

    func testAssignsMonotonicIdsFromOne() {
        let table = StableElementTable()
        table.beginPass()
        let a = table.assign(handle: FakeHandle(), fingerprint: fingerprint(title: "A"))
        let b = table.assign(handle: FakeHandle(), fingerprint: fingerprint(title: "B"))
        let c = table.assign(handle: FakeHandle(), fingerprint: fingerprint(title: "C"))
        table.endPass()
        XCTAssertEqual([a, b, c], [1, 2, 3])
        XCTAssertEqual(StableElementTable.idString(a), "e1")
    }

    // MARK: - Reuse

    func testReusesIdsWhenFingerprintMatchesAndHandleLive() {
        let table = StableElementTable()
        let hA = FakeHandle(); let hB = FakeHandle()
        let fpA = fingerprint(title: "A"); let fpB = fingerprint(title: "B")

        table.beginPass()
        let a1 = table.assign(handle: hA, fingerprint: fpA)
        let b1 = table.assign(handle: hB, fingerprint: fpB)
        table.endPass()

        // Rebuild with fresh (still live) handles and identical fingerprints.
        table.beginPass()
        let a2 = table.assign(handle: FakeHandle(), fingerprint: fpA)
        let b2 = table.assign(handle: FakeHandle(), fingerprint: fpB)
        table.endPass()

        XCTAssertEqual(a1, a2)
        XCTAssertEqual(b1, b2)
    }

    func testChangedFingerprintGetsNewIdAndRetiresOld() {
        let table = StableElementTable()
        table.beginPass()
        let a1 = table.assign(handle: FakeHandle(), fingerprint: fingerprint(title: "Save"))
        table.endPass()

        table.beginPass()
        // Title changed → different fingerprint → new id; old id retired.
        let a2 = table.assign(handle: FakeHandle(), fingerprint: fingerprint(title: "Saved"))
        table.endPass()

        XCTAssertNotEqual(a1, a2)
        XCTAssertFalse(table.contains(numericId: a1), "old id retired")
        XCTAssertTrue(table.contains(numericId: a2))
    }

    func testDeadPriorHandleBlocksReuse() {
        let table = StableElementTable()
        let hA = FakeHandle()
        let fpA = fingerprint(title: "A")

        table.beginPass()
        let a1 = table.assign(handle: hA, fingerprint: fpA)
        table.endPass()

        // The prior element was destroyed; a new element shares the fingerprint.
        hA.live = false
        table.beginPass()
        let a2 = table.assign(handle: FakeHandle(), fingerprint: fpA)
        table.endPass()

        XCTAssertNotEqual(a1, a2, "a dead prior handle must not reuse its id")
    }

    func testDuplicateFingerprintsInOnePassGetDistinctIds() {
        let table = StableElementTable()
        table.beginPass()
        let fp = fingerprint(title: "same")
        let x = table.assign(handle: FakeHandle(), fingerprint: fp)
        let y = table.assign(handle: FakeHandle(), fingerprint: fp)
        table.endPass()
        XCTAssertNotEqual(x, y)
    }

    // MARK: - Retirement / never-reused

    func testRemovedElementIdIsRetiredAndNeverReused() {
        let table = StableElementTable()
        let hA = FakeHandle()
        let fpA = fingerprint(title: "A"); let fpB = fingerprint(title: "B")

        table.beginPass()
        let a = table.assign(handle: hA, fingerprint: fpA) // 1
        let b = table.assign(handle: FakeHandle(), fingerprint: fpB) // 2
        table.endPass()
        XCTAssertEqual([a, b], [1, 2])

        // Rebuild without fpB: its id retires.
        table.beginPass()
        _ = table.assign(handle: hA, fingerprint: fpA) // reuse 1
        table.endPass()
        XCTAssertFalse(table.contains(numericId: b))

        // A brand-new element must get a fresh counter value, never the retired 2.
        table.beginPass()
        _ = table.assign(handle: hA, fingerprint: fpA) // reuse 1
        let c = table.assign(handle: FakeHandle(), fingerprint: fingerprint(title: "C"))
        table.endPass()
        XCTAssertEqual(c, 3, "counter never rewinds onto a retired id")
    }

    // MARK: - reset() (forceFullTree = "rebuild ids too", §15.1)

    /// `reset()` retires the whole live id space so the next pass re-mints fresh ids for
    /// every element (distinct from `disableDiff`, which keeps ids stable), while the
    /// monotonic counter never rewinds (§3): a matched fingerprint gets a NEW id and the
    /// prior id is gone.
    func testResetReminsAllIdsAndPreservesMonotonicCounter() {
        let table = StableElementTable(reuseAcrossPasses: true)
        let fpA = fingerprint(title: "A"); let fpB = fingerprint(title: "B")

        table.beginPass()
        let a1 = table.assign(handle: FakeHandle(), fingerprint: fpA)
        let b1 = table.assign(handle: FakeHandle(), fingerprint: fpB)
        table.endPass()
        XCTAssertEqual([a1, b1], [1, 2])

        table.reset()
        XCTAssertFalse(table.contains(numericId: a1), "reset retires all prior ids")
        XCTAssertFalse(table.contains(numericId: b1))

        // Same fingerprints reappear but must NOT reuse the retired ids: fresh, monotonic.
        table.beginPass()
        let a2 = table.assign(handle: FakeHandle(), fingerprint: fpA)
        let b2 = table.assign(handle: FakeHandle(), fingerprint: fpB)
        table.endPass()
        XCTAssertEqual([a2, b2], [3, 4], "counter never rewinds; every element is re-minted fresh")
    }

    /// A retired id from `reset()` never resolves — the id space really is rebuilt.
    func testResetRetiredIdsNoLongerResolve() {
        let table = StableElementTable(reuseAcrossPasses: true)
        table.beginPass()
        let a = table.assign(handle: FakeHandle(), fingerprint: fingerprint(title: "A"))
        table.endPass()
        table.reset()
        assertStaleElement(sessionId: "s1", elementId: StableElementTable.idString(a), revision: 1) {
            try table.resolve(StableElementTable.idString(a), sessionId: "s1", revision: 1)
        }
    }

    // MARK: - Cancellation checkpoint / rollback (§17.2)

    /// A build pass cancelled *after* it ran is rolled back to the pre-build id space: a retired
    /// id resolves again (the client still holds it), an id minted during the abandoned pass is
    /// gone, and the monotonic counter is NOT rewound (§3) so no retired id is ever reused.
    func testRollbackRestoresPreBuildIdSpaceWithoutRewindingCounter() throws {
        let table = StableElementTable(reuseAcrossPasses: true)
        let hA = FakeHandle(); let hB = FakeHandle()
        let fpA = fingerprint(title: "A"); let fpB = fingerprint(title: "B")

        // Committed snapshot N: e1 (A, live), e2 (B, live).
        table.beginPass()
        let a = table.assign(handle: hA, fingerprint: fpA) // 1
        let b = table.assign(handle: hB, fingerprint: fpB) // 2
        table.endPass()
        XCTAssertEqual([a, b], [1, 2])

        // Checkpoint the committed id space, then run a build that retires e2 (B gone) and mints a
        // new element C — exactly what a snapshot-N+1 build does before a cancel is caught.
        let checkpoint = table.checkpoint()
        table.beginPass()
        _ = table.assign(handle: hA, fingerprint: fpA)                                    // reuse e1
        let c = table.assign(handle: FakeHandle(), fingerprint: fingerprint(title: "C"))  // 3
        table.endPass()
        XCTAssertFalse(table.contains(numericId: b), "B retired by the soon-abandoned pass")
        XCTAssertTrue(table.contains(numericId: c))

        // Cancel caught after the build → roll back.
        table.rollback(to: checkpoint)

        // The pre-build id space is restored: e1 and e2 both resolve; e3 is gone.
        XCTAssertTrue(table.contains(numericId: a))
        XCTAssertTrue(table.contains(numericId: b), "the retired id is restored — the client still holds it")
        XCTAssertFalse(table.contains(numericId: c), "an id minted during the abandoned pass is discarded")
        XCTAssertTrue(try table.resolve("e2", sessionId: "s1", revision: 1) === hB, "e2 resolves to its original handle")

        // The counter never rewinds: a genuinely new element after the rollback gets a value ABOVE
        // the abandoned pass's mint (never the restored e2 or the discarded e3).
        table.beginPass()
        _ = table.assign(handle: hA, fingerprint: fpA) // reuse e1
        _ = table.assign(handle: hB, fingerprint: fpB) // reuse restored e2
        let d = table.assign(handle: FakeHandle(), fingerprint: fingerprint(title: "D"))
        table.endPass()
        XCTAssertEqual(d, 4, "counter never rewinds onto e2/e3; the abandoned mint stays retired")
    }

    /// Rollback also undoes a `reset()` (forceFullTree = "rebuild ids too"): the whole retired id
    /// space is restored so a cancelled forceFullTree snapshot leaves the ids the client holds intact.
    func testRollbackUndoesForceFullTreeReset() throws {
        let table = StableElementTable(reuseAcrossPasses: true)
        let hA = FakeHandle()
        let fpA = fingerprint(title: "A")

        table.beginPass()
        let a = table.assign(handle: hA, fingerprint: fpA) // 1
        table.endPass()

        let checkpoint = table.checkpoint()
        table.reset() // forceFullTree retires the whole id space before the build
        table.beginPass()
        let a2 = table.assign(handle: FakeHandle(), fingerprint: fpA) // fresh id (2); e1 retired
        table.endPass()
        XCTAssertNotEqual(a, a2)
        XCTAssertFalse(table.contains(numericId: a))

        table.rollback(to: checkpoint) // cancel caught → undo the reset + build

        XCTAssertTrue(table.contains(numericId: a), "reset is rolled back; the original id resolves again")
        XCTAssertFalse(table.contains(numericId: a2), "the fresh mint is discarded")
        XCTAssertTrue(try table.resolve("e1", sessionId: "s1", revision: 1) === hA)
    }

    // MARK: - Fingerprint-reuse matrix

    /// Matched unchanged element → same id across many rebuilds (id stability, §15.2).
    func testMatchedElementKeepsIdAcrossManyPasses() {
        let table = StableElementTable(reuseAcrossPasses: true)
        let fp = fingerprint(role: "AXTextField", axIdentifier: "field.text", title: nil)
        let handle = FakeHandle()

        table.beginPass()
        let first = table.assign(handle: handle, fingerprint: fp)
        table.endPass()

        // Ten more rebuilds with the same live fingerprint keep the id pinned.
        for _ in 0..<10 {
            table.beginPass()
            let again = table.assign(handle: FakeHandle(), fingerprint: fp)
            table.endPass()
            XCTAssertEqual(again, first, "an unchanged element keeps its id across rebuilds")
        }
    }

    /// Replaced element at the *same structural position* (same role/subrole/parent/
    /// ordinal, different title) → NEW id; the old id is retired and never resurfaces.
    func testReplacedElementAtSamePositionGetsNewId() {
        let table = StableElementTable(reuseAcrossPasses: true)
        let handle = FakeHandle()

        table.beginPass()
        let saveId = table.assign(
            handle: handle,
            fingerprint: fingerprint(role: "AXButton", parentHash: 99, ordinal: 0, title: "Save")
        )
        table.endPass()

        // Same slot (role/parent/ordinal) but a different label → different fingerprint.
        table.beginPass()
        let deleteId = table.assign(
            handle: FakeHandle(),
            fingerprint: fingerprint(role: "AXButton", parentHash: 99, ordinal: 0, title: "Delete")
        )
        table.endPass()

        XCTAssertNotEqual(saveId, deleteId, "a replaced element at the same position must not inherit the id")
        XCTAssertFalse(table.contains(numericId: saveId), "the replaced element's id is retired")

        // And the retired id is never handed back to a later brand-new element.
        table.beginPass()
        let third = table.assign(handle: FakeHandle(), fingerprint: fingerprint(title: "Third"))
        table.endPass()
        XCTAssertNotEqual(third, saveId)
    }

    /// The live-element check gates reuse: a destroyed element at the same position with
    /// an *identical* fingerprint still yields a new id (the dead prior handle blocks it).
    func testDestroyedThenRecreatedIdenticalElementGetsNewId() {
        let table = StableElementTable(reuseAcrossPasses: true)
        let original = FakeHandle()
        let fp = fingerprint(role: "AXRow", parentHash: 7, ordinal: 3, title: "Row 4")

        table.beginPass()
        let firstId = table.assign(handle: original, fingerprint: fp)
        table.endPass()

        original.live = false // the row was destroyed and recreated with the same text
        table.beginPass()
        let secondId = table.assign(handle: FakeHandle(), fingerprint: fp)
        table.endPass()

        XCTAssertNotEqual(firstId, secondId, "a dead prior handle blocks reuse even on an identical fingerprint")
        XCTAssertFalse(table.contains(numericId: firstId))
    }

    // MARK: - Resolution + stale

    func testResolveReturnsHandleForLiveId() throws {
        let table = StableElementTable()
        let hA = FakeHandle()
        table.beginPass()
        let a = table.assign(handle: hA, fingerprint: fingerprint(title: "A"))
        table.endPass()

        let resolved = try table.resolve(StableElementTable.idString(a), sessionId: "s1", revision: 1)
        XCTAssertTrue(resolved === hA)
    }

    func testResolveThrowsStaleForRetiredId() {
        let table = StableElementTable()
        let hA = FakeHandle()
        table.beginPass()
        _ = table.assign(handle: hA, fingerprint: fingerprint(title: "A")) // e1
        _ = table.assign(handle: FakeHandle(), fingerprint: fingerprint(title: "B")) // e2
        table.endPass()

        table.beginPass()
        _ = table.assign(handle: hA, fingerprint: fingerprint(title: "A")) // reuse e1, drop e2
        table.endPass()

        assertStaleElement(sessionId: "s1", elementId: "e2", revision: 1) {
            try table.resolve("e2", sessionId: "s1", revision: 1)
        }
    }

    func testResolveThrowsStaleForDeadHandle() {
        let table = StableElementTable()
        let hA = FakeHandle()
        table.beginPass()
        _ = table.assign(handle: hA, fingerprint: fingerprint(title: "A"))
        table.endPass()

        hA.live = false
        assertStaleElement(sessionId: "s9", elementId: "e1", revision: 7) {
            try table.resolve("e1", sessionId: "s9", revision: 7)
        }
    }

    func testResolveThrowsStaleForUnknownOrMalformedIds() {
        let table = StableElementTable()
        table.beginPass()
        _ = table.assign(handle: FakeHandle(), fingerprint: fingerprint(title: "A"))
        table.endPass()

        for bad in ["e999", "bogus", "e", "42", "e1x", ""] {
            assertStaleElement(sessionId: "s1", elementId: bad, revision: 1) {
                try table.resolve(bad, sessionId: "s1", revision: 1)
            }
        }
    }

    // MARK: - Fingerprint normalization

    func testNormalizeTitle() {
        XCTAssertEqual(ElementFingerprint.normalizeTitle("  Hello   World  "), "hello world")
        XCTAssertEqual(ElementFingerprint.normalizeTitle(nil), "")
        XCTAssertEqual(ElementFingerprint.normalizeTitle("\t\n  "), "")
        XCTAssertEqual(ElementFingerprint.normalizeTitle("MixED"), "mixed")
    }

    func testParentHashDisambiguatesLikeRoleSubtrees() {
        // Same role/subrole/ordinal/title, different parent → different fingerprint.
        let underA = fingerprint(parentHash: 111, ordinal: 0, title: "Row")
        let underB = fingerprint(parentHash: 222, ordinal: 0, title: "Row")
        XCTAssertNotEqual(underA, underB)

        let table = StableElementTable()
        table.beginPass()
        let a = table.assign(handle: FakeHandle(), fingerprint: underA)
        let b = table.assign(handle: FakeHandle(), fingerprint: underB)
        table.endPass()
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Helpers

    private func assertStaleElement(
        sessionId: String,
        elementId: String,
        revision: Int,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Any
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case let CUError.staleElement(sid, eid, rev) = error else {
                return XCTFail("expected staleElement, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(sid, sessionId, file: file, line: line)
            XCTAssertEqual(eid, elementId, file: file, line: line)
            XCTAssertEqual(rev, revision, file: file, line: line)
        }
    }
}
