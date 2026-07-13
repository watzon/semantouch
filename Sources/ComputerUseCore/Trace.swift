import Foundation
import Dispatch

// Trace — a lightweight, dependency-free boundary-tracing facility. This is
// instrumentation, not an optimization pass: it measures runtime latency and
// payload-size boundaries and does nothing until explicitly enabled.
//
// - Off by default. Enabled only when the environment variable `SEMANTOUCH_TRACE=1` is
//   set at process start.
// - Emits ONE line per span to **STDERR** (never stdout — stdout carries framed
//   MCP protocol traffic only, PROTOCOL §1).
// - Zero-overhead when off: `Tracer.span(_:)` returns `nil`, so every instrumentation
//   site is written as `span?.mark(...)` / `span?.count(...)` and allocates and
//   measures nothing on the hot path.
// - The span/aggregation logic takes an injected clock so it is unit-testable without
//   the wall clock.

/// The process tracer. Construct directly with an injected clock + sink for tests;
/// use `Tracer.shared` in production.
public final class Tracer: @unchecked Sendable {
    /// A monotonic clock returning nanoseconds. Injected so tests are deterministic.
    public typealias Clock = @Sendable () -> UInt64

    /// Whether tracing is on. When `false`, `span(_:)` returns `nil`.
    public let isEnabled: Bool
    private let clock: Clock
    private let sink: @Sendable (String) -> Void

    public init(
        enabled: Bool,
        clock: @escaping Clock,
        sink: @escaping @Sendable (String) -> Void
    ) {
        self.isEnabled = enabled
        self.clock = clock
        self.sink = sink
    }

    /// The process-wide tracer. Reads `SEMANTOUCH_TRACE` once; uses a monotonic clock and a
    /// stderr sink. `SEMANTOUCH_TRACE=1` turns it on; anything else leaves it off.
    public static let shared = Tracer(
        enabled: ProcessInfo.processInfo.environment["SEMANTOUCH_TRACE"] == "1",
        clock: { DispatchTime.now().uptimeNanoseconds },
        sink: { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    )

    /// Open a span named `name`, or `nil` when tracing is off (the zero-overhead path).
    /// The span records boundary marks (`mark`) and scalar metrics (`count`) and emits a
    /// single line when `end()` is called.
    public func span(_ name: String) -> TraceSpan? {
        guard isEnabled else { return nil }
        return TraceSpan(name: name, start: clock(), clock: clock, sink: sink)
    }
}

/// One traced operation. Records boundary crossings (`mark` — elapsed-ns-since-open) and
/// scalar metrics (`count` — node counts, byte sizes), then emits a single-line summary to
/// the tracer's sink on `end()`. Thread-safe; `end()` is idempotent.
public final class TraceSpan: @unchecked Sendable {
    private let name: String
    private let start: UInt64
    private let clock: Tracer.Clock
    private let sink: (String) -> Void

    private let lock = NSLock()
    private var marks: [(label: String, elapsed: UInt64)] = []
    private var counters: [(label: String, value: Int)] = []
    private var ended = false

    init(name: String, start: UInt64, clock: @escaping Tracer.Clock, sink: @escaping (String) -> Void) {
        self.name = name
        self.start = start
        self.clock = clock
        self.sink = sink
    }

    /// Record a boundary crossing: the nanoseconds elapsed since the span opened.
    public func mark(_ label: String) {
        let elapsed = clock() &- start
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        marks.append((label, elapsed))
    }

    /// Record a scalar metric (e.g. `nodes`, `tree_bytes`, `diff_bytes`).
    public func count(_ label: String, _ value: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        counters.append((label, value))
    }

    /// Emit the span's single summary line to the sink (idempotent). The line is
    /// `trace <name> total_us=<n> <mark>_us=<n> … <counter>=<n> …` — microseconds for
    /// timings, raw values for counters.
    public func end() {
        let total = clock() &- start
        lock.lock()
        if ended { lock.unlock(); return }
        ended = true
        let marksCopy = marks
        let countersCopy = counters
        lock.unlock()
        sink(TraceSpan.format(name: name, totalNanos: total, marks: marksCopy, counters: countersCopy))
    }

    /// Pure line formatter, exposed for unit tests.
    static func format(
        name: String,
        totalNanos: UInt64,
        marks: [(label: String, elapsed: UInt64)],
        counters: [(label: String, value: Int)]
    ) -> String {
        var parts: [String] = ["trace", name, "total_us=\(micros(totalNanos))"]
        for mark in marks {
            parts.append("\(mark.label)_us=\(micros(mark.elapsed))")
        }
        for counter in counters {
            parts.append("\(counter.label)=\(counter.value)")
        }
        return parts.joined(separator: " ")
    }

    /// Nanoseconds → whole microseconds (truncating). Micros keep trace lines compact
    /// while retaining useful resolution for runtime boundaries.
    static func micros(_ nanos: UInt64) -> UInt64 { nanos / 1_000 }
}
