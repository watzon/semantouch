import XCTest
import CoreGraphics
import ComputerUseCore
@testable import ActionEngine

/// Permission-free integration coverage for Phase-4 input reliability:
/// bounded coordinate→AX semantic clicks and settable string AXValue append,
/// both gated after policy/session/ownership/PID/window validation and before
/// CGEvent synthesis. No Accessibility grant, no live AXUIElement, no real events.
///
/// Fakes are local to this file (ActionEngineTests doubles are not visible here).
final class InputReliabilityIntegrationTests: XCTestCase {
    private func executor() -> ActionExecutor { ActionExecutor() }

    private func readyEnvironment(frontmostPID: pid_t? = 42) -> ReliabilityEnv {
        let workspace = LocalFakeWorkspace(frontmostPID: frontmostPID, frontmostAppName: "UserApp")
        let env = ReliabilityEnv(workspace: workspace)
        env.revisions["s1"] = 1
        env.pids["s1"] = 42
        env.geometries["s1"] = WindowGeometry(
            windowId: 7,
            framePoints: Rect(x: 100, y: 200, width: 400, height: 300),
            screenshotPixels: Size(width: 800, height: 600),
            scale: 2.0
        )
        return env
    }

    private func leftClick(at x: Double = 10, _ y: Double = 20, count: Int = 1) -> FallbackAction {
        .coordinateClick(at: Point(x: x, y: y), space: .window, button: .left, modifiers: [], clickCount: count)
    }

    private func target(
        interference: InterferencePolicy = .backgroundOnly,
        revision: Int? = nil,
        elementId: String? = nil
    ) -> FallbackTarget {
        FallbackTarget(
            app: "computer-use-fixture",
            sessionId: "s1",
            interference: interference,
            revision: revision,
            elementId: elementId
        )
    }

    // MARK: - Gate order

    func testPolicyDenialNeverInvokesResolverOrValueWrite() {
        let env = readyEnvironment()
        env.denyReason = .appDenied
        env.clickResolution = .press(
            element: ReliabilityPressElement(),
            anchor: Point(x: 110, y: 220),
            reason: "direct_press",
            pid: 42,
            frame: Rect(x: 100, y: 200, width: 80, height: 28)
        )
        XCTAssertThrowsError(try executor().executeFallback(leftClick(), target: target(), environment: env)) { error in
            guard case CUError.policyDenied = error else { return XCTFail("expected policyDenied") }
        }
        XCTAssertEqual(env.resolveCalls, 0)
        XCTAssertEqual(env.focusedLookups, 0)
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
    }

    func testUnknownSessionNeverInvokesResolver() {
        let env = readyEnvironment()
        env.revisions.removeValue(forKey: "s1")
        env.clickResolution = .press(
            element: ReliabilityPressElement(),
            anchor: Point(x: 110, y: 220),
            reason: "direct_press",
            pid: 42,
            frame: Rect(x: 100, y: 200, width: 80, height: 28)
        )
        XCTAssertThrowsError(try executor().executeFallback(leftClick(), target: target(), environment: env))
        XCTAssertEqual(env.resolveCalls, 0)
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
    }

    func testForeignSessionNeverInvokesResolver() {
        let env = readyEnvironment()
        env.sessionOwnedByAppResult = false
        env.clickResolution = .press(
            element: ReliabilityPressElement(),
            anchor: Point(x: 110, y: 220),
            reason: "direct_press",
            pid: 42,
            frame: Rect(x: 100, y: 200, width: 80, height: 28)
        )
        XCTAssertThrowsError(try executor().executeFallback(leftClick(), target: target(), environment: env))
        XCTAssertEqual(env.resolveCalls, 0)
    }

    func testMissingPIDNeverInvokesResolverOrFocusedLookup() {
        let env = readyEnvironment()
        env.pids.removeValue(forKey: "s1")
        env.clickResolution = .press(
            element: ReliabilityPressElement(),
            anchor: Point(x: 110, y: 220),
            reason: "direct_press",
            pid: 42,
            frame: Rect(x: 100, y: 200, width: 80, height: 28)
        )
        XCTAssertThrowsError(try executor().executeFallback(leftClick(), target: target(), environment: env))
        XCTAssertEqual(env.resolveCalls, 0)
        XCTAssertEqual(env.focusedLookups, 0)
    }

    func testWindowGoneNeverInvokesResolver() {
        let env = readyEnvironment()
        env.missingCurrentFrames.insert("s1")
        env.clickResolution = .press(
            element: ReliabilityPressElement(),
            anchor: Point(x: 110, y: 220),
            reason: "direct_press",
            pid: 42,
            frame: Rect(x: 100, y: 200, width: 80, height: 28)
        )
        XCTAssertThrowsError(try executor().executeFallback(leftClick(), target: target(), environment: env))
        XCTAssertEqual(env.resolveCalls, 0)
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
    }

    func testPointOutsideWindowNeverInvokesResolver() {
        let env = readyEnvironment()
        env.clickResolution = .press(
            element: ReliabilityPressElement(),
            anchor: Point(x: 110, y: 220),
            reason: "direct_press",
            pid: 42,
            frame: Rect(x: 100, y: 200, width: 80, height: 28)
        )
        XCTAssertThrowsError(try executor().executeFallback(leftClick(at: 1000, 20), target: target(), environment: env))
        XCTAssertEqual(env.resolveCalls, 0)
    }

    // MARK: - Semantic coordinate press

    func testDirectSemanticPressEmitsZeroEvents() throws {
        let env = readyEnvironment()
        let pressElement = ReliabilityPressElement()
        env.clickResolution = .press(
            element: pressElement,
            anchor: Point(x: 140, y: 214),
            reason: "direct_press",
            pid: 42,
            frame: Rect(x: 100, y: 200, width: 80, height: 28)
        )
        let result = try executor().executeFallback(leftClick(), target: target(), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .accessibility)
        XCTAssertEqual(result.focusChanged, false)
        XCTAssertEqual(result.focusRestored, false)
        XCTAssertEqual(result.targetVerified, true)
        XCTAssertEqual(result.stateChanged, false, "AXPress API success is not an observed UI change")
        XCTAssertTrue(result.warning?.contains("direct_press") ?? false)
        XCTAssertEqual(pressElement.performed, ["AXPress"])
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty, "semantic press must emit zero CGEvents")
        XCTAssertTrue(env.fakeWorkspace.activatedPIDs.isEmpty)
        XCTAssertEqual(env.resolveCalls, 1)
    }

    func testSummaryParentPressUsesSelectedElement() throws {
        let env = readyEnvironment()
        let pressElement = ReliabilityPressElement()
        env.clickResolution = .press(
            element: pressElement,
            anchor: Point(x: 120, y: 224),
            reason: "summary_parent_press",
            notes: ["summary_parent_press"],
            pid: 42,
            frame: Rect(x: 100, y: 200, width: 200, height: 48)
        )
        let result = try executor().executeFallback(leftClick(), target: target(), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .accessibility)
        XCTAssertTrue(result.warning?.contains("summary_parent_press") ?? false)
        XCTAssertEqual(pressElement.performed, ["AXPress"])
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
    }

    func testCoordinateActivationSynthesizesAtSafeAnchor() throws {
        let env = readyEnvironment()
        env.clickResolution = .coordinate(
            anchor: Point(x: 112, y: 224),
            reason: "synthetic_row_left_anchor",
            notes: ["synthetic_row_left_anchor"]
        )
        let result = try executor().executeFallback(leftClick(), target: target(), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .pointer)
        XCTAssertEqual(env.fakeSynthesizer.events, [
            .mouseDown(CGPoint(x: 112, y: 224), .left),
            .mouseUp(CGPoint(x: 112, y: 224), .left),
        ])
    }

    func testPressFailureFallsBackToSameSafeAnchor() throws {
        let env = readyEnvironment()
        let pressElement = ReliabilityPressElement()
        pressElement.performError = CUError.internalError(detail: "ax press fault")
        env.clickResolution = .press(
            element: pressElement,
            anchor: Point(x: 118, y: 230),
            reason: "direct_press",
            pid: 42,
            frame: Rect(x: 100, y: 200, width: 80, height: 28)
        )
        let result = try executor().executeFallback(leftClick(), target: target(), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .pointer)
        XCTAssertTrue(pressElement.performed.isEmpty)
        XCTAssertEqual(env.fakeSynthesizer.events, [
            .mouseDown(CGPoint(x: 118, y: 230), .left),
            .mouseUp(CGPoint(x: 118, y: 230), .left),
        ])
    }

    func testUnsafeNilPIDNeverPressesFallsBackToAnchor() throws {
        let env = readyEnvironment()
        let pressElement = ReliabilityPressElement()
        env.clickResolution = .press(
            element: pressElement,
            anchor: Point(x: 115, y: 225),
            reason: "direct_press",
            pid: nil,
            frame: Rect(x: 100, y: 200, width: 80, height: 28)
        )
        _ = try executor().executeFallback(leftClick(), target: target(), environment: env)
        XCTAssertTrue(pressElement.performed.isEmpty)
        XCTAssertEqual(env.fakeSynthesizer.events.first, .mouseDown(CGPoint(x: 115, y: 225), .left))
    }

    func testWrongSelectedPIDNeverPresses() throws {
        let env = readyEnvironment()
        let pressElement = ReliabilityPressElement()
        env.clickResolution = .press(
            element: pressElement,
            anchor: Point(x: 115, y: 225),
            reason: "direct_press",
            pid: 999,
            frame: Rect(x: 100, y: 200, width: 80, height: 28)
        )
        _ = try executor().executeFallback(leftClick(), target: target(), environment: env)
        XCTAssertTrue(pressElement.performed.isEmpty)
    }

    func testFrameNotContainingOriginalPointNeverPresses() throws {
        let env = readyEnvironment()
        let pressElement = ReliabilityPressElement()
        env.clickResolution = .press(
            element: pressElement,
            anchor: Point(x: 300, y: 250),
            reason: "direct_press",
            pid: 42,
            frame: Rect(x: 250, y: 240, width: 40, height: 20)
        )
        _ = try executor().executeFallback(leftClick(), target: target(), environment: env)
        XCTAssertTrue(pressElement.performed.isEmpty)
        XCTAssertEqual(env.fakeSynthesizer.events.first, .mouseDown(CGPoint(x: 300, y: 250), .left))
    }

    func testGiantContainerStyleUnauthorizedNeverHijacks() throws {
        let env = readyEnvironment()
        let pressElement = ReliabilityPressElement()
        env.clickResolution = .press(
            element: pressElement,
            anchor: Point(x: 380, y: 450),
            reason: "deepest_pressable",
            pid: 42,
            frame: Rect(x: 350, y: 430, width: 40, height: 30)
        )
        _ = try executor().executeFallback(leftClick(), target: target(), environment: env)
        XCTAssertTrue(pressElement.performed.isEmpty)
    }

    func testResolverMissKeepsOriginalPoint() throws {
        let env = readyEnvironment()
        env.clickResolution = .miss
        let result = try executor().executeFallback(leftClick(), target: target(), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .pointer)
        XCTAssertEqual(env.fakeSynthesizer.events, [
            .mouseDown(CGPoint(x: 110, y: 220), .left),
            .mouseUp(CGPoint(x: 110, y: 220), .left),
        ])
    }

    func testRightMiddleMultiBypassSemanticAX() throws {
        let env = readyEnvironment()
        env.clickResolution = .press(
            element: ReliabilityPressElement(),
            anchor: Point(x: 999, y: 999),
            reason: "direct_press",
            pid: 42,
            frame: Rect(x: 100, y: 200, width: 80, height: 28)
        )
        for action in [
            FallbackAction.coordinateClick(at: Point(x: 10, y: 20), space: .window, button: .right, modifiers: [], clickCount: 1),
            FallbackAction.coordinateClick(at: Point(x: 10, y: 20), space: .window, button: .middle, modifiers: [], clickCount: 1),
            FallbackAction.coordinateClick(at: Point(x: 10, y: 20), space: .window, button: .left, modifiers: [], clickCount: 2),
            FallbackAction.coordinateClick(at: Point(x: 10, y: 20), space: .window, button: .left, modifiers: [], clickCount: 3),
        ] {
            env.fakeSynthesizer.events.removeAll()
            env.resetResolveCalls()
            _ = try executor().executeFallback(action, target: target(), environment: env)
            XCTAssertEqual(env.resolveCalls, 0, "non-left-single must never resolve")
            XCTAssertFalse(env.fakeSynthesizer.events.isEmpty)
        }
    }

    func testBackgroundOnlyNonFrontmostPressSuccessNoActivation() throws {
        let env = readyEnvironment(frontmostPID: 99)
        let pressElement = ReliabilityPressElement()
        env.clickResolution = .press(
            element: pressElement,
            anchor: Point(x: 140, y: 214),
            reason: "direct_press",
            pid: 42,
            frame: Rect(x: 100, y: 200, width: 80, height: 28)
        )
        let result = try executor().executeFallback(
            leftClick(),
            target: target(interference: .backgroundOnly),
            environment: env
        )
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .accessibility)
        XCTAssertEqual(pressElement.performed, ["AXPress"])
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
        XCTAssertTrue(env.fakeWorkspace.activatedPIDs.isEmpty)
    }

    func testBackgroundOnlyNonFrontmostCoordinateFallsToFocusRequired() {
        let env = readyEnvironment(frontmostPID: 99)
        env.clickResolution = .coordinate(
            anchor: Point(x: 112, y: 224),
            reason: "synthetic_row_left_anchor"
        )
        XCTAssertThrowsError(
            try executor().executeFallback(
                leftClick(),
                target: target(interference: .backgroundOnly),
                environment: env
            )
        ) { error in
            guard case CUError.focusRequired = error else { return XCTFail("expected focusRequired") }
        }
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
        XCTAssertTrue(env.fakeWorkspace.activatedPIDs.isEmpty)
    }

    // MARK: - type_text settable string AXValue

    func testTargetedStringAXValueAppendEmitsZeroEvents() throws {
        let env = readyEnvironment(frontmostPID: 99)
        let field = ReliabilityStringElement(value: "hello")
        env.elements["s1/e5"] = field
        let result = try executor().executeFallback(
            .typeText("!"),
            target: target(interference: .backgroundOnly, revision: 1, elementId: "e5"),
            environment: env
        )
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .accessibility)
        XCTAssertEqual(result.stateChanged, true)
        XCTAssertEqual(result.targetVerified, true)
        XCTAssertEqual(field.stringValue, "hello!")
        XCTAssertEqual(field.writeCount, 1)
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
        XCTAssertTrue(env.fakeWorkspace.activatedPIDs.isEmpty)
        XCTAssertEqual(field.focusRequests, 0)
        XCTAssertEqual(env.focusedLookups, 0)
    }

    func testBackgroundFocusedStringAXValueAppend() throws {
        let env = readyEnvironment(frontmostPID: 99)
        let field = ReliabilityStringElement(value: "ab")
        env.focused = field
        let result = try executor().executeFallback(
            .typeText("c"),
            target: target(interference: .backgroundOnly),
            environment: env
        )
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .accessibility)
        XCTAssertEqual(field.stringValue, "abc")
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
        XCTAssertEqual(env.focusedLookups, 1)
    }

    func testNonSettableFallsBackToSynthesis() throws {
        let env = readyEnvironment()
        let field = ReliabilityStringElement(value: "x", settable: false)
        env.elements["s1/e5"] = field
        env.fakeWorkspace.frontmostPID = 42
        let result = try executor().executeFallback(
            .typeText("y"),
            target: target(interference: .backgroundOnly, revision: 1, elementId: "e5"),
            environment: env
        )
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .keyboard)
        XCTAssertEqual(field.writeCount, 0)
        XCTAssertFalse(env.fakeSynthesizer.events.isEmpty)
    }

    func testNonStringFallsBackWithoutWrite() throws {
        let env = readyEnvironment()
        let field = ReliabilityStringElement(value: nil)
        env.elements["s1/e5"] = field
        env.fakeWorkspace.frontmostPID = 42
        _ = try executor().executeFallback(
            .typeText("z"),
            target: target(interference: .backgroundOnly, revision: 1, elementId: "e5"),
            environment: env
        )
        XCTAssertEqual(field.writeCount, 0)
        XCTAssertFalse(env.fakeSynthesizer.events.isEmpty)
    }

    func testWriteThrowWithOriginalIntactSynthesizesOnce() throws {
        let env = readyEnvironment()
        let field = ReliabilityStringElement(value: "old")
        field.writeBehavior = .throwAndKeepOriginal
        env.elements["s1/e5"] = field
        env.fakeWorkspace.frontmostPID = 42
        let result = try executor().executeFallback(
            .typeText("NEW"),
            target: target(interference: .backgroundOnly, revision: 1, elementId: "e5"),
            environment: env
        )
        XCTAssertEqual(result.method, .keyboard)
        XCTAssertEqual(field.stringValue, "old")
        XCTAssertEqual(env.fakeSynthesizer.events, [.type("N"), .type("E"), .type("W")])
    }

    func testWriteThrowButExpectedConfirmedNeverSynthesizes() throws {
        let env = readyEnvironment()
        let field = ReliabilityStringElement(value: "old")
        field.writeBehavior = .throwButApply
        env.elements["s1/e5"] = field
        env.fakeWorkspace.frontmostPID = 42
        let result = try executor().executeFallback(
            .typeText("NEW"),
            target: target(interference: .backgroundOnly, revision: 1, elementId: "e5"),
            environment: env
        )
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .accessibility)
        XCTAssertEqual(field.stringValue, "oldNEW")
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
        XCTAssertTrue(result.warning?.contains("fault") ?? false)
    }

    func testPartialWriteWithoutRollbackNeverSynthesizes() throws {
        let env = readyEnvironment()
        let field = ReliabilityStringElement(value: "old")
        field.writeBehavior = .partial("oldNE")
        field.rollbackFails = true
        env.elements["s1/e5"] = field
        env.fakeWorkspace.frontmostPID = 42
        let result = try executor().executeFallback(
            .typeText("NEW"),
            target: target(interference: .backgroundOnly, revision: 1, elementId: "e5"),
            environment: env
        )
        XCTAssertEqual(result.status, .interrupted)
        XCTAssertEqual(result.method, .accessibility)
        XCTAssertEqual(result.targetVerified, false)
        XCTAssertTrue(env.fakeSynthesizer.events.isEmpty)
        XCTAssertEqual(field.stringValue, "oldNE")
        XCTAssertTrue(result.warning?.contains("indeterminate") ?? false)
    }

    func testPartialWriteWithRollbackConfirmedSynthesizesOnce() throws {
        let env = readyEnvironment()
        let field = ReliabilityStringElement(value: "old")
        field.writeBehavior = .partial("oldNE")
        field.rollbackFails = false
        env.elements["s1/e5"] = field
        env.fakeWorkspace.frontmostPID = 42
        let result = try executor().executeFallback(
            .typeText("NEW"),
            target: target(interference: .backgroundOnly, revision: 1, elementId: "e5"),
            environment: env
        )
        XCTAssertEqual(result.method, .keyboard)
        XCTAssertEqual(field.stringValue, "old")
        XCTAssertEqual(env.fakeSynthesizer.events, [.type("N"), .type("E"), .type("W")])
    }

    func testExplicitNonSettableDoesNotUseFocusedElement() throws {
        let env = readyEnvironment()
        let explicit = ReliabilityStringElement(value: "x", settable: false)
        let focused = ReliabilityStringElement(value: "focused")
        env.elements["s1/e5"] = explicit
        env.focused = focused
        env.fakeWorkspace.frontmostPID = 42
        _ = try executor().executeFallback(
            .typeText("y"),
            target: target(interference: .backgroundOnly, revision: 1, elementId: "e5"),
            environment: env
        )
        XCTAssertEqual(focused.writeCount, 0)
        XCTAssertEqual(env.focusedLookups, 0)
    }

    func testTargetExitBeforeAXValueWritePostsNothing() throws {
        let env = readyEnvironment(frontmostPID: 99)
        let field = ReliabilityStringElement(value: "ab")
        env.focused = field
        env.pidReadOverride = { count in
            if count >= 2 { return nil }
            return 42
        }
        _ = try executor().executeFallback(
            .typeText("c"),
            target: target(interference: .backgroundOnly),
            environment: env
        )
        XCTAssertNotEqual(field.stringValue, "abc")
        XCTAssertEqual(field.writeCount, 0)
    }

    func testInterruptionBeforeAXValueWriteDoesNotWrite() throws {
        let env = readyEnvironment(frontmostPID: 99)
        let field = ReliabilityStringElement(value: "ab")
        env.focused = field
        env.onFocusedLookup = {
            env.monitor.observe(isOurs: false, at: 1.0)
        }
        let result = try executor().executeFallback(
            .typeText("c"),
            target: target(interference: .backgroundOnly),
            environment: env
        )
        XCTAssertNotEqual(field.stringValue, "abc")
        XCTAssertTrue(field.writeCount == 0 || result.status == .interrupted)
    }
}

// MARK: - Local fakes

private final class LocalFakeSynthesizer: InputSynthesizer, ProcessTargetedInputSynthesizer {
    enum Event: Equatable {
        case keyDown(CGKeyCode, CGEventFlags)
        case keyUp(CGKeyCode, CGEventFlags)
        case type(String)
        case targetedKeyDown(CGKeyCode, CGEventFlags, pid_t)
        case targetedKeyUp(CGKeyCode, CGEventFlags, pid_t)
        case targetedType(String, pid_t)
        case mouseDown(CGPoint, PointerButton)
        case mouseUp(CGPoint, PointerButton)
        case mouseDrag(CGPoint, PointerButton)
        case scroll(CGPoint, Int32, Int32)
        case movePointer(CGPoint)
    }

    var events: [Event] = []
    var reportedPointerLocation: CGPoint?

    func keyDown(keyCode: CGKeyCode, flags: CGEventFlags) { events.append(.keyDown(keyCode, flags)) }
    func keyUp(keyCode: CGKeyCode, flags: CGEventFlags) { events.append(.keyUp(keyCode, flags)) }
    func typeUnicode(_ string: String) { events.append(.type(string)) }
    func keyDown(keyCode: CGKeyCode, flags: CGEventFlags, toPid pid: pid_t) {
        events.append(.targetedKeyDown(keyCode, flags, pid))
    }
    func keyUp(keyCode: CGKeyCode, flags: CGEventFlags, toPid pid: pid_t) {
        events.append(.targetedKeyUp(keyCode, flags, pid))
    }
    func typeUnicode(_ string: String, toPid pid: pid_t) { events.append(.targetedType(string, pid)) }
    func mouseDown(at: CGPoint, button: PointerButton, flags: CGEventFlags) { events.append(.mouseDown(at, button)) }
    func mouseUp(at: CGPoint, button: PointerButton, flags: CGEventFlags) { events.append(.mouseUp(at, button)) }
    func mouseDrag(to: CGPoint, button: PointerButton, flags: CGEventFlags) { events.append(.mouseDrag(to, button)) }
    func scroll(at: CGPoint, deltaX: Int32, deltaY: Int32, flags: CGEventFlags) {
        events.append(.scroll(at, deltaX, deltaY))
    }
    func pointerLocation() -> CGPoint? { reportedPointerLocation }
    func movePointer(to point: CGPoint) { events.append(.movePointer(point)) }
}

private final class LocalFakeWorkspace: WorkspaceControlling {
    var frontmostPID: pid_t?
    var frontmostAppName: String?
    var activationBringsFrontmost = true
    var axRaiseBringsFrontmost = false
    private(set) var activatedPIDs: [pid_t] = []
    private(set) var axRaisedPIDs: [pid_t] = []

    init(frontmostPID: pid_t? = nil, frontmostAppName: String? = nil) {
        self.frontmostPID = frontmostPID
        self.frontmostAppName = frontmostAppName
    }

    func activate(pid: pid_t) -> Bool {
        activatedPIDs.append(pid)
        if activationBringsFrontmost { frontmostPID = pid }
        return activationBringsFrontmost
    }

    func raiseViaAccessibility(pid: pid_t) -> Bool {
        axRaisedPIDs.append(pid)
        if axRaiseBringsFrontmost { frontmostPID = pid }
        return axRaiseBringsFrontmost
    }

    func recordFocusedElement() -> FocusedElementToken? { FocusedElementToken(payload: "focused") }
    func restoreFocusedElement(_ token: FocusedElementToken) -> Bool { true }
}

private final class ReliabilityPressElement: ActionElement {
    var live = true
    var performed: [String] = []
    var performError: Error?
    var focusRequests = 0

    var isLive: Bool { live }
    var role: String? { "AXButton" }
    func actionNames() -> [String] { ["AXPress"] }
    func perform(_ action: String) throws {
        if let performError { throw performError }
        performed.append(action)
    }
    func isSettable(_ attribute: String) -> Bool { false }
    func snapshot(_ attribute: String) -> String? { nil }
    func writeValue(_ value: ActionValue) throws {}
    func writeSelectedRange(location: Int, length: Int) throws {}
    func element(for attribute: String) -> ActionElement? { nil }
    func children() -> [ActionElement] { [] }
    func setKeyboardFocus() -> Bool { focusRequests += 1; return false }
    func holdsKeyboardFocus() -> Bool { false }
}

private final class ReliabilityStringElement: ActionElement, StringAXValueCapable {
    enum WriteBehavior {
        case apply
        case throwAndKeepOriginal
        case throwButApply
        case partial(String)
    }

    var live = true
    var stringValue: String?
    var settable: Bool
    var writeBehavior: WriteBehavior = .apply
    var rollbackFails = false
    private(set) var writeCount = 0
    private(set) var focusRequests = 0
    private var originalAtFirstWrite: String?

    init(value: String?, settable: Bool = true) {
        self.stringValue = value
        self.settable = settable
    }

    var isLive: Bool { live }
    var role: String? { "AXTextField" }
    func actionNames() -> [String] { [] }
    func perform(_ action: String) throws {}
    func isSettable(_ attribute: String) -> Bool {
        attribute == AXActionName.value ? settable : false
    }
    func snapshot(_ attribute: String) -> String? {
        if attribute == AXActionName.value { return stringValue ?? "42" }
        return nil
    }
    func writeValue(_ value: ActionValue) throws {
        if case let .string(s) = value { try writeStringAXValue(s) }
    }
    func writeSelectedRange(location: Int, length: Int) throws {}
    func element(for attribute: String) -> ActionElement? { nil }
    func children() -> [ActionElement] { [] }
    func setKeyboardFocus() -> Bool { focusRequests += 1; return false }
    func holdsKeyboardFocus() -> Bool { false }

    func stringAXValue() -> String? { stringValue }
    func canSetStringAXValue() -> Bool { settable && stringValue != nil }

    func writeStringAXValue(_ value: String) throws {
        writeCount += 1
        if originalAtFirstWrite == nil { originalAtFirstWrite = stringValue }
        switch writeBehavior {
        case .apply:
            stringValue = value
        case .throwAndKeepOriginal:
            throw CUError.internalError(detail: "ax set fault")
        case .throwButApply:
            stringValue = value
            throw CUError.internalError(detail: "ax set fault after side effect")
        case let .partial(partial):
            if writeCount == 1 {
                stringValue = partial
            } else if rollbackFails {
                throw CUError.internalError(detail: "rollback fault")
            } else {
                stringValue = originalAtFirstWrite
            }
        }
    }
}

private final class ReliabilityEnv: FallbackEnvironment, CoordinateClickResolving, FocusedElementProviding {
    enum ClickResolution {
        case miss
        case press(element: ActionElement, anchor: Point, reason: String, notes: [String] = [], pid: pid_t?, frame: Rect?)
        case coordinate(anchor: Point, reason: String, notes: [String] = [])
    }

    var denyReason: PolicyDenyReason?
    var policyError: Error?
    var revisions: [String: Int] = [:]
    var sessionOwnedByAppResult = true
    var pids: [String: pid_t] = [:]
    var geometries: [String: WindowGeometry] = [:]
    var currentFrames: [String: Rect] = [:]
    var missingCurrentFrames: Set<String> = []
    var elements: [String: ActionElement] = [:]
    var clickResolution: ClickResolution = .miss
    var focused: ActionElement?
    var pidReadOverride: ((Int) -> pid_t?)?
    var onFocusedLookup: (() -> Void)?

    private(set) var resolveCalls = 0
    private(set) var focusedLookups = 0
    private var pidReads = 0

    let fakeWorkspace: LocalFakeWorkspace
    let fakeSynthesizer: LocalFakeSynthesizer
    let monitor: InterruptionState

    init(
        workspace: LocalFakeWorkspace = LocalFakeWorkspace(),
        synthesizer: LocalFakeSynthesizer = LocalFakeSynthesizer(),
        interruption: InterruptionState = InterruptionState()
    ) {
        self.fakeWorkspace = workspace
        self.fakeSynthesizer = synthesizer
        self.monitor = interruption
    }

    func resetResolveCalls() { resolveCalls = 0 }

    func policyCheck(app: String) throws -> PolicyDenyReason? {
        if let policyError { throw policyError }
        return denyReason
    }
    func currentRevision(sessionId: String) -> Int? { revisions[sessionId] }
    func sessionOwnedByApp(sessionId: String, app: String) throws -> Bool { sessionOwnedByAppResult }
    func resolveElement(sessionId: String, elementId: String, revision: Int) throws -> ActionElement {
        if let element = elements["\(sessionId)/\(elementId)"] { return element }
        throw CUError.staleElement(sessionId: sessionId, elementId: elementId, revision: revision)
    }
    func targetPID(sessionId: String) -> pid_t? {
        pidReads += 1
        if let pidReadOverride { return pidReadOverride(pidReads) }
        return pids[sessionId]
    }
    func windowGeometry(sessionId: String) -> WindowGeometry? { geometries[sessionId] }
    func currentWindowFrame(sessionId: String) -> Rect? {
        if missingCurrentFrames.contains(sessionId) { return nil }
        return currentFrames[sessionId] ?? geometries[sessionId]?.framePoints
    }
    var workspace: WorkspaceControlling { fakeWorkspace }
    var synthesizer: InputSynthesizer { fakeSynthesizer }
    var interruption: InterruptionMonitoring { monitor }

    func resolveCoordinateClick(
        atGlobal point: CGPoint,
        windowBounds: Rect,
        expectedPID: pid_t
    ) -> AXCoordinateClickResolution? {
        resolveCalls += 1
        switch clickResolution {
        case .miss:
            return nil
        case let .press(element, anchor, reason, notes, pid, frame):
            return AXCoordinateClickResolution(
                activation: .press,
                anchor: anchor,
                reason: reason,
                evidenceNotes: notes,
                pressElement: element,
                selectedPID: pid,
                selectedFrame: frame
            )
        case let .coordinate(anchor, reason, notes):
            return AXCoordinateClickResolution(
                activation: .coordinate,
                anchor: anchor,
                reason: reason,
                evidenceNotes: notes
            )
        }
    }

    func focusedElement(forPID pid: pid_t) -> ActionElement? {
        focusedLookups += 1
        onFocusedLookup?()
        return focused
    }
}
