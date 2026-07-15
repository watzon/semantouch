import XCTest
import CoreGraphics
import ComputerUseCore
@testable import ActionEngine

/// End-to-end fallback execution over fakes (§16): the validation order, the interference
/// decision, focus transactions, coordinate mapping, target verification, and interruption.
final class FallbackExecutorTests: XCTestCase {
    private func executor() -> ActionExecutor { ActionExecutor() }

    /// A ready environment: session s1 @ revision 1, owned by pid 42, with geometry.
    private func readyEnvironment(
        frontmostPID: pid_t? = nil,
        geometry: WindowGeometry? = fixtureGeometry()
    ) -> FakeFallbackEnvironment {
        let workspace = FakeWorkspace(frontmostPID: frontmostPID, frontmostAppName: "UserApp")
        let env = FakeFallbackEnvironment(workspace: workspace)
        env.revisions["s1"] = 1
        env.pids["s1"] = 42
        if let geometry { env.geometries["s1"] = geometry }
        return env
    }

    private func pressA() -> FallbackAction {
        .pressKey(chords: [KeyChord(flags: [], keyCode: 0x00)])
    }

    // MARK: - Validation order

    func testPolicyDenialWinsBeforeDelivery() {
        let env = readyEnvironment(frontmostPID: 42)
        env.denyReason = .appDenied
        XCTAssertThrowsError(try executor().executeFallback(pressA(), target: fallbackTarget(), environment: env)) { error in
            guard case let CUError.policyDenied(reason, _, tool) = error else { return XCTFail("expected policyDenied") }
            XCTAssertEqual(reason, .appDenied)
            XCTAssertEqual(tool, "press_key")
        }
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty, "no input when policy denies")
    }

    func testPolicyResolutionErrorPropagates() {
        let env = readyEnvironment(frontmostPID: 42)
        env.policyError = CUError.appNotFound(query: "Ghost")
        XCTAssertThrowsError(try executor().executeFallback(pressA(), target: fallbackTarget(app: "Ghost"), environment: env)) { error in
            guard case CUError.appNotFound = error else { return XCTFail("expected appNotFound") }
        }
    }

    func testUnknownSessionYieldsStaleRevisionNullCurrent() {
        let env = readyEnvironment(frontmostPID: 42)
        env.revisions.removeValue(forKey: "s1")
        XCTAssertThrowsError(try executor().executeFallback(pressA(), target: fallbackTarget(), environment: env)) { error in
            guard case let CUError.staleRevision(_, _, current) = error else { return XCTFail("expected staleRevision") }
            XCTAssertNil(current)
        }
    }

    func testForeignSessionIsPolicyDenied() {
        let env = readyEnvironment(frontmostPID: 42)
        env.sessionOwnedByAppResult = false
        XCTAssertThrowsError(try executor().executeFallback(pressA(), target: fallbackTarget(), environment: env)) { error in
            guard case let CUError.policyDenied(reason, _, _) = error else { return XCTFail("expected policyDenied") }
            XCTAssertEqual(reason, .appDenied)
        }
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
    }

    func testMissingTargetPIDYieldsWindowNotFound() {
        let env = readyEnvironment(frontmostPID: 42)
        env.pids.removeValue(forKey: "s1")
        XCTAssertThrowsError(try executor().executeFallback(pressA(), target: fallbackTarget(), environment: env)) { error in
            guard case CUError.windowNotFound = error else { return XCTFail("expected windowNotFound") }
        }
    }

    // MARK: - Interference modes

    func testBackgroundOnlyPointerNotFrontmostReturnsFocusRequired() {
        // Pointer actions remain ineligible for the targeted lane: background-only +
        // non-frontmost still returns focus_required and posts nothing.
        let env = readyEnvironment(frontmostPID: 99) // user app frontmost, not the target
        let action = FallbackAction.coordinateClick(at: Point(x: 10, y: 20), space: .window, button: .left, modifiers: [], clickCount: 1)
        XCTAssertThrowsError(try executor().executeFallback(action, target: fallbackTarget(interference: .backgroundOnly), environment: env)) { error in
            guard case let CUError.focusRequired(app, frontmostApp) = error else { return XCTFail("expected focusRequired") }
            XCTAssertEqual(app, "computer-use-fixture")
            XCTAssertEqual(frontmostApp, "UserApp")
        }
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty, "pointer must not silently fall back to global delivery")
        XCTAssertTrue(env.fakeWorkspace.activatedPIDs.isEmpty, "never auto-escalates to focus")
    }

    // MARK: - Process-targeted keyboard delivery

    func testBackgroundOnlyKeyboardNotFrontmostUsesTargetedLane() throws {
        // Eligible background keys take the targeted lane without activation.
        let env = readyEnvironment(frontmostPID: 99) // user app frontmost, not the target
        let result = try executor().executeFallback(pressA(), target: fallbackTarget(interference: .backgroundOnly), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .keyboard)
        XCTAssertEqual(result.focusChanged, false, "targeted delivery never claims focus changed")
        XCTAssertEqual(result.focusRestored, false)
        XCTAssertEqual(result.targetVerified, false, "postToPid has no acknowledgement")
        XCTAssertTrue(result.warning?.contains("unconfirmed") ?? false)
        XCTAssertEqual(env.fakeSynthesizer.events, [
            .targetedKeyDown(0x00, [], 42),
            .targetedKeyUp(0x00, [], 42),
        ])
        XCTAssertTrue(env.fakeWorkspace.activatedPIDs.isEmpty, "no activation on the targeted lane")
        XCTAssertEqual(env.fakeWorkspace.frontmostPID, 99, "user foreground undisturbed")
    }

    func testBackgroundOnlyTypeTextNotFrontmostUsesTargetedLane() throws {
        let env = readyEnvironment(frontmostPID: 99)
        let result = try executor().executeFallback(.typeText("hi"), target: fallbackTarget(interference: .backgroundOnly), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.focusChanged, false)
        XCTAssertEqual(result.targetVerified, false)
        XCTAssertTrue(result.warning?.contains("unconfirmed") ?? false)
        XCTAssertEqual(env.fakeSynthesizer.events, [
            .targetedType("h", 42),
            .targetedType("i", 42),
        ])
        XCTAssertTrue(env.fakeWorkspace.activatedPIDs.isEmpty)
    }

    func testTargetedDeliveryConfirmedWhenElementFocused() throws {
        // Existing element-focused postcondition can confirm delivery for the targeted lane.
        let env = readyEnvironment(frontmostPID: 99)
        let element = FakeActionElement(settable: [AXActionName.focused])
        element.focusConfirmed = true
        env.elements["s1/e5"] = element
        let target = FallbackTarget(
            app: "computer-use-fixture",
            sessionId: "s1",
            interference: .backgroundOnly,
            revision: 1,
            elementId: "e5"
        )
        let result = try executor().executeFallback(pressA(), target: target, environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.elementFocused, true)
        XCTAssertEqual(result.targetVerified, true, "element-focused postcondition confirms delivery")
        XCTAssertEqual(result.focusChanged, false)
        XCTAssertNil(result.warning, "confirmed targeted delivery needs no unconfirmed warning")
        XCTAssertEqual(env.fakeSynthesizer.events, [
            .targetedKeyDown(0x00, [], 42),
            .targetedKeyUp(0x00, [], 42),
        ])
    }

    func testIneligibleSynthesizerDoesNotSilentlyFallBackGlobally() {
        // Without ProcessTargetedInputSynthesizer capability, keyboard stays focus_required —
        // never silently posts to the session tap into the frontmost (wrong) app.
        let workspace = FakeWorkspace(frontmostPID: 99, frontmostAppName: "UserApp")
        let env = FakeFallbackEnvironment(workspace: workspace, globalOnlySynthesizer: GlobalOnlyFakeSynthesizer())
        env.revisions["s1"] = 1
        env.pids["s1"] = 42
        env.geometries["s1"] = fixtureGeometry()
        XCTAssertThrowsError(try executor().executeFallback(pressA(), target: fallbackTarget(interference: .backgroundOnly), environment: env)) { error in
            guard case CUError.focusRequired = error else { return XCTFail("expected focusRequired") }
        }
        XCTAssertTrue(env.globalOnlySynthesizer?.events.isEmpty ?? false, "no global keyboard events posted")
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
        XCTAssertTrue(env.fakeWorkspace.activatedPIDs.isEmpty)
    }

    func testTargetedDeliveryPIDMismatchStopsFurtherPosts() throws {
        // Mid-delivery PID identity change: remaining chords are cancelled; no activation.
        let env = readyEnvironment(frontmostPID: 99)
        var emitted = 0
        env.fakeSynthesizer.onEmit = {
            emitted += 1
            if emitted == 2 {
                env.pids["s1"] = 999 // PID reuse / identity change
            }
        }
        let action = FallbackAction.pressKey(chords: [
            KeyChord(flags: [], keyCode: 0x00),
            KeyChord(flags: [], keyCode: 0x08),
            KeyChord(flags: [], keyCode: 0x09),
        ])
        let result = try executor().executeFallback(action, target: fallbackTarget(interference: .backgroundOnly), environment: env)
        XCTAssertEqual(result.status, .interrupted)
        XCTAssertEqual(result.targetVerified, false)
        XCTAssertEqual(result.focusChanged, false)
        XCTAssertEqual(env.fakeSynthesizer.events.count, 2, "remaining chords cancelled after PID mismatch")
        XCTAssertTrue(env.fakeWorkspace.activatedPIDs.isEmpty)
        XCTAssertTrue(
            (result.warning?.contains("process") ?? false) || (result.warning?.contains("identity") ?? false),
            "warning should describe process/identity loss"
        )
    }
    func testTargetedDeliveryTargetExitBeforePostPostsNothing() throws {
        // Target exit between decide and re-bind: second targetPID read is nil → post nothing.
        final class CountingPIDEnv: FallbackEnvironment {
            let base: FakeFallbackEnvironment
            private var pidReads = 0
            init(base: FakeFallbackEnvironment) { self.base = base }
            func policyCheck(app: String) throws -> PolicyDenyReason? { try base.policyCheck(app: app) }
            func currentRevision(sessionId: String) -> Int? { base.currentRevision(sessionId: sessionId) }
            func sessionOwnedByApp(sessionId: String, app: String) throws -> Bool {
                try base.sessionOwnedByApp(sessionId: sessionId, app: app)
            }
            func resolveElement(sessionId: String, elementId: String, revision: Int) throws -> ActionElement {
                try base.resolveElement(sessionId: sessionId, elementId: elementId, revision: revision)
            }
            func targetPID(sessionId: String) -> pid_t? {
                pidReads += 1
                // First read: decide. Second read: targeted re-bind → nil (target exited).
                if pidReads >= 2 { return nil }
                return base.targetPID(sessionId: sessionId)
            }
            func windowGeometry(sessionId: String) -> WindowGeometry? { base.windowGeometry(sessionId: sessionId) }
            func currentWindowFrame(sessionId: String) -> Rect? { base.currentWindowFrame(sessionId: sessionId) }
            var workspace: WorkspaceControlling { base.workspace }
            var synthesizer: InputSynthesizer { base.synthesizer }
            var interruption: InterruptionMonitoring { base.interruption }
        }

        let base = readyEnvironment(frontmostPID: 99)
        let env = CountingPIDEnv(base: base)
        let result = try executor().executeFallback(pressA(), target: fallbackTarget(interference: .backgroundOnly), environment: env)
        XCTAssertEqual(result.status, .interrupted)
        XCTAssertEqual(result.targetVerified, false)
        XCTAssertEqual(result.focusChanged, false)
        XCTAssertTrue(base.fakeSynthesizer.events.isEmpty, "target exit before post delivers nothing")
        XCTAssertTrue(base.fakeWorkspace.activatedPIDs.isEmpty)
    }

    func testTargetedInterruptionReleasesHeldModifiers() throws {
        // Interruption mid-chord sequence still cancels remaining units; the chord already
        // emitted released its own modifiers (KeyboardActions.emit is atomic per chord).
        let env = readyEnvironment(frontmostPID: 99)
        var emitted = 0
        env.fakeSynthesizer.onEmit = {
            emitted += 1
            // After the first full chord (modifier down, key down/up, modifier up = 4 events
            // for cmd+a), interrupt before the second chord.
            if emitted == 4 { env.monitor.observe(isOurs: false, at: 1.0) }
        }
        let action = FallbackAction.pressKey(chords: [
            KeyChord(flags: .maskCommand, keyCode: 0x00), // cmd+a
            KeyChord(flags: .maskCommand, keyCode: 0x08), // cmd+c — must not start
        ])
        let result = try executor().executeFallback(action, target: fallbackTarget(interference: .backgroundOnly), environment: env)
        XCTAssertEqual(result.status, .interrupted)
        XCTAssertEqual(result.focusChanged, false)
        XCTAssertEqual(result.targetVerified, false)
        // First chord fully released (left-Command down, a down, a up, left-Command up).
        XCTAssertEqual(env.fakeSynthesizer.events, [
            .targetedKeyDown(0x37, .maskCommand, 42),
            .targetedKeyDown(0x00, .maskCommand, 42),
            .targetedKeyUp(0x00, .maskCommand, 42),
            .targetedKeyUp(0x37, [], 42),
        ])
        XCTAssertTrue(env.fakeWorkspace.activatedPIDs.isEmpty)
    }

    func testForegroundBehaviorUnchangedUsesGlobalLane() throws {
        // Already-frontmost keyboard still uses the global synthesizer methods (not targeted).
        let env = readyEnvironment(frontmostPID: 42)
        let result = try executor().executeFallback(pressA(), target: fallbackTarget(interference: .backgroundOnly), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.targetVerified, true)
        XCTAssertEqual(env.fakeSynthesizer.events, [.keyDown(0x00, []), .keyUp(0x00, [])])
        XCTAssertFalse(env.fakeSynthesizer.events.contains { event in
            if case .targetedKeyDown = event { return true }
            if case .targetedKeyUp = event { return true }
            return false
        }, "frontmost delivery stays on the global lane")
    }

    func testBackgroundOnlyFrontmostDelivers() throws {
        let env = readyEnvironment(frontmostPID: 42) // target already frontmost
        let result = try executor().executeFallback(pressA(), target: fallbackTarget(interference: .backgroundOnly), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .keyboard)
        XCTAssertEqual(result.focusChanged, false)
        XCTAssertEqual(result.focusRestored, false)
        XCTAssertEqual(result.targetVerified, true)
        XCTAssertEqual(env.fakeSynthesizer.events, [.keyDown(0x00, []), .keyUp(0x00, [])])
        XCTAssertTrue(env.fakeWorkspace.activatedPIDs.isEmpty, "no activation when already frontmost")
    }

    func testAllowBriefFocusRunsTransaction() throws {
        let env = readyEnvironment(frontmostPID: 99)
        let result = try executor().executeFallback(pressA(), target: fallbackTarget(interference: .allowBriefFocus), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.focusChanged, true)
        XCTAssertEqual(result.focusRestored, true)
        XCTAssertEqual(result.targetVerified, true)
        XCTAssertEqual(env.fakeWorkspace.activatedPIDs, [42, 99], "activate target, then restore prior")
        XCTAssertFalse(env.fakeSynthesizer.events.isEmpty)
    }

    func testForegroundTakeoverActivatesAndLeaves() throws {
        let env = readyEnvironment(frontmostPID: 99)
        let result = try executor().executeFallback(pressA(), target: fallbackTarget(interference: .foregroundTakeover), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.focusChanged, true)
        XCTAssertEqual(result.focusRestored, false)
        XCTAssertEqual(result.targetVerified, true)
        XCTAssertEqual(env.fakeWorkspace.activatedPIDs, [42])
        XCTAssertEqual(env.fakeWorkspace.frontmostPID, 42, "target left activated")
    }

    func testBriefFocusActivationFailureRejectsWithoutDelivery() throws {
        let env = readyEnvironment(frontmostPID: 99)
        env.fakeWorkspace.activationBringsFrontmost = false
        env.fakeWorkspace.axRaiseBringsFrontmost = false // FIX B fallback also cannot foreground it
        let result = try executor().executeFallback(pressA(), target: fallbackTarget(interference: .allowBriefFocus), environment: env)
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.targetVerified, false)
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty, "never deliver input when the target cannot be foregrounded")
        XCTAssertEqual(env.fakeWorkspace.axRaisedPIDs, [42], "FIX B: the AX fallback is attempted before rejecting")
        XCTAssertNotNil(result.warning)
    }

    func testBriefFocusActivationFailsButAXFallbackForegroundsDelivers() throws {
        // FIX B: NSRunningApplication.activate() did not foreground the target, but the PUBLIC
        // Accessibility fallback (kAXFrontmost / raise) did — so input is delivered and the
        // action completes (never rejected when a public route foregrounds the target).
        let env = readyEnvironment(frontmostPID: 99)
        env.fakeWorkspace.activationBringsFrontmost = false
        env.fakeWorkspace.axRaiseBringsFrontmost = true
        let result = try executor().executeFallback(pressA(), target: fallbackTarget(interference: .allowBriefFocus), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.focusChanged, true)
        XCTAssertEqual(result.targetVerified, true)
        // FIX (finding A): the RESTORE is symmetric with the forward AX raise. A bare
        // activate(prior) cannot foreground the user's app from a non-frontmost helper, so the
        // restore also falls back to the AX raise (pid 99), which foregrounds it here.
        XCTAssertEqual(env.fakeWorkspace.axRaisedPIDs, [42, 99], "the AX fallback rescues foregrounding of BOTH the target and the restored prior")
        XCTAssertEqual(result.focusRestored, true, "the prior app truly regained the foreground via the AX raise")
        XCTAssertEqual(env.fakeWorkspace.frontmostPID, 99, "the user's prior app is frontmost again")
        XCTAssertFalse(env.fakeSynthesizer.events.isEmpty, "input delivered after the AX fallback foregrounded the target")
    }

    // MARK: - Interruption

    func testInterruptionDuringDeliveryReturnsInterrupted() throws {
        let env = readyEnvironment(frontmostPID: 42)
        // Interrupt after the first chord's two events; the executor arms the monitor.
        var emitted = 0
        env.fakeSynthesizer.onEmit = {
            emitted += 1
            if emitted == 2 { env.monitor.observe(isOurs: false, at: 1.0) }
        }
        let action = FallbackAction.pressKey(chords: [
            KeyChord(flags: [], keyCode: 0x00),
            KeyChord(flags: [], keyCode: 0x08),
            KeyChord(flags: [], keyCode: 0x09),
        ])
        let result = try executor().executeFallback(action, target: fallbackTarget(), environment: env)
        XCTAssertEqual(result.status, .interrupted)
        XCTAssertEqual(env.fakeSynthesizer.events.count, 2, "remaining chords were cancelled")
    }

    func testTargetLosesFrontmostMidDeliveryYieldsInterrupted() throws {
        // A self-activating app steals the foreground mid-delivery (no HID event, so the
        // interruption monitor cannot see it). Delivery must stop so the remaining keys never
        // land in the intruder, and the result is interrupted with targetVerified=false.
        let env = readyEnvironment(frontmostPID: 42) // target starts frontmost
        var emitted = 0
        env.fakeSynthesizer.onEmit = {
            emitted += 1
            if emitted == 2 { env.fakeWorkspace.frontmostPID = 99 } // intruder takes the foreground
        }
        let action = FallbackAction.pressKey(chords: [
            KeyChord(flags: [], keyCode: 0x00),
            KeyChord(flags: [], keyCode: 0x08),
            KeyChord(flags: [], keyCode: 0x09),
        ])
        let result = try executor().executeFallback(action, target: fallbackTarget(), environment: env)
        XCTAssertEqual(result.status, .interrupted)
        XCTAssertEqual(result.targetVerified, false)
        XCTAssertEqual(env.fakeSynthesizer.events.count, 2, "delivery stopped when the target lost the foreground")
        XCTAssertTrue(result.warning?.contains("foreground") ?? false)
    }

    // MARK: - Pointer restore (v1.5: return the user's cursor after a coordinate action)

    func testCoordinateClickRestoresPointerAfterDelivery() throws {
        let env = readyEnvironment(frontmostPID: 42)
        env.fakeSynthesizer.reportedPointerLocation = CGPoint(x: 555, y: 444)
        let action = FallbackAction.coordinateClick(at: Point(x: 10, y: 20), space: .window, button: .left, modifiers: [], clickCount: 1)
        let result = try executor().executeFallback(action, target: fallbackTarget(), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(env.fakeSynthesizer.events, [
            .mouseDown(CGPoint(x: 110, y: 220), .left),
            .mouseUp(CGPoint(x: 110, y: 220), .left),
            .movePointer(CGPoint(x: 555, y: 444)),   // cursor returned where the user left it
        ])
    }

    func testKeyboardActionNeverMovesOrRestoresPointer() throws {
        let env = readyEnvironment(frontmostPID: 42)
        env.fakeSynthesizer.reportedPointerLocation = CGPoint(x: 555, y: 444)
        _ = try executor().executeFallback(pressA(), target: fallbackTarget(), environment: env)
        XCTAssertFalse(env.fakeSynthesizer.events.contains { event in
            if case .movePointer = event { return true }
            return false
        }, "a keyboard action never moved the pointer, so nothing is restored")
    }

    func testInterruptedPointerActionSkipsRestore() throws {
        // A genuine user interruption means the user's hand is on the mouse — warping the
        // pointer back would fight them. The restore is skipped.
        let env = readyEnvironment(frontmostPID: 42)
        env.fakeSynthesizer.reportedPointerLocation = CGPoint(x: 555, y: 444)
        env.fakeSynthesizer.onEmit = { env.monitor.observe(isOurs: false, at: 1.0) }
        let action = FallbackAction.coordinateClick(at: Point(x: 10, y: 20), space: .window, button: .left, modifiers: [], clickCount: 1)
        let result = try executor().executeFallback(action, target: fallbackTarget(), environment: env)
        XCTAssertEqual(result.status, .interrupted)
        XCTAssertFalse(env.fakeSynthesizer.events.contains { event in
            if case .movePointer = event { return true }
            return false
        }, "no restore after a user interruption")
    }

    func testUnreadablePointerLocationSkipsRestore() throws {
        let env = readyEnvironment(frontmostPID: 42)
        env.fakeSynthesizer.reportedPointerLocation = nil
        let action = FallbackAction.coordinateClick(at: Point(x: 10, y: 20), space: .window, button: .left, modifiers: [], clickCount: 1)
        let result = try executor().executeFallback(action, target: fallbackTarget(), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(env.fakeSynthesizer.events, [
            .mouseDown(CGPoint(x: 110, y: 220), .left),
            .mouseUp(CGPoint(x: 110, y: 220), .left),
        ])
    }

    // MARK: - Coordinate safety (point must land over the target window)

    func testCoordinateClickOutsideWindowIsRejected() {
        let env = readyEnvironment(frontmostPID: 42) // frame (100,200,400,300)
        // Window point (1000,20) → global (1100,220): far outside the 400-wide window.
        let action = FallbackAction.coordinateClick(at: Point(x: 1000, y: 20), space: .window, button: .left, modifiers: [], clickCount: 1)
        XCTAssertThrowsError(try executor().executeFallback(action, target: fallbackTarget(), environment: env)) { error in
            guard case CUError.windowNotFound = error else { return XCTFail("expected windowNotFound") }
        }
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty, "a point outside the window must never be delivered")
    }

    func testCoordinateClickWhenWindowGoneIsRejected() {
        let env = readyEnvironment(frontmostPID: 42)
        env.missingCurrentFrames.insert("s1") // window closed / off-screen since capture
        let action = FallbackAction.coordinateClick(at: Point(x: 10, y: 20), space: .window, button: .left, modifiers: [], clickCount: 1)
        XCTAssertThrowsError(try executor().executeFallback(action, target: fallbackTarget(), environment: env)) { error in
            guard case CUError.windowNotFound = error else { return XCTFail("expected windowNotFound") }
        }
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
    }

    func testCoordinateClickWhenWindowMovedOffPointIsRejected() {
        let env = readyEnvironment(frontmostPID: 42) // captured frame (100,200,400,300)
        // The window jumped far away since capture; the mapped global point (110,220) is no
        // longer over the live window, so delivery is refused (would land on another app).
        env.currentFrames["s1"] = Rect(x: 900, y: 900, width: 400, height: 300)
        let action = FallbackAction.coordinateClick(at: Point(x: 10, y: 20), space: .window, button: .left, modifiers: [], clickCount: 1)
        XCTAssertThrowsError(try executor().executeFallback(action, target: fallbackTarget(), environment: env)) { error in
            guard case CUError.windowNotFound = error else { return XCTFail("expected windowNotFound") }
        }
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
    }

    func testCoordinateClickInsideBothFramesDelivers() throws {
        let env = readyEnvironment(frontmostPID: 42)
        // Window unmoved (explicit current frame equals captured); an in-window point delivers.
        env.currentFrames["s1"] = Rect(x: 100, y: 200, width: 400, height: 300)
        let action = FallbackAction.coordinateClick(at: Point(x: 10, y: 20), space: .window, button: .left, modifiers: [], clickCount: 1)
        let result = try executor().executeFallback(action, target: fallbackTarget(), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(env.fakeSynthesizer.events.first, .mouseDown(CGPoint(x: 110, y: 220), .left))
    }

    func testDegradedMonitorSurfacesWarning() throws {
        let env = readyEnvironment(frontmostPID: 42)
        env.monitor.markDegraded()
        let result = try executor().executeFallback(pressA(), target: fallbackTarget(), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertNotNil(result.warning)
        XCTAssertTrue(result.warning?.contains("interruption") ?? false)
    }

    // MARK: - Coordinate mapping

    func testCoordinateClickWindowSpaceMapsToGlobal() throws {
        let env = readyEnvironment(frontmostPID: 42)
        // Window point (10,20) with frame origin (100,200) → global (110,220).
        let action = FallbackAction.coordinateClick(at: Point(x: 10, y: 20), space: .window, button: .left, modifiers: [], clickCount: 1)
        let result = try executor().executeFallback(action, target: fallbackTarget(), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .pointer)
        XCTAssertEqual(env.fakeSynthesizer.events, [
            .mouseDown(CGPoint(x: 110, y: 220), .left),
            .mouseUp(CGPoint(x: 110, y: 220), .left),
        ])
    }

    func testCoordinateClickScreenshotSpaceMapsToGlobal() throws {
        let env = readyEnvironment(frontmostPID: 42)
        // Screenshot pixel (400,300) with 800×600 px over a 400×300 pt frame at (100,200):
        // kx=ky=2 → window (200,150) → global (300,350).
        let action = FallbackAction.coordinateClick(at: Point(x: 400, y: 300), space: .screenshot, button: .left, modifiers: [], clickCount: 1)
        _ = try executor().executeFallback(action, target: fallbackTarget(), environment: env)
        guard case let .mouseDown(point, _) = env.fakeSynthesizer.events.first else {
            return XCTFail("expected a mouseDown")
        }
        XCTAssertEqual(point, CGPoint(x: 300, y: 350))
    }

    func testCoordinateClickWithoutGeometryYieldsWindowNotFound() {
        let env = readyEnvironment(frontmostPID: 42, geometry: nil)
        let action = FallbackAction.coordinateClick(at: Point(x: 1, y: 1), space: .window, button: .left, modifiers: [], clickCount: 1)
        XCTAssertThrowsError(try executor().executeFallback(action, target: fallbackTarget(), environment: env)) { error in
            guard case CUError.windowNotFound = error else { return XCTFail("expected windowNotFound") }
        }
    }

    func testScreenshotSpaceWithoutScreenshotPixelsYieldsWindowNotFound() {
        let env = readyEnvironment(frontmostPID: 42, geometry: fixtureGeometry(screenshotPixels: nil))
        let action = FallbackAction.coordinateClick(at: Point(x: 1, y: 1), space: .screenshot, button: .left, modifiers: [], clickCount: 1)
        XCTAssertThrowsError(try executor().executeFallback(action, target: fallbackTarget(), environment: env)) { error in
            guard case CUError.windowNotFound = error else { return XCTFail("expected windowNotFound") }
        }
    }

    func testDragMapsBothEndpoints() throws {
        let env = readyEnvironment(frontmostPID: 42)
        let action = FallbackAction.drag(from: Point(x: 0, y: 0), to: Point(x: 40, y: 0), space: .window, button: .left, modifiers: [])
        let result = try executor().executeFallback(action, target: fallbackTarget(), environment: env)
        XCTAssertEqual(result.method, .pointer)
        guard case let .mouseDown(down, _) = env.fakeSynthesizer.events.first else { return XCTFail("expected mouseDown") }
        XCTAssertEqual(down, CGPoint(x: 100, y: 200)) // from (0,0) + origin
        guard case let .mouseUp(up, _) = env.fakeSynthesizer.events.last else { return XCTFail("expected mouseUp") }
        XCTAssertEqual(up, CGPoint(x: 140, y: 200)) // to (40,0) + origin
    }

    func testCoordinateScrollDeliversWheel() throws {
        let env = readyEnvironment(frontmostPID: 42)
        let action = FallbackAction.coordinateScroll(at: Point(x: 0, y: 0), space: .window, direction: .down, by: .line, count: 2)
        _ = try executor().executeFallback(action, target: fallbackTarget(), environment: env)
        XCTAssertEqual(env.fakeSynthesizer.events, [.scroll(CGPoint(x: 100, y: 200), 0, -6)])
    }

    // MARK: - Element-targeted keyboard input (§18.6)

    /// A press_key targeting element `e5` in session `s1` at revision 1.
    private func elementPress(revision: Int = 1, elementId: String = "e5") -> FallbackTarget {
        FallbackTarget(app: "computer-use-fixture", sessionId: "s1", interference: .backgroundOnly, revision: revision, elementId: elementId)
    }

    func testElementTargetedKeyPreFocusesAndConfirms() throws {
        let env = readyEnvironment(frontmostPID: 42) // target already frontmost → deliver directly
        let element = FakeActionElement(settable: [AXActionName.focused])
        element.focusConfirmed = true
        env.elements["s1/e5"] = element
        let result = try executor().executeFallback(pressA(), target: elementPress(), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.elementFocused, true, "the AXFocusedUIElement re-read confirmed the target")
        XCTAssertEqual(element.focusRequests, 1, "the element was pre-focused before synthesis")
        XCTAssertFalse(env.fakeSynthesizer.events.isEmpty, "keys were still delivered")
    }

    func testElementTargetedKeyDeliversEvenWhenFocusUnconfirmed() throws {
        let env = readyEnvironment(frontmostPID: 42)
        let element = FakeActionElement(settable: [AXActionName.focused])
        element.focusConfirmed = false // the re-read did not confirm focus
        env.elements["s1/e5"] = element
        let result = try executor().executeFallback(pressA(), target: elementPress(), environment: env)
        XCTAssertEqual(result.status, .completed, "delivery proceeds even when focus is unconfirmed (§18.6)")
        XCTAssertEqual(result.elementFocused, false)
        XCTAssertFalse(env.fakeSynthesizer.events.isEmpty)
    }

    func testElementTargetedKeyRevisionMismatchIsStaleRevision() {
        let env = readyEnvironment(frontmostPID: 42) // session s1 @ revision 1
        env.elements["s1/e5"] = FakeActionElement(settable: [AXActionName.focused])
        XCTAssertThrowsError(try executor().executeFallback(pressA(), target: elementPress(revision: 2), environment: env)) { error in
            guard case let CUError.staleRevision(_, provided, current) = error else { return XCTFail("expected staleRevision") }
            XCTAssertEqual(provided, 2)
            XCTAssertEqual(current, 1)
        }
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty, "no keys delivered when the revision is stale")
    }

    func testElementTargetedKeyUnresolvedElementIsStaleElement() {
        let env = readyEnvironment(frontmostPID: 42) // no element registered for s1/e5
        XCTAssertThrowsError(try executor().executeFallback(pressA(), target: elementPress(), environment: env)) { error in
            guard case let CUError.staleElement(_, elementId, _) = error else { return XCTFail("expected staleElement") }
            XCTAssertEqual(elementId, "e5")
        }
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
    }

    func testNonElementTargetedKeyOmitsElementFocused() throws {
        let env = readyEnvironment(frontmostPID: 42)
        let result = try executor().executeFallback(pressA(), target: fallbackTarget(), environment: env)
        XCTAssertNil(result.elementFocused, "elementFocused is present only when an element was targeted")
    }

    func testElementTargetedKeyRejectedModeReportsElementFocusedFalse() throws {
        // background-only + not frontmost → focus_required is thrown before delivery, so cover the
        // focus-changing rejection path instead: allow-brief-focus that cannot foreground the
        // target delivers nothing and never attempts the element focus, reporting false.
        let env = readyEnvironment(frontmostPID: 99) // user app frontmost
        env.fakeWorkspace.activationBringsFrontmost = false
        env.fakeWorkspace.axRaiseBringsFrontmost = false
        let element = FakeActionElement(settable: [AXActionName.focused])
        env.elements["s1/e5"] = element
        let target = FallbackTarget(app: "computer-use-fixture", sessionId: "s1", interference: .allowBriefFocus, revision: 1, elementId: "e5")
        let result = try executor().executeFallback(pressA(), target: target, environment: env)
        XCTAssertEqual(result.status, .rejected, "could not foreground the target → nothing delivered")
        XCTAssertEqual(result.elementFocused, false, "never confirmed (delivery body never ran)")
        XCTAssertEqual(element.focusRequests, 0)
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
    }


    func testCoordinateDoubleClickEmitsTwoPairs() throws {
        let env = readyEnvironment(frontmostPID: 42)
        let action = FallbackAction.coordinateClick(
            at: Point(x: 10, y: 20), space: .window, button: .left, modifiers: [], clickCount: 2
        )
        _ = try executor().executeFallback(action, target: fallbackTarget(), environment: env)
        XCTAssertEqual(env.fakeSynthesizer.events, [
            .mouseDown(CGPoint(x: 110, y: 220), .left),
            .mouseUp(CGPoint(x: 110, y: 220), .left),
            .mouseDown(CGPoint(x: 110, y: 220), .left),
            .mouseUp(CGPoint(x: 110, y: 220), .left),
        ])
    }

    func testCoordinateMiddleClickUsesMiddleButton() throws {
        let env = readyEnvironment(frontmostPID: 42)
        let action = FallbackAction.coordinateClick(
            at: Point(x: 10, y: 20), space: .window, button: .middle, modifiers: [], clickCount: 1
        )
        _ = try executor().executeFallback(action, target: fallbackTarget(), environment: env)
        XCTAssertEqual(env.fakeSynthesizer.events, [
            .mouseDown(CGPoint(x: 110, y: 220), .middle),
            .mouseUp(CGPoint(x: 110, y: 220), .middle),
        ])
    }

    func testCoordinateFractionalPageScroll() throws {
        let env = readyEnvironment(frontmostPID: 42)
        let action = FallbackAction.coordinateScroll(
            at: Point(x: 0, y: 0), space: .window, direction: .down, by: .page, count: 0.5
        )
        _ = try executor().executeFallback(action, target: fallbackTarget(), environment: env)
        // half page = 5 line units
        XCTAssertEqual(env.fakeSynthesizer.events, [.scroll(CGPoint(x: 100, y: 200), 0, -5)])
    }
}
