import Foundation
import ApplicationServices
import CoreGraphics
import ComputerUseCore

/// Bounded AX coordinate→semantic click resolution.
///
/// Given a global click point and the target window's global bounds, hit-test the live
/// accessibility hierarchy (`AXUIElementCopyElementAtPosition`) and select a **pressable**
/// element or a safe coordinate anchor. The pure selection logic is fully unit-tested over
/// value `Candidate`s; the live adapter is a thin injectable seam that never performs
/// `AXPress` and never synthesizes pointer input.
///
/// Reliability heuristics (competitive scar tissue for Electron/chat UIs):
/// - prefer the exact hit element's `AXPress` when it is pressable and in-window;
/// - walk summary / static-text hits up to the nearest actionable parent row;
/// - for synthetic Electron/chat text rows, expose a **left-side safe anchor** inside the
///   row frame so trailing done/checkbox actions are not clicked by accident;
/// - ordinary controls get a **center** anchor for coordinate fallback;
/// - when the hit lands on a **giant container** (substantially larger than a neighborhood
///   around the click), stop descendant exploration so far-away clickables cannot hijack;
/// - reject candidates whose PID or frame falls outside the target window;
/// - bound candidate count and ancestry/descendant depth (no unbounded tree scans).
public enum AXClickTargetResolver {

    /// Raw action name preferred for semantic activation.
    public static let pressAction = "AXPress"

    /// Default ceilings for the bounded walk / selection.
    public static let defaultMaxCandidates = 32
    public static let defaultMaxDepth = 8
    /// Half-extent (points) of the click neighborhood used for giant-container detection.
    public static let defaultNeighborhoodPadding: Double = 48
    /// A container is "giant" when its area exceeds `neighborhood.area ×` this multiplier.
    public static let defaultGiantAreaMultiplier: Double = 16
    /// Inset from the row's leading edge for the synthetic-row safe anchor.
    public static let defaultSafeAnchorXInset: Double = 12
    /// Minimum horizontal inset so a degenerate narrow row still lands inside its frame.
    public static let minimumSafeAnchorInset: Double = 2

    // MARK: - Limits

    /// Hard bounds on candidate collection and giant-container detection.
    public struct Limits: Equatable, Sendable {
        /// Maximum candidates retained (hit + ancestors + allowed descendants).
        public var maxCandidates: Int
        /// Maximum parent/descendant steps walked from the hit element (hit is depth 0).
        public var maxDepth: Int
        /// Half-extent of the click neighborhood for giant-container comparison.
        public var neighborhoodPadding: Double
        /// Area ratio above which a hit frame is treated as a giant container.
        public var giantAreaMultiplier: Double
        /// Preferred leading inset for synthetic-row safe anchors.
        public var safeAnchorXInset: Double

        public init(
            maxCandidates: Int = AXClickTargetResolver.defaultMaxCandidates,
            maxDepth: Int = AXClickTargetResolver.defaultMaxDepth,
            neighborhoodPadding: Double = AXClickTargetResolver.defaultNeighborhoodPadding,
            giantAreaMultiplier: Double = AXClickTargetResolver.defaultGiantAreaMultiplier,
            safeAnchorXInset: Double = AXClickTargetResolver.defaultSafeAnchorXInset
        ) {
            self.maxCandidates = max(1, maxCandidates)
            self.maxDepth = max(0, maxDepth)
            self.neighborhoodPadding = max(1, neighborhoodPadding)
            self.giantAreaMultiplier = max(1, giantAreaMultiplier)
            self.safeAnchorXInset = max(AXClickTargetResolver.minimumSafeAnchorInset, safeAnchorXInset)
        }

        public static let `default` = Limits()
    }

    // MARK: - Pure candidate model

    /// One accessibility element considered for coordinate→semantic resolution.
    ///
    /// Frames are in **global points** (same space as the click point and window bounds).
    /// `id` is an opaque stable key within one resolution pass (not a session `e<N>` id).
    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var role: String?
        public var subrole: String?
        public var title: String?
        public var value: String?
        public var description: String?
        /// `AXEnabled`; defaults to `true` when unknown.
        public var enabled: Bool
        /// Raw AX action names (e.g. `["AXPress"]`).
        public var actions: [String]
        /// Global-point frame; `nil` when unreadable.
        public var frame: Rect?
        /// Owning process id when known.
        public var pid: pid_t?
        /// Parent candidate id within this pass, if collected.
        public var parentId: String?
        /// Child candidate ids within this pass (AX child order), if collected.
        public var childIds: [String]
        /// Discovery order (0 = hit element, then ancestors / descendants as collected).
        public var discoveryOrder: Int

        public init(
            id: String,
            role: String? = nil,
            subrole: String? = nil,
            title: String? = nil,
            value: String? = nil,
            description: String? = nil,
            enabled: Bool = true,
            actions: [String] = [],
            frame: Rect? = nil,
            pid: pid_t? = nil,
            parentId: String? = nil,
            childIds: [String] = [],
            discoveryOrder: Int = 0
        ) {
            self.id = id
            self.role = role
            self.subrole = subrole
            self.title = title
            self.value = value
            self.description = description
            self.enabled = enabled
            self.actions = actions
            self.frame = frame
            self.pid = pid
            self.parentId = parentId
            self.childIds = childIds
            self.discoveryOrder = discoveryOrder
        }

        /// Whether this candidate exposes a usable `AXPress`.
        public var isPressable: Bool {
            enabled && actions.contains(AXClickTargetResolver.pressAction)
        }
    }

    // MARK: - Resolution

    /// How the caller should activate the selected target.
    ///
    /// The resolver never performs either path — it only names the preferred action.
    public enum Action: String, Equatable, Sendable {
        /// Invoke `AXPress` on the selected element.
        case press
        /// Synthesize a pointer click at `Resolution.anchor` (resolver never posts input).
        case coordinate
    }

    /// One rejected candidate with a stable reason slug for evidence.
    public struct Rejection: Equatable, Sendable {
        public var id: String
        public var reason: String

        public init(id: String, reason: String) {
            self.id = id
            self.reason = reason
        }
    }

    /// Structured evidence for the resolution decision (always populated, including misses).
    public struct Evidence: Equatable, Sendable {
        /// The hit-test candidate id (`elementAtPosition`), when present.
        public var hitId: String?
        /// Candidate ids examined in discovery order.
        public var examinedIds: [String]
        /// Candidates rejected with reason slugs.
        public var rejected: [Rejection]
        /// Free-form deterministic notes (reason trail, heuristic labels).
        public var notes: [String]
        /// True when descendant exploration was skipped because the hit was a giant container.
        public var giantContainerStopped: Bool
        /// True when the candidate ceiling stopped further collection/selection.
        public var candidateLimitReached: Bool
        /// True when the depth ceiling stopped further ancestry/descendant walks.
        public var depthLimitReached: Bool
        /// Count of candidates supplied to pure selection (after collection filters).
        public var candidateCount: Int

        public init(
            hitId: String? = nil,
            examinedIds: [String] = [],
            rejected: [Rejection] = [],
            notes: [String] = [],
            giantContainerStopped: Bool = false,
            candidateLimitReached: Bool = false,
            depthLimitReached: Bool = false,
            candidateCount: Int = 0
        ) {
            self.hitId = hitId
            self.examinedIds = examinedIds
            self.rejected = rejected
            self.notes = notes
            self.giantContainerStopped = giantContainerStopped
            self.candidateLimitReached = candidateLimitReached
            self.depthLimitReached = depthLimitReached
            self.candidateCount = candidateCount
        }
    }

    /// Structured outcome of a coordinate click resolution. Never posts input.
    public struct Resolution: Equatable, Sendable {
        /// Selected candidate id within the pass, or `nil` when nothing is usable.
        public var selectedId: String?
        /// Preferred activation. `nil` when no target was selected.
        public var action: Action?
        /// Global-point anchor for coordinate fallback / evidence. Set whenever a target
        /// is selected (center of ordinary controls; left-side safe anchor for synthetic rows).
        public var anchor: Point?
        /// Stable reason slug describing the decision.
        public var reason: String
        /// Full decision evidence (examined/rejected ids, notes, bound flags).
        public var evidence: Evidence

        public init(
            selectedId: String? = nil,
            action: Action? = nil,
            anchor: Point? = nil,
            reason: String,
            evidence: Evidence = Evidence()
        ) {
            self.selectedId = selectedId
            self.action = action
            self.anchor = anchor
            self.reason = reason
            self.evidence = evidence
        }

        /// Whether a usable target was selected.
        public var didResolve: Bool { selectedId != nil && action != nil }
    }

    // MARK: - Live seams

    /// One live accessibility element navigable for hit-test collection.
    ///
    /// Implemented by the thin `LiveAXElement` adapter (and by fakes in tests). The pure
    /// selection path never touches this protocol — it only sees `Candidate` values.
    public protocol LiveElement: AnyObject {
        var role: String? { get }
        var subrole: String? { get }
        var title: String? { get }
        var value: String? { get }
        var descriptionText: String? { get }
        var enabled: Bool { get }
        var actions: [String] { get }
        /// Global-point frame.
        var frame: Rect? { get }
        var pid: pid_t? { get }
        func parent() -> LiveElement?
        func children() -> [LiveElement]
    }

    /// Injectable hit-test entry point (`AXUIElementCopyElementAtPosition` live).
    public protocol LiveHitTester: AnyObject {
        /// Deepest element under the global point, or `nil` when nothing is hit.
        func elementAt(x: Double, y: Double) -> LiveElement?
    }

    /// Live resolution pairs the pure `Resolution` with the selected live element (if any).
    public struct LiveResolution: Equatable {
        public var resolution: Resolution
        /// Selected live element for a subsequent `AXPress`. The resolver never presses it.
        public var selectedElement: LiveElement?

        public init(resolution: Resolution, selectedElement: LiveElement? = nil) {
            self.resolution = resolution
            self.selectedElement = selectedElement
        }

        public static func == (lhs: LiveResolution, rhs: LiveResolution) -> Bool {
            lhs.resolution == rhs.resolution
                && (lhs.selectedElement === rhs.selectedElement)
        }
    }

    // MARK: - Pure resolve

    /// Pure coordinate→semantic selection over an already-collected candidate graph.
    ///
    /// - Parameters:
    ///   - point: Click location in **global points**.
    ///   - windowBounds: Target window frame in **global points**; candidates outside it
    ///     are rejected.
    ///   - expectedPID: Owning process of the target window; candidates with a different
    ///     pid are rejected when both are known.
    ///   - hitId: Id of the `elementAtPosition` hit within `candidates`, when known.
    ///   - candidates: Bounded candidate set (hit + ancestors ± descendants).
    ///   - limits: Candidate/depth/giant-container ceilings.
    ///   - giantContainerStopped / candidateLimitReached / depthLimitReached: collection
    ///     diagnostics folded into evidence.
    public static func resolve(
        point: Point,
        windowBounds: Rect,
        expectedPID: pid_t?,
        hitId: String?,
        candidates: [Candidate],
        limits: Limits = .default,
        giantContainerStopped: Bool = false,
        candidateLimitReached: Bool = false,
        depthLimitReached: Bool = false
    ) -> Resolution {
        var evidence = Evidence(
            hitId: hitId,
            examinedIds: [],
            rejected: [],
            notes: [],
            giantContainerStopped: giantContainerStopped,
            candidateLimitReached: candidateLimitReached,
            depthLimitReached: depthLimitReached,
            candidateCount: candidates.count
        )

        // Point must lie inside the target window — otherwise refuse (wrong-target guard).
        guard windowBounds.contains(x: point.x, y: point.y) else {
            evidence.notes.append("point_outside_window")
            return Resolution(reason: "point_outside_window", evidence: evidence)
        }

        guard !candidates.isEmpty else {
            evidence.notes.append("no_candidates")
            return Resolution(reason: "no_candidate", evidence: evidence)
        }

        let byId = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        // Examine in discovery order for deterministic evidence, then apply filters.
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.discoveryOrder != rhs.discoveryOrder {
                return lhs.discoveryOrder < rhs.discoveryOrder
            }
            return lhs.id < rhs.id
        }

        var eligible: [Candidate] = []
        for candidate in ordered {
            evidence.examinedIds.append(candidate.id)
            if let rejection = rejectionReason(
                for: candidate,
                point: point,
                windowBounds: windowBounds,
                expectedPID: expectedPID
            ) {
                evidence.rejected.append(Rejection(id: candidate.id, reason: rejection))
                continue
            }
            eligible.append(candidate)
        }

        if eligible.isEmpty {
            evidence.notes.append("all_candidates_rejected")
            // Prefer a more specific reason when every rejection shares one cause.
            let reasons = Set(evidence.rejected.map(\.reason))
            let reason: String
            if reasons == ["pid_mismatch"] {
                reason = "rejected_pid"
            } else if reasons == ["outside_window"] || reasons == ["frame_outside_window"] {
                reason = "rejected_window"
            } else if reasons.contains("pid_mismatch") && reasons.count == 1 {
                reason = "rejected_pid"
            } else {
                reason = "no_candidate"
            }
            return Resolution(reason: reason, evidence: evidence)
        }

        // --- Selection ladder -------------------------------------------------------
        // 1. Exact hit is pressable → press it (center anchor for coordinate fallback).
        if let hitId,
           let hit = byId[hitId],
           eligible.contains(where: { $0.id == hitId }),
           hit.isPressable {
            let anchor = centerAnchor(for: hit, point: point, windowBounds: windowBounds)
            evidence.notes.append("direct_press")
            return Resolution(
                selectedId: hit.id,
                action: .press,
                anchor: anchor,
                reason: "direct_press",
                evidence: evidence
            )
        }

        // 2. Summary / static-text hit → walk parents for the nearest pressable ancestor.
        //    If that ancestor is a synthetic chat/list row, report the synthetic-row reason
        //    and left-safe anchor so callers can distinguish trailing-action avoidance.
        if let hitId,
           let hit = byId[hitId],
           isSummaryLike(hit) {
            if let parent = nearestPressableAncestor(of: hitId, byId: byId, eligible: eligible) {
                let synthetic = isSyntheticRow(parent, byId: byId)
                    || (isRowLikeRole(parent.role) && {
                        if let frame = parent.frame {
                            return frame.width >= max(frame.height * 2.5, 80)
                        }
                        return false
                    }())
                let anchor: Point
                let reason: String
                if synthetic {
                    anchor = leftSafeAnchor(for: parent, limits: limits, windowBounds: windowBounds)
                    reason = isSyntheticRow(parent, byId: byId)
                        ? "synthetic_row_left_anchor"
                        : "summary_parent_press"
                    if reason == "synthetic_row_left_anchor" {
                        evidence.notes.append("synthetic_row_left_anchor")
                    } else {
                        evidence.notes.append("summary_parent_press")
                        evidence.notes.append("left_safe_anchor_for_row_parent")
                    }
                } else {
                    anchor = centerAnchor(for: parent, point: point, windowBounds: windowBounds)
                    reason = "summary_parent_press"
                    evidence.notes.append("summary_parent_press")
                }
                return Resolution(
                    selectedId: parent.id,
                    action: parent.isPressable ? .press : .coordinate,
                    anchor: anchor,
                    reason: reason,
                    evidence: evidence
                )
            }
            evidence.notes.append("summary_without_pressable_parent")
        }

        // 3. Synthetic Electron/chat row (wide row + text + trailing action) → left safe anchor.
        //    Handles the non-pressable row case (coordinate activation at the safe point).
        if let hitId, let hit = byId[hitId] {
            if let row = nearestSyntheticRow(from: hitId, byId: byId, eligible: eligible)
                ?? (isSyntheticRow(hit, byId: byId) ? hit : nil) {
                let anchor = leftSafeAnchor(for: row, limits: limits, windowBounds: windowBounds)
                evidence.notes.append("synthetic_row_left_anchor")
                if row.isPressable {
                    return Resolution(
                        selectedId: row.id,
                        action: .press,
                        anchor: anchor,
                        reason: "synthetic_row_left_anchor",
                        evidence: evidence
                    )
                }
                return Resolution(
                    selectedId: row.id,
                    action: .coordinate,
                    anchor: anchor,
                    reason: "synthetic_row_left_anchor",
                    evidence: evidence
                )
            }
        }

        // 4. Deepest eligible pressable candidate that contains the point.
        let containing = eligible.filter { containsPoint($0, point) }
        if let pressable = preferredPressable(in: containing) {
            let anchor = centerAnchor(for: pressable, point: point, windowBounds: windowBounds)
            evidence.notes.append("deepest_pressable")
            return Resolution(
                selectedId: pressable.id,
                action: .press,
                anchor: anchor,
                reason: "direct_press",
                evidence: evidence
            )
        }

        // 5. Ordinary control (button-like) without AXPress → center coordinate anchor.
        if let control = preferredOrdinaryControl(in: containing) {
            let anchor = centerAnchor(for: control, point: point, windowBounds: windowBounds)
            evidence.notes.append("ordinary_control_center_anchor")
            return Resolution(
                selectedId: control.id,
                action: .coordinate,
                anchor: anchor,
                reason: "ordinary_control_center_anchor",
                evidence: evidence
            )
        }

        // 6. Any remaining eligible that contains the point → center coordinate anchor.
        if let fallback = preferredByAreaThenOrder(containing) {
            let anchor = centerAnchor(for: fallback, point: point, windowBounds: windowBounds)
            evidence.notes.append("containing_coordinate_fallback")
            return Resolution(
                selectedId: fallback.id,
                action: .coordinate,
                anchor: anchor,
                reason: "coordinate_fallback",
                evidence: evidence
            )
        }

        // 7. Eligible candidates that do not contain the point (e.g. parent rows collected
        //    for a text hit already handled above) — last-resort nearest pressable.
        if let pressable = preferredPressable(in: eligible) {
            let anchor = centerAnchor(for: pressable, point: point, windowBounds: windowBounds)
            evidence.notes.append("nearest_pressable")
            return Resolution(
                selectedId: pressable.id,
                action: .press,
                anchor: anchor,
                reason: "direct_press",
                evidence: evidence
            )
        }

        evidence.notes.append("no_usable_target")
        return Resolution(reason: "no_candidate", evidence: evidence)
    }

    // MARK: - Live resolve

    /// Live hit-test → bounded candidate collection → pure selection.
    ///
    /// Never performs `AXPress` and never synthesizes pointer events. The returned
    /// `selectedElement` is for the caller to press (or ignore in favour of `anchor`).
    public static func resolve(
        point: Point,
        windowBounds: Rect,
        expectedPID: pid_t?,
        hitTester: LiveHitTester,
        limits: Limits = .default
    ) -> LiveResolution {
        let hit = hitTester.elementAt(x: point.x, y: point.y)
        let collected = collectCandidates(
            hit: hit,
            point: point,
            windowBounds: windowBounds,
            expectedPID: expectedPID,
            limits: limits
        )
        let resolution = resolve(
            point: point,
            windowBounds: windowBounds,
            expectedPID: expectedPID,
            hitId: collected.hitId,
            candidates: collected.candidates,
            limits: limits,
            giantContainerStopped: collected.giantContainerStopped,
            candidateLimitReached: collected.candidateLimitReached,
            depthLimitReached: collected.depthLimitReached
        )
        let selected: LiveElement?
        if let id = resolution.selectedId {
            selected = collected.elementsById[id]
        } else {
            selected = nil
        }
        return LiveResolution(resolution: resolution, selectedElement: selected)
    }

    /// Bounded collection from a live hit element into pure `Candidate` values.
    ///
    /// Walks ancestors always; walks descendants only when the hit is **not** a giant
    /// container. Caps total candidates and depth.
    public static func collectCandidates(
        hit: LiveElement?,
        point: Point,
        windowBounds: Rect,
        expectedPID: pid_t?,
        limits: Limits = .default
    ) -> CollectedCandidates {
        var candidates: [Candidate] = []
        var elementsById: [String: LiveElement] = [:]
        var idByObject: [ObjectIdentifier: String] = [:]
        var discovery = 0
        var candidateLimitReached = false
        var depthLimitReached = false
        var giantContainerStopped = false

        guard let hit else {
            return CollectedCandidates(
                hitId: nil,
                candidates: [],
                elementsById: [:],
                giantContainerStopped: false,
                candidateLimitReached: false,
                depthLimitReached: false
            )
        }

        func assignId(_ element: LiveElement) -> String {
            let key = ObjectIdentifier(element)
            if let existing = idByObject[key] { return existing }
            let id = "c\(discovery)"
            discovery += 1
            idByObject[key] = id
            elementsById[id] = element
            return id
        }

        func append(_ element: LiveElement, parentId: String?) -> String? {
            if candidates.count >= limits.maxCandidates {
                candidateLimitReached = true
                return idByObject[ObjectIdentifier(element)]
            }
            let id = assignId(element)
            if candidates.contains(where: { $0.id == id }) {
                return id
            }
            candidates.append(Candidate(
                id: id,
                role: element.role,
                subrole: element.subrole,
                title: element.title,
                value: element.value,
                description: element.descriptionText,
                enabled: element.enabled,
                actions: element.actions,
                frame: element.frame,
                pid: element.pid,
                parentId: parentId,
                childIds: [],
                discoveryOrder: candidates.count
            ))
            return id
        }

        func linkChild(_ childId: String, to parentId: String) {
            guard let idx = candidates.firstIndex(where: { $0.id == parentId }) else { return }
            if !candidates[idx].childIds.contains(childId) {
                candidates[idx].childIds.append(childId)
            }
        }

        func shouldCollectChild(_ child: LiveElement) -> Bool {
            guard let frame = child.frame else { return true }
            if !intersects(frame, windowBounds) { return false }
            if frame.contains(x: point.x, y: point.y) { return true }
            if nearNeighborhood(frame: frame, point: point, limits: limits) { return true }
            // Interactive / text children inside a parent row are still useful for
            // synthetic-row classification even when they miss the click neighborhood.
            let interactive = child.actions.contains(pressAction) || isOrdinaryControlRole(child.role)
            let textual = child.role == "AXStaticText"
                || child.role == "AXHeading"
                || !(child.value ?? child.title ?? "").isEmpty
            return interactive || textual
        }

        func walkChildren(of element: LiveElement, elementId: String, depth: Int) {
            if depth >= limits.maxDepth {
                if !element.children().isEmpty { depthLimitReached = true }
                return
            }
            if candidates.count >= limits.maxCandidates {
                candidateLimitReached = true
                return
            }
            for child in element.children() {
                if candidates.count >= limits.maxCandidates {
                    candidateLimitReached = true
                    return
                }
                guard shouldCollectChild(child) else { continue }
                guard let childId = append(child, parentId: elementId) else { return }
                linkChild(childId, to: elementId)
                walkChildren(of: child, elementId: childId, depth: depth + 1)
                if candidateLimitReached { return }
            }
        }

        // Hit element is discovery order 0.
        let hitId = append(hit, parentId: nil) ?? assignId(hit)

        // Giant-container gate: based on the hit frame vs neighborhood around the click.
        if isGiantContainer(frame: hit.frame, point: point, limits: limits) {
            giantContainerStopped = true
        }

        // Walk ancestors (parent chain) up to maxDepth.
        var current: LiveElement? = hit
        var currentId = hitId
        var depth = 0
        while depth < limits.maxDepth {
            guard let parent = current?.parent() else { break }
            depth += 1
            if candidates.count >= limits.maxCandidates {
                candidateLimitReached = true
                break
            }
            guard let parentId = append(parent, parentId: nil) else { break }
            if let idx = candidates.firstIndex(where: { $0.id == currentId }) {
                candidates[idx].parentId = parentId
            }
            linkChild(currentId, to: parentId)
            current = parent
            currentId = parentId
        }
        if depth >= limits.maxDepth, current?.parent() != nil {
            depthLimitReached = true
        }

        // Descendants of the hit only when it is not a giant container.
        if !giantContainerStopped {
            walkChildren(of: hit, elementId: hitId, depth: 0)
        }

        // One-level siblings under each collected ancestor so a text hit can still
        // observe trailing actions on a synthetic chat/list row. Bounded by maxCandidates.
        // Never re-opens a giant hit's descendant scan.
        if !giantContainerStopped {
            let ancestorSnapshot = candidates.compactMap { candidate -> (String, LiveElement)? in
                guard candidate.id != hitId, let element = elementsById[candidate.id] else { return nil }
                // Only walk ancestors that look row-like / group-like; skip pure windows.
                if candidate.role == "AXWindow" || candidate.role == "AXApplication" { return nil }
                return (candidate.id, element)
            }
            for (ancestorId, ancestorElement) in ancestorSnapshot {
                if candidates.count >= limits.maxCandidates {
                    candidateLimitReached = true
                    break
                }
                for sibling in ancestorElement.children() {
                    if candidates.count >= limits.maxCandidates {
                        candidateLimitReached = true
                        break
                    }
                    guard shouldCollectChild(sibling) else { continue }
                    // Already collected (the hit or a previously walked child)?
                    if idByObject[ObjectIdentifier(sibling)] != nil {
                        if let existing = idByObject[ObjectIdentifier(sibling)] {
                            linkChild(existing, to: ancestorId)
                        }
                        continue
                    }
                    if let siblingId = append(sibling, parentId: ancestorId) {
                        linkChild(siblingId, to: ancestorId)
                    }
                }
            }
        }

        // Soft PID pre-filter note only — pure resolve applies the authoritative rejection.
        _ = expectedPID

        return CollectedCandidates(
            hitId: hitId,
            candidates: candidates,
            elementsById: elementsById,
            giantContainerStopped: giantContainerStopped,
            candidateLimitReached: candidateLimitReached,
            depthLimitReached: depthLimitReached
        )
    }

    /// Result of a bounded live (or fake) candidate collection pass.
    public struct CollectedCandidates {
        public var hitId: String?
        public var candidates: [Candidate]
        public var elementsById: [String: LiveElement]
        public var giantContainerStopped: Bool
        public var candidateLimitReached: Bool
        public var depthLimitReached: Bool

        public init(
            hitId: String?,
            candidates: [Candidate],
            elementsById: [String: LiveElement],
            giantContainerStopped: Bool,
            candidateLimitReached: Bool,
            depthLimitReached: Bool
        ) {
            self.hitId = hitId
            self.candidates = candidates
            self.elementsById = elementsById
            self.giantContainerStopped = giantContainerStopped
            self.candidateLimitReached = candidateLimitReached
            self.depthLimitReached = depthLimitReached
        }
    }

    // MARK: - Classification helpers (pure)

    /// Roles treated as summary / static text that should walk up for a parent press.
    public static func isSummaryLike(_ candidate: Candidate) -> Bool {
        guard let role = candidate.role else { return false }
        switch role {
        case "AXStaticText", "AXHeading", "AXImage", "AXHelpTag":
            return true
        default:
            // Some Electron builds expose summary rows as generic AXGroup with only text value.
            if role == "AXGroup" || role == "AXUnknown" {
                let hasText = !(candidate.value ?? "").isEmpty || !(candidate.title ?? "").isEmpty
                return hasText && !candidate.isPressable
            }
            return false
        }
    }

    /// Ordinary interactive control roles (center-anchor coordinate fallback).
    public static func isOrdinaryControl(_ candidate: Candidate) -> Bool {
        guard let role = candidate.role else { return false }
        switch role {
        case "AXButton", "AXCheckBox", "AXRadioButton", "AXLink", "AXMenuItem",
             "AXPopUpButton", "AXComboBox", "AXDisclosureTriangle", "AXTab",
             "AXToggle", "AXSwitch", "AXIncrementor", "AXDecrementor",
             "AXMenuButton", "AXSortButton", "AXColorWell":
            return true
        default:
            return false
        }
    }

    /// Role-only ordinary-control check for live collection (no Candidate yet).
    public static func isOrdinaryControlRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return isOrdinaryControl(Candidate(id: "_", role: role))
    }

    /// Row-like container roles used by Electron/chat lists.
    public static func isRowLikeRole(_ role: String?) -> Bool {
        guard let role else { return false }
        switch role {
        case "AXRow", "AXCell", "AXListItem", "AXOutlineRow", "AXGroup", "AXUnknown":
            return true
        default:
            return false
        }
    }

    /// Synthetic Electron/chat text row: row-like frame, text content, and a trailing
    /// interactive child on the right half (done/checkbox/etc.).
    public static func isSyntheticRow(_ candidate: Candidate, byId: [String: Candidate]) -> Bool {
        guard isRowLikeRole(candidate.role), let frame = candidate.frame else { return false }
        // Row-like aspect: substantially wider than tall (chat rows, list rows).
        guard frame.width >= max(frame.height * 2.5, 80) else { return false }

        let children = candidate.childIds.compactMap { byId[$0] }
        guard !children.isEmpty else { return false }

        let hasTextChild = children.contains { child in
            isSummaryLike(child) || !(child.value ?? child.title ?? "").isEmpty
        }
        guard hasTextChild else { return false }

        let midX = frame.x + frame.width * 0.55
        let trailingInteractive = children.contains { child in
            guard let childFrame = child.frame else { return false }
            let interactive = child.isPressable || isOrdinaryControl(child)
            return interactive && childFrame.x >= midX
        }
        return trailingInteractive
    }

    /// Whether `frame` is substantially larger than the neighborhood around `point`.
    public static func isGiantContainer(frame: Rect?, point: Point, limits: Limits) -> Bool {
        guard let frame else { return false }
        let pad = limits.neighborhoodPadding
        let neighborhoodArea = (pad * 2) * (pad * 2)
        let area = max(0, frame.width) * max(0, frame.height)
        if area >= neighborhoodArea * limits.giantAreaMultiplier {
            return true
        }
        // Also treat frames that dwarf the neighborhood in **both** dimensions as giant,
        // even when the area ratio is borderline (very wide-and-tall scroll views).
        if frame.width >= pad * 4 && frame.height >= pad * 4
            && area >= neighborhoodArea * (limits.giantAreaMultiplier * 0.5) {
            return true
        }
        // Ignore unused point parameter shape — neighborhood is centered on the click.
        _ = point
        return false
    }

    // MARK: - Private selection helpers

    private static func rejectionReason(
        for candidate: Candidate,
        point: Point,
        windowBounds: Rect,
        expectedPID: pid_t?
    ) -> String? {
        if let expectedPID, let pid = candidate.pid, pid != expectedPID {
            return "pid_mismatch"
        }
        guard let frame = candidate.frame else {
            return "missing_frame"
        }
        // Frame must intersect the target window; fully outside → reject.
        if !intersects(frame, windowBounds) {
            return "frame_outside_window"
        }
        // Candidate must be associated with the click: contain the point, or be an
        // ancestor/row collected for a summary hit (ancestors often do not contain a
        // point that landed on a child text node that fills them — but parent frames
        // usually do). If the frame does not contain the point and the candidate is
        // not pressable/row-like, reject as unrelated.
        if !frame.contains(x: point.x, y: point.y)
            && !candidate.isPressable
            && !isRowLikeRole(candidate.role)
            && !isOrdinaryControl(candidate) {
            return "does_not_contain_point"
        }
        // Frame center (or any part used for anchors) should not fall outside the window
        // for activation; still allow if intersection is non-empty and pressable.
        if !windowBounds.contains(x: point.x, y: point.y) {
            return "outside_window"
        }
        return nil
    }

    private static func containsPoint(_ candidate: Candidate, _ point: Point) -> Bool {
        guard let frame = candidate.frame else { return false }
        return frame.contains(x: point.x, y: point.y)
    }

    private static func nearestPressableAncestor(
        of id: String,
        byId: [String: Candidate],
        eligible: [Candidate]
    ) -> Candidate? {
        let eligibleIds = Set(eligible.map(\.id))
        var current = byId[id]?.parentId
        var guardCounter = 0
        while let pid = current, guardCounter < 64 {
            guardCounter += 1
            guard let candidate = byId[pid] else { break }
            if eligibleIds.contains(candidate.id), candidate.isPressable {
                return candidate
            }
            // Prefer a synthetic row ancestor even without press (coordinate path).
            if eligibleIds.contains(candidate.id), isSyntheticRow(candidate, byId: byId) {
                return candidate
            }
            current = candidate.parentId
        }
        return nil
    }

    private static func nearestSyntheticRow(
        from id: String,
        byId: [String: Candidate],
        eligible: [Candidate]
    ) -> Candidate? {
        let eligibleIds = Set(eligible.map(\.id))
        var current: String? = id
        var guardCounter = 0
        while let cid = current, guardCounter < 64 {
            guardCounter += 1
            guard let candidate = byId[cid] else { break }
            if eligibleIds.contains(candidate.id), isSyntheticRow(candidate, byId: byId) {
                return candidate
            }
            current = candidate.parentId
        }
        return nil
    }

    private static func preferredPressable(in candidates: [Candidate]) -> Candidate? {
        let pressable = candidates.filter(\.isPressable)
        return preferredByAreaThenOrder(pressable)
    }

    private static func preferredOrdinaryControl(in candidates: [Candidate]) -> Candidate? {
        let controls = candidates.filter { isOrdinaryControl($0) }
        return preferredByAreaThenOrder(controls)
    }

    /// Deterministic tie-break: smallest area first (deepest visual target), then discovery
    /// order, then id. Equal areas stay stable.
    private static func preferredByAreaThenOrder(_ candidates: [Candidate]) -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        return candidates.min { lhs, rhs in
            let la = area(lhs.frame)
            let ra = area(rhs.frame)
            if la != ra { return la < ra }
            if lhs.discoveryOrder != rhs.discoveryOrder {
                return lhs.discoveryOrder < rhs.discoveryOrder
            }
            return lhs.id < rhs.id
        }
    }

    /// Center of the candidate frame, clamped into the window; falls back to the click point.
    public static func centerAnchor(for candidate: Candidate, point: Point, windowBounds: Rect) -> Point {
        guard let frame = candidate.frame else {
            return clamp(point, to: windowBounds)
        }
        let raw = Point(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        return clamp(raw, to: windowBounds)
    }

    /// Left-side safe anchor inside the row frame (avoids trailing actions).
    public static func leftSafeAnchor(
        for candidate: Candidate,
        limits: Limits,
        windowBounds: Rect
    ) -> Point {
        guard let frame = candidate.frame else {
            return clamp(Point(x: windowBounds.x, y: windowBounds.y), to: windowBounds)
        }
        let inset = min(limits.safeAnchorXInset, max(minimumSafeAnchorInset, frame.width / 4))
        let x = frame.x + inset
        let y = frame.y + frame.height / 2
        return clamp(Point(x: x, y: y), to: windowBounds)
    }

    private static func clamp(_ point: Point, to rect: Rect) -> Point {
        let minX = rect.x
        let maxX = rect.x + max(0, rect.width)
        let minY = rect.y
        let maxY = rect.y + max(0, rect.height)
        return Point(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }

    private static func area(_ frame: Rect?) -> Double {
        guard let frame else { return Double.greatestFiniteMagnitude }
        return max(0, frame.width) * max(0, frame.height)
    }

    private static func intersects(_ a: Rect, _ b: Rect) -> Bool {
        let ax2 = a.x + a.width
        let ay2 = a.y + a.height
        let bx2 = b.x + b.width
        let by2 = b.y + b.height
        return a.x <= bx2 && ax2 >= b.x && a.y <= by2 && ay2 >= b.y
    }

    private static func nearNeighborhood(frame: Rect, point: Point, limits: Limits) -> Bool {
        let pad = limits.neighborhoodPadding * 2
        let neighborhood = Rect(
            x: point.x - pad,
            y: point.y - pad,
            width: pad * 2,
            height: pad * 2
        )
        return intersects(frame, neighborhood)
    }
}

// MARK: - Live AX adapters

/// Thin live `LiveElement` over a real `AXUIElement` + `AXClient` (public APIs only).
///
/// Impure. Never unit-tested directly; the pure `Candidate` selection is.
public final class LiveAXClickElement: AXClickTargetResolver.LiveElement {
    public let element: AXUIElement
    private let client: AXClient

    public init(element: AXUIElement, client: AXClient = AXClient()) {
        self.element = element
        self.client = client
    }

    public var role: String? { client.role(of: element) }
    public var subrole: String? { client.subrole(of: element) }
    public var title: String? { client.copyString(element, AXAttr.title) }
    public var value: String? {
        guard let raw = try? client.copyAttribute(element, AXAttr.value) else { return nil }
        if let s = raw as? String { return s }
        if CFGetTypeID(raw) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((raw as! CFBoolean)) ? "1" : "0"
        }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }
    public var descriptionText: String? { client.copyString(element, AXAttr.description) }
    public var enabled: Bool { client.copyBool(element, AXAttr.enabled) ?? true }
    public var actions: [String] { client.actionNames(of: element) }
    public var frame: Rect? {
        guard let cg = client.frame(of: element) else { return nil }
        return Rect(x: cg.origin.x, y: cg.origin.y, width: cg.size.width, height: cg.size.height)
    }
    public var pid: pid_t? { try? client.pid(of: element) }

    public func parent() -> AXClickTargetResolver.LiveElement? {
        guard let parent = client.copyElement(element, "AXParent") else { return nil }
        return LiveAXClickElement(element: parent, client: client)
    }

    public func children() -> [AXClickTargetResolver.LiveElement] {
        client.children(of: element).map { LiveAXClickElement(element: $0, client: client) }
    }
}

/// Live hit-tester using `AXUIElementCopyElementAtPosition` (public API).
///
/// System-wide hit test; the resolver still rejects wrong-PID / out-of-window candidates.
/// Impure and injectable — unit tests supply a fake `LiveHitTester`.
public final class LiveAXClickHitTester: AXClickTargetResolver.LiveHitTester {
    private let client: AXClient
    /// Optional system-wide element; when nil, a temporary system-wide element is created
    /// per hit-test via `AXUIElementCreateSystemWide()`.
    private let systemWide: AXUIElement?

    public init(client: AXClient = AXClient(), systemWide: AXUIElement? = nil) {
        self.client = client
        self.systemWide = systemWide
    }

    public func elementAt(x: Double, y: Double) -> AXClickTargetResolver.LiveElement? {
        let root = systemWide ?? AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(root, Float(x), Float(y), &element)
        guard err == .success, let element else { return nil }
        return LiveAXClickElement(element: element, client: client)
    }
}
