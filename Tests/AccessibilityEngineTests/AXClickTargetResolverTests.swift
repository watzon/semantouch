import XCTest
import ComputerUseCore
@testable import AccessibilityEngine

/// Permission-free coverage for the pure AX coordinate→semantic click resolver.
///
/// All selection logic is exercised over value `Candidate`s (and a fake `LiveElement`
/// graph for collection bounds). No Accessibility permission, no real AXUIElement,
/// no input synthesis.
final class AXClickTargetResolverTests: XCTestCase {

    private typealias R = AXClickTargetResolver
    private typealias Candidate = AXClickTargetResolver.Candidate
    private typealias Limits = AXClickTargetResolver.Limits

    private let window = Rect(x: 100, y: 100, width: 400, height: 600)
    private let pid: pid_t = 4242

    // MARK: - Helpers

    private func point(_ x: Double, _ y: Double) -> Point { Point(x: x, y: y) }

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
        Rect(x: x, y: y, width: w, height: h)
    }

    private func resolve(
        at x: Double,
        _ y: Double,
        hitId: String?,
        candidates: [Candidate],
        limits: Limits = .default,
        expectedPID: pid_t? = 4242,
        windowBounds: Rect? = nil,
        giantContainerStopped: Bool = false,
        candidateLimitReached: Bool = false,
        depthLimitReached: Bool = false
    ) -> R.Resolution {
        R.resolve(
            point: point(x, y),
            windowBounds: windowBounds ?? window,
            expectedPID: expectedPID,
            hitId: hitId,
            candidates: candidates,
            limits: limits,
            giantContainerStopped: giantContainerStopped,
            candidateLimitReached: candidateLimitReached,
            depthLimitReached: depthLimitReached
        )
    }

    // MARK: - Direct press

    func testDirectPressOnExactHit() {
        let button = Candidate(
            id: "btn",
            role: "AXButton",
            title: "Save",
            actions: ["AXPress"],
            frame: rect(120, 140, 80, 28),
            pid: pid,
            discoveryOrder: 0
        )
        let result = resolve(at: 150, 150, hitId: "btn", candidates: [button])
        XCTAssertTrue(result.didResolve)
        XCTAssertEqual(result.selectedId, "btn")
        XCTAssertEqual(result.action, .press)
        XCTAssertEqual(result.reason, "direct_press")
        XCTAssertEqual(result.anchor, point(160, 154)) // center of 120,140,80×28
        XCTAssertEqual(result.evidence.hitId, "btn")
        XCTAssertEqual(result.evidence.examinedIds, ["btn"])
        XCTAssertTrue(result.evidence.notes.contains("direct_press"))
        XCTAssertTrue(result.evidence.rejected.isEmpty)
    }

    // MARK: - Summary → parent press

    func testSummaryTextWalksToParentPress() {
        let row = Candidate(
            id: "row",
            role: "AXRow",
            title: "Message row",
            actions: ["AXPress"],
            frame: rect(110, 200, 360, 48),
            pid: pid,
            childIds: ["text"],
            discoveryOrder: 1
        )
        let text = Candidate(
            id: "text",
            role: "AXStaticText",
            value: "Hello from chat",
            actions: [],
            frame: rect(120, 210, 200, 28),
            pid: pid,
            parentId: "row",
            discoveryOrder: 0
        )
        let result = resolve(at: 150, 220, hitId: "text", candidates: [text, row])
        XCTAssertEqual(result.selectedId, "row")
        XCTAssertEqual(result.action, .press)
        XCTAssertEqual(result.reason, "summary_parent_press")
        XCTAssertTrue(result.evidence.notes.contains("summary_parent_press"))
        // Wide row parent → left safe anchor preference for summary→parent.
        XCTAssertNotNil(result.anchor)
        if let anchor = result.anchor {
            XCTAssertLessThan(anchor.x, 110 + 360 / 2, "left-biased anchor for row parent")
            XCTAssertEqual(anchor.y, 200 + 24, accuracy: 0.01)
        }
    }

    // MARK: - Synthetic row left anchor

    func testSyntheticRowLeftSafeAnchor() {
        // Wide chat row with text + trailing "done" checkbox on the right.
        let row = Candidate(
            id: "row",
            role: "AXGroup",
            frame: rect(110, 300, 360, 44),
            pid: pid,
            childIds: ["label", "done"],
            discoveryOrder: 0
        )
        let label = Candidate(
            id: "label",
            role: "AXStaticText",
            value: "Ship the release notes",
            frame: rect(120, 308, 220, 28),
            pid: pid,
            parentId: "row",
            discoveryOrder: 1
        )
        let done = Candidate(
            id: "done",
            role: "AXCheckBox",
            title: "Done",
            actions: ["AXPress"],
            frame: rect(420, 310, 40, 24),
            pid: pid,
            parentId: "row",
            discoveryOrder: 2
        )
        // Hit the text (summary); synthetic-row detection on the parent.
        let result = resolve(at: 180, 320, hitId: "label", candidates: [row, label, done])
        XCTAssertEqual(result.selectedId, "row")
        XCTAssertEqual(result.reason, "synthetic_row_left_anchor")
        XCTAssertEqual(result.action, .coordinate) // row itself has no AXPress
        guard let anchor = result.anchor else {
            return XCTFail("expected left safe anchor")
        }
        // Left-side safe anchor: near the leading edge, not center, not the trailing checkbox.
        XCTAssertEqual(anchor.x, 110 + 12, accuracy: 0.01)
        XCTAssertEqual(anchor.y, 300 + 22, accuracy: 0.01)
        XCTAssertLessThan(anchor.x, 420, "must not land on the trailing action")
        XCTAssertTrue(result.evidence.notes.contains("synthetic_row_left_anchor"))
    }

    func testSyntheticRowWithPressableRowUsesPressAndLeftAnchor() {
        let row = Candidate(
            id: "row",
            role: "AXRow",
            actions: ["AXPress"],
            frame: rect(110, 300, 360, 44),
            pid: pid,
            childIds: ["label", "done"],
            discoveryOrder: 0
        )
        let label = Candidate(
            id: "label",
            role: "AXStaticText",
            value: "Todo item",
            frame: rect(120, 308, 220, 28),
            pid: pid,
            parentId: "row",
            discoveryOrder: 1
        )
        let done = Candidate(
            id: "done",
            role: "AXButton",
            title: "…",
            actions: ["AXPress"],
            frame: rect(430, 310, 30, 24),
            pid: pid,
            parentId: "row",
            discoveryOrder: 2
        )
        let result = resolve(at: 180, 320, hitId: "label", candidates: [row, label, done])
        // Summary walk finds pressable parent first (summary_parent_press), which is also correct.
        // Either summary_parent_press or synthetic_row_left_anchor is acceptable; both pick the row.
        XCTAssertEqual(result.selectedId, "row")
        XCTAssertEqual(result.action, .press)
        guard let anchor = result.anchor else {
            return XCTFail("expected left-biased anchor")
        }
        XCTAssertLessThan(anchor.x, 110 + 180, "left-biased for wide row")
    }

    // MARK: - Ordinary control center anchor

    func testOrdinaryControlCenterAnchorWithoutPress() {
        // A link-like control that exposes no AXPress → coordinate at center.
        let link = Candidate(
            id: "link",
            role: "AXLink",
            title: "Docs",
            actions: [],
            frame: rect(200, 400, 100, 20),
            pid: pid,
            discoveryOrder: 0
        )
        let result = resolve(at: 230, 410, hitId: "link", candidates: [link])
        XCTAssertEqual(result.selectedId, "link")
        XCTAssertEqual(result.action, .coordinate)
        XCTAssertEqual(result.reason, "ordinary_control_center_anchor")
        XCTAssertEqual(result.anchor, point(250, 410))
        XCTAssertTrue(result.evidence.notes.contains("ordinary_control_center_anchor"))
    }

    // MARK: - Giant container stop / no hijack

    func testGiantContainerStopsDescendantHijack() {
        // Hit is a giant scroll view; a far-away button must not win.
        let scroll = Candidate(
            id: "scroll",
            role: "AXScrollArea",
            frame: rect(100, 100, 400, 600), // entire window
            pid: pid,
            childIds: ["far"],
            discoveryOrder: 0
        )
        let far = Candidate(
            id: "far",
            role: "AXButton",
            title: "Far",
            actions: ["AXPress"],
            frame: rect(350, 650, 80, 24), // far from the click at (150,150)
            pid: pid,
            parentId: "scroll",
            discoveryOrder: 1
        )
        // Pure resolve with giantContainerStopped=true and only the hit collected
        // (descendants not explored). The far button is NOT in the candidate set.
        let result = resolve(
            at: 150, 150,
            hitId: "scroll",
            candidates: [scroll],
            giantContainerStopped: true
        )
        XCTAssertTrue(result.evidence.giantContainerStopped)
        // Giant scroll is not pressable / not ordinary control containing a useful press —
        // may fall back to coordinate on the scroll itself, but must NOT select "far".
        XCTAssertNotEqual(result.selectedId, "far")
        if let selected = result.selectedId {
            XCTAssertEqual(selected, "scroll")
        }
    }

    func testIsGiantContainerDetection() {
        let limits = Limits(neighborhoodPadding: 48, giantAreaMultiplier: 16)
        let giant = rect(0, 0, 800, 600)
        let small = rect(100, 100, 40, 20)
        XCTAssertTrue(R.isGiantContainer(frame: giant, point: point(120, 120), limits: limits))
        XCTAssertFalse(R.isGiantContainer(frame: small, point: point(120, 120), limits: limits))
    }

    func testCollectCandidatesStopsDescendantsOnGiantHit() {
        let far = FakeLiveElement(
            id: "far",
            role: "AXButton",
            actions: ["AXPress"],
            frame: rect(350, 650, 80, 24),
            pid: pid
        )
        let scroll = FakeLiveElement(
            id: "scroll",
            role: "AXScrollArea",
            frame: rect(100, 100, 400, 600),
            pid: pid,
            childrenElements: [far]
        )
        far.parentElement = scroll

        let collected = R.collectCandidates(
            hit: scroll,
            point: point(150, 150),
            windowBounds: window,
            expectedPID: pid,
            limits: .default
        )
        XCTAssertTrue(collected.giantContainerStopped)
        XCTAssertEqual(collected.hitId, "c0")
        // Only the hit (and possibly ancestors — none here); far button not collected.
        XCTAssertEqual(collected.candidates.count, 1)
        XCTAssertEqual(collected.candidates[0].role, "AXScrollArea")
        XCTAssertFalse(collected.candidates.contains { $0.role == "AXButton" })
    }

    // MARK: - PID / window rejection

    func testRejectsWrongPID() {
        let foreign = Candidate(
            id: "btn",
            role: "AXButton",
            actions: ["AXPress"],
            frame: rect(120, 140, 80, 28),
            pid: 9999,
            discoveryOrder: 0
        )
        let result = resolve(at: 150, 150, hitId: "btn", candidates: [foreign])
        XCTAssertFalse(result.didResolve)
        XCTAssertEqual(result.reason, "rejected_pid")
        XCTAssertEqual(result.evidence.rejected.map(\.reason), ["pid_mismatch"])
    }

    func testRejectsFrameOutsideWindow() {
        let outside = Candidate(
            id: "btn",
            role: "AXButton",
            actions: ["AXPress"],
            frame: rect(900, 900, 80, 28),
            pid: pid,
            discoveryOrder: 0
        )
        let result = resolve(at: 150, 150, hitId: "btn", candidates: [outside])
        XCTAssertFalse(result.didResolve)
        XCTAssertTrue(
            result.reason == "rejected_window" || result.reason == "no_candidate",
            "outside-window candidates must not resolve; got \(result.reason)"
        )
        XCTAssertTrue(result.evidence.rejected.contains { $0.reason == "frame_outside_window" })
    }

    func testPointOutsideWindowRejected() {
        let button = Candidate(
            id: "btn",
            role: "AXButton",
            actions: ["AXPress"],
            frame: rect(120, 140, 80, 28),
            pid: pid,
            discoveryOrder: 0
        )
        let result = resolve(at: 10, 10, hitId: "btn", candidates: [button])
        XCTAssertFalse(result.didResolve)
        XCTAssertEqual(result.reason, "point_outside_window")
        XCTAssertTrue(result.evidence.notes.contains("point_outside_window"))
    }

    // MARK: - Depth / candidate bounds

    func testCollectCandidatesRespectsMaxCandidates() {
        var children: [FakeLiveElement] = []
        for i in 0..<20 {
            children.append(FakeLiveElement(
                id: "b\(i)",
                role: "AXButton",
                actions: ["AXPress"],
                frame: rect(120 + Double(i), 150, 20, 20),
                pid: pid
            ))
        }
        let group = FakeLiveElement(
            id: "group",
            role: "AXGroup",
            frame: rect(110, 140, 200, 40),
            pid: pid,
            childrenElements: children
        )
        for child in children { child.parentElement = group }

        let limits = Limits(maxCandidates: 5, maxDepth: 8)
        let collected = R.collectCandidates(
            hit: group,
            point: point(130, 155),
            windowBounds: window,
            expectedPID: pid,
            limits: limits
        )
        XCTAssertLessThanOrEqual(collected.candidates.count, 5)
        XCTAssertTrue(collected.candidateLimitReached)
    }

    func testCollectCandidatesRespectsMaxDepth() {
        // Chain: hit → parent1 → parent2 → parent3; maxDepth 2 keeps hit + 2 ancestors.
        let root = FakeLiveElement(id: "root", role: "AXWindow", frame: window, pid: pid)
        let mid = FakeLiveElement(id: "mid", role: "AXGroup", frame: rect(110, 110, 300, 300), pid: pid)
        let leaf = FakeLiveElement(
            id: "leaf",
            role: "AXStaticText",
            value: "x",
            frame: rect(150, 150, 40, 16),
            pid: pid
        )
        leaf.parentElement = mid
        mid.parentElement = root
        mid.childrenElements = [leaf]
        root.childrenElements = [mid]

        let limits = Limits(maxCandidates: 32, maxDepth: 1)
        let collected = R.collectCandidates(
            hit: leaf,
            point: point(160, 155),
            windowBounds: window,
            expectedPID: pid,
            limits: limits
        )
        // depth 0 = leaf, depth 1 = mid; root is beyond maxDepth.
        XCTAssertEqual(collected.candidates.count, 2)
        XCTAssertTrue(collected.depthLimitReached)
        XCTAssertFalse(collected.candidates.contains { $0.role == "AXWindow" })
    }

    // MARK: - Deterministic ties

    func testDeterministicTieBreakSmallestAreaThenDiscoveryOrder() {
        // Two equal-area pressable buttons both containing the point; smaller discoveryOrder wins.
        // Use slightly different areas so area is primary; then equal-area with discovery order.
        let a = Candidate(
            id: "a",
            role: "AXButton",
            title: "A",
            actions: ["AXPress"],
            frame: rect(140, 140, 60, 30), // area 1800
            pid: pid,
            discoveryOrder: 2
        )
        let b = Candidate(
            id: "b",
            role: "AXButton",
            title: "B",
            actions: ["AXPress"],
            frame: rect(145, 145, 50, 20), // area 1000 — smaller → wins
            pid: pid,
            discoveryOrder: 3
        )
        let result = resolve(at: 160, 155, hitId: "container", candidates: [
            Candidate(id: "container", role: "AXGroup", frame: rect(100, 100, 200, 200), pid: pid, childIds: ["a", "b"], discoveryOrder: 0),
            a, b,
        ])
        XCTAssertEqual(result.selectedId, "b")
        XCTAssertEqual(result.action, .press)

        // Equal area: lower discoveryOrder wins.
        let c = Candidate(
            id: "c",
            role: "AXButton",
            title: "C",
            actions: ["AXPress"],
            frame: rect(150, 150, 40, 20),
            pid: pid,
            discoveryOrder: 1
        )
        let d = Candidate(
            id: "d",
            role: "AXButton",
            title: "D",
            actions: ["AXPress"],
            frame: rect(152, 152, 40, 20), // same area
            pid: pid,
            discoveryOrder: 4
        )
        let tied = resolve(at: 160, 155, hitId: "g", candidates: [
            Candidate(id: "g", role: "AXGroup", frame: rect(100, 100, 200, 200), pid: pid, discoveryOrder: 0),
            c, d,
        ])
        XCTAssertEqual(tied.selectedId, "c")
    }

    func testDeterministicEqualAreaEqualOrderUsesId() {
        let a = Candidate(
            id: "aaa",
            role: "AXButton",
            actions: ["AXPress"],
            frame: rect(150, 150, 40, 20),
            pid: pid,
            discoveryOrder: 1
        )
        let b = Candidate(
            id: "bbb",
            role: "AXButton",
            actions: ["AXPress"],
            frame: rect(150, 150, 40, 20),
            pid: pid,
            discoveryOrder: 1
        )
        let result = resolve(at: 160, 155, hitId: "g", candidates: [
            Candidate(id: "g", role: "AXGroup", frame: rect(100, 100, 200, 200), pid: pid, discoveryOrder: 0),
            b, a, // insertion order reversed; id "aaa" still wins
        ])
        XCTAssertEqual(result.selectedId, "aaa")
    }

    // MARK: - No candidate

    func testNoCandidateWhenEmpty() {
        let result = resolve(at: 150, 150, hitId: nil, candidates: [])
        XCTAssertFalse(result.didResolve)
        XCTAssertEqual(result.reason, "no_candidate")
        XCTAssertTrue(result.evidence.notes.contains("no_candidates"))
        XCTAssertEqual(result.evidence.candidateCount, 0)
    }

    func testNoCandidateWhenOnlyNonInteractive() {
        let text = Candidate(
            id: "t",
            role: "AXStaticText",
            value: "Idle",
            frame: rect(120, 140, 80, 16),
            pid: pid,
            discoveryOrder: 0
        )
        let result = resolve(at: 150, 145, hitId: "t", candidates: [text])
        // Static text with no pressable parent → no usable target (or coordinate fallback on the text).
        // Coordinate fallback on the containing text is acceptable; must not claim press.
        if result.didResolve {
            XCTAssertEqual(result.action, .coordinate)
            XCTAssertNotEqual(result.action, .press)
        } else {
            XCTAssertEqual(result.reason, "no_candidate")
        }
    }

    // MARK: - Pure evidence

    func testEvidenceAlwaysPopulatedOnSuccess() {
        let button = Candidate(
            id: "btn",
            role: "AXButton",
            actions: ["AXPress"],
            frame: rect(120, 140, 80, 28),
            pid: pid,
            discoveryOrder: 0
        )
        let result = resolve(at: 150, 150, hitId: "btn", candidates: [button])
        XCTAssertEqual(result.evidence.hitId, "btn")
        XCTAssertEqual(result.evidence.candidateCount, 1)
        XCTAssertEqual(result.evidence.examinedIds, ["btn"])
        XCTAssertFalse(result.evidence.notes.isEmpty)
        XCTAssertFalse(result.evidence.giantContainerStopped)
        XCTAssertFalse(result.evidence.candidateLimitReached)
        XCTAssertFalse(result.evidence.depthLimitReached)
    }

    func testEvidenceRecordsRejectionsAndBoundsFlags() {
        let wrong = Candidate(
            id: "w",
            role: "AXButton",
            actions: ["AXPress"],
            frame: rect(120, 140, 80, 28),
            pid: 1,
            discoveryOrder: 0
        )
        let result = resolve(
            at: 150, 150,
            hitId: "w",
            candidates: [wrong],
            candidateLimitReached: true,
            depthLimitReached: true
        )
        XCTAssertTrue(result.evidence.candidateLimitReached)
        XCTAssertTrue(result.evidence.depthLimitReached)
        XCTAssertEqual(result.evidence.rejected.count, 1)
        XCTAssertEqual(result.evidence.rejected[0].id, "w")
        XCTAssertEqual(result.evidence.rejected[0].reason, "pid_mismatch")
        XCTAssertEqual(result.evidence.examinedIds, ["w"])
    }

    // MARK: - Live adapter thin + injectable

    func testLiveResolveUsesInjectableHitTester() {
        let button = FakeLiveElement(
            id: "btn",
            role: "AXButton",
            title: "OK",
            actions: ["AXPress"],
            frame: rect(120, 140, 80, 28),
            pid: pid
        )
        let tester = FakeHitTester(element: button)
        let live = R.resolve(
            point: point(150, 150),
            windowBounds: window,
            expectedPID: pid,
            hitTester: tester
        )
        XCTAssertEqual(tester.calls.count, 1)
        XCTAssertEqual(tester.calls[0].x, 150, accuracy: 0.001)
        XCTAssertEqual(tester.calls[0].y, 150, accuracy: 0.001)
        XCTAssertTrue(live.resolution.didResolve)
        XCTAssertEqual(live.resolution.action, .press)
        XCTAssertEqual(live.resolution.reason, "direct_press")
        XCTAssertTrue(live.selectedElement === button)
        // Resolver never posts input / never presses.
        XCTAssertTrue(button.performedActions.isEmpty)
    }

    func testLiveResolveMissYieldsNoCandidate() {
        let tester = FakeHitTester(element: nil)
        let live = R.resolve(
            point: point(150, 150),
            windowBounds: window,
            expectedPID: pid,
            hitTester: tester
        )
        XCTAssertFalse(live.resolution.didResolve)
        XCTAssertEqual(live.resolution.reason, "no_candidate")
        XCTAssertNil(live.selectedElement)
        XCTAssertEqual(live.resolution.evidence.candidateCount, 0)
    }

    // MARK: - Anchor helpers

    func testLeftSafeAnchorClampsIntoFrame() {
        let narrow = Candidate(
            id: "n",
            role: "AXRow",
            frame: rect(100, 100, 8, 20),
            pid: pid
        )
        let anchor = R.leftSafeAnchor(
            for: narrow,
            limits: Limits(safeAnchorXInset: 12),
            windowBounds: window
        )
        // Inset is clamped to width/4 for narrow rows, still inside the frame.
        XCTAssertGreaterThanOrEqual(anchor.x, 100)
        XCTAssertLessThanOrEqual(anchor.x, 108)
        XCTAssertEqual(anchor.y, 110, accuracy: 0.01)
    }

    func testCenterAnchorFallsBackToPointWhenFrameMissing() {
        let c = Candidate(id: "x", role: "AXButton", frame: nil, pid: pid)
        let anchor = R.centerAnchor(for: c, point: point(150, 160), windowBounds: window)
        XCTAssertEqual(anchor, point(150, 160))
    }

    // MARK: - Classification

    func testSummaryLikeRoles() {
        XCTAssertTrue(R.isSummaryLike(Candidate(id: "1", role: "AXStaticText")))
        XCTAssertTrue(R.isSummaryLike(Candidate(id: "2", role: "AXHeading", title: "H")))
        XCTAssertFalse(R.isSummaryLike(Candidate(id: "3", role: "AXButton", actions: ["AXPress"])))
        XCTAssertTrue(R.isSummaryLike(Candidate(id: "4", role: "AXGroup", value: "plain", actions: [])))
    }

    func testIsSyntheticRowRequiresTrailingAction() {
        let row = Candidate(
            id: "row",
            role: "AXGroup",
            frame: rect(0, 0, 300, 40),
            childIds: ["t"],
            discoveryOrder: 0
        )
        let text = Candidate(
            id: "t",
            role: "AXStaticText",
            value: "only text",
            frame: rect(10, 5, 200, 30),
            parentId: "row"
        )
        let byId = ["row": row, "t": text]
        XCTAssertFalse(R.isSyntheticRow(row, byId: byId), "text-only row is not synthetic")

        let done = Candidate(
            id: "done",
            role: "AXCheckBox",
            actions: ["AXPress"],
            frame: rect(250, 8, 30, 24),
            parentId: "row"
        )
        let row2 = Candidate(
            id: "row",
            role: "AXGroup",
            frame: rect(0, 0, 300, 40),
            childIds: ["t", "done"],
            discoveryOrder: 0
        )
        let byId2 = ["row": row2, "t": text, "done": done]
        XCTAssertTrue(R.isSyntheticRow(row2, byId: byId2))
    }
}

// MARK: - Fakes

private final class FakeLiveElement: AXClickTargetResolver.LiveElement {
    let stableId: String
    var role: String?
    var subrole: String?
    var title: String?
    var value: String?
    var descriptionText: String?
    var enabled: Bool
    var actions: [String]
    var frame: Rect?
    var pid: pid_t?
    weak var parentElement: FakeLiveElement?
    var childrenElements: [FakeLiveElement]
    private(set) var performedActions: [String] = []

    init(
        id: String,
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        descriptionText: String? = nil,
        enabled: Bool = true,
        actions: [String] = [],
        frame: Rect? = nil,
        pid: pid_t? = nil,
        childrenElements: [FakeLiveElement] = []
    ) {
        self.stableId = id
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.descriptionText = descriptionText
        self.enabled = enabled
        self.actions = actions
        self.frame = frame
        self.pid = pid
        self.childrenElements = childrenElements
    }

    func parent() -> AXClickTargetResolver.LiveElement? { parentElement }
    func children() -> [AXClickTargetResolver.LiveElement] { childrenElements }
}

private final class FakeHitTester: AXClickTargetResolver.LiveHitTester {
    var element: AXClickTargetResolver.LiveElement?
    private(set) var calls: [(x: Double, y: Double)] = []

    init(element: AXClickTargetResolver.LiveElement?) {
        self.element = element
    }

    func elementAt(x: Double, y: Double) -> AXClickTargetResolver.LiveElement? {
        calls.append((x, y))
        return element
    }
}
