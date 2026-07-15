import Foundation
import ComputerUseCore
import CursorOverlay

// Offline renderer: drive CursorAnimator with a fixed dt, sample CursorArt
// outline paths + ripples, and emit one self-contained HTML/SVG document.
// Deterministic given (frameCount, fixed session id, fixed waypoint set).
//
// Timeline is PROPORTIONAL to the requested frame count:
//   moves (when they fit) → tip press + held ripple → idle.
// Tiny counts never claim events they cannot sample.

enum DemoRenderer {
    /// Fixed step matching a 60 Hz display. Reproducibility metadata records this.
    static let fixedDt: Double = 1.0 / 60.0
    /// Matches the live AppKit presenter art scale (CursorPanel).
    static let artScale: Double = 0.62
    /// Stable demo session id → deterministic identity colour.
    static let sessionId = "semantouch-cursor-demo"
    static let canvasWidth = 720.0
    static let canvasHeight = 420.0

    /// Candidate waypoints (panel-local). A proportional plan picks a prefix.
    private static let candidateWaypoints: [Point] = [
        Point(x: 80, y: 80),
        Point(x: 520, y: 110),
        Point(x: 300, y: 280),
        Point(x: 600, y: 320),
        Point(x: 180, y: 340),
    ]

    /// Default ripple lifetime from CursorMotionConfig (0.45 s) → frames at fixedDt.
    /// Used only to size the hold so a sampled frame still contains a live ring.
    private static let rippleHoldFramesDefault = max(2, Int((0.45 / fixedDt).rounded(.up)) / 2)

    static func render(frameCount: Int) -> String {
        let count = max(1, frameCount)
        let plan = ScriptPlan.make(frameCount: count)
        let frames = sampleFrames(plan: plan)
        let color = CursorColor.identity(forSession: sessionId, alpha: 0.95)
        return buildHTML(frames: frames, color: color, plan: plan)
    }

    // MARK: - Script plan (proportional, honest)

    /// What the offline script will actually exercise for this frame count.
    fileprivate struct ScriptPlan {
        let frameCount: Int
        /// Waypoints drawn / visited (always at least the start rest point).
        let waypoints: [Point]
        /// Frame indices at which we retarget to `waypoints[i]` as `.moving`.
        let moveAt: [Int]
        /// Frame index of the tip press, if any. Ripple is forced via `press()`.
        let pressAt: Int?
        /// Frame index when we release into idle after the press hold, if any.
        let idleAt: Int?
        /// Human summary of what this run samples (never overclaims).
        let summary: String
        let includesMoves: Bool
        let includesPressRipple: Bool

        static func make(frameCount n: Int) -> ScriptPlan {
            let start = candidateWaypoints[0]

            // --frames 1: a single rest sample. No moves, no press.
            if n <= 1 {
                return ScriptPlan(
                    frameCount: n,
                    waypoints: [start],
                    moveAt: [],
                    pressAt: nil,
                    idleAt: nil,
                    summary: "single rest frame at the start point (no moves, no press)",
                    includesMoves: false,
                    includesPressRipple: false
                )
            }

            // Need: ≥1 move-segment frame + press frame + ≥1 post-press sample for the ring.
            // Absolute minimum for a truthful press/ripple: 3 frames
            //   0: rest/setup, 1: press(), 2: tick still showing aged ripple.
            // Prefer a visible hold (~half of default ripple life) when budget allows.
            let minPressHold = 2
            let desiredPressHold = min(rippleHoldFramesDefault, max(minPressHold, n / 8))
            let desiredIdleTail = max(1, min(12, n / 15))

            // Short: press-only demo (no multi-move claim).
            // Budget: pressAt + hold + optional idle.
            if n < 24 {
                if n < 3 {
                    // 2 frames: rest then a second rest — still no room to show a ring
                    // after press and a hold sample. Stay honest.
                    return ScriptPlan(
                        frameCount: n,
                        waypoints: [start],
                        moveAt: [],
                        pressAt: nil,
                        idleAt: nil,
                        summary: "short rest hold at the start point (frame count too small for moves or a press/ripple sample)",
                        includesMoves: false,
                        includesPressRipple: false
                    )
                }
                let pressAt = max(0, n / 3)
                let hold = max(minPressHold, min(desiredPressHold, n - pressAt - 1))
                let idleAt = min(n - 1, pressAt + hold)
                return ScriptPlan(
                    frameCount: n,
                    waypoints: [start],
                    moveAt: [],
                    pressAt: pressAt,
                    idleAt: idleAt < n ? idleAt : nil,
                    summary: "tip press with click ripple at the start point (no multi-point moves at this frame count)",
                    includesMoves: false,
                    includesPressRipple: true
                )
            }

            // Full script: 3–4 moves, then tip press, then idle.
            // Reserve press hold + idle tail from the end; spend the rest on moves.
            let pressHold = desiredPressHold
            let idleTail = desiredIdleTail
            let reserved = pressHold + idleTail
            let moveBudget = max(8, n - reserved)

            // 4 waypoints → 3 move segments when budget is healthy; 3 waypoints (2 moves)
            // when tighter. Always at least 2 move retargets beyond the start snap.
            let waypointCount: Int
            if moveBudget >= 90 {
                waypointCount = 5 // 4 moves across 5 points
            } else if moveBudget >= 48 {
                waypointCount = 4 // 3 moves
            } else {
                waypointCount = 3 // 2 moves
            }
            let points = Array(candidateWaypoints.prefix(waypointCount))

            // Evenly spaced retarget frames in [0, moveBudget).
            // Index 0 snaps/retargets to the start; subsequent indices fly to later points.
            var moveAt: [Int] = []
            let segments = max(1, points.count - 1)
            for i in 0..<points.count {
                let t = Double(i) / Double(segments)
                let frame = min(moveBudget - 1, Int((t * Double(moveBudget - 1)).rounded()))
                if moveAt.last != frame {
                    moveAt.append(frame)
                }
            }
            // Ensure the final move retarget lands strictly before the press.
            if let last = moveAt.last, last >= moveBudget {
                moveAt[moveAt.count - 1] = moveBudget - 1
            }

            let pressAt = min(n - minPressHold - 1, moveBudget)
            let idleAt = min(n - 1, pressAt + pressHold)
            let moveCount = max(0, points.count - 1)

            return ScriptPlan(
                frameCount: n,
                waypoints: points,
                moveAt: moveAt,
                pressAt: pressAt,
                idleAt: idleAt,
                summary: "\(moveCount) scripted move\(moveCount == 1 ? "" : "s"), then a tip press/ripple, then idle",
                includesMoves: moveCount > 0,
                includesPressRipple: true
            )
        }
    }

    // MARK: - Sampling

    fileprivate struct SampledFrame {
        let index: Int
        let time: Double
        let pose: CursorPose
        let visualState: CursorVisualState
        let outline: [Point]
        let ripples: [RippleFrame]
        let settled: Bool
    }

    private static func sampleFrames(plan: ScriptPlan) -> [SampledFrame] {
        let animator = CursorAnimator()
        let color = CursorColor.identity(forSession: sessionId, alpha: 0.95)
        let start = plan.waypoints[0]
        animator.reset(color: color, at: start)

        // Map move frame → waypoint index for retargets.
        var moveIndexByFrame: [Int: Int] = [:]
        for (idx, frame) in plan.moveAt.enumerated() {
            moveIndexByFrame[frame] = min(idx, plan.waypoints.count - 1)
        }
        // Tip position from the previous sample (or start before frame 0). Used so a
        // press holds the drawn cursor where it is — not a far unfinished waypoint.
        var currentTip = start
        // Once pressed, hold/idle stay on this exact point so the pulse sits under a
        // stationary tip (no second deferred pulse at another target).
        var heldTip: Point?

        var samples: [SampledFrame] = []
        samples.reserveCapacity(plan.frameCount)

        for i in 0..<plan.frameCount {
            if heldTip == nil, let wpIndex = moveIndexByFrame[i] {
                let target = plan.waypoints[wpIndex]
                // Start snap (frame 0 / first point) as idle rest; later points fly as moves.
                let state: CursorVisualState = (wpIndex == 0) ? .idle : .moving
                animator.retarget(to: target, state: state)
            }

            if let pressAt = plan.pressAt, i == pressAt {
                // Press at the previously sampled tip. Transition into `.pressed` arms
                // the animator's single deferred arrival pulse at that exact point —
                // do NOT also call press(), which would duplicate the ring.
                let tip = currentTip
                heldTip = tip
                animator.retarget(to: tip, state: .pressed)
            }

            if let idleAt = plan.idleAt, i == idleAt {
                let tip = heldTip ?? currentTip
                heldTip = tip
                animator.retarget(to: tip, state: .idle)
            }

            // Decorative synchronize — action path never blocks on motion.
            animator.synchronize()

            let frame = animator.tickRender(dt: fixedDt)
            let outline = CursorArt.outlinePath(pose: frame.pose, artScale: artScale)
            samples.append(
                SampledFrame(
                    index: i,
                    time: Double(i) * fixedDt,
                    pose: frame.pose,
                    visualState: frame.visualState,
                    outline: outline,
                    ripples: frame.ripples,
                    settled: frame.settled
                )
            )
            currentTip = frame.pose.position
        }
        return samples
    }

    // MARK: - HTML

    private static func buildHTML(
        frames: [SampledFrame],
        color: CursorColor,
        plan: ScriptPlan
    ) -> String {
        let frameCount = plan.frameCount
        let fill = cssColor(color, alpha: color.alpha)
        let stroke = cssColor(color, alpha: min(1.0, color.alpha + 0.05))
        let rippleStroke = cssColor(color, alpha: 1.0)

        var svgFrames = ""
        svgFrames.reserveCapacity(frames.count * 256)
        var sampledRippleCount = 0
        for (offset, frame) in frames.enumerated() {
            let display = offset == 0 ? "inline" : "none"
            let pathD = svgPath(frame.outline)
            var ripplesSVG = ""
            for r in frame.ripples {
                sampledRippleCount += 1
                let a = String(format: "%.4f", r.alpha)
                let rad = String(format: "%.2f", r.radius)
                let cx = String(format: "%.2f", r.center.x)
                let cy = String(format: "%.2f", r.center.y)
                ripplesSVG += """
                <circle class="ripple" cx="\(cx)" cy="\(cy)" r="\(rad)" fill="none" stroke="\(rippleStroke)" stroke-width="2" opacity="\(a)"/>
                """
            }
            let tipX = String(format: "%.2f", frame.pose.position.x)
            let tipY = String(format: "%.2f", frame.pose.position.y)
            svgFrames += """
            <g class="frame" data-index="\(frame.index)" data-t="\(String(format: "%.4f", frame.time))" data-state="\(stateLabel(frame.visualState))" data-settled="\(frame.settled)" data-ripples="\(frame.ripples.count)" style="display:\(display)">
              \(ripplesSVG)
              <path class="cursor" d="\(pathD)" fill="\(fill)" stroke="\(stroke)" stroke-width="1.25" stroke-linejoin="round" stroke-linecap="round"/>
              <circle class="hotspot" cx="\(tipX)" cy="\(tipY)" r="1.5" fill="#111" opacity="0.55"/>
            </g>
            """
        }

        // Truthful flags: only claim a press/ripple if the plan intended one AND
        // at least one sampled frame actually carried a ring (guards tiny counts).
        let hasSampledRipple = sampledRippleCount > 0
        let claimsPressRipple = plan.includesPressRipple && hasSampledRipple
        let claimsMoves = plan.includesMoves

        let metaJSON = """
        {"generator":"semantouch-cursor-demo","sessionId":\(jsonString(sessionId)),"frameCount":\(frameCount),"fixedDt":\(fixedDt),"fps":\(Int((1.0 / fixedDt).rounded())),"artScale":\(artScale),"canvas":{"width":\(Int(canvasWidth)),"height":\(Int(canvasHeight))},"script":\(jsonString(plan.summary)),"includesMoves":\(claimsMoves),"includesPressRipple":\(claimsPressRipple),"sampledRippleShapes":\(sampledRippleCount),"decorativeOnly":true,"movesSystemPointer":false,"gatesActions":false}
        """

        let colorSwatch = cssColor(color, alpha: 1.0)
        let colorLabel = String(
            format: "rgba(%.3f, %.3f, %.3f, %.3f)",
            color.red, color.green, color.blue, color.alpha
        )

        let title = htmlEscape("Semantouch decorative virtual cursor demo")
        let sessionEsc = htmlEscape(sessionId)
        let colorEsc = htmlEscape(colorLabel)
        let metaEsc = htmlEscape(metaJSON)
        let summaryEsc = htmlEscape(plan.summary)
        let scriptDetail = scriptDetailHTML(
            claimsMoves: claimsMoves,
            claimsPressRipple: claimsPressRipple,
            summary: plan.summary,
            frameCount: frameCount
        )

        let waypointPolyline: String
        if plan.waypoints.count >= 2 {
            let pts = plan.waypoints.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ")
            waypointPolyline = """
            <polyline fill="none" stroke="#2e3d4d" stroke-width="1.5" stroke-dasharray="4 5" marker-mid="url(#dot)" marker-end="url(#dot)" marker-start="url(#dot)"
                points="\(pts)"/>
            """
        } else {
            let p = plan.waypoints[0]
            waypointPolyline = """
            <circle cx="\(Int(p.x))" cy="\(Int(p.y))" r="3" fill="#2e3d4d"/>
            """
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <meta name="generator" content="semantouch-cursor-demo"/>
        <meta name="semantouch:decorative-only" content="true"/>
        <meta name="semantouch:frame-count" content="\(frameCount)"/>
        <meta name="semantouch:fixed-dt" content="\(fixedDt)"/>
        <meta name="semantouch:includes-moves" content="\(claimsMoves)"/>
        <meta name="semantouch:includes-press-ripple" content="\(claimsPressRipple)"/>
        <title>\(title)</title>
        <style>
          :root {
            --bg: #0f1419;
            --panel: #1a222c;
            --ink: #e7eef7;
            --muted: #9aabbd;
            --accent: \(colorSwatch);
            --line: #2a3542;
          }
          * { box-sizing: border-box; }
          body {
            margin: 0;
            font: 15px/1.5 ui-sans-serif, system-ui, -apple-system, Segoe UI, sans-serif;
            color: var(--ink);
            background:
              radial-gradient(1200px 600px at 10% -10%, #1c2a3a 0%, transparent 55%),
              radial-gradient(900px 500px at 100% 0%, #1a2830 0%, transparent 50%),
              var(--bg);
            min-height: 100vh;
          }
          main {
            max-width: 880px;
            margin: 0 auto;
            padding: 32px 20px 48px;
          }
          h1 {
            font-size: 1.45rem;
            font-weight: 650;
            letter-spacing: -0.02em;
            margin: 0 0 8px;
          }
          .banner {
            border: 1px solid #3a4d2f;
            background: linear-gradient(180deg, #1d2a1a, #162016);
            color: #d7efc6;
            border-radius: 10px;
            padding: 12px 14px;
            margin: 0 0 18px;
          }
          .banner strong { color: #f0ffdf; }
          .meta {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
            gap: 10px;
            margin: 0 0 18px;
          }
          .meta div {
            background: var(--panel);
            border: 1px solid var(--line);
            border-radius: 10px;
            padding: 10px 12px;
          }
          .meta dt {
            display: block;
            color: var(--muted);
            font-size: 0.78rem;
            text-transform: uppercase;
            letter-spacing: 0.04em;
            margin-bottom: 2px;
          }
          .meta dd {
            margin: 0;
            font-variant-numeric: tabular-nums;
            font-weight: 600;
          }
          .stage {
            background:
              linear-gradient(180deg, #121820, #0d1218);
            border: 1px solid var(--line);
            border-radius: 14px;
            padding: 12px;
            box-shadow: 0 18px 50px rgba(0,0,0,0.35);
          }
          svg {
            display: block;
            width: 100%;
            height: auto;
            background:
              linear-gradient(0deg, rgba(255,255,255,0.02), transparent 40%),
              repeating-linear-gradient(
                0deg, transparent, transparent 19px, rgba(255,255,255,0.03) 20px
              ),
              repeating-linear-gradient(
                90deg, transparent, transparent 19px, rgba(255,255,255,0.03) 20px
              ),
              #0b1015;
            border-radius: 10px;
          }
          .controls {
            display: flex;
            flex-wrap: wrap;
            gap: 10px;
            align-items: center;
            margin-top: 12px;
          }
          button, input[type="range"] {
            font: inherit;
          }
          button {
            background: #243140;
            color: var(--ink);
            border: 1px solid #3a4b5c;
            border-radius: 8px;
            padding: 7px 12px;
            cursor: pointer;
          }
          button:hover { background: #2c3b4d; }
          .readout {
            color: var(--muted);
            font-variant-numeric: tabular-nums;
            min-width: 12ch;
          }
          .swatch {
            display: inline-block;
            width: 0.85em;
            height: 0.85em;
            border-radius: 999px;
            background: var(--accent);
            vertical-align: -0.05em;
            margin-right: 0.35em;
            box-shadow: 0 0 0 1px rgba(255,255,255,0.15) inset;
          }
          footer {
            margin-top: 22px;
            color: var(--muted);
            font-size: 0.9rem;
          }
          code {
            font: 0.9em/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
            background: rgba(255,255,255,0.05);
            padding: 0.1em 0.35em;
            border-radius: 4px;
          }
        </style>
        </head>
        <body>
        <main>
          <h1>\(title)</h1>
          <p class="banner">
            <strong>Decorative virtual cursor only.</strong>
            This artifact is a pure offline render of Semantouch
            <code>CursorAnimator</code> / <code>CursorArt</code> frames.
            It does <em>not</em> move the system pointer, does not receive
            clicks, does not request Accessibility or Screen Recording
            permission, and never gates real actions.
          </p>

          <section class="meta" aria-label="Reproducibility metadata">
            <div><dt>Session id</dt><dd>\(sessionEsc)</dd></div>
            <div><dt>Identity color</dt><dd><span class="swatch" aria-hidden="true"></span>\(colorEsc)</dd></div>
            <div><dt>Frame count</dt><dd>\(frameCount)</dd></div>
            <div><dt>Fixed dt</dt><dd>\(fixedDt) s (\(Int((1.0 / fixedDt).rounded())) Hz)</dd></div>
            <div><dt>Art scale</dt><dd>\(artScale)</dd></div>
            <div><dt>Script</dt><dd>\(summaryEsc)</dd></div>
          </section>

          <section class="stage" aria-label="Cursor motion stage">
            <svg id="stage" viewBox="0 0 \(Int(canvasWidth)) \(Int(canvasHeight))" role="img" aria-label="Animated decorative cursor path">
              <defs>
                <marker id="dot" markerWidth="4" markerHeight="4" refX="2" refY="2">
                  <circle cx="2" cy="2" r="1.4" fill="#6f8499"/>
                </marker>
              </defs>
              <!-- Scripted waypoints (visual guide only; proportional to frame count). -->
              \(waypointPolyline)
              \(svgFrames)
            </svg>
            <div class="controls">
              <button type="button" id="toggle" aria-pressed="true">Pause</button>
              <button type="button" id="restart">Restart</button>
              <input id="scrub" type="range" min="0" max="\(max(0, frameCount - 1))" value="0" aria-label="Scrub frames"/>
              <span class="readout" id="readout">frame 0 / \(max(0, frameCount - 1))</span>
            </div>
          </section>

          <footer>
            <p>
              Generated by <code>semantouch-cursor-demo</code>.
              Reproducibility payload:
              <code id="meta-json">\(metaEsc)</code>
            </p>
            <p>\(scriptDetail)</p>
          </footer>
        </main>
        <script>
        (function () {
          var frames = Array.prototype.slice.call(document.querySelectorAll("g.frame"));
          if (!frames.length) return;
          var i = 0;
          var playing = true;
          var timer = null;
          var dtMs = \(Int((fixedDt * 1000.0).rounded()));
          var toggle = document.getElementById("toggle");
          var restart = document.getElementById("restart");
          var scrub = document.getElementById("scrub");
          var readout = document.getElementById("readout");

          function show(n) {
            if (n < 0) n = 0;
            if (n >= frames.length) n = frames.length - 1;
            frames[i].style.display = "none";
            i = n;
            frames[i].style.display = "inline";
            scrub.value = String(i);
            var state = frames[i].getAttribute("data-state") || "";
            var settled = frames[i].getAttribute("data-settled") === "true";
            var ripples = frames[i].getAttribute("data-ripples") || "0";
            readout.textContent = "frame " + i + " / " + (frames.length - 1) +
              " · " + state +
              (ripples !== "0" ? " · ripple×" + ripples : "") +
              (settled ? " · settled" : "");
          }

          function tick() {
            var next = i + 1;
            if (next >= frames.length) next = 0;
            show(next);
          }

          function play() {
            if (timer) return;
            playing = true;
            toggle.textContent = "Pause";
            toggle.setAttribute("aria-pressed", "true");
            timer = setInterval(tick, dtMs);
          }

          function pause() {
            playing = false;
            toggle.textContent = "Play";
            toggle.setAttribute("aria-pressed", "false");
            if (timer) { clearInterval(timer); timer = null; }
          }

          toggle.addEventListener("click", function () {
            if (playing) pause(); else play();
          });
          restart.addEventListener("click", function () {
            show(0);
            if (!playing) play();
          });
          scrub.addEventListener("input", function () {
            pause();
            show(parseInt(scrub.value, 10) || 0);
          });

          show(0);
          play();
        })();
        </script>
        </body>
        </html>
        """
    }

    private static func scriptDetailHTML(
        claimsMoves: Bool,
        claimsPressRipple: Bool,
        summary: String,
        frameCount: Int
    ) -> String {
        let base = htmlEscape(summary) + "."
        let repro = " Sampled with fixed dt so two runs with the same <code>--frames</code> produce the same geometry."
        if frameCount <= 1 {
            return base + " <code>--frames 1</code> is a single rest pose only." + repro
        }
        if claimsMoves && claimsPressRipple {
            return base + " Waypoints, press hold, and idle tail scale with the requested frame count." + repro
        }
        if claimsPressRipple {
            return base + " Increase <code>--frames</code> (default 180) for multi-point moves before the press." + repro
        }
        return base + " Increase <code>--frames</code> to include moves and a press/ripple." + repro
    }

    // MARK: - Formatting helpers

    private static func stateLabel(_ state: CursorVisualState) -> String {
        switch state {
        case .idle: return "idle"
        case .moving: return "moving"
        case .pressed: return "pressed"
        case .dragging: return "dragging"
        case .progress(let fraction):
            return "progress(\(String(format: "%.2f", fraction)))"
        }
    }

    private static func cssColor(_ color: CursorColor, alpha: Double) -> String {
        let r = Int((clamp01(color.red) * 255.0).rounded())
        let g = Int((clamp01(color.green) * 255.0).rounded())
        let b = Int((clamp01(color.blue) * 255.0).rounded())
        let a = String(format: "%.3f", clamp01(alpha))
        return "rgba(\(r),\(g),\(b),\(a))"
    }

    private static func svgPath(_ points: [Point]) -> String {
        guard let first = points.first else { return "" }
        var d = String(format: "M %.2f %.2f", first.x, first.y)
        for p in points.dropFirst() {
            d += String(format: " L %.2f %.2f", p.x, p.y)
        }
        d += " Z"
        return d
    }

    private static func htmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch.value {
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x00..<0x20:
                out += String(format: "\\u%04x", ch.value)
            default:
                out.unicodeScalars.append(ch)
            }
        }
        out += "\""
        return out
    }

    private static func clamp01(_ x: Double) -> Double {
        min(max(x, 0), 1)
    }
}
