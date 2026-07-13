import XCTest
import Foundation
import ComputerUseCore
@testable import MCPServer

/// Cancellation dispatch (§17): `notifications/cancelled` reaching an in-flight request's
/// token, process-shutdown cancellation, and the registry's unknown/completed no-op. The
/// end-to-end tests drive the concurrent `run()` loop over an in-memory pipe transport, using
/// a fake slow handler injected through the existing `ToolHandler` seam (no permissions, no
/// real capture) to prove the plumbing deterministically.
final class CancellationDispatchTests: XCTestCase {
    // MARK: - Registry unit behavior

    func testRegistryRoutesCancelToRegisteredToken() {
        let registry = RequestCancellationRegistry()
        let token = registry.register(id: .int(7))
        XCTAssertEqual(registry.inFlightCount, 1)
        registry.cancel(id: .int(7), reason: "stop")
        XCTAssertTrue(token.isCancelled)
        XCTAssertEqual(token.reason, "stop")
    }

    func testRegistryCancelUnknownIdIsNoOp() {
        let registry = RequestCancellationRegistry()
        // No token registered for this id — must not crash and must change nothing.
        registry.cancel(id: .int(999), reason: nil)
        XCTAssertEqual(registry.inFlightCount, 0)
    }

    func testRegistryCancelCompletedIdIsNoOp() {
        let registry = RequestCancellationRegistry()
        let token = registry.register(id: .string("abc"))
        registry.deregister(id: .string("abc"), token: token) // request completed
        registry.cancel(id: .string("abc"), reason: "late") // arrives after completion
        XCTAssertFalse(token.isCancelled, "a cancel for a completed request is inert")
        XCTAssertEqual(registry.inFlightCount, 0)
    }

    func testRegistryCancelAllCancelsEveryInFlightToken() {
        let registry = RequestCancellationRegistry()
        let a = registry.register(id: .int(1))
        let b = registry.register(id: .string("two"))
        registry.cancelAll(reason: "sigterm")
        XCTAssertTrue(a.isCancelled)
        XCTAssertTrue(b.isCancelled)
        XCTAssertEqual(a.reason, "sigterm")
    }

    func testStringAndNumericIdsKeyDistinctly() {
        let registry = RequestCancellationRegistry()
        let numeric = registry.register(id: .int(7))
        let string = registry.register(id: .string("7"))
        // A cancel for the numeric id must not trip the string-"7" token, and vice versa.
        registry.cancel(id: .int(7), reason: nil)
        XCTAssertTrue(numeric.isCancelled)
        XCTAssertFalse(string.isCancelled)
    }

    func testDeregisterIsInstanceGuardedAgainstDuplicateInFlightId() {
        // A later request reuses an id whose earlier request is still registered (register
        // replaces the entry, newest-wins). When the EARLIER request completes and deregisters
        // with ITS token, the instance guard leaves the later token in place, so a cancel for
        // that id still reaches the later, in-flight request.
        let registry = RequestCancellationRegistry()
        let first = registry.register(id: .int(1))
        let second = registry.register(id: .int(1)) // duplicate id: replaces the map entry
        XCTAssertEqual(registry.inFlightCount, 1)

        registry.deregister(id: .int(1), token: first) // the earlier request finishes
        XCTAssertEqual(registry.inFlightCount, 1, "the earlier request must not evict the later token")

        registry.cancel(id: .int(1), reason: "stop")
        XCTAssertTrue(second.isCancelled, "the still-in-flight (later) request must remain cancellable")
        XCTAssertFalse(first.isCancelled)

        registry.deregister(id: .int(1), token: second) // the later request finishes
        XCTAssertEqual(registry.inFlightCount, 0)
    }

    // MARK: - End-to-end over the concurrent run() loop

    func testCancelledRequestReturnsTypedResultAndStopsWork() throws {
        let started = DispatchSemaphore(value: 0)
        let observed = DispatchSemaphore(value: 0)
        let returnedNormally = Flag()

        let registry = ToolRegistry.standard(handlers: [
            "list_apps": { _ in
                started.signal()
                do {
                    // A long operation standing in for the get_app_state capture/tree build.
                    // Task.sleep reacts to cancellation immediately (deterministic).
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    returnedNormally.set()
                    return ToolResult.text(#"{"apps":[]}"#)
                } catch {
                    observed.signal() // the work saw the cancellation and stops
                    throw error       // -> mapped to CUError.cancelled by the server
                }
            },
        ])

        let harness = PipeHarness(registry: registry)
        harness.start()
        harness.send(Self.initializeLine)
        harness.send(Self.callLine(id: 7, name: "list_apps"))

        XCTAssertEqual(started.wait(timeout: .now() + 5), .success, "handler should be in-flight")
        harness.send(Self.cancelLine(requestId: 7, reason: "client requested"))
        XCTAssertEqual(observed.wait(timeout: .now() + 5), .success, "handler should observe the cancel")

        let responses = harness.finishAndCollect()
        let call = try XCTUnwrap(responses.first { $0["id"]?.intValue == 7 }, "no reply for the cancelled call")
        XCTAssertNil(call["error"], "a cancelled tool call is a successful envelope with isError:true")
        XCTAssertEqual(call["result"]?["isError"]?.boolValue, true)
        let text = try XCTUnwrap(call["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let payload = try JSONValue.parse(text)
        XCTAssertEqual(payload["code"]?.stringValue, "cancelled")
        XCTAssertEqual(payload["data"]?["reason"]?.stringValue, "client requested")
        XCTAssertFalse(returnedNormally.value, "the cancelled work must not have completed normally")
    }

    func testQueuedRequestCancelledWhileWaitingBehindSlowRequest() throws {
        // Exercises the queued-but-not-yet-executing window that the `started`-synchronized
        // test above structurally hides: a slow request occupies the single serial execution
        // lane while the *target* request sits queued behind it, and a cancel for the target
        // arrives while it is still queued (it never gets a `started` signal). The token must
        // already be registered — on the read thread, in `enqueueRequest`, before the async
        // submit — so the cancel latches and the target returns the typed `cancelled` result
        // instead of running to completion. Registering the token inside the execution block
        // (the prior bug) would drop this cancel, and the target would complete normally.
        let blockerStarted = DispatchSemaphore(value: 0)
        let (releaseStream, releaseContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let targetCompletedNormally = Flag()

        let registry = ToolRegistry.standard(handlers: [
            // The blocker: occupies the serial execution lane until explicitly released.
            "doctor": { _ in
                blockerStarted.signal()
                for await _ in releaseStream { break }
                return ToolResult.text(#"{"ok":true}"#)
            },
            // The target: if it ever completes normally, the queued cancel was lost.
            "list_apps": { _ in
                try await Task.sleep(nanoseconds: 60_000_000_000)
                targetCompletedNormally.set()
                return ToolResult.text(#"{"apps":[]}"#)
            },
        ])

        let harness = PipeHarness(registry: registry)
        harness.start()
        harness.send(Self.initializeLine)
        // 1. The blocker occupies the execution lane.
        harness.send(Self.callLine(id: 1, name: "doctor"))
        XCTAssertEqual(blockerStarted.wait(timeout: .now() + 5), .success, "blocker should hold the lane")
        // 2. The target enqueues behind the blocker; then a cancel for it, with NO
        //    synchronization on the target — it is provably still queued when the cancel is read.
        harness.send(Self.callLine(id: 2, name: "list_apps"))
        harness.send(Self.cancelLine(requestId: 2, reason: "queued cancel"))
        // 3. Release the blocker so the (already-cancelled) target can be dequeued and unwind.
        releaseContinuation.yield(())
        releaseContinuation.finish()

        let responses = harness.finishAndCollect()
        let call = try XCTUnwrap(responses.first { $0["id"]?.intValue == 2 }, "no reply for the queued call")
        XCTAssertNil(call["error"], "a cancelled tool call is a successful envelope with isError:true")
        XCTAssertEqual(call["result"]?["isError"]?.boolValue, true)
        let text = try XCTUnwrap(call["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let payload = try JSONValue.parse(text)
        XCTAssertEqual(payload["code"]?.stringValue, "cancelled")
        XCTAssertEqual(
            payload["data"]?["reason"]?.stringValue, "queued cancel",
            "the cancel read while the request was queued must latch its token (not EOF/shutdown)"
        )
        XCTAssertFalse(targetCompletedNormally.value, "the cancelled work must not have completed normally")
    }

    func testNormalRequestIsUnaffected() throws {
        let registry = ToolRegistry.standard(handlers: [
            "list_apps": { _ in ToolResult.text(#"{"apps":[]}"#) },
        ])
        let harness = PipeHarness(registry: registry)
        harness.start()
        harness.send(Self.initializeLine)
        harness.send(Self.callLine(id: 3, name: "list_apps"))

        let responses = harness.finishAndCollect()
        let call = try XCTUnwrap(responses.first { $0["id"]?.intValue == 3 })
        XCTAssertNil(call["error"])
        XCTAssertEqual(call["result"]?["isError"]?.boolValue, false)
        let text = try XCTUnwrap(call["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertEqual(text, #"{"apps":[]}"#)
    }

    func testCancelForUnknownIdDoesNotDisturbALaterRequest() throws {
        let registry = ToolRegistry.standard(handlers: [
            "list_apps": { _ in ToolResult.text(#"{"apps":[]}"#) },
        ])
        let harness = PipeHarness(registry: registry)
        harness.start()
        harness.send(Self.initializeLine)
        // A stray cancel for an id that was never issued — must be a safe no-op.
        harness.send(Self.cancelLine(requestId: 999, reason: nil))
        harness.send(Self.callLine(id: 5, name: "list_apps"))

        let responses = harness.finishAndCollect()
        let call = try XCTUnwrap(responses.first { $0["id"]?.intValue == 5 })
        XCTAssertEqual(call["result"]?["isError"]?.boolValue, false)
    }

    func testStdinEOFCancelsInFlightWorkAndReturns() throws {
        let started = DispatchSemaphore(value: 0)
        let observed = DispatchSemaphore(value: 0)
        let registry = ToolRegistry.standard(handlers: [
            "list_apps": { _ in
                started.signal()
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    return ToolResult.text(#"{"apps":[]}"#)
                } catch {
                    observed.signal()
                    throw error
                }
            },
        ])
        let harness = PipeHarness(registry: registry)
        harness.start()
        harness.send(Self.initializeLine)
        harness.send(Self.callLine(id: 11, name: "list_apps"))
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)

        // Close stdin WITHOUT a cancel notification: run() must cancel in-flight work on EOF.
        let responses = harness.finishAndCollect()
        XCTAssertEqual(observed.wait(timeout: .now() + 5), .success, "EOF should cancel in-flight work")
        let call = try XCTUnwrap(responses.first { $0["id"]?.intValue == 11 })
        XCTAssertEqual(call["result"]?["isError"]?.boolValue, true)
        let text = try XCTUnwrap(call["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertEqual(try JSONValue.parse(text)["code"]?.stringValue, "cancelled")
    }

    // MARK: - Line builders

    private static let initializeLine = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#

    private static func callLine(id: Int, name: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":{}}}"#
    }

    private static func cancelLine(requestId: Int, reason: String?) -> String {
        if let reason {
            return #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(requestId),"reason":"\#(reason)"}}"#
        }
        return #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(requestId)}}"#
    }
}

/// A one-shot boolean flag, thread-safe.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Drives an `MCPServer.run()` over in-memory pipes: feed request lines, then close stdin and
/// collect every reply as parsed JSON.
private final class PipeHarness: @unchecked Sendable {
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let server: MCPServer
    private let done = DispatchSemaphore(value: 0)

    init(registry: ToolRegistry) {
        let transport = StdioTransport(
            input: inPipe.fileHandleForReading,
            output: outPipe.fileHandleForWriting
        )
        server = MCPServer(transport: transport, registry: registry)
    }

    func start() {
        Thread.detachNewThread { [server, done] in
            server.run()
            done.signal()
        }
    }

    func send(_ line: String) {
        inPipe.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    /// Close stdin (EOF), wait for `run()` to return, then read and parse every reply line.
    func finishAndCollect() -> [JSONValue] {
        inPipe.fileHandleForWriting.closeFile()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "run() should return after EOF")
        // The server never closes its output; close the write end so readToEnd sees EOF.
        try? outPipe.fileHandleForWriting.close()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONValue.parse(String($0)) }
    }
}
