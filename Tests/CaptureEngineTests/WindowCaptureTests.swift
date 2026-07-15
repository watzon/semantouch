import XCTest
import ComputerUseCore
@testable import CaptureEngine

/// Pure `uncapturable_window` classification (§6) plus the capture-deadline race
/// helper. Live `SCScreenshotManager` needs Screen Recording; these seams do not.
final class WindowCaptureTests: XCTestCase {
    // MARK: - Uncapturable classification

    func testZeroSizeFrameIsUnsupportedSurface() {
        XCTAssertEqual(
            WindowCapture.classifyUncapturable(
                frameIsZeroSize: true, stillPresent: true, isOnscreen: true, isScreenCaptureKitError: true
            ),
            .unsupportedSurface
        )
    }

    func testVanishedWindowIsStale() {
        XCTAssertEqual(
            WindowCapture.classifyUncapturable(
                frameIsZeroSize: false, stillPresent: false, isOnscreen: true, isScreenCaptureKitError: true
            ),
            .stale
        )
    }

    func testPresentButOffscreenIsMinimized() {
        XCTAssertEqual(
            WindowCapture.classifyUncapturable(
                frameIsZeroSize: false, stillPresent: true, isOnscreen: false, isScreenCaptureKitError: true
            ),
            .minimized
        )
    }

    func testPresentOnscreenScreenCaptureKitErrorIsProtected() {
        XCTAssertEqual(
            WindowCapture.classifyUncapturable(
                frameIsZeroSize: false, stillPresent: true, isOnscreen: true, isScreenCaptureKitError: true
            ),
            .protected
        )
    }

    func testPresentOnscreenNonScreenCaptureKitErrorIsUnsupportedSurface() {
        XCTAssertEqual(
            WindowCapture.classifyUncapturable(
                frameIsZeroSize: false, stillPresent: true, isOnscreen: true, isScreenCaptureKitError: false
            ),
            .unsupportedSurface
        )
    }

    // MARK: - Capture deadline (injected async work; no ScreenCaptureKit)

    func testCaptureDeadlineConstantsMatchProtocol() {
        // Production `captureImage` races against these exact wire values.
        XCTAssertEqual(WindowCapture.captureDeadlineMs, 5_000)
        XCTAssertEqual(WindowCapture.captureOperation, "capture_window")
    }

    func testDeadlineReturnsSuccessBeforeDeadline() async throws {
        let value = try await WindowCapture.withDeadline(
            deadlineMs: 500,
            operation: WindowCapture.captureOperation
        ) {
            42
        }
        XCTAssertEqual(value, 42)
    }

    func testDeadlineTimesOutWithExactPayload() async {
        // Use the production operation string with a short injected deadline so
        // the race is fast; production captureImage uses the same helper with
        // captureDeadlineMs (asserted above) so the wire shape is locked here.
        let deadlineMs = 40
        let operation = WindowCapture.captureOperation
        do {
            _ = try await WindowCapture.withDeadline(
                deadlineMs: deadlineMs,
                operation: operation
            ) {
                // Hang past the deadline; cancellation-aware sleep so group cleanup is prompt.
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return "should-not-return"
            }
            XCTFail("expected CUError.timeout")
        } catch let error as CUError {
            guard case let .timeout(op, ms) = error else {
                XCTFail("expected timeout, got \(error)")
                return
            }
            XCTAssertEqual(op, "capture_window")
            XCTAssertEqual(ms, deadlineMs)
            // Production path substitutes captureDeadlineMs for the second field.
            XCTAssertEqual(WindowCapture.captureDeadlineMs, 5_000)
            XCTAssertEqual(op, WindowCapture.captureOperation)
        } catch {
            XCTFail("expected CUError.timeout, got \(error)")
        }
    }

    func testCallerCancellationWinsOverDeadline() async {
        let started = expectation(description: "work started")
        let task = Task {
            try await WindowCapture.withDeadline(
                deadlineMs: 5_000,
                operation: WindowCapture.captureOperation
            ) {
                started.fulfill()
                // Park until cancelled. Must not reach a timeout throw.
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return "completed"
            }
        }

        await fulfillment(of: [started], timeout: 2.0)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // Expected: caller cancel stays cancellation, not timeout.
        } catch let error as CUError {
            XCTFail("cancellation must not become \(error)")
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testDeadlineDoesNotDoubleComplete() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() {
                lock.lock(); value += 1; lock.unlock()
            }
            var current: Int {
                lock.lock(); defer { lock.unlock() }; return value
            }
        }
        let successes = Counter()
        let deadlineMs = 40

        do {
            _ = try await WindowCapture.withDeadline(
                deadlineMs: deadlineMs,
                operation: WindowCapture.captureOperation
            ) {
                // Longer than the deadline; if not cancelled, would complete "late".
                try await Task.sleep(nanoseconds: 500_000_000)
                successes.increment()
                return "late"
            }
            XCTFail("expected timeout")
        } catch let error as CUError {
            guard case let .timeout(op, ms) = error else {
                XCTFail("expected timeout, got \(error)")
                return
            }
            XCTAssertEqual(op, "capture_window")
            XCTAssertEqual(ms, deadlineMs)
        } catch {
            XCTFail("expected CUError.timeout, got \(error)")
            return
        }

        // Allow any straggler that ignored cancellation to finish; the race must
        // still have returned exactly once via timeout (already observed above),
        // and the cancelled work body must not have recorded a success.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(
            successes.current,
            0,
            "work cancelled by the deadline must not also complete successfully"
        )
    }

    func testWorkErrorPropagatesUnchanged() async {
        struct Boom: Error, Equatable {}
        do {
            _ = try await WindowCapture.withDeadline(
                deadlineMs: 500,
                operation: WindowCapture.captureOperation
            ) {
                throw Boom()
            }
            XCTFail("expected Boom")
        } catch is Boom {
            // Expected: capture faults stay raw for classifyUncapturable.
        } catch let error as CUError {
            XCTFail("work errors must not become \(error)")
        } catch {
            XCTFail("expected Boom, got \(error)")
        }
    }
}
