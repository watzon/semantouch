import XCTest
import ComputerUseCore
@testable import CursorOverlay

/// Lifecycle goldens for the controller over a fake presenter. No AppKit.
/// The overlay APPEARS on the first pointer-kind action, PERSISTS (idle but
/// visible) between actions and through interruption, HIDES after 30 s of true
/// idle via an injectable cleanup scheduler, and HIDES immediately on explicit teardown.
final class CursorControllerTests: XCTestCase {

    private func makeController(
        presenter: FakeCursorPresenter,
        preference: CursorPreference = .on,
        idleCleanupScheduler: CursorIdleCleanupScheduling = FakeIdleCleanupScheduler(),
        idleCleanupTimeout: TimeInterval = CursorController.defaultIdleCleanupTimeout
    ) -> (CursorController, CursorAnimator, FakeIdleCleanupScheduler?) {
        let animator = CursorAnimator()
        let controller = CursorController(
            presenter: presenter,
            animator: animator,
            preference: preference,
            idleCleanupScheduler: idleCleanupScheduler,
            idleCleanupTimeout: idleCleanupTimeout
        )
        return (controller, animator, idleCleanupScheduler as? FakeIdleCleanupScheduler)
    }

    // MARK: First-show arming (pointer-kind vs keyboard-only)

    func testFirstPointerActionShows() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 50, y: 60), pointerKind: true)

        XCTAssertEqual(presenter.showCount, 1)
        XCTAssertEqual(presenter.updateCount, 1)
        XCTAssertEqual(presenter.lastUpdate?.panelFrame, .fixtureWindow)
        XCTAssertEqual(presenter.lastUpdate?.cursorInPanel, Point(x: 50, y: 60))
        XCTAssertEqual(presenter.lastUpdate?.visualState, .pressed)
    }

    func testKeyboardOnlyActionDoesNotShow() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        // A keyboard-only (non-pointer) action before any pointer action reflects nothing.
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .progress, pointerKind: false)

        XCTAssertEqual(presenter.calls.count, 0)
    }

    func testKeyboardThenPointerShowsOnThePointerAction() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        // A preceding keyboard action does NOT show...
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .progress, pointerKind: false)
        XCTAssertEqual(presenter.showCount, 0)

        // ...but a later pointer-kind action (click) does.
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 10, y: 10), pointerKind: true)
        XCTAssertEqual(presenter.showCount, 1)
        XCTAssertEqual(presenter.lastUpdate?.visualState, .pressed)
    }

    func testKeyboardActionReflectsOnceActivated() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        // Activate with a pointer action, then a keyboard action updates (no re-show).
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 10, y: 10), pointerKind: true)
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .progress, progress: 0.4, pointerKind: false)

        XCTAssertEqual(presenter.showCount, 1)                 // still shown exactly once
        XCTAssertEqual(presenter.updateCount, 2)               // keyboard action DID reflect
        XCTAssertEqual(presenter.lastUpdate?.visualState, .progress(fraction: 0.4))
    }

    func testLocationlessActionKeepsLastPointOnActiveSession() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        // An independent pointer stays where it last acted: a location-less action
        // (keyboard progress, an unresolvable semantic frame) on an already-visible
        // overlay must NOT yank the cursor to the window centre.
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 50, y: 60), pointerKind: true)
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .progress, progress: 0.2, pointerKind: false)

        XCTAssertEqual(presenter.lastUpdate?.cursorInPanel, Point(x: 50, y: 60))
        XCTAssertEqual(presenter.lastUpdate?.visualState, .progress(fraction: 0.2))

        // A first show with no point still falls back to the plan's centre anchor.
        controller.endSession(sessionId: "s1")
        controller.reflect(sessionId: "s2", windowFrame: .fixtureWindow, action: .move, pointerKind: true)
        XCTAssertEqual(
            presenter.lastUpdate?.cursorInPanel,
            Point(x: Rect.fixtureWindow.width / 2, y: Rect.fixtureWindow.height / 2)
        )
    }

    func testShowUsesDeterministicIdentityColor() {
        let presenter = FakeCursorPresenter()
        let (controller, animator, _) = makeController(presenter: presenter)

        controller.reflect(sessionId: "s9", windowFrame: .fixtureWindow, action: .move, pointerKind: true)

        XCTAssertEqual(presenter.shownColors.first, CursorColor.identity(forSession: "s9", alpha: 0.95))
        // The animator adopted the same identity colour.
        XCTAssertEqual(animator.identityColor, CursorColor.identity(forSession: "s9", alpha: 0.95))
    }

    func testSecondReflectSameSessionDoesNotReshow() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .move, at: Point(x: 10, y: 10), pointerKind: true)
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 20, y: 20), pointerKind: true)

        XCTAssertEqual(presenter.showCount, 1)          // shown once
        XCTAssertEqual(presenter.updateCount, 2)        // updated twice
        XCTAssertEqual(presenter.lastUpdate?.visualState, .pressed)
    }

    func testSwitchingSessionsReshows() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .move, pointerKind: true)
        controller.reflect(sessionId: "s2", windowFrame: .fixtureWindow, action: .move, pointerKind: true)

        XCTAssertEqual(presenter.showCount, 2)
        XCTAssertEqual(presenter.shownColors.last, CursorColor.identity(forSession: "s2", alpha: 0.95))
    }

    // MARK: Persist across actions + through interruption (never hide per-action)

    func testFinishCompletedDropsToIdleWithoutHiding() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 40, y: 40), pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)

        XCTAssertEqual(presenter.hideCount, 0)
        XCTAssertEqual(presenter.lastUpdate?.visualState, .idle)
        // The idle cursor stays at the last action point.
        XCTAssertEqual(presenter.lastUpdate?.cursorInPanel, Point(x: 40, y: 40))
    }

    func testFinishInterruptedStaysVisible() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 15, y: 25), pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: true)

        // User-interruption does NOT hide — the cursor goes idle but stays visible.
        XCTAssertEqual(presenter.hideCount, 0)
        XCTAssertEqual(presenter.lastUpdate?.visualState, .idle)
        XCTAssertEqual(presenter.lastUpdate?.cursorInPanel, Point(x: 15, y: 25))

        // A later action for the same session updates the SAME overlay (no re-show).
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .move, at: Point(x: 30, y: 30), pointerKind: true)
        XCTAssertEqual(presenter.showCount, 1)
    }

    func testOverlayStaysVisibleAcrossManySequentialActions() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        // A pointer action shows the overlay, then N reflect/finish cycles (pointer AND
        // keyboard) never hide between actions.
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 1, y: 1), pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)
        for i in 0..<5 {
            controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .move, at: Point(x: Double(i), y: Double(i)), pointerKind: true)
            controller.finish(sessionId: "s1", interrupted: false)
            // Interleave a keyboard action too (activated → reflects).
            controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .progress, progress: 0.5, pointerKind: false)
            controller.finish(sessionId: "s1", interrupted: false)
        }

        XCTAssertEqual(presenter.showCount, 1)   // shown exactly once across all actions
        XCTAssertEqual(presenter.hideCount, 0)   // never hidden between actions
    }

    func testFinishForInactiveSessionDoesNothing() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        let before = presenter.calls.count
        controller.finish(sessionId: "s2", interrupted: true)
        XCTAssertEqual(presenter.calls.count, before)
    }

    // MARK: Teardown hides (end_app_session / shutdown)

    func testEndSessionHidesActiveOverlay() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        controller.endSession(sessionId: "s1")
        XCTAssertEqual(presenter.hideCount, 1)
    }

    func testEndSessionDisarmsFirstShow() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        // Activate + tear down; a subsequent keyboard-only action must NOT re-show (the
        // session's first-show arming was cleared by endSession).
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        controller.endSession(sessionId: "s1")
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .progress, pointerKind: false)
        XCTAssertEqual(presenter.showCount, 1)   // only the original show; no re-show
    }

    func testEndSessionForInactiveSessionIsNoop() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        let before = presenter.calls.count
        controller.endSession(sessionId: "s2")
        XCTAssertEqual(presenter.calls.count, before)
    }

    func testShutdownHidesAndDisarmsAllSessions() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        controller.shutdown()
        XCTAssertEqual(presenter.hideCount, 1)

        // After a full teardown every session is disarmed: a keyboard-only action stays inert
        // and a fresh pointer action must re-show from scratch.
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .progress, pointerKind: false)
        XCTAssertEqual(presenter.showCount, 1)
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        XCTAssertEqual(presenter.showCount, 2)
    }

    // MARK: Turn end (notifications/turn-ended) — decorative only

    /// `endTurn` hides an active cursor and disarms first-show, but does NOT clear stored
    /// window geometry or end app sessions (geometry still usable for a later re-show).
    func testEndTurnHidesAndDisarmsPreservingWindowGeometry() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        controller.reflect(
            sessionId: "s1",
            windowFrame: .fixtureWindow,
            action: .press,
            at: Point(x: 30, y: 40),
            pointerKind: true
        )
        XCTAssertEqual(presenter.showCount, 1)
        XCTAssertEqual(presenter.hideCount, 0)

        controller.endTurn()
        XCTAssertEqual(presenter.hideCount, 1)

        // First-show is disarmed: a keyboard-only action must NOT re-show.
        controller.reflect(
            sessionId: "s1",
            windowFrame: .fixtureWindow,
            action: .progress,
            pointerKind: false
        )
        XCTAssertEqual(presenter.showCount, 1)

        // A later pointer action re-shows. Stored geometry was preserved by endTurn, so a
        // noteWindowFrame follow after re-show still works (session lifecycle intact).
        controller.reflect(
            sessionId: "s1",
            windowFrame: .fixtureWindow,
            action: .press,
            at: Point(x: 10, y: 10),
            pointerKind: true
        )
        XCTAssertEqual(presenter.showCount, 2)
        controller.noteWindowFrame(sessionId: "s1", .fixtureWindowMoved)
        XCTAssertEqual(presenter.lastUpdate?.panelFrame, .fixtureWindowMoved)
        XCTAssertEqual(presenter.lastUpdate?.cursorInPanel, Point(x: 10, y: 10))
    }

    func testEndTurnIsInertWhenDisabled() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter, preference: .off)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        controller.endTurn()
        XCTAssertEqual(presenter.calls.count, 0)
    }

    func testEndTurnIsInertWhenHeadless() {
        let presenter = FakeCursorPresenter(canPresent: false)
        let (controller, _, _) = makeController(presenter: presenter, preference: .on)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        controller.endTurn()
        XCTAssertEqual(presenter.calls.count, 0)
    }

    func testEndTurnWithNoActiveOverlayIsSafe() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        // Geometry recorded but never shown — endTurn must not call the presenter.
        controller.noteWindowFrame(sessionId: "s1", .fixtureWindow)
        controller.endTurn()
        XCTAssertEqual(presenter.calls.count, 0)
    }

    // MARK: Window-move follow

    func testNoteWindowFrameFollowsMoveForActiveSession() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 30, y: 30), pointerKind: true)
        controller.noteWindowFrame(sessionId: "s1", .fixtureWindowMoved)

        XCTAssertEqual(presenter.lastUpdate?.panelFrame, .fixtureWindowMoved)
        // The panel moved but the drawn state/point are preserved.
        XCTAssertEqual(presenter.lastUpdate?.cursorInPanel, Point(x: 30, y: 30))
        XCTAssertEqual(presenter.lastUpdate?.visualState, .pressed)
    }

    func testNoteWindowFrameBeforeAnyReflectDoesNotPresent() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        // get_app_state records geometry but must never bring the overlay on screen.
        controller.noteWindowFrame(sessionId: "s1", .fixtureWindow)
        XCTAssertEqual(presenter.calls.count, 0)
    }

    func testNoteWindowFrameForInactiveSessionDoesNotMoveOverlay() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        let before = presenter.calls.count
        controller.noteWindowFrame(sessionId: "s2", .fixtureWindowMoved)
        XCTAssertEqual(presenter.calls.count, before)
    }

    // MARK: Hide/dim preference (SEMANTOUCH_CURSOR)

    func testPreferenceOffIsFullyInert() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter, preference: .off)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: true)
        controller.endSession(sessionId: "s1")
        controller.shutdown()
        controller.noteWindowFrame(sessionId: "s1", .fixtureWindowMoved)

        XCTAssertEqual(presenter.calls.count, 0)
    }

    func testPreferenceDimUsesTranslucentAlpha() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter, preference: .dim)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        XCTAssertEqual(presenter.shownColors.first?.alpha, 0.5)
    }

    func testHeadlessPresenterNeverPresents() {
        // GUI unavailable (headless/mcp): even preference `on` must create nothing.
        let presenter = FakeCursorPresenter(canPresent: false)
        let (controller, _, _) = makeController(presenter: presenter, preference: .on)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: true)
        controller.shutdown()
        XCTAssertEqual(presenter.calls.count, 0)
    }

    // MARK: Degenerate window

    func testDegenerateWindowHidesRatherThanPresenting() {
        let presenter = FakeCursorPresenter()
        let (controller, _, _) = makeController(presenter: presenter)

        controller.reflect(sessionId: "s1", windowFrame: Rect(x: 0, y: 0, width: 0, height: 0), action: .press, pointerKind: true)
        XCTAssertEqual(presenter.updateCount, 0)
        XCTAssertEqual(presenter.hideCount, 1)
    }

    // MARK: Preference resolution from environment

    func testPreferenceFromEnvironment() {
        XCTAssertEqual(CursorPreference.fromEnvironment([:]), .on)                       // default
        XCTAssertEqual(CursorPreference.fromEnvironment(["SEMANTOUCH_CURSOR": "off"]), .off)
        XCTAssertEqual(CursorPreference.fromEnvironment(["SEMANTOUCH_CURSOR": "dim"]), .dim)
        XCTAssertEqual(CursorPreference.fromEnvironment(["SEMANTOUCH_CURSOR": "ON"]), .on)   // case-insensitive
        XCTAssertEqual(CursorPreference.fromEnvironment(["SEMANTOUCH_CURSOR": "weird"]), .on) // unknown → default
    }

    func testDisabledFactoryNeverPresents() {
        let controller = CursorController.disabled()
        // No presenter to inspect, but it must not crash and must accept the full lifecycle.
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)
        controller.endSession(sessionId: "s1")
        controller.shutdown()
        controller.synchronize()
    }

    // MARK: Idle cleanup (injectable scheduler; no wall clock)

    func testFinishSchedulesDefaultThirtySecondIdleCleanup() {
        let presenter = FakeCursorPresenter()
        let scheduler = FakeIdleCleanupScheduler()
        let (controller, _, fake) = makeController(presenter: presenter, idleCleanupScheduler: scheduler)
        XCTAssertTrue(fake === scheduler)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 12, y: 18), pointerKind: true)
        XCTAssertEqual(scheduler.liveCount, 0)

        controller.finish(sessionId: "s1", interrupted: false)
        XCTAssertEqual(presenter.hideCount, 0)
        XCTAssertEqual(presenter.lastUpdate?.visualState, .idle)
        XCTAssertEqual(scheduler.liveCount, 1)
        XCTAssertEqual(scheduler.lastDelay, CursorController.defaultIdleCleanupTimeout)
        XCTAssertEqual(scheduler.lastDelay, 30)
    }

    func testIdleCleanupHidesAfterTimeoutWhenStillIdle() {
        let presenter = FakeCursorPresenter()
        let scheduler = FakeIdleCleanupScheduler()
        let (controller, _, _) = makeController(presenter: presenter, idleCleanupScheduler: scheduler)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 5, y: 5), pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)
        XCTAssertEqual(presenter.hideCount, 0)

        XCTAssertTrue(scheduler.fireNext())
        XCTAssertEqual(presenter.hideCount, 1)
        XCTAssertEqual(scheduler.liveCount, 0)
    }

    func testReflectAfterFinishCancelsIdleCleanupAndPersistsPosition() {
        let presenter = FakeCursorPresenter()
        let scheduler = FakeIdleCleanupScheduler()
        let (controller, _, _) = makeController(presenter: presenter, idleCleanupScheduler: scheduler)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 40, y: 50), pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)
        XCTAssertEqual(scheduler.liveCount, 1)

        // Next tool call cancels the idle timer and keeps the same overlay identity.
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .move, at: Point(x: 70, y: 80), pointerKind: true)
        XCTAssertEqual(scheduler.liveCount, 0)
        XCTAssertEqual(presenter.showCount, 1)
        XCTAssertEqual(presenter.hideCount, 0)
        XCTAssertEqual(presenter.lastUpdate?.cursorInPanel, Point(x: 70, y: 80))

        // A stale fire of the cancelled token must not hide.
        XCTAssertFalse(scheduler.fireNext())
        XCTAssertEqual(presenter.hideCount, 0)
    }

    func testSuccessiveFinishReschedulesIdleCleanup() {
        let presenter = FakeCursorPresenter()
        let scheduler = FakeIdleCleanupScheduler()
        let (controller, _, _) = makeController(presenter: presenter, idleCleanupScheduler: scheduler)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 1, y: 1), pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)
        XCTAssertEqual(scheduler.scheduledDelays.count, 1)
        XCTAssertEqual(scheduler.liveCount, 1)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 2, y: 2), pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)
        XCTAssertEqual(scheduler.scheduledDelays.count, 2)
        XCTAssertEqual(scheduler.liveCount, 1)
        XCTAssertEqual(scheduler.lastDelay, 30)

        // Only the latest schedule is live; firing once hides, a second fire is empty.
        XCTAssertTrue(scheduler.fireNext())
        XCTAssertEqual(presenter.hideCount, 1)
        XCTAssertFalse(scheduler.fireNext())
        XCTAssertEqual(presenter.hideCount, 1)
    }

    func testNoteWindowFrameWhileIdleReschedulesCleanup() {
        let presenter = FakeCursorPresenter()
        let scheduler = FakeIdleCleanupScheduler()
        let (controller, _, _) = makeController(presenter: presenter, idleCleanupScheduler: scheduler)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 20, y: 20), pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)
        XCTAssertEqual(scheduler.scheduledDelays.count, 1)

        controller.noteWindowFrame(sessionId: "s1", .fixtureWindowMoved)
        XCTAssertEqual(scheduler.scheduledDelays.count, 2)
        XCTAssertEqual(scheduler.liveCount, 1)
        XCTAssertEqual(presenter.lastUpdate?.panelFrame, .fixtureWindowMoved)
        XCTAssertEqual(presenter.lastUpdate?.cursorInPanel, Point(x: 20, y: 20))
        XCTAssertEqual(presenter.lastUpdate?.visualState, .idle)
        XCTAssertEqual(presenter.hideCount, 0)

        XCTAssertTrue(scheduler.fireNext())
        XCTAssertEqual(presenter.hideCount, 1)
    }

    func testStaleIdleCleanupDoesNotHideAfterReflect() {
        let presenter = FakeCursorPresenter()
        let scheduler = FakeIdleCleanupScheduler()
        let (controller, _, _) = makeController(presenter: presenter, idleCleanupScheduler: scheduler)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 9, y: 9), pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)
        let firstGenerationPending = scheduler.pending
        XCTAssertEqual(firstGenerationPending.count, 1)

        // Capture and later force-fire the original work even after cancellation, proving
        // generation isolation (not only token cancel) protects the active overlay.
        let staleWork = firstGenerationPending[0].work
        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .move, at: Point(x: 11, y: 11), pointerKind: true)
        XCTAssertEqual(presenter.hideCount, 0)
        XCTAssertEqual(presenter.showCount, 1)

        staleWork()
        XCTAssertEqual(presenter.hideCount, 0)
        XCTAssertEqual(presenter.lastUpdate?.cursorInPanel, Point(x: 11, y: 11))
    }

    func testSessionSwitchInvalidatesPreviousIdleCleanup() {
        let presenter = FakeCursorPresenter()
        let scheduler = FakeIdleCleanupScheduler()
        let (controller, _, _) = makeController(presenter: presenter, idleCleanupScheduler: scheduler)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 3, y: 3), pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)
        let s1Work = scheduler.pending[0].work

        // Switch owner: s2 acquires the overlay. Old s1 cleanup must not hide s2.
        controller.reflect(sessionId: "s2", windowFrame: .fixtureWindow, action: .press, at: Point(x: 4, y: 4), pointerKind: true)
        XCTAssertEqual(presenter.showCount, 2)
        XCTAssertEqual(presenter.hideCount, 0)
        XCTAssertEqual(scheduler.liveCount, 0)

        s1Work()
        XCTAssertEqual(presenter.hideCount, 0)
        XCTAssertEqual(presenter.lastUpdate?.cursorInPanel, Point(x: 4, y: 4))

        controller.finish(sessionId: "s2", interrupted: false)
        XCTAssertEqual(scheduler.liveCount, 1)
        XCTAssertTrue(scheduler.fireNext())
        XCTAssertEqual(presenter.hideCount, 1)
    }

    func testEndSessionCancelsPendingIdleCleanup() {
        let presenter = FakeCursorPresenter()
        let scheduler = FakeIdleCleanupScheduler()
        let (controller, _, _) = makeController(presenter: presenter, idleCleanupScheduler: scheduler)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)
        XCTAssertEqual(scheduler.liveCount, 1)

        controller.endSession(sessionId: "s1")
        XCTAssertEqual(presenter.hideCount, 1)
        XCTAssertEqual(scheduler.liveCount, 0)

        // Stale fire after explicit teardown is harmless.
        XCTAssertFalse(scheduler.fireNext())
        XCTAssertEqual(presenter.hideCount, 1)
    }

    func testEndTurnCancelsPendingIdleCleanup() {
        let presenter = FakeCursorPresenter()
        let scheduler = FakeIdleCleanupScheduler()
        let (controller, _, _) = makeController(presenter: presenter, idleCleanupScheduler: scheduler)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)
        XCTAssertEqual(scheduler.liveCount, 1)

        controller.endTurn()
        XCTAssertEqual(presenter.hideCount, 1)
        XCTAssertEqual(scheduler.liveCount, 0)
        XCTAssertFalse(scheduler.fireNext())
        XCTAssertEqual(presenter.hideCount, 1)
    }

    func testShutdownCancelsPendingIdleCleanup() {
        let presenter = FakeCursorPresenter()
        let scheduler = FakeIdleCleanupScheduler()
        let (controller, _, _) = makeController(presenter: presenter, idleCleanupScheduler: scheduler)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)
        XCTAssertEqual(scheduler.liveCount, 1)

        controller.shutdown()
        XCTAssertEqual(presenter.hideCount, 1)
        XCTAssertEqual(scheduler.liveCount, 0)
        XCTAssertFalse(scheduler.fireNext())
        XCTAssertEqual(presenter.hideCount, 1)
    }

    func testDisabledNeverSchedulesIdleCleanup() {
        let presenter = FakeCursorPresenter()
        let scheduler = FakeIdleCleanupScheduler()
        let (controller, _, _) = makeController(
            presenter: presenter,
            preference: .off,
            idleCleanupScheduler: scheduler
        )

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)
        controller.noteWindowFrame(sessionId: "s1", .fixtureWindowMoved)
        controller.endTurn()
        controller.shutdown()

        XCTAssertEqual(presenter.calls.count, 0)
        XCTAssertEqual(scheduler.scheduledDelays.count, 0)
        XCTAssertEqual(scheduler.liveCount, 0)
    }

    func testHeadlessNeverSchedulesIdleCleanup() {
        let presenter = FakeCursorPresenter(canPresent: false)
        let scheduler = FakeIdleCleanupScheduler()
        let (controller, _, _) = makeController(
            presenter: presenter,
            preference: .on,
            idleCleanupScheduler: scheduler
        )

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: false)
        controller.endSession(sessionId: "s1")

        XCTAssertEqual(presenter.calls.count, 0)
        XCTAssertEqual(scheduler.scheduledDelays.count, 0)
    }

    func testInterruptedFinishAlsoArmsIdleCleanup() {
        let presenter = FakeCursorPresenter()
        let scheduler = FakeIdleCleanupScheduler()
        let (controller, _, _) = makeController(presenter: presenter, idleCleanupScheduler: scheduler)

        controller.reflect(sessionId: "s1", windowFrame: .fixtureWindow, action: .press, at: Point(x: 8, y: 8), pointerKind: true)
        controller.finish(sessionId: "s1", interrupted: true)
        XCTAssertEqual(presenter.hideCount, 0)
        XCTAssertEqual(presenter.lastUpdate?.visualState, .idle)
        XCTAssertEqual(scheduler.liveCount, 1)
        XCTAssertEqual(scheduler.lastDelay, 30)

        XCTAssertTrue(scheduler.fireNext())
        XCTAssertEqual(presenter.hideCount, 1)
    }
}
