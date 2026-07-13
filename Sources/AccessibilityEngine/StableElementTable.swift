import Foundation
import ComputerUseCore

/// A live element reference the stable table can test for validity.
///
/// The table is written against this seam so the live `AXUIElement` (see
/// `AXElementHandle` in `AXClient.swift`) is one conformance and unit tests supply
/// fakes — no Accessibility permission required to exercise identity/reuse/stale
/// behavior.
public protocol ElementHandle: AnyObject {
    /// Whether the underlying element still exists and is addressable. A dead handle
    /// must never satisfy an id-reuse check or resolve a stale id.
    var isLive: Bool { get }
}

/// Structural fingerprint used to decide id reuse across rebuilds (§11).
///
/// Deliberately excludes the raw `AXUIElement` pointer (which is not durable) and
/// the frame (which shifts on relayout). `parentHash` chains each node to its
/// ancestry so two like-role siblings in different subtrees never collide, and
/// `siblingOrdinal` disambiguates like-role siblings under one parent.
public struct ElementFingerprint: Hashable, Sendable {
    public let role: String
    public let subrole: String?
    public let axIdentifier: String?
    /// `stableHash` of the parent fingerprint; `rootParentHash` for the root.
    public let parentHash: Int
    /// 0-based ordinal among siblings sharing this element's role under one parent.
    public let siblingOrdinal: Int
    /// Title normalized by `normalizeTitle` (trim + collapse whitespace + lowercase).
    public let normalizedTitle: String

    public init(
        role: String,
        subrole: String?,
        axIdentifier: String?,
        parentHash: Int,
        siblingOrdinal: Int,
        normalizedTitle: String
    ) {
        self.role = role
        self.subrole = subrole
        self.axIdentifier = axIdentifier
        self.parentHash = parentHash
        self.siblingOrdinal = siblingOrdinal
        self.normalizedTitle = normalizedTitle
    }

    /// Sentinel parent hash for the root element.
    public static let rootParentHash = 0

    /// A within-process-stable hash of this fingerprint, suitable as a child's
    /// `parentHash`. `Hasher` is seeded once per process, so the value is consistent
    /// for the whole session lifetime — exactly the scope element ids live in.
    public var stableHash: Int {
        var hasher = Hasher()
        hasher.combine(role)
        hasher.combine(subrole)
        hasher.combine(axIdentifier)
        hasher.combine(parentHash)
        hasher.combine(siblingOrdinal)
        hasher.combine(normalizedTitle)
        return hasher.finalize()
    }

    /// Normalize a title for fingerprinting: trim, collapse internal whitespace to a
    /// single space, and lowercase. `nil`/whitespace-only → `""`.
    public static func normalizeTitle(_ title: String?) -> String {
        guard let title else { return "" }
        let parts = title.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ").lowercased()
    }
}

/// Session-scoped table that assigns opaque `e<N>` element ids and (when
/// `reuseAcrossPasses` is enabled) reuses them across rebuilds only when the
/// structural fingerprint matches **and** the prior handle is still live
/// (docs/PROTOCOL.md §11).
///
/// Guarantees:
/// - ids come from a monotonic counter starting at 1, formatted `e<N>`; the counter
///   never rewinds, so an id is **never reused for a different element within the
///   session** (§3) — regardless of `reuseAcrossPasses`;
/// - with `reuseAcrossPasses == true` an id is carried across a rebuild only when the
///   same fingerprint reappears and its previously stored handle is still live
///   (Phase 2/3 diff support, §11);
/// - with `reuseAcrossPasses == false` (the Phase-1 pipeline) every pass mints fresh
///   ids from the ongoing counter, so a full snapshot never reuses an id (§11
///   "Phase 1 is full-only and never reuses an id") while ids still stay monotonic
///   and session-unique (§3);
/// - a removed/replaced element's id is retired and **never** reused within the
///   session (the counter never rewinds);
/// - `resolve` throws `stale_element` for an id that is unknown or whose handle died.
///
/// Rebuild protocol: `beginPass()`, one `assign(...)` per element in traversal
/// order, then `endPass()` to retire ids not seen this pass.
///
/// Thread-safety: every access to the mutable state (`entriesById`,
/// `idByFingerprint`, `nextCounter`, and the per-pass scratch sets) is guarded by an
/// internal lock. A session normally drives the table from a single serialized
/// context, but in Phase 2 two paths touch a session's table on different threads —
/// `get_app_state` rebuilds it (beginPass/assign/endPass) on the tool-handler thread
/// while a mutation resolves it on the session lane — so the lock makes that safety
/// explicit rather than relying on the MCP runtime happening to process one request
/// at a time. The lock serializes each individual operation; the caller still owns
/// the higher-level ordering of a full rebuild versus a resolve.
public final class StableElementTable: @unchecked Sendable {
    private let lock = NSLock()

    fileprivate struct Entry {
        var numericId: Int
        var handle: ElementHandle
        var fingerprint: ElementFingerprint
    }

    /// Whether an unchanged element keeps its id across passes. The fingerprint-reuse
    /// machinery is Phase 2/3 (diffs/revisions); Phase 1 is full-only and mints fresh
    /// ids on every snapshot, so the Phase-1 pipeline constructs the table with this
    /// `false` (§11). The safety-critical guarantee (a removed/replaced element MUST
    /// NOT inherit a live id; retired ids never rewind) holds either way.
    private let reuseAcrossPasses: Bool

    private var nextCounter = 1
    private var entriesById: [Int: Entry] = [:]
    private var idByFingerprint: [ElementFingerprint: Int] = [:]

    // Per-pass scratch state.
    private var seenThisPass: Set<Int> = []
    private var assignedThisPass: Set<Int> = []
    private var passInProgress = false

    /// - Parameter reuseAcrossPasses: carry a matching fingerprint's id across passes
    ///   (Phase 2/3 default). Pass `false` for the Phase-1 full-only pipeline.
    public init(reuseAcrossPasses: Bool = true) {
        self.reuseAcrossPasses = reuseAcrossPasses
    }

    // MARK: - Rebuild lifecycle

    /// Begin a rebuild pass. Clears per-pass tracking; existing ids persist until
    /// `endPass` retires the unseen ones.
    public func beginPass() {
        lock.lock()
        defer { lock.unlock() }
        seenThisPass.removeAll(keepingCapacity: true)
        assignedThisPass.removeAll(keepingCapacity: true)
        passInProgress = true
    }

    /// Assign (reusing when possible) the numeric id for one element in the current
    /// pass. Returns the `N` in `e<N>`; format the wire string with `idString(_:)`.
    ///
    /// Reuse requires the same fingerprint to have been assigned in a prior build to
    /// a still-live handle that has not already been claimed this pass. Otherwise a
    /// fresh id is minted (so a replaced element cannot inherit a stale id).
    @discardableResult
    public func assign(handle: ElementHandle, fingerprint: ElementFingerprint) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if reuseAcrossPasses,
           let candidate = idByFingerprint[fingerprint],
           let prior = entriesById[candidate],
           prior.handle.isLive,
           !assignedThisPass.contains(candidate) {
            // Reuse: refresh the stored handle to the current live reference.
            entriesById[candidate] = Entry(numericId: candidate, handle: handle, fingerprint: fingerprint)
            assignedThisPass.insert(candidate)
            seenThisPass.insert(candidate)
            return candidate
        }

        let newId = nextCounter
        nextCounter += 1
        entriesById[newId] = Entry(numericId: newId, handle: handle, fingerprint: fingerprint)
        idByFingerprint[fingerprint] = newId
        assignedThisPass.insert(newId)
        seenThisPass.insert(newId)
        return newId
    }

    /// Retire the entire live id space, forcing the next build pass to mint all-fresh
    /// ids. Backs `get_app_state`'s `forceFullTree` = "rebuild ids too" (§15.1, distinct
    /// from `disableDiff` = "send the whole tree text" which keeps ids stable): every
    /// prior fingerprint→id mapping is dropped so no element can reuse its old id, while
    /// the monotonic `nextCounter` is **preserved** (§3: the counter never rewinds, so a
    /// retired id is never reused). After this the next `beginPass`/`assign`/`endPass`
    /// re-mints fresh ids for every element and the prior snapshot's ids are all retired.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        entriesById.removeAll(keepingCapacity: true)
        idByFingerprint.removeAll(keepingCapacity: true)
        seenThisPass.removeAll(keepingCapacity: true)
        assignedThisPass.removeAll(keepingCapacity: true)
        passInProgress = false
    }

    /// Finish the current pass: retire every id not assigned this pass. Retired ids
    /// are gone for good — the counter never rewinds, so they are never reused.
    public func endPass() {
        lock.lock()
        defer { lock.unlock() }
        for (id, entry) in entriesById where !seenThisPass.contains(id) {
            entriesById.removeValue(forKey: id)
            if idByFingerprint[entry.fingerprint] == id {
                idByFingerprint.removeValue(forKey: entry.fingerprint)
            }
        }
        seenThisPass.removeAll(keepingCapacity: true)
        assignedThisPass.removeAll(keepingCapacity: true)
        passInProgress = false
    }

    // MARK: - Cancellation rollback (§17)

    /// An opaque capture of the table's committed id mappings, taken before a build pass so
    /// the pass can be undone if the surrounding `get_app_state` is cancelled after the tree
    /// was already built (§17.2). External callers hold it opaquely and hand it back to
    /// `rollback(to:)`; they cannot inspect it.
    public struct Checkpoint {
        fileprivate let entriesById: [Int: Entry]
        fileprivate let idByFingerprint: [ElementFingerprint: Int]
    }

    /// Capture the current committed id mappings for a possible later `rollback(to:)`. Cheap:
    /// copies two dictionaries of value/reference entries; take it before `reset()`/`beginPass`
    /// so a rollback restores the exact pre-build id space.
    public func checkpoint() -> Checkpoint {
        lock.lock()
        defer { lock.unlock() }
        return Checkpoint(entriesById: entriesById, idByFingerprint: idByFingerprint)
    }

    /// Undo a build pass's id-space mutations (assigns, reuse-handle refreshes, retirements, and
    /// any `reset()`) by restoring the mappings captured by `checkpoint()`, so ids a client
    /// already holds keep resolving and a cancelled build leaves the element table observably
    /// untouched (§13.1). The monotonic `nextCounter` is deliberately **not** rewound (§3): any
    /// ids minted during the abandoned pass are retired forever and never reused, leaving only a
    /// (permitted) gap in the id space. Used only on the cancellation/failure path; a successful
    /// build discards its checkpoint.
    public func rollback(to checkpoint: Checkpoint) {
        lock.lock()
        defer { lock.unlock() }
        entriesById = checkpoint.entriesById
        idByFingerprint = checkpoint.idByFingerprint
        seenThisPass.removeAll(keepingCapacity: true)
        assignedThisPass.removeAll(keepingCapacity: true)
        passInProgress = false
    }

    // MARK: - Resolution (Phase 2 mutation)

    /// The wire id string for a numeric id: `e<N>`.
    public static func idString(_ numericId: Int) -> String { "e\(numericId)" }

    /// Resolve a wire `e<N>` id to its live handle, or throw `stale_element` (§6) if
    /// the id is malformed, retired, or backed by a dead handle.
    public func resolve(_ elementId: String, sessionId: String, revision: Int) throws -> ElementHandle {
        lock.lock()
        defer { lock.unlock() }
        guard let numeric = Self.parse(elementId),
              let entry = entriesById[numeric],
              entry.handle.isLive
        else {
            throw CUError.staleElement(sessionId: sessionId, elementId: elementId, revision: revision)
        }
        return entry.handle
    }

    /// Parse an `e<N>` id to its numeric part; `nil` when it is not `^e[0-9]+$`.
    static func parse(_ elementId: String) -> Int? {
        guard elementId.hasPrefix("e") else { return nil }
        let digits = elementId.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    // MARK: - Introspection (diagnostics / tests)

    /// Currently live numeric ids, sorted ascending.
    public var liveNumericIds: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return entriesById.keys.sorted()
    }

    /// Whether a numeric id is currently assigned.
    public func contains(numericId: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entriesById[numericId] != nil
    }
}
