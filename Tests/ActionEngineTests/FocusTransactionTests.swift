import XCTest
import ComputerUseCore
@testable import ActionEngine

/// FocusTransaction record/activate/restore bookkeeping over a fake workspace (§16).
final class FocusTransactionTests: XCTestCase {
    // MARK: - .none (already frontmost)

    func testNoneModeDeliversWithoutFocusChange() {
        let workspace = FakeWorkspace(frontmostPID: 42)
        var delivered = false
        let outcome = FocusTransaction(workspace: workspace).run(targetPID: 42, mode: .none) {
            delivered = true
        }
        XCTAssertTrue(delivered)
        XCTAssertFalse(outcome.focusChanged)
        XCTAssertFalse(outcome.focusRestored)
        XCTAssertTrue(outcome.targetBecameFrontmost, "target was still frontmost after delivery")
        XCTAssertTrue(workspace.activatedPIDs.isEmpty, "no activation in background mode")
    }

    func testNoneModeReportsTargetLostFrontmost() {
        // The user stole focus during delivery: still-frontmost check fails.
        let workspace = FakeWorkspace(frontmostPID: 42)
        let outcome = FocusTransaction(workspace: workspace).run(targetPID: 42, mode: .none) {
            workspace.frontmostPID = 99 // user app grabbed the foreground mid-delivery
        }
        XCTAssertFalse(outcome.targetBecameFrontmost)
    }

    // MARK: - .activateRestore (allow-brief-focus)

    func testActivateRestoreRecordsActivatesDeliversRestores() {
        let workspace = FakeWorkspace(frontmostPID: 99, frontmostAppName: "UserApp")
        var delivered = false
        let outcome = FocusTransaction(workspace: workspace).run(targetPID: 42, mode: .activateRestore) {
            delivered = true
            XCTAssertEqual(workspace.frontmostPID, 42, "target is frontmost during delivery")
        }
        XCTAssertTrue(delivered)
        XCTAssertTrue(outcome.focusChanged)
        XCTAssertTrue(outcome.targetBecameFrontmost)
        XCTAssertTrue(outcome.focusRestored)
        XCTAssertEqual(outcome.priorFrontmostPID, 99)
        // Recorded the focused element, activated the target, restored (re-activated prior).
        XCTAssertEqual(workspace.recordCount, 1)
        XCTAssertEqual(workspace.activatedPIDs, [42, 99])
        XCTAssertEqual(workspace.restoredTokens.count, 1)
        XCTAssertEqual(workspace.frontmostPID, 99, "prior foreground restored")
    }

    func testActivateRestoreDoesNotDeliverWhenTargetNeverBecomesFrontmost() {
        let workspace = FakeWorkspace(frontmostPID: 99)
        workspace.activationBringsFrontmost = false // activation fails to foreground the target
        workspace.axRaiseBringsFrontmost = false    // the AX fallback also cannot foreground it
        var delivered = false
        let outcome = fastTransaction(workspace).run(targetPID: 42, mode: .activateRestore) {
            delivered = true
        }
        XCTAssertFalse(delivered, "never deliver input when the target did not become frontmost")
        XCTAssertFalse(outcome.delivered)
        XCTAssertFalse(outcome.targetBecameFrontmost)
        XCTAssertTrue(outcome.focusChanged, "we still attempted (and must restore) focus")
        XCTAssertEqual(workspace.axRaisedPIDs, [42], "FIX B: the AX fallback is attempted when activation fails")
    }

    // MARK: - FIX B: AX foreground fallback decision (activate-failed → try-AX → re-check)

    /// A FocusTransaction with an injected instant clock so the bounded waits do not really
    /// sleep (the `FakeWorkspace` is synchronous, so activate/raise take effect at once).
    private func fastTransaction(_ workspace: WorkspaceControlling) -> FocusTransaction {
        var fakeNow = 0.0
        return FocusTransaction(
            workspace: workspace,
            activationDeadline: 0.6,
            activationPoll: 0.02,
            sleep: { fakeNow += $0 },
            now: { fakeNow }
        )
    }

    func testActivationFailsThenAXFallbackForegroundsAndDelivers() {
        // Decision: activate() did not foreground the target → try the AX raise → re-check
        // frontmost → it worked → deliver.
        let workspace = FakeWorkspace(frontmostPID: 99)
        workspace.activationBringsFrontmost = false // NSRunningApplication.activate did not foreground
        workspace.axRaiseBringsFrontmost = true     // the AX kAXFrontmost / raise fallback did
        var delivered = false
        let outcome = fastTransaction(workspace).run(targetPID: 42, mode: .activateLeave) {
            delivered = true
            XCTAssertEqual(workspace.frontmostPID, 42, "target is frontmost via the AX fallback")
        }
        XCTAssertTrue(delivered, "AX fallback foregrounded the target, so input is delivered")
        XCTAssertTrue(outcome.delivered)
        XCTAssertTrue(outcome.targetBecameFrontmost)
        XCTAssertEqual(workspace.activatedPIDs, [42], "activation is attempted first")
        XCTAssertEqual(workspace.axRaisedPIDs, [42], "the AX raise fallback is tried after activation fails")
    }

    func testActivationSuccessSkipsAXFallback() {
        // When activate() foregrounds the target, the AX fallback must NOT be attempted.
        let workspace = FakeWorkspace(frontmostPID: 99) // activationBringsFrontmost defaults true
        let outcome = fastTransaction(workspace).run(targetPID: 42, mode: .activateLeave) {}
        XCTAssertTrue(outcome.targetBecameFrontmost)
        XCTAssertTrue(workspace.axRaisedPIDs.isEmpty, "no AX fallback needed when activation foregrounded the target")
    }

    func testActivateRestoreReportsRestoreFailure() {
        let workspace = FakeWorkspace(frontmostPID: 99)
        workspace.restoreReturns = false
        let outcome = FocusTransaction(workspace: workspace).run(targetPID: 42, mode: .activateRestore) {}
        XCTAssertFalse(outcome.focusRestored)
    }

    // MARK: - Finding A: RESTORE must be symmetric with the forward AX raise

    func testActivateRestoreUsesAXRaiseToRestorePriorWhenActivateCannotForeground() {
        // Forward: activate() cannot foreground the target, but the AX raise does — so input is
        // delivered. Restore: a bare activate(prior) also cannot foreground the user's app (the
        // helper is still non-frontmost), so the restore must ALSO fall back to the AX raise.
        // focusRestored is only reported once the prior is truly frontmost again.
        let workspace = FakeWorkspace(frontmostPID: 99)
        workspace.activationBringsFrontmost = false // neither activate() foregrounds anything
        workspace.axRaiseBringsFrontmost = true     // the AX raise foregrounds whatever it targets
        var delivered = false
        let outcome = fastTransaction(workspace).run(targetPID: 42, mode: .activateRestore) {
            delivered = true
        }
        XCTAssertTrue(delivered, "the AX raise foregrounded the target, so input was delivered")
        XCTAssertTrue(outcome.targetBecameFrontmost)
        XCTAssertEqual(workspace.axRaisedPIDs, [42, 99], "the AX raise is used for BOTH the target and the restore")
        XCTAssertEqual(workspace.frontmostPID, 99, "the user's prior app is truly frontmost again")
        XCTAssertTrue(outcome.focusRestored, "focusRestored reflects the real frontmost==prior recheck")
    }

    func testActivateRestoreReportsNotRestoredWhenPriorCannotRegainForeground() {
        // The target is foregrounded (via the AX raise) and input delivered, but NEITHER
        // activate() NOR the AX raise can bring the user's prior app back. focusRestored MUST be
        // false — the target is left frontmost — and must NOT be masked true by a kAXFocused set
        // that succeeds against the (background) prior element.
        let workspace = SelectiveRaiseWorkspace(frontmostPID: 99, raisablePID: 42)
        workspace.restoreReturns = true // the element restore "succeeds" on a background element
        var delivered = false
        let outcome = fastTransaction(workspace).run(targetPID: 42, mode: .activateRestore) {
            delivered = true
        }
        XCTAssertTrue(delivered, "the target was raised, so input was delivered")
        XCTAssertTrue(outcome.targetBecameFrontmost)
        XCTAssertEqual(workspace.frontmostPID, 42, "the target is left frontmost; the prior never regained it")
        XCTAssertFalse(
            outcome.focusRestored,
            "focusRestored must be false when the prior never returns to the foreground, even though restoreFocusedElement succeeded"
        )
    }

    /// A workspace where `activate()` never foregrounds (the FIX B finding) and the AX raise
    /// foregrounds ONLY `raisablePID` — modelling "the target can be raised but the user's prior
    /// app cannot be brought back", so the restore's `frontmost == prior` recheck governs
    /// `focusRestored`.
    private final class SelectiveRaiseWorkspace: WorkspaceControlling {
        var frontmostPID: pid_t?
        var frontmostAppName: String?
        let raisablePID: pid_t
        var restoreReturns = true
        private(set) var axRaisedPIDs: [pid_t] = []

        init(frontmostPID: pid_t?, raisablePID: pid_t) {
            self.frontmostPID = frontmostPID
            self.raisablePID = raisablePID
        }

        func activate(pid: pid_t) -> Bool { false }
        func raiseViaAccessibility(pid: pid_t) -> Bool {
            axRaisedPIDs.append(pid)
            if pid == raisablePID { frontmostPID = pid; return true }
            return true // the AX call "succeeds" but does not foreground a non-raisable app
        }
        func recordFocusedElement() -> FocusedElementToken? { FocusedElementToken(payload: "focused") }
        func restoreFocusedElement(_ token: FocusedElementToken) -> Bool { restoreReturns }
    }

    // MARK: - .activateLeave (foreground-takeover)

    // MARK: - Asynchronous activation (bounded wait)

    /// A workspace whose `activate()` only makes the target frontmost after `delayReads`
    /// subsequent `frontmostPID` reads — modelling `NSRunningApplication.activate()`'s
    /// asynchronous behaviour, where frontmost is NOT updated by the next statement.
    private final class AsyncActivateWorkspace: WorkspaceControlling {
        private var current: pid_t?
        private var pendingTarget: pid_t?
        private var readsRemaining = 0
        private let delayReads: Int
        var frontmostAppName: String?

        init(frontmostPID: pid_t?, delayReads: Int) {
            self.current = frontmostPID
            self.delayReads = delayReads
        }

        var frontmostPID: pid_t? {
            if let target = pendingTarget {
                if readsRemaining <= 0 {
                    current = target
                    pendingTarget = nil
                } else {
                    readsRemaining -= 1
                }
            }
            return current
        }

        func activate(pid: pid_t) -> Bool {
            pendingTarget = pid
            readsRemaining = delayReads
            return true
        }

        /// This fake exercises the async `activate()` path only; the AX fallback is a no-op
        /// here (it neither foregrounds nor claims success), so these tests observe the
        /// activation timing in isolation.
        func raiseViaAccessibility(pid: pid_t) -> Bool { false }

        func recordFocusedElement() -> FocusedElementToken? { nil }
        func restoreFocusedElement(_ token: FocusedElementToken) -> Bool { true }
    }

    func testActivateWaitsForAsyncFrontmostBeforeDelivering() {
        let workspace = AsyncActivateWorkspace(frontmostPID: 99, delayReads: 3)
        var fakeNow = 0.0
        // Injected clock/sleep keep the poll deterministic and instant (no real Thread.sleep).
        let tx = FocusTransaction(
            workspace: workspace,
            activationDeadline: 1.0,
            activationPoll: 0.01,
            sleep: { fakeNow += $0 },
            now: { fakeNow }
        )
        var delivered = false
        let outcome = tx.run(targetPID: 42, mode: .activateLeave) { delivered = true }
        XCTAssertTrue(delivered, "delivery must wait until the async activation makes the target frontmost")
        XCTAssertTrue(outcome.targetBecameFrontmost)
        XCTAssertTrue(outcome.delivered)
    }

    func testActivateGivesUpAfterDeadlineWhenActivationNeverTakes() {
        // Activation is issued but the target never becomes frontmost within the deadline;
        // the transaction must fail safe (no delivery, targetBecameFrontmost=false).
        let workspace = AsyncActivateWorkspace(frontmostPID: 99, delayReads: 10_000)
        var fakeNow = 0.0
        let tx = FocusTransaction(
            workspace: workspace,
            activationDeadline: 0.1,
            activationPoll: 0.01,
            sleep: { fakeNow += $0 },
            now: { fakeNow }
        )
        var delivered = false
        let outcome = tx.run(targetPID: 42, mode: .activateLeave) { delivered = true }
        XCTAssertFalse(delivered, "never deliver when activation did not foreground the target in time")
        XCTAssertFalse(outcome.targetBecameFrontmost)
    }

    func testActivateLeaveActivatesAndDoesNotRestore() {
        let workspace = FakeWorkspace(frontmostPID: 99)
        var delivered = false
        let outcome = FocusTransaction(workspace: workspace).run(targetPID: 42, mode: .activateLeave) {
            delivered = true
        }
        XCTAssertTrue(delivered)
        XCTAssertTrue(outcome.focusChanged)
        XCTAssertTrue(outcome.targetBecameFrontmost)
        XCTAssertFalse(outcome.focusRestored, "takeover leaves the target activated")
        XCTAssertEqual(workspace.recordCount, 0, "no need to record focus when not restoring")
        XCTAssertEqual(workspace.activatedPIDs, [42])
        XCTAssertEqual(workspace.frontmostPID, 42, "target left activated")
    }
}
