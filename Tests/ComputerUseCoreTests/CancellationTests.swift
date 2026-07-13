import XCTest
@testable import ComputerUseCore

/// Cooperative cancellation latch (§17). Pure, permission-free logic tests.
final class CancellationTests: XCTestCase {
    func testCancelLatchesAndCarriesReason() {
        let token = CancellationToken()
        XCTAssertFalse(token.isCancelled)
        XCTAssertNil(token.reason)
        token.cancel(reason: "client requested")
        XCTAssertTrue(token.isCancelled)
        XCTAssertEqual(token.reason, "client requested")
    }

    func testSecondCancelIsIgnored() {
        let token = CancellationToken()
        token.cancel(reason: "first")
        token.cancel(reason: "second")
        XCTAssertEqual(token.reason, "first", "the first cancel's reason wins")
    }

    func testOnCancelFiresExactlyOnce() {
        let token = CancellationToken()
        var fires = 0
        token.onCancel { fires += 1 }
        token.cancel()
        token.cancel() // no second fire
        XCTAssertEqual(fires, 1)
    }

    func testOnCancelAfterAlreadyCancelledFiresImmediately() {
        let token = CancellationToken()
        token.cancel()
        var fired = false
        token.onCancel { fired = true }
        XCTAssertTrue(fired, "registering after cancel must fire immediately")
    }

    func testThrowIfCancelledThrowsTypedError() throws {
        let token = CancellationToken()
        XCTAssertNoThrow(try token.throwIfCancelled())
        token.cancel(reason: "boom")
        do {
            try token.throwIfCancelled()
            XCTFail("expected a throw")
        } catch let error as CUError {
            guard case let .cancelled(reason) = error else {
                return XCTFail("expected .cancelled, got \(error.code.rawValue)")
            }
            XCTAssertEqual(reason, "boom")
        }
    }

    func testCheckpointHonoursAmbientCurrentToken() throws {
        let token = CancellationToken()
        token.cancel(reason: "ambient")
        try CancellationToken.$current.withValue(token) {
            do {
                try CancellationToken.checkpoint()
                XCTFail("expected the ambient token to trip the checkpoint")
            } catch let error as CUError {
                guard case let .cancelled(reason) = error else {
                    return XCTFail("expected .cancelled")
                }
                XCTAssertEqual(reason, "ambient")
            }
        }
    }

    func testCheckpointPassesWhenNoAmbientTokenCancelled() {
        // No ambient token, task not cancelled → checkpoint is a no-op.
        XCTAssertNoThrow(try CancellationToken.checkpoint())
    }
}
