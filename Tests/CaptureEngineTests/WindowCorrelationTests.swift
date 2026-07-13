import XCTest
import ComputerUseCore
@testable import CaptureEngine

/// AX↔SCWindow correlation scoring on synthetic fixtures (PROTOCOL §10.3).
/// No permissions.
///
/// This is the Phase-0 headline acceptance suite: **at least 25 distinct window-configuration
/// scenarios** exercised through the same `correlate` entry point, asserting per the contract:
///
/// 1. **ZERO wrong AX↔SCWindow matches** — every successful match returns exactly the intended
///    window (never an approximate neighbour), and every refusal scenario refuses.
/// 2. Conflicting signals yield **`ambiguous_window`** (several plausible) or
///    **`uncorrelated_window`** (no plausible counterpart) — never a guess.
/// 3. Every successful match **records which signals decided it** (`match.signals`), always
///    beginning with the `pid`+`frame` gate.
///
/// The scenarios are a table so the count is self-evident (`testScenarioCountIsAtLeast25`).
/// They span: multiple normal windows, duplicate/identical titles, empty titles, sheets /
/// drawers / panels (non-zero layer), Retina + non-Retina scaling, sub-pixel / off-by-one
/// frame rounding, heavy overlap, near-identical frames differing only by owner pid,
/// minimized / off-screen candidates, alpha<1 cover windows, and genuinely-ambiguous cases.
final class WindowCorrelationTests: XCTestCase {
    private let app = "Fixture"

    // MARK: - Fixture builders

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
        Rect(x: x, y: y, width: w, height: h)
    }

    private func win(
        _ number: Int,
        pid: Int32,
        _ frame: Rect,
        title: String? = nil,
        layer: Int = 0,
        onscreen: Bool = true,
        alpha: Double = 1.0
    ) -> WindowInfo {
        WindowInfo(
            windowNumber: number,
            ownerPID: pid,
            bounds: frame,
            title: title,
            layer: layer,
            isOnscreen: onscreen,
            alpha: alpha,
            hasShareableWindow: true
        )
    }

    private func ax(_ pid: Int32, _ frame: Rect, _ title: String? = nil) -> AXWindowDescriptor {
        AXWindowDescriptor(pid: pid, frame: frame, title: title)
    }

    // MARK: - Scenario model

    /// The expected correlation outcome for a scenario.
    private enum Expected: Equatable {
        /// A successful, unambiguous match: the chosen `windowNumber`, the exact deciding
        /// signal log, and the confidence.
        case match(window: Int, signals: [String], confidence: CorrelationConfidence)
        /// A refusal because several windows remained plausible (`ambiguous_window`), listing
        /// the candidate window ids.
        case ambiguous(candidates: Set<Int>)
        /// A refusal because no plausible counterpart survived (`uncorrelated_window`), with the
        /// signals tried and the surfaced diagnostic sc-window id (if any).
        case uncorrelated(tried: [String], scGuess: Int?)
    }

    private struct Scenario {
        let name: String
        let ax: AXWindowDescriptor
        let candidates: [WindowInfo]
        let expected: Expected
    }

    /// The default 400×300 target frame at the origin.
    private var F: Rect { rect(0, 0, 400, 300) }

    /// The full table. **At least 25** distinct configurations; asserted below.
    private var scenarios: [Scenario] {
        [
            // --- Clean single matches (frame is the primary discriminator) -----------------
            Scenario(
                name: "unique frame + matching title → high",
                ax: ax(10, F, "A"),
                candidates: [win(1, pid: 10, F, title: "A"), win(2, pid: 10, rect(500, 0, 400, 300), title: "B")],
                expected: .match(window: 1, signals: ["pid", "frame", "title"], confidence: .high)
            ),
            Scenario(
                name: "single frame match, no titles anywhere → high",
                ax: ax(10, F, nil),
                candidates: [win(1, pid: 10, F, title: nil)],
                expected: .match(window: 1, signals: ["pid", "frame"], confidence: .high)
            ),
            Scenario(
                name: "single frame match, AX title but candidate has none → title not credited, high",
                ax: ax(10, F, "Doc"),
                candidates: [win(1, pid: 10, F, title: nil)],
                expected: .match(window: 1, signals: ["pid", "frame"], confidence: .high)
            ),
            Scenario(
                // Single frame match where BOTH sides carry a (different) title: the sole
                // candidate is not a guess — frame already singled it out — but the title
                // disagreement softens confidence to medium and is NOT credited as a signal.
                name: "single frame match, conflicting titles → title not credited, medium",
                ax: ax(10, F, "X"),
                candidates: [win(1, pid: 10, F, title: "Y")],
                expected: .match(window: 1, signals: ["pid", "frame"], confidence: .medium)
            ),
            Scenario(
                name: "off-by-one bounds within tolerance → high",
                ax: ax(10, F, "A"),
                candidates: [
                    win(1, pid: 10, rect(1, 1, 401, 299), title: "A"),
                    win(2, pid: 10, rect(100, 100, 400, 300), title: "A"),
                ],
                expected: .match(window: 1, signals: ["pid", "frame", "title"], confidence: .high)
            ),
            Scenario(
                name: "Retina sub-pixel half-point offset within tolerance → high",
                ax: ax(10, rect(100, 200, 800, 600), "Editor"),
                candidates: [win(1, pid: 10, rect(100.5, 200.5, 800, 600), title: "Editor")],
                expected: .match(window: 1, signals: ["pid", "frame", "title"], confidence: .high)
            ),
            Scenario(
                name: "non-Retina integer frame, exact match → high",
                ax: ax(20, rect(0, 0, 1024, 768), "Term"),
                candidates: [win(1, pid: 20, rect(0, 0, 1024, 768), title: "Term")],
                expected: .match(window: 1, signals: ["pid", "frame", "title"], confidence: .high)
            ),

            // --- Multiple normal windows ---------------------------------------------------
            Scenario(
                name: "three normal windows, frame selects the middle one",
                ax: ax(10, rect(200, 150, 640, 480), "Mid"),
                candidates: [
                    win(1, pid: 10, rect(0, 0, 300, 200), title: "Top"),
                    win(2, pid: 10, rect(200, 150, 640, 480), title: "Mid"),
                    win(3, pid: 10, rect(900, 600, 300, 200), title: "Bot"),
                ],
                expected: .match(window: 2, signals: ["pid", "frame", "title"], confidence: .high)
            ),
            Scenario(
                name: "five windows, exactly one frame matches",
                ax: ax(10, rect(50, 50, 200, 200), "X"),
                candidates: [
                    win(1, pid: 10, rect(0, 0, 100, 100), title: "a"),
                    win(2, pid: 10, rect(300, 0, 100, 100), title: "b"),
                    win(3, pid: 10, rect(50, 50, 200, 200), title: "X"),
                    win(4, pid: 10, rect(600, 600, 100, 100), title: "d"),
                    win(5, pid: 10, rect(800, 800, 100, 100), title: "e"),
                ],
                expected: .match(window: 3, signals: ["pid", "frame", "title"], confidence: .high)
            ),

            // --- Duplicate / identical titles ----------------------------------------------
            Scenario(
                name: "duplicate titles disambiguated by frame",
                ax: ax(10, F, "Doc"),
                candidates: [win(1, pid: 10, F, title: "Doc"), win(2, pid: 10, rect(500, 0, 400, 300), title: "Doc")],
                expected: .match(window: 1, signals: ["pid", "frame", "title"], confidence: .high)
            ),
            Scenario(
                name: "identical frames AND identical titles → ambiguous",
                ax: ax(10, F, "Same"),
                candidates: [win(1, pid: 10, F, title: "Same"), win(2, pid: 10, F, title: "Same")],
                expected: .ambiguous(candidates: [1, 2])
            ),

            // --- Empty titles --------------------------------------------------------------
            Scenario(
                name: "whitespace-only AX title normalizes to nil → title not credited",
                ax: ax(10, F, "   "),
                candidates: [win(1, pid: 10, F, title: "Actual")],
                expected: .match(window: 1, signals: ["pid", "frame"], confidence: .high)
            ),
            Scenario(
                name: "empty candidate title → title not credited",
                ax: ax(10, F, "Real"),
                candidates: [win(1, pid: 10, F, title: "")],
                expected: .match(window: 1, signals: ["pid", "frame"], confidence: .high)
            ),
            Scenario(
                name: "both titles empty/nil → frame alone matches",
                ax: ax(10, F, ""),
                candidates: [win(1, pid: 10, F, title: nil)],
                expected: .match(window: 1, signals: ["pid", "frame"], confidence: .high)
            ),

            // --- Sheets / drawers / panels (non-zero layer) --------------------------------
            Scenario(
                name: "sheet shares parent frame; title disambiguates (both layer 0)",
                ax: ax(10, F, "Sheet"),
                candidates: [win(1, pid: 10, F, title: "Main", layer: 0), win(2, pid: 10, F, title: "Sheet", layer: 0)],
                expected: .match(window: 2, signals: ["pid", "frame", "title"], confidence: .high)
            ),
            Scenario(
                name: "panel on a non-zero layer loses to the normal window (no titles)",
                ax: ax(10, F, nil),
                candidates: [win(1, pid: 10, F, title: nil, layer: 0), win(2, pid: 10, F, title: nil, layer: 3)],
                expected: .match(window: 1, signals: ["pid", "frame", "layer"], confidence: .medium)
            ),
            Scenario(
                name: "drawer shares title with parent; layer decides",
                ax: ax(10, F, "Doc"),
                candidates: [win(1, pid: 10, F, title: "Doc", layer: 0), win(2, pid: 10, F, title: "Doc", layer: 20)],
                expected: .match(window: 1, signals: ["pid", "frame", "layer"], confidence: .medium)
            ),

            // --- Heavy overlap -------------------------------------------------------------
            Scenario(
                name: "heavily overlapping frames; only the exact one is within tolerance",
                ax: ax(10, rect(100, 100, 500, 400), "Main"),
                candidates: [
                    win(1, pid: 10, rect(100, 100, 500, 400), title: "Main"),
                    win(2, pid: 10, rect(120, 120, 500, 400), title: "Other"),
                    win(3, pid: 10, rect(80, 80, 540, 440), title: "Third"),
                ],
                expected: .match(window: 1, signals: ["pid", "frame", "title"], confidence: .high)
            ),
            Scenario(
                name: "cascaded windows offset by 22pt; frame tolerance isolates the exact one",
                ax: ax(10, rect(66, 66, 400, 300), "W4"),
                candidates: [
                    win(1, pid: 10, rect(0, 0, 400, 300), title: "W1"),
                    win(2, pid: 10, rect(22, 22, 400, 300), title: "W2"),
                    win(3, pid: 10, rect(44, 44, 400, 300), title: "W3"),
                    win(4, pid: 10, rect(66, 66, 400, 300), title: "W4"),
                ],
                expected: .match(window: 4, signals: ["pid", "frame", "title"], confidence: .high)
            ),

            // --- Near-identical frames differing only by owner pid -------------------------
            Scenario(
                name: "same frame, wrong pid → uncorrelated at the pid gate, no sc guess",
                ax: ax(10, F, "A"),
                candidates: [win(1, pid: 99, F, title: "A")],
                expected: .uncorrelated(tried: ["pid"], scGuess: nil)
            ),
            Scenario(
                name: "two pids share a frame; the owning pid wins (never the foreign one)",
                ax: ax(10, F, "A"),
                candidates: [win(1, pid: 10, F, title: "A"), win(2, pid: 99, F, title: "A")],
                expected: .match(window: 1, signals: ["pid", "frame", "title"], confidence: .high)
            ),
            Scenario(
                name: "only foreign-pid window sits at the frame; owning pid is off-frame → uncorrelated w/ sc guess",
                ax: ax(10, F, "X"),
                candidates: [win(1, pid: 50, F, title: "X"), win(2, pid: 10, rect(900, 900, 400, 300), title: "X")],
                expected: .uncorrelated(tried: ["pid", "frame"], scGuess: 2)
            ),

            // --- Minimized / off-screen candidates -----------------------------------------
            Scenario(
                name: "identical frame+layer, on-screen state is the last-resort tiebreak → low",
                ax: ax(10, F, nil),
                candidates: [
                    win(1, pid: 10, F, title: nil, layer: 0, onscreen: true),
                    win(2, pid: 10, F, title: nil, layer: 0, onscreen: false),
                ],
                expected: .match(window: 1, signals: ["pid", "frame", "onscreen"], confidence: .low)
            ),
            Scenario(
                name: "minimized (off-screen) sibling at a different frame is ignored; frame is unique",
                ax: ax(10, F, "Doc"),
                candidates: [
                    win(1, pid: 10, F, title: "Doc", onscreen: true),
                    win(2, pid: 10, rect(500, 0, 400, 300), title: "Doc", onscreen: false),
                ],
                expected: .match(window: 1, signals: ["pid", "frame", "title"], confidence: .high)
            ),
            Scenario(
                name: "sole candidate is off-screen but frame+title match → still correlates (on-screen not required)",
                ax: ax(10, F, "Doc"),
                candidates: [win(1, pid: 10, F, title: "Doc", onscreen: false)],
                expected: .match(window: 1, signals: ["pid", "frame", "title"], confidence: .high)
            ),

            // --- alpha<1 cover windows (alpha is NOT a correlation signal) ------------------
            Scenario(
                name: "translucent cover identical in every signal → ambiguous (alpha never breaks a tie)",
                ax: ax(10, F, "App"),
                candidates: [
                    win(1, pid: 10, F, title: "App", layer: 0, alpha: 1.0),
                    win(2, pid: 10, F, title: "App", layer: 0, alpha: 0.5),
                ],
                expected: .ambiguous(candidates: [1, 2])
            ),
            Scenario(
                name: "translucent cover on a higher layer; the opaque layer-0 target wins",
                ax: ax(10, F, nil),
                candidates: [
                    win(1, pid: 10, F, title: nil, layer: 0, alpha: 1.0),
                    win(2, pid: 10, F, title: nil, layer: 8, alpha: 0.4),
                ],
                expected: .match(window: 1, signals: ["pid", "frame", "layer"], confidence: .medium)
            ),

            // --- Genuinely-ambiguous cases -------------------------------------------------
            Scenario(
                name: "three windows identical in every signal → ambiguous over all three",
                ax: ax(10, F, "Same"),
                candidates: [
                    win(1, pid: 10, F, title: "Same"),
                    win(2, pid: 10, F, title: "Same"),
                    win(3, pid: 10, F, title: "Same"),
                ],
                expected: .ambiguous(candidates: [1, 2, 3])
            ),
            Scenario(
                name: "two frame matches with conflicting titles, neither equals AX → ambiguous",
                ax: ax(10, F, "Ghost"),
                candidates: [win(1, pid: 10, F, title: "Alpha"), win(2, pid: 10, F, title: "Beta")],
                expected: .ambiguous(candidates: [1, 2])
            ),
            Scenario(
                name: "title narrows the pool but two identical siblings remain → ambiguous over the two",
                ax: ax(10, F, "Dup"),
                candidates: [
                    win(1, pid: 10, F, title: "Dup", layer: 0, onscreen: true),
                    win(2, pid: 10, F, title: "Dup", layer: 0, onscreen: true),
                    win(3, pid: 10, F, title: "Other"),
                ],
                expected: .ambiguous(candidates: [1, 2])
            ),

            // --- Uncorrelated variants -----------------------------------------------------
            Scenario(
                name: "no candidates at all → uncorrelated",
                ax: ax(10, F, "A"),
                candidates: [],
                expected: .uncorrelated(tried: ["pid"], scGuess: nil)
            ),
            Scenario(
                name: "frame just outside tolerance (3pt), lone pid candidate surfaced as sc guess",
                ax: ax(10, F, "A"),
                candidates: [win(1, pid: 10, rect(3, 0, 400, 300), title: "A")],
                expected: .uncorrelated(tried: ["pid", "frame"], scGuess: 1)
            ),
            Scenario(
                name: "two pid candidates both off-frame → uncorrelated, no sc guess",
                ax: ax(10, F, "A"),
                candidates: [
                    win(1, pid: 10, rect(500, 0, 400, 300), title: "A"),
                    win(2, pid: 10, rect(0, 500, 400, 300), title: "A"),
                ],
                expected: .uncorrelated(tried: ["pid", "frame"], scGuess: nil)
            ),
        ]
    }

    // MARK: - Count is self-evidently ≥ 25

    func testScenarioCountIsAtLeast25() {
        XCTAssertGreaterThanOrEqual(scenarios.count, 25, "Phase 0 requires ≥25 correlation configurations")
    }

    // MARK: - The suite: zero wrong matches, typed refusals, recorded signals

    func testAllScenariosMatchExpectationWithZeroWrongMatches() {
        for scenario in scenarios {
            let result = WindowCorrelation.correlate(ax: scenario.ax, candidates: scenario.candidates, app: app)
            switch scenario.expected {
            case let .match(window, signals, confidence):
                guard case let .success(match) = result else {
                    XCTFail("[\(scenario.name)] expected a match, got a refusal")
                    continue
                }
                // ZERO wrong matches: the intended window, exactly.
                XCTAssertEqual(match.window.windowNumber, window, "[\(scenario.name)] wrong window chosen")
                // The deciding-signal log is recorded and begins with the pid+frame gate.
                XCTAssertEqual(match.signals, signals, "[\(scenario.name)] signal log mismatch")
                XCTAssertFalse(match.signals.isEmpty, "[\(scenario.name)] a match must record its signals")
                XCTAssertEqual(Array(match.signals.prefix(2)), ["pid", "frame"], "[\(scenario.name)] signals must start with pid,frame")
                XCTAssertEqual(match.confidence, confidence, "[\(scenario.name)] confidence mismatch")

            case let .ambiguous(candidates):
                guard case let .failure(error) = result, case let .ambiguousWindow(a, refs) = error else {
                    XCTFail("[\(scenario.name)] expected ambiguous_window")
                    continue
                }
                XCTAssertEqual(a, app)
                XCTAssertEqual(Set(refs.compactMap(\.windowId)), candidates, "[\(scenario.name)] ambiguous candidate set mismatch")
                XCTAssertTrue(refs.allSatisfy { $0.source == .screencapturekit }, "[\(scenario.name)] refs must be sc-side")

            case let .uncorrelated(tried, scGuess):
                guard case let .failure(error) = result, case let .uncorrelatedWindow(a, axRef, sc, signalsTried) = error else {
                    XCTFail("[\(scenario.name)] expected uncorrelated_window")
                    continue
                }
                XCTAssertEqual(a, app)
                XCTAssertEqual(axRef?.source, .ax, "[\(scenario.name)] the AX side must be surfaced")
                XCTAssertEqual(signalsTried, tried, "[\(scenario.name)] signalsTried mismatch")
                XCTAssertEqual(sc?.windowId, scGuess, "[\(scenario.name)] sc-guess mismatch")
            }
        }
    }

    /// Cross-cutting invariant: across the whole table, no refusal scenario ever produces a
    /// success and no match scenario ever produces a refusal — the "zero wrong matches" bar.
    func testNoScenarioSilentlyGuesses() {
        for scenario in scenarios {
            let result = WindowCorrelation.correlate(ax: scenario.ax, candidates: scenario.candidates, app: app)
            switch (scenario.expected, result) {
            case (.match, .success), (.ambiguous, .failure), (.uncorrelated, .failure):
                continue // outcome class matches the contract
            default:
                XCTFail("[\(scenario.name)] outcome class diverged from the contract (a guess or a wrong refusal)")
            }
        }
    }

    // MARK: - Pure helpers

    func testFramesEqualTolerance() {
        XCTAssertTrue(WindowCorrelation.framesEqual(rect(0, 0, 400, 300), rect(2, -2, 402, 298), tolerance: 2.0))
        XCTAssertFalse(WindowCorrelation.framesEqual(rect(0, 0, 400, 300), rect(2.1, 0, 400, 300), tolerance: 2.0))
    }

    func testNormalizedTitleTrimsAndNilsEmpty() {
        XCTAssertNil(WindowCorrelation.normalizedTitle(nil))
        XCTAssertNil(WindowCorrelation.normalizedTitle("   "))
        XCTAssertEqual(WindowCorrelation.normalizedTitle("  Hi  "), "Hi")
    }
}
