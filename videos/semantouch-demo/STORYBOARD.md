---
format: 1920x1080
message: "Computer use should be inspectable, interruptible, and provable."
arc: Thesis → Observe → Act → Verify → Wait → Yield → Install
audience: MCP client authors, agent engineers, and macOS automation users
mode: autonomous
---

## Video direction

- Palette: warm paper is the canvas, forest ink carries every load-bearing mark, and phosphor green is reserved for verified outcomes and the virtual cursor. Use the permanent measured grid, top/bottom rules, ledger rows, and QR-like evidence blocks from `frame.md`.
- Type: display, body, and mono roles come only from `frame.md`. Mono chrome carries revisions, IDs, result codes, timestamps, and fixture sequence numbers.
- Motion: smooth long-tail transforms; one evidence item reveals at each caption cue. The cursor follows a heading-aware path and settles before click pulses. Final reads hold still; no idle breathing.
- Rhythm: Frames 1–4 build quickly, Frame 5 is the deliberate wait/breather, Frame 6 stops sharply on human input, and Frame 7 resolves as a still installation plate.
- Evidence: every green state is populated from `evidence/demo-evidence.json`. The render gate refuses sample, missing, stale, unsigned-release, or incomplete evidence.
- Negative list: no browser chrome, fake screenshots, stock imagery, glow, gradients, rounded SaaS cards, front-loaded slideshow motion, independent screensaver drift, or claim without a matching tool result and fixture event.

## Frame 1 — Computer use, with receipts

- status: built
- src: compositions/frames/01-hook.html
- duration: 4s
- poster: 3s
- transition_in: cut
- scene: A revision ledger opens around a single exact promise
- asset_candidates: evidence/demo-evidence.json
- blueprint: compose
- focal: evidence/demo-evidence.json
- roles: demo-evidence = supporting
- caption: "Native macOS computer use. Every state transition leaves evidence."

Scene 1 (0.0–1.3s): the measured grid and top/bottom registry rules draw on; `SEMANTOUCH / EVIDENCE RUN` seats upper-left in mono chrome — rule-of-thirds, sparse, two depth layers.
Scene 2 (1.3–2.8s): “Computer use, with receipts.” assembles line-by-line across the upper two-thirds; a forest cursor takes a bounded curve toward the final period — asymmetric 70/30, display hierarchy 3:1.
Scene 3 (2.8–4.0s): run id, signed release version, fixture id, and `VERIFIED` stamp resolve on the lower ledger and hold absolutely still.

## Frame 2 — Launch, then see through the cover

- status: built
- src: compositions/frames/02-observe.html
- duration: 6s
- poster: 5s
- transition_in: wipe
- scene: Policy-gated launch and covered-window capture become two linked records
- asset_candidates: evidence/demo-evidence.json
- blueprint: compose
- focal: evidence/demo-evidence.json
- roles: demo-evidence = supporting
- caption: "Launch is explicit. ScreenCaptureKit still captures an occluded window."

Scene 1 (0.0–1.8s): a launch request ledger row enters from the left with exact app selector and policy result; the process/window row joins only after the recorded tool result — split-screen 60/40, dense technical chrome.
Scene 2 (1.8–4.4s): the right panel reconstructs a fixture window, then a solid orange cover crosses it; the captured image plane peels forward unchanged with its recorded dimensions and checksum — layered-depth, three planes, cover remains visibly opaque.
Scene 3 (4.4–6.0s): `launch_app → launched/recovered` and `screenshot → image/png` lock to the same run id; the evidence rail holds.

## Frame 3 — Meaning before coordinates

- status: built
- src: compositions/frames/03-act.html
- duration: 6s
- poster: 5s
- transition_in: cut
- scene: A stable element ID resolves to AXPress before any bounded fallback
- asset_candidates: evidence/demo-evidence.json
- blueprint: compose
- focal: evidence/demo-evidence.json
- roles: demo-evidence = supporting
- caption: "Stable ID. Matching revision. Native AXPress."

Scene 1 (0.0–1.8s): an accessibility tree grows from root to `fixture.button.press`; revision and session sit on the frame edge — asymmetric 60/40, ledger density, primary node at upper third.
Scene 2 (1.8–4.2s): the selected stable element row pulls forward; a heading-aware cursor arcs to its semantic center while the `AXPress` capability illuminates only when the tool result names it.
Scene 3 (4.2–6.0s): the click pulse lands, fixture event `press / fixture.button.press` increments, and method `semantic` holds in the result strip; coordinate fallback stays crossed out.

## Frame 4 — Diff, then reject the stale past

- status: built
- src: compositions/frames/04-prove.html
- duration: 6s
- poster: 5s
- transition_in: wipe
- scene: Revision N becomes N+1 with a reconstructable diff; reuse of N fails closed
- asset_candidates: evidence/demo-evidence.json
- blueprint: compose
- focal: evidence/demo-evidence.json
- roles: demo-evidence = supporting
- caption: "The action advances the revision. The old target cannot be replayed."

Scene 1 (0.0–2.2s): before/after tree ledgers align on a shared baseline; only changed rows animate across the center rail — split-screen comparison, dense rows, revision numerals dominate.
Scene 2 (2.2–4.2s): the recorded patch folds into the after tree and a compact equality proof resolves: `apply(diff, N) = N+1` — full-width strip, one phosphor verification mark.
Scene 3 (4.2–6.0s): an attempted old-revision click enters, stops against the revision boundary, and returns exact `stale_revision`; the rejected row remains visible as a deliberate held read.

## Frame 5 — Wait for state, not sleep

- status: built
- src: compositions/frames/05-wait.html
- duration: 5s
- poster: 4s
- transition_in: cut
- scene: wait_for evaluates bounded state until the recorded condition resolves
- asset_candidates: evidence/demo-evidence.json
- blueprint: compose
- focal: evidence/demo-evidence.json
- roles: demo-evidence = supporting
- caption: "Bounded polling. Typed outcome. No blind sleep."

Scene 1 (0.0–1.5s): a monotonic deadline rail draws from request to deadline with condition `text_contains`; the rest of the frame stays quiet — full-width timeline, sparse.
Scene 2 (1.5–3.7s): recorded evaluations step along the rail one at a time; the matched fixture event seats exactly where the tool returned, not before.
Scene 3 (3.7–5.0s): outcome `satisfied` and elapsed milliseconds resolve together and hold; timeout remains a distinct unselected branch.

## Frame 6 — Human input wins immediately

- status: built
- src: compositions/frames/06-yield.html
- duration: 6s
- poster: 5s
- transition_in: cut
- scene: Background-targeted input preserves focus until physical input interrupts the lane
- asset_candidates: evidence/demo-evidence.json
- blueprint: compose
- focal: evidence/demo-evidence.json
- roles: demo-evidence = supporting
- caption: "Targeted when safe. Cancelled when the user intervenes."

Scene 1 (0.0–2.0s): foreground app and target fixture occupy separate columns; a targeted delivery line reaches the fixture while the foreground PID remains unchanged — split-screen 50/50, strong positional hierarchy.
Scene 2 (2.0–4.2s): physical mouse/key evidence slices across the action lane; every pending segment halts on the same frame — layered-depth, hard stop signature, no decorative continuation.
Scene 3 (4.2–6.0s): result `interrupted` and fixture `no duplicate mutation` proof stamp in; the cursor dims and the frame holds still.

## Frame 7 — One app. One contract. Sixteen tools.

- status: built
- src: compositions/frames/07-close.html
- duration: 5s
- poster: 4s
- transition_in: wipe
- scene: The signed universal app and its three installation routes close the proof
- asset_candidates: evidence/demo-evidence.json
- blueprint: compose
- focal: evidence/demo-evidence.json
- roles: demo-evidence = supporting
- caption: "Signed whole-app updates preserve identity. Choose OMP, npm, or Homebrew."

Scene 1 (0.0–1.6s): `Semantouch.app` assembles from universal2 host and relay slices; bundle, Team, version, architecture, and notarization rows verify in sequence — asymmetric 60/40, dense ledger.
Scene 2 (1.6–3.5s): three installation commands reveal one at a time on a warm-paper code strip, all converging on the same immutable app ZIP.
Scene 3 (3.5–5.0s): “One app. One contract. Sixteen tools.” fills the upper field; repository URL and `REPRODUCE THIS RUN` command hold in mono chrome.
