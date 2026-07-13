import XCTest
@testable import ComputerUseCore

/// Boundary-tracing scaffold. Span/aggregation logic is
/// exercised with an INJECTED clock and sink — never the wall clock — so the assertions are
/// deterministic. Zero-overhead-when-off is proven by asserting `span(_:)` is `nil` and the
/// sink is never touched.
final class TraceTests: XCTestCase {
    /// A deterministic clock returning the next value from a scripted sequence on each call.
    private final class ScriptedClock: @unchecked Sendable {
        private let values: [UInt64]
        private var index = 0
        private let lock = NSLock()
        init(_ values: [UInt64]) { self.values = values }
        func next() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            defer { index += 1 }
            return values[min(index, values.count - 1)]
        }
    }

    /// A thread-safe sink capturing every emitted line.
    private final class CaptureSink: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var lines: [String] = []
        func write(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            lines.append(line)
        }
    }

    // MARK: - Disabled tracer is zero-overhead

    func testDisabledTracerReturnsNilSpanAndNeverEmits() {
        let sink = CaptureSink()
        let tracer = Tracer(enabled: false, clock: { 0 }, sink: { sink.write($0) })
        XCTAssertFalse(tracer.isEnabled)
        XCTAssertNil(tracer.span("get_app_state"), "a disabled tracer opens no span (zero-overhead)")
        // The optional-chained instrumentation site does nothing.
        tracer.span("get_app_state")?.mark("ax_tree")
        XCTAssertTrue(sink.lines.isEmpty)
    }

    // MARK: - Enabled span aggregation with an injected clock

    func testEnabledSpanEmitsMarksAndCountsWithInjectedClock() throws {
        // Clock calls, in order: span() start=1000; mark() 5000; end() total=9000.
        let clock = ScriptedClock([1_000, 5_000, 9_000])
        let sink = CaptureSink()
        let tracer = Tracer(enabled: true, clock: { clock.next() }, sink: { sink.write($0) })

        let span = try XCTUnwrap(tracer.span("get_app_state"))
        span.mark("ax_tree")   // elapsed 5000-1000 = 4000ns = 4us
        span.count("nodes", 42)
        span.count("tree_bytes", 1536)
        span.end()             // total 9000-1000 = 8000ns = 8us

        XCTAssertEqual(sink.lines.count, 1)
        XCTAssertEqual(
            sink.lines[0],
            "trace get_app_state total_us=8 ax_tree_us=4 nodes=42 tree_bytes=1536"
        )
    }

    func testEndIsIdempotent() throws {
        let clock = ScriptedClock([0, 3_000, 3_000])
        let sink = CaptureSink()
        let tracer = Tracer(enabled: true, clock: { clock.next() }, sink: { sink.write($0) })
        let span = try XCTUnwrap(tracer.span("action:click"))
        span.end()
        span.end() // second end must not emit again
        XCTAssertEqual(sink.lines.count, 1)
    }

    // MARK: - Pure formatter

    func testFormatMicrosecondConversionAndOrdering() {
        let line = TraceSpan.format(
            name: "mcp_request:tools/call",
            totalNanos: 12_345,
            marks: [("policy_ok", 2_000), ("screenshot", 10_000)],
            counters: [("nodes", 7)]
        )
        // 12_345 ns -> 12 us (truncating). Marks precede counters; both preserve order.
        XCTAssertEqual(line, "trace mcp_request:tools/call total_us=12 policy_ok_us=2 screenshot_us=10 nodes=7")
    }

    func testMicrosTruncates() {
        XCTAssertEqual(TraceSpan.micros(999), 0)
        XCTAssertEqual(TraceSpan.micros(1_000), 1)
        XCTAssertEqual(TraceSpan.micros(1_999), 1)
    }
}
