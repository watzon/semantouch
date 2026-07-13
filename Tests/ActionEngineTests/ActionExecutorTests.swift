import XCTest
import Dispatch
import ComputerUseCore
@testable import ActionEngine

/// The per-session serial lane (§13.6) and the in-lane validation order (§13.2).
final class ActionExecutorTests: XCTestCase {
    // MARK: - Serial FIFO lane

    func testSameSessionSubmissionsRunInFIFOOrder() {
        let executor = ActionExecutor()
        let lock = NSLock()
        var order: [Int] = []
        let gate = DispatchSemaphore(value: 0)

        // op1 parks on the gate; op2/op3 are enqueued while op1 is still running. A
        // serial FIFO lane must run them in submission order once op1 is released.
        executor.submit(sessionId: "s1") { gate.wait(); lock.lock(); order.append(1); lock.unlock() }
        executor.submit(sessionId: "s1") { lock.lock(); order.append(2); lock.unlock() }
        executor.submit(sessionId: "s1") { lock.lock(); order.append(3); lock.unlock() }

        gate.signal()
        let done = DispatchSemaphore(value: 0)
        executor.submit(sessionId: "s1") { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)

        lock.lock(); let snapshot = order; lock.unlock()
        XCTAssertEqual(snapshot, [1, 2, 3])
    }

    func testSameSessionActionsNeverOverlapUnderConcurrentSubmission() {
        let executor = ActionExecutor()
        let lock = NSLock()
        var active = 0
        var maxActive = 0
        let group = DispatchGroup()

        for _ in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                executor.submit(sessionId: "s1") {
                    lock.lock(); active += 1; maxActive = max(maxActive, active); lock.unlock()
                    Thread.sleep(forTimeInterval: 0.0005)
                    lock.lock(); active -= 1; lock.unlock()
                    group.leave()
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
        lock.lock(); let peak = maxActive; lock.unlock()
        XCTAssertEqual(peak, 1, "same-session actions must never run concurrently")
    }

    func testDifferentSessionsRunConcurrently() {
        let executor = ActionExecutor()
        let s1Started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        // Block session s1's lane indefinitely.
        executor.submit(sessionId: "s1") { s1Started.signal(); release.wait() }
        XCTAssertEqual(s1Started.wait(timeout: .now() + 5), .success)

        // With s1 blocked, an s2 op must still run — distinct lanes are concurrent.
        let s2Done = DispatchSemaphore(value: 0)
        executor.submit(sessionId: "s2") { s2Done.signal() }
        XCTAssertEqual(s2Done.wait(timeout: .now() + 5), .success, "distinct sessions must not block each other")

        release.signal()
    }

    func testOnLaneReturnsResult() {
        let executor = ActionExecutor()
        let value = executor.onLane(sessionId: "s1") { 6 * 7 }
        XCTAssertEqual(value, 42)
    }

    // MARK: - Validation order (§13.2)

    func testPolicyDenialWinsBeforeAnyResolutionOrDispatch() {
        let executor = ActionExecutor()
        let env = FakeActionEnvironment()
        env.denyReason = .appDenied
        // A fully valid session/element is present; policy must still win first.
        env.revisions["s1"] = 1
        let element = FakeActionElement(actions: [AXActionName.press])
        env.elements["s1/e1"] = element

        XCTAssertThrowsError(try executor.execute(.click, target: target(), environment: env)) { error in
            guard case let CUError.policyDenied(reason, app, tool) = error else {
                return XCTFail("expected policyDenied, got \(error)")
            }
            XCTAssertEqual(reason, .appDenied)
            XCTAssertEqual(app, "computer-use-fixture")
            XCTAssertEqual(tool, "click")
        }
        XCTAssertTrue(element.performed.isEmpty, "no AX action may run when policy denies the app")
    }

    func testPolicyResolutionErrorPropagates() {
        let executor = ActionExecutor()
        let env = FakeActionEnvironment()
        env.policyError = CUError.appNotFound(query: "Ghost")
        XCTAssertThrowsError(try executor.execute(.click, target: target(app: "Ghost"), environment: env)) { error in
            guard case CUError.appNotFound = error else { return XCTFail("expected appNotFound, got \(error)") }
        }
    }

    func testForeignSessionUnderSelectedAppNameIsPolicyDenied() {
        let executor = ActionExecutor()
        let env = FakeActionEnvironment()
        // The named app passes policy and a fully valid session/element is present,
        // but the session belongs to a DIFFERENT app (confused-deputy, §13.5).
        env.revisions["s1"] = 1
        let element = FakeActionElement(actions: [AXActionName.press])
        env.elements["s1/e1"] = element
        env.sessionOwnedByAppResult = false

        XCTAssertThrowsError(try executor.execute(.click, target: target(), environment: env)) { error in
            guard case let CUError.policyDenied(reason, app, tool) = error else {
                return XCTFail("expected policyDenied, got \(error)")
            }
            XCTAssertEqual(reason, .appDenied)
            XCTAssertEqual(app, "computer-use-fixture")
            XCTAssertEqual(tool, "click")
        }
        XCTAssertTrue(element.performed.isEmpty, "a foreign session's element must never be mutated")
    }

    func testUnknownSessionYieldsStaleRevisionWithNullCurrent() {
        let executor = ActionExecutor()
        let env = FakeActionEnvironment() // no revisions ⇒ session unknown; policy allows
        XCTAssertThrowsError(try executor.execute(.click, target: target(session: "s404"), environment: env)) { error in
            guard case let CUError.staleRevision(sessionId, provided, current) = error else {
                return XCTFail("expected staleRevision, got \(error)")
            }
            XCTAssertEqual(sessionId, "s404")
            XCTAssertEqual(provided, 1)
            XCTAssertNil(current, "unknown/ended session ⇒ current revision is null")
        }
    }

    func testMismatchedRevisionYieldsStaleRevisionWithCurrent() {
        let executor = ActionExecutor()
        let env = FakeActionEnvironment()
        env.revisions["s1"] = 3
        env.elements["s1/e1"] = FakeActionElement(actions: [AXActionName.press])
        // Provided revision 1 ≠ current 3: stale before element resolution.
        XCTAssertThrowsError(try executor.execute(.click, target: target(revision: 1), environment: env)) { error in
            guard case let CUError.staleRevision(_, provided, current) = error else {
                return XCTFail("expected staleRevision, got \(error)")
            }
            XCTAssertEqual(provided, 1)
            XCTAssertEqual(current, 3)
        }
    }

    func testMatchedRevisionButUnknownElementYieldsStaleElement() {
        let executor = ActionExecutor()
        let env = FakeActionEnvironment()
        env.revisions["s1"] = 2
        // No element seeded ⇒ resolveElement throws stale_element.
        XCTAssertThrowsError(try executor.execute(.click, target: target(revision: 2, element: "e9"), environment: env)) { error in
            guard case let CUError.staleElement(sessionId, elementId, revision) = error else {
                return XCTFail("expected staleElement, got \(error)")
            }
            XCTAssertEqual(sessionId, "s1")
            XCTAssertEqual(elementId, "e9")
            XCTAssertEqual(revision, 2)
        }
    }

    func testValidTargetPerformsTheAction() throws {
        let executor = ActionExecutor()
        let env = FakeActionEnvironment()
        env.revisions["s1"] = 1
        let element = FakeActionElement(actions: [AXActionName.press])
        env.elements["s1/e1"] = element

        let result = try executor.execute(.click, target: target(), environment: env)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.method, .accessibility)
        XCTAssertTrue(result.refreshRecommended)
        XCTAssertEqual(element.performed, [AXActionName.press])
    }
}
