# Execution Plan

Historical implementation log for the system now summarized in [README.md](../README.md). Once frozen, `docs/PROTOCOL.md` overrides other documentation on wire-contract details.

## Working agreements

- Clean-room: public Apple APIs only; no private frameworks or SPI; nothing copied from the OpenAI bundle.
- MCP stdout carries protocol traffic only; all logging goes to stderr.
- Swift Package Manager, zero external dependencies, macOS 14.4+ target, Apple Silicon first.
- No git commits until the user asks for them.
- Runtime proofs that need Accessibility / Screen Recording run best-effort and report `blocked` with exact remediation instead of guessing.

## Stages

### Stage A — protocol freeze + scaffold
- [x] `docs/PROTOCOL.md`: transport, tool schemas (all phases, gated), tree grammar v1, element/session IDs, payload limits, error codes, coordinate spaces, screenshot policy.
- [x] Package skeleton; ComputerUseCore DTOs/errors/policy/resolver; executable subcommand routing.
- Gate: `swift build` + `swift test` green. ✔

### Stage B — engines (parallel)
- [x] AccessibilityEngine: AX client, pure UINode model, tree builder + pruning, deterministic renderer, stable element table.
- [x] CaptureEngine: window catalog, AX↔SCWindow correlation (public signals only), desktop-independent window capture, coordinate mapping, encoders.
- [x] MCPServer: newline-delimited JSON-RPC 2.0 stdio transport, tool registry + schemas.
- [x] Fixture app: counters, fields, dynamic rows, duplicate labels, menus/sheet, cover-window mode, state-file event log.
- Gate: each target compiles. ✔

### Stage C — Phase 1 integration (read-only MCP)
- [x] `doctor` / `list_apps` / `get_app_state` / `end_app_session` wired end to end (in `ComputerUseService`), served by the `mcp` subcommand; CLI probes (`capture`/`ax-tree`/`press`/`set-value`) as Phase-0 spike drivers.
- [x] Contract + unit tests green (177 tests); `ProtocolContractTests` covers the golden tools/list, request validation, every `CUError` wire code, disabled-tool `policy_denied`, and the `end_app_session` lifecycle.
- Gate: full build + tests green. ✔

### Stage D — Phase 0 runtime proofs (permission-dependent)
- [x] All 8 proofs pass (evidence in `probes/`): doctor, MCP handshake (2025-06-18, 4 tools), fixture tree fidelity, get_app_state coordinate math, covered-window capture (0% cover pixels vs 100% on the raw display), covered `AXPress` ×2 with Finder frontmost throughout, covered `AXValue` set, `list_apps` sanity (187 apps).
- Caveats: fixture resolves as `computer-use-fixture` (or `pid:<N>`), not window title "CU Fixture"; strict frontmost-unchanged is unverifiable on this desktop (Orca/Pindrop self-activate) — the robust invariant "target never becomes frontmost" held across all 14 covered ops. AX `set_value` does not fire `controlTextDidChange`, so assert the field's own AXValue, not the mirror label.
- Gate: Phase 0 acceptance items pass. ✔ **Feasibility hypothesis proven.**

### Stage E — Phase 2 semantic actions
- [x] PROTOCOL addendum: v1.1 §13 turns the reserved Phase-2 semantics normative (revision advances per snapshot, full-only; fresh ids per snapshot; action validation order session→revision→element; `stale_revision.data.current` nullable; optional `unsupported_action.data.reason`; `ActionResult` `method:accessibility`/`refreshRecommended:true`/best-effort `stateChanged`), plus a §14 changelog. Frozen v1 §1–§12 left intact.
- [x] `ActionEngine`: `ActionExecutor` (per-session FIFO lane, concurrent across sessions; policy gate before enqueue, session/revision/element validation inside the lane); `SemanticActions` (click=AXPress, perform_action=named AX action); `TextActions` (set_value settable-AXValue, select_text AXSelectedTextRange); `ScrollActions` (scrollbar AXValue → by-page action → AXScrollToVisible descendant → unsupported_action). Ladder is semantic-only — no keyboard/pointer fallback; `AXActionElement` is the live seam, faked in tests.
- [x] Policy gate: `PolicyEngine` app denylist (`SEMANTOUCH_DENIED_APPS`; permissive when unset/empty; applies to reads and mutations; no mutation allowlist / no built-in hard denies) wired before dispatch; documented in `docs/SECURITY.md §2`. Historical Stage E shipped an allowlist first; the live contract is the operator denylist.
- [x] Five tools wired into the service and enabled in the catalog (`tools/list` → 9); `click` element-path only (coordinate path is Phase 4 → unsupported_action); `ActionResult` per contract.
- [x] Tests: `ProtocolContractTests` (9-tool golden list, action schemas, policy_denied for a denied app, stale_revision null/mismatch + stale_element over a faked session); `ActionEngineTests` (FIFO/serialization/cross-session concurrency, every unsupported-action path, settability gate) over fake handles; `PolicyEngineTests`; `CUErrorTests` for the two additive fields. 228 tests, permission-free.
- Gate: full `swift build` + `swift test` green (228 tests). Runtime proof: real `click` on the fixture logged its press event with the fixture never frontmost; revision advanced 1→2; set_value→unsupported_action; stale revision→stale_revision(current:2); Finder→policy_denied before any AX call. ✔ **Phase 2 delivered.**

### Stage F — Phase 3 incremental state
- [x] PROTOCOL addendum: v1.2 §15 freezes the diff mode reserved in §11 — full-vs-diff selection, `disableDiff` request field, `full`/`baseRevision` response shape, the `semantouch-ax-tree-v1` diff grammar (`~`/`+`/`-` with parent+ordinal placement and range-collapsed removals), cross-revision id reuse, the `diff_reset` and `possibly_unsettled` warnings, and the frozen settle timings (75/150 ms, 1/5 s). §14 changelog entry added; frozen §1–§13 untouched.
- [x] AccessibilityEngine: `AXTreeDiff` (pure `compute`/`apply`/`render`; reconstruction proven exact), `SettleDetector` (pure `decide` + injectable driver loop), `AXObserverCoordinator` + `ObserverActivityState` (dedicated CFRunLoop thread, minimal AX notification set, lock-guarded dirty/activity/loading state, graceful degradation to always-dirty). `StableElementTable` reuse turned on in the service with the tightened fingerprint contract + live-element gate; `AXTreeRenderer` factored into identity/attribute segments the diff reuses.
- [x] Service wiring: `get_app_state` attaches an observer on first use, settles when dirty, emits a diff when {same session+window, lineage intact, base+current untruncated, not forceFullTree/disableDiff, prior snapshot exists} else full (with `diff_reset` when lineage broke); mutations mark the session dirty; `end_app_session` detaches the observer and frees the lane/table/snapshot. Revision/element validation from Phase 2 unchanged (ids now persist across revisions when matched; `stale_element` still fires for ids absent from the current revision).
- [x] Fixture cleanup: menu items now carry `fixture.menu.ping` / `fixture.menu.showSheet` AXIdentifiers per docs/FIXTURE.md.
- [x] Tests (permission-free): diff-reconstruction equivalence (adds/removes/attr changes/moves/mixed bursts → `apply(prev, diff) == next` structurally and re-rendered), diff grammar goldens (range collapse, parent/ordinal placement, toggle deltas), fingerprint reuse matrix (matched→same id, replaced-same-position→new id, destroyed→new id, removed→never reused), SettleDetector timing with a fake clock, observer state machine with injected notifications. Adversarial review caught a **critical** diff bug (a still-live reused element emitted in both `+` and `-` sections, breaking reconstruction) + 9 more; all fixed. 279 tests (was 234).
- Gate: full `swift build` + `swift test` green (279 tests). ✔ **Phase 3 code delivered.**
- ⏳ **DEFERRED (screen was locked):** live runtime acceptance evidence — full→diff over the MCP pipe, client-side reconstruction equals a fresh full tree, measured diff-vs-full byte reduction, settle behavior, `diff_reset` on lineage break. Driver ready at `probes/stage-f/stage_f_driver.py`; offline diff-applier self-test already passes. Run once the console is unlocked. Locked-screen operation is a documented non-goal, so `get_app_state`→`window_not_found` under lock is correct, not a regression.

### Stage G — Phase 4 fallback input
- [x] PROTOCOL addendum: v1.3 §16 freezes native fallback input — enables `press_key`/`type_text`/`drag` and the coordinate path of `click`/`scroll` (`tools/list` → 12); the per-call `interference` field (`background-only` default / `allow-brief-focus` / `foreground-takeover`) on every fallback action with a full decision table; the new `focus_required` error code (§6); `ActionResult` gains `focusChanged`/`focusRestored`/`targetVerified` and activates `method: keyboard|pointer` and `status: interrupted`; coordinate spaces (window default, screenshot optional) mapped to global points; chord grammar (§4.3) + `CGEventKeyboardSetUnicodeString` for text + drag button/modifier semantics; and the honest **background-only feasibility conclusion** (§16.7). §14 changelog entry added; frozen §1–§15 untouched (the new error row is purely additive).
- [x] `ActionEngine` fallback layer (public CGEvent API only, clean-room): `KeyboardActions` (pure `Keymap` + `KeyChord.parse` chord grammar → tagged key events; per-character `type_text`), `PointerActions` (coordinate click/drag/scroll on global points; drag interpolation + button-release on interrupt; scroll-delta mapping), `FocusTransaction` + `WorkspaceControlling` (record→activate→deliver→restore; never delivers to a non-frontmost target under a focus mode), `UserInterruptionMonitor` (pure `InterruptionState` + a passive listen-only session tap on a dedicated run-loop thread; ours-tagged events ignored, debounce, graceful degradation), `CGEventSynthesizer` (live tagged emitter via `eventSourceUserData`), and `InterferencePlan.decide` (the pure decision table). All impure pieces sit behind seams (`InputSynthesizer`, `WorkspaceControlling`, `InterruptionMonitoring`, `FallbackEnvironment`).
- [x] Executor: `ActionExecutor.executeFallback` runs mutation policy gate BEFORE enqueue, then in the session lane — session existence → confused-deputy ownership guard → coordinate→global mapping (before any focus change) → interference decision (`background-only` + not-frontmost → `focus_required`) → bounded focus transaction → tagged delivery under an armed interruption monitor → post-delivery target verification. Semantic ladder intact: `click`/`scroll` prefer the element path and only take the coordinate path when the caller passes `at` (no auto-fallback).
- [x] Service wiring: `press_key`/`type_text`/`drag` handlers + coordinate paths for `click`/`scroll` (dispatched on `at`); `ServiceContext` owns the synthesizer/workspace/interruption seams (injectable) and a per-session window-geometry store set by `get_app_state` and freed by `end_app_session`; the `mcp` runtime starts/stops the interruption tap; catalog + schemas updated (12 tools; additive `interference`/`at`/`space`/`button`/`modifiers`; `click`/`scroll` required relaxed).
- [x] Tests (permission-free; no real CGEvent posted, no live tap/workspace): interference decision table; keymap/chord goldens + error cases; keyboard/pointer delivery + interruption cancellation; scroll-delta mapping; `FocusTransaction` record/restore bookkeeping over a fake workspace; `InterruptionState` injected-event logic + debounce; end-to-end `executeFallback` over fakes (validation order, focus modes, coordinate window/screenshot mapping, target verification, interruption, degradation); and real-service wire tests (`policy_denied`, `focus_required`, completed delivery, brief-focus transaction, coordinate mapping, malformed-combo `-32602`, semantic-path preserved). 342 tests (was 279).
- [x] Adversarial safety review caught **two critical wrong-target holes** — coordinate delivery with no window-bounds/staleness guard, and no mid-delivery frontmost re-check (a focus change would route remaining input to the wrong app) — plus a major bug where `FocusTransaction` read frontmost synchronously after the async `activate()` (both focus modes would have been inert live). All 10 findings fixed with new tests.
- Gate: full `swift build` + `swift test` green (352 tests). ✔ **Phase 4 code delivered.**
- ⏳ **DEFERRED (console may be locked; live GUI proofs are a documented non-goal under lock):** live acceptance evidence — real `press_key`/`type_text`/coordinate `click`/`drag` against the fixture with an interference-mode matrix (background-only→`focus_required` while the fixture stays non-frontmost; allow-brief-focus record/restore; foreground-takeover), tagged-event self-recognition (our input never self-interrupts), physical-input cancellation (<100 ms), and target verification that the fixture — not the user app — received the input. Run once the console is unlocked; the executor + seams already prove the logic offline.

### Stage H — Phase 5 cursor overlay + Phase 6 packaging

#### Phase 5 — virtual cursor overlay
- [x] New `CursorOverlay` target (public AppKit only, zero deps). Pure core carries the
  tested behaviour: `CursorPlan` (deterministic geometry — panel frame = target window in
  global points, cursor clamped into panel-local points, action→visual-state mapping,
  degenerate-window `presentable=false`, per-session `CursorColor.identity` via FNV-1a
  hue) and `CursorAnimator` (framerate-independent exponential ease with a `tick(dt:)`
  reference model; owns the identity colour; exposes the decoupled `synchronize()`).
- [x] `CursorPanel` — a nonactivating transparent `NSPanel`: `.borderless` +
  `.nonactivatingPanel`, `canBecomeKey`/`canBecomeMain` overridden to **false**, floating
  level, `ignoresMouseEvents=true` (click-through; system pointer untouched),
  collectionBehavior `[.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`,
  out of the window cycle. Independently-authored cursor art (disc + ring + arrow tail +
  progress arc) — nothing copied from the OpenAI bundle.
- [x] `CursorController` — lifecycle over a `CursorPresenting` seam (all AppKit behind it,
  so the controller is fully unit-tested with a fake presenter): show-on-action,
  follow-window-move (`noteWindowFrame`), drop-to-idle on completion, hide-immediately on
  interrupt/end. Honours `SEMANTOUCH_CURSOR=off|dim|on` (default `on`). `AppKitCursorPresenter`
  self-guards on an active display (`CGMainDisplayID`/`CGDisplayIsActive`, public + thread-safe)
  and **coalesces** main-thread work (at most one apply-block outstanding), so the
  run-loop-less headless `mcp` server creates no window and never piles up closures.
- [x] Wiring (`ComputerUseService`): the controller lives on `ServiceContext` (default
  `.disabled()` for CLI/tests; the `mcp` runtime injects live `.system()`). `get_app_state`
  records the window frame (move-follow); Phase 2 semantic + Phase 4 fallback handlers
  reflect move/press/drag/progress before dispatch and finish (idle / hide-on-interrupt)
  after — best-effort: a cursor failure or a headless session NEVER fails or delays an
  action, and the action result is returned independent of any animation. Semantic actions
  still move the system pointer 0px (the overlay is purely drawn). `end_app_session` hides.
- [x] Tests (permission-free, no real windows): `CursorPlanTests` (geometry goldens +
  colour determinism + HSB), `CursorControllerTests` (full lifecycle over the fake
  presenter — show/update/hide on start/interrupt/end, preference off/dim/headless,
  window-move follow, degenerate window), `CursorAnimatorTests` (ease/settle/stop + the
  **decoupling invariant**: a controller driven by an animator that never settles still
  runs reflect→synchronize→finish to completion), `CocoaRectTests` (global→Cocoa flip).
- Gate: full `swift build` + `swift test` green (391 tests; 352 baseline preserved). ✔
  **Phase 5 code delivered.**
- [x] **Live on-screen overlay — DELIVERED and proven live** (was deferred). The `mcp` runtime now
  hosts the overlay on a **main-thread accessory `NSApplication` run loop** (LSUIElement: no Dock
  tile, never activates) with MCP I/O on a background thread, gated by `MCPRuntime.shouldHostOverlay`
  = `SEMANTOUCH_CURSOR != off` AND `GUISession.isAvailable` (shared with the presenter self-guard, so
  headless/`off` stays byte-identical — zero windows, Stage H headless-safe proof preserved).
- [x] **Codex-style persistent lifecycle** (user feedback): the ghost cursor now APPEARS on the
  first pointer-kind action (click/coordinate-click/scroll/drag), PERSISTS idle-but-visible between
  actions and through user-interruption, and HIDES only on `end_app_session` / stdin EOF / SIGTERM —
  not per-action. See [[omp-cu-cursor-behavior]].
- [x] Live-verified against the REAL `semantouch mcp` server (not the Stage H harness):
  absent before any action → appears on first semantic click → persists across scroll + type + a
  second click (same overlay window, layer 3, owner `semantouch`, separate from the fixture)
  → keyboard-first shows nothing → hides on end_app_session/EOF/SIGTERM; system pointer 0px the whole
  time; `SEMANTOUCH_CURSOR=off` creates zero windows. Screenshot: `probes/cursor/overlay_live_screenshot.png`.
  Adversarial review: 1 minor finding (EOF wake-event edge) fixed with an unconditional
  `CFRunLoopStop`; hosted-server clean EOF shutdown re-verified (exit 0, stdout protocol-only).
- Gate: full `swift build` + `swift test` green (464 tests). ✔ **Phase 5 fully delivered + live-proven.**

#### Phase 6 — OMP packaging
- [x] `config` subcommand wired into `main.swift` routing — the OMP-facing MCP server
  config generator. Deterministic canonical JSON to stdout (the ONE sanctioned CLI-stdout
  JSON path; `mcp` still owns stdout for framed JSON-RPC only, logs to stderr). Default
  emits the full `{ "mcpServers": { "semantouch": MCPStdioServerConfig } }` block with
  `command` auto-resolved to the running binary (absolute, symlink-resolved); `--path`
  overrides the command path, `--cwd` sets the (else-omitted) `cwd`, `--name`/`--timeout`
  tune the key/timeout, `--bare` emits just the inner object, `--manifest` emits the plugin
  manifest. Also added `--version`/`-v`/`version`.
- [x] `Sources/ComputerUseService/Packaging.swift` — single-source-of-truth packaging
  constants + deterministic generators (`MCPStdioServerConfig`, `OMPMCPServersConfig`,
  `PluginManifest`, all `Codable` through `CanonicalJSON`). Version reads
  `MCPServer.serverVersion`; the tool list reads `ToolCatalog.enabled` (12 tools with
  phases); TCC permissions read from one list. Bundle id is the neutral **placeholder**
  `dev.watzon.semantouch` (`bundleIdIsPlaceholder: true`), min macOS `14.4`, arch
  `arm64`, MCP `2025-06-18`, contract `semantouch/1`.
- [x] `packaging/` artifacts generated from the binary: `semantouch.plugin.json` (plugin
  manifest), `omp-mcp-config.example.json` (example OMP block), and `packaging/README.md`
  (what they are + exact regeneration commands). Pretty-printed for readability; the tool
  emits semantically identical compact canonical JSON.
- [x] Diagnostics: `doctor` already reports helper path / signed state / both permissions /
  ready / exact remediation (sufficient for onboarding); the human-readable output now adds
  a `next:` hint pointing at `config` when ready. `doctor` JSON schema (frozen §4.1)
  unchanged.
- [x] Docs: `docs/INSTALL.md` (build → binary location → the exact Accessibility + Screen
  Recording grants keyed to the running binary, verified by `doctor` → OMP registration via
  `config`), `docs/USAGE.md` (all 12 tools with request/response, once-per-turn discipline,
  revision/stale-id contract, interference policy, `SEMANTOUCH_DENIED_APPS` denylist),
  `docs/RELEASE.md` (codesign `--options runtime` + `notarytool submit` +
  `stapler` documented not executed; entitlements minimal because Accessibility/Screen
  Recording are user-consented TCC, not entitlements; the SIGNED binary is the one that must
  receive the grants), and `docs/OVERVIEW.md` (Getting-started pointer set → INSTALL / USAGE
  / PROTOCOL plus the product README).
- [x] Tests: `Tests/ProtocolContractTests/PackagingTests.swift` (11 pure, permission-free
  tests) — version tracks `MCPServer.serverVersion`; manifest tool list == enabled catalog
  with matching phases; permissions == the two TCC grants; placeholder bundle id is neither
  `com.apple.*` nor `com.openai.*`; `MCPStdioServerConfig` shape (`type:stdio`, `args:[mcp]`,
  timeout default, `cwd` omitted-when-nil / present-when-set); JSON round-trip; determinism.
- Gate: full `swift build` + `swift test` green (402 tests; 391 baseline preserved). ✔
  **Phase 6 code + docs delivered.**

##### Decisions
- **Single source of truth for version**: `MCPServer.serverVersion` (`0.1.0`). `--version`,
  `doctor.helper.version`, `serverInfo.version`, and the manifest all read it; bump the one
  constant to cut a release.
- **Placeholder bundle id** `dev.watzon.semantouch` — neutral, no-masquerade
  (SECURITY.md §5). Flagged `bundleIdIsPlaceholder: true`; RELEASE.md §0 documents replacing
  it with the real publisher namespace before shipping.
- **`config` is the one CLI→stdout JSON path**, kept strictly separate from the `mcp`
  channel; determinism via `CanonicalJSON` (sorted keys, no trailing newline).
- **Manifest/config are generated artifacts**, not hand-maintained — regeneration commands
  live in `packaging/README.md`; tests verify the generators against the code constants.

##### Issues / needs real credentials or OMP-side work
- **Signing & notarization are documented, not executed** — no Developer ID / notarytool
  credentials in this environment (hard rule). RELEASE.md is the runbook; the ad-hoc
  `swift build` signature means the SIGNED release must be re-granted TCC after install.
- **Production app-approval UI + OMP approval-protocol integration is OMP-side work**, out
  of scope for this helper. Server app policy is the operator denylist `SEMANTOUCH_DENIED_APPS`
  (permissive by default; no built-in hard denies / no mutation allowlist). Until OMP ships
  an elicitation/approval bridge, every mutating action should still be treated as requiring
  human confirmation (SECURITY.md §3) — that confirmation gate is independent of app policy.
- **OMP skill work was deferred at this stage.** Later stages added the
  `semantouch` and `semantouch-setup` skills from the per-turn, stale-id,
  interference, and diagnostics guidance.
- **Live overlay + live packaged-app proofs remain deferred under console lock** (Stage H
  Phase 5 note); the packaging path itself is lock-independent and fully exercised offline.

### Stage I — final whole-repo review + gap closure
- [x] Final review across the entire repo (4 lenses: cross-phase correctness, clean-room+security, contract integrity, completeness ledger). Headline fix at the time: **read-side app policy** — `get_app_state` now consults the policy engine before AX/capture. Plus array-`items` schema validation, `^…$` trailing-newline pattern leak, and injectable-resolver wiring. All 5 findings fixed. Independently verified: 413 tests green; SPI scan clean; no OpenAI artifacts (neutral-bundle-id comments only).
- Genuine gaps the completeness critic surfaced (skeptically, by reading code — not from this plan):
  - **Closable offline (this stage):** Phase 0 "≥25 correlation configs" (only ~11 existed); Phase 1 "cancellation returns a typed result" (no code path); multi-display coordinate round-trip; boundary tracing/timing scaffold.
  - **Deferred (need an unlocked console):** live Phase 3 diff/byte-reduction, Phase 4 interference/interruption matrix, Phase 5 overlay drawing — drivers staged under `probes/stage-{f,g,h}/`.
  - **Deferred (need credentials / OMP-side):** signed+notarized artifacts; OMP approval-UI/protocol + skill file.
- [x] **Gap closure for the closable-offline items.** All four closed offline, 413 baseline
  preserved → **435 tests** green (independently re-verified; build clean, SPI scan clean).
  Details:
  - **Phase 0 "≥25 correlation configs"** — `WindowCorrelationTests` rewritten as a
    table-driven suite of **32 distinct scenarios** (`scenarios.count >= 25` asserted) over
    synthetic `WindowInfo`/AX fixtures: multiple normal windows, duplicate/identical titles,
    empty/whitespace titles, sheets/drawers/panels (non-zero layer), Retina sub-pixel +
    non-Retina + off-by-one frame rounding, heavy overlap, near-identical frames differing
    only by owner pid, minimized/off-screen candidates, alpha<1 cover windows (proving alpha
    is *not* a tiebreak), and genuinely-ambiguous cases. Asserts ZERO wrong matches, typed
    `ambiguous_window`/`uncorrelated_window` on conflict (never an approximate pick), and a
    recorded `match.signals` (always beginning `pid,frame`) on every success.
  - **Phase 1 cancellation** — real cooperative path (PROTOCOL **v1.4 §17**). `MCPServer.run()`
    now decouples reading from execution (serial execution queue + concurrent reader) so a
    client `notifications/cancelled {requestId,reason?}` reaches the in-flight request's
    `CancellationToken`; `get_app_state` checks the token at app-resolve/settle/pre-capture
    boundaries and the async ScreenCaptureKit call is torn down via `Task.cancel()`; a cancel
    surfaces as the new typed `CUError.cancelled` (frozen additively in §6 + §17, changelog
    v1.4). stdin EOF / SIGTERM cancel in-flight work and exit cleanly. Permission-free tests
    over an in-memory pipe transport + a fake slow handler prove: cancelled request → typed
    `cancelled` result + cooperative work stops at the next checkpoint (an already-started
    ScreenCaptureKit capture may run to completion but is surfaced as `cancelled` at the
    post-capture checkpoint — never a partial success; SCK teardown best-effort); normal request
    unaffected; unknown/completed id no-op; EOF cancels in-flight (bounded drain, symmetric with
    SIGTERM). `CancellationToken` + `RequestCancellationRegistry` unit-tested.
  - **Phase 1 multi-display coordinate round-trip** — `CoordinateMapperTests` gains synthetic
    multi-display cases: a secondary display left-of-primary (negative global X), above-primary
    (negative global Y), a two-display different-scale (2x/1x) pair with independent exact
    round trips, and a negative-origin downscale-boundary window — all asserting exact
    G↔W↔S round trips including the top-left origin hazard and the scale/pixel-extent boundary.
  - **Tracing scaffold** — new `Sources/ComputerUseCore/Trace.swift`: a `Tracer`/`TraceSpan`
    span+counter API, off by default, enabled by `SEMANTOUCH_TRACE=1`, emitting one line per span
    to **STDERR** (never stdout), zero-overhead when off (`span(_:)` returns `nil`).
    Instrumented at the main runtime boundaries: `get_app_state` (ax_tree / screenshot marks +
    nodes / tree_bytes / diff_bytes counts), the action executor (semantic + fallback), and
    MCP request dispatch. Span/aggregation logic unit-tested with an injected clock (no
    wall-clock); the stderr-only sink is guaranteed by construction (the production sink
    writes only to `FileHandle.standardError`) and unit-tested via an injected sink; a live
    end-to-end smoke test asserting no stdout leak is pending.
- [x] **Adversarial review of the cancellation path — all findings applied.** Two independent
  reviewers audited the new §17 cancellation path + the gap-closure tests; every confirmed finding
  is fixed (see below), tests stay green and the count grows with the new coverage:
  - **Post-capture cancellation checkpoint (critical, §17.2).** `AppStateBuilder.build` now runs a
    `CancellationToken.checkpoint()` immediately AFTER the `includeScreenshot` switch (before
    geometry/assemble) — closing the gap where a cancel that landed after
    `SCScreenshotManager.captureImage` (which honors neither `Task` cancellation nor
    `Task.isCancelled`) returned a spuriously-successful screenshot-bearing state. The single
    checkpoint also covers the no-screenshot paths (`never`, SR-denied `auto`/`always`), whose only
    prior post-settle checkpoint was skipped, so build/render/diff on those paths are now
    cancellation-checked too.
  - **Cancelled read no longer mutates session state (§13.1 invariant preserved).** The revision
    bump, diff-base snapshot store, and dirty/lineage clear are DEFERRED to a commit block after the
    post-capture checkpoint, and the element table is checkpointed before the build and rolled back
    on the cancel path (`StableElementTable.checkpoint()`/`rollback(to:)`, which restores the
    pre-build id space without rewinding the monotonic counter, §3) — so a cancelled build leaves
    BOTH the revision counter and the element table untouched, matching the builder's stated
    invariant. (Preferred option taken; a large table refactor was not required.)
  - **Settle wait consults the token (§17.2).** `SettleDetector.waitForSettle` gained an injectable
    `isCancelled` poll (checked between sleep slices, default never-cancelled so frozen timings are
    unchanged); `AppStateBuilder.waitForSettle` threads the ambient token, so a cancel breaks the
    up-to-5 s settle promptly instead of paying the full deadline. Unit-tested with the fake clock.
  - **Bounded, symmetric shutdown drain (§17.4).** `MCPServer.run()`'s EOF drain is now a bounded
    `inFlight.wait(timeout:)` (shared `shutdownDrainMilliseconds` = 500 ms) matching the SIGTERM
    drain, so a handler that ignores cancellation can no longer hang shutdown forever.
  - **Instance-guarded cancellation deregister.** `RequestCancellationRegistry.deregister(id:token:)`
    removes only the exact token instance it registered, so a completing request never evicts a
    later in-flight request that reused the same JSON-RPC id (newest-wins for routing a cancel).
  - **Test gap-closure.** Added a single-frame-match/conflicting-titles correlation scenario (→
    `.medium`, title not credited) and a `topLeftY`→`CoordinateMapper` composition round trip on a
    non-primary display (bottom-left→top-left flip), plus settle-cancellation and
    instance-guarded-deregister unit tests.

### Stage J — live GUI acceptance (console UNLOCKED; macOS 26.5.1, Swift 6.3)

The previously-deferred live proofs (Stages F/G/H) ran against the bundled fixture
(`computer-use-fixture` / `pid:<N>`). Recorded honestly — passes AND the genuine findings.

- **Stage F (Phase 3 incremental state) — 7/8 live pass.** PROVEN live: the KEY
  **reconstruction gate** — base full tree + 3 successive diffs applied client-side is
  **byte-identical** to a fresh full tree captured at the same revision — plus **99.1% payload
  reduction** (diff vs. full) and a **0px** semantic-pointer (mutations never moved the system
  cursor). The one path NOT exercised live is the **`+`/`−` structural-diff** (add/remove rows):
  the fixture's Add Row / Remove Row calls `NSTableView.reloadData()`, which **re-mints every
  row's AX identity**, so the pipeline correctly emits a **`diff_reset`** (full tree) instead of
  a structural add/remove delta. This is a **fixture-coverage limitation**, not a diff defect —
  the structural add/remove/move path is exhaustively proven **offline** (the
  `AXTreeDiff` reconstruction suite: adds/removes/attr-changes/moves/mixed bursts). To exercise
  it live the fixture would need a mutation that inserts/removes a row **without** `reloadData()`
  (stable ids across the change).
- **Stage H (Phase 5 ghost cursor overlay) — full live pass.** PROVEN live: the overlay panel is
  **nonactivating** (`canBecomeKey` / `canBecomeMain` both **false**), **click-through**
  (ignores mouse events), draws the virtual cursor while the **system pointer moved 0px**,
  **hides on session end**, and **follows the target window** as it moves. Decorative-only
  contract upheld (never gates or delays an action).
- **Stage G (Phase 4 fallback input) — deliver-in-background + gates + interruption proven;
  brief-focus activation surfaced two findings (fixed here).** PROVEN live:
  - **Deliver-in-background** (target already frontmost) delivers fully — `type_text` /
    `press_key` / coordinate `click` land in the fixture, `targetVerified: true`.
  - **Policy gates** — a denied app → `policy_denied` before any synthesis; `background-only`
    against a non-frontmost target → `focus_required` with nothing delivered.
  - **User interruption** — a genuine physical keystroke during a 15000-char `type_text`
    cancelled the remainder; the result was `status: interrupted` at **952/15000 chars**
    delivered (our own tagged events never self-interrupted).
  - **Target verification** — the fixture, never the user's app, was confirmed frontmost during
    delivery; a mid-delivery foreground steal forces `targetVerified: false`.
  - **Finding A — cmd-chord modifiers (FIXED).** `press_key "cmd+a"` returned `completed` but did
    **not** select-all: a following `delete`/`type` acted on a single character (seed `abcdef` +
    `cmd+a` + `delete` → `abcde`; seed `erase-me` + `cmd+a` + type `Z` → unchanged). Root cause:
    the synthesizer set the Command flag on the key event but posted **no modifier key event**
    (no `flagsChanged`), which the responder requires to recognize a chord. **Fix:** a modified
    chord is now delivered as a real modifier-key sequence — left-Command **down**
    (`flagsChanged`) before the main key, mask on both the modifier and main key-down/up, Command
    **up** after; multiple modifiers nest and release in reverse; a chord is emitted atomically
    (no stuck modifier). Unit-tested over the synthesizer seam
    (`testPressEmitsModifierWrappedChordSequence`, `testPressMultiModifierChordPressesAndReleasesInStableNestedOrder`,
    `testPressUnmodifiedChordEmitsBareKeyDownUp`). **Live-validated against a real Select All**
    in the Stage J Verify pass: with the fix, `press_key "cmd+a"` now genuinely selects the whole
    field (the `flagsChanged` reaches the responder and the chord is recognized), where the
    pre-fix flag-only form did not (seed `abcdef` + `cmd+a` + `delete` had left `abcde`).
  - **Finding B — background→foreground activation (FIXED, mechanism; efficacy verified
    separately).** The `allow-brief-focus` positive path could not foreground a **background**
    app: `NSRunningApplication.activate()` / `.activateIgnoringOtherApps` / `.activateAllWindows`
    all return `true` yet the target never reached frontmost from the non-frontmost helper
    (`waitUntilFrontmost` timed out), so brief-focus `type_text`/`press_key` returned
    `status: rejected` with **nothing delivered** — it FAILS SAFE (never wrong-target). **Fix:**
    when `activate()` does not foreground the target within the bounded wait, the transaction now
    tries a **PUBLIC Accessibility** fallback using the **already-granted Accessibility
    permission** — set the app `AXUIElement`'s `kAXFrontmost` and raise its main/focused window
    (`kAXRaise`) — then **re-verifies** frontmost; delivery still happens only if confirmed
    frontmost, else `focus_required`/`rejected` with nothing delivered. Deliberately **no
    `osascript`/System Events** (that would need a third TCC grant — Automation — and a
    process-per-action shell-out). The AX-fallback **decision logic** is unit-tested
    (`testActivationFailsThenAXFallbackForegroundsAndDelivers`, `testActivationSuccessSkipsAXFallback`).
    **Confirmed live limitation (macOS 26.5.1) — `focusFallbackWorks = no` from the server
    process.** The AX foreground fallback was probed live: from a plain background CLI the
    identical `kAXFrontmost` + `kAXRaise` calls **do** bring the target frontmost (5/5), but from
    **this helper running as the MCP server process** they do **not** (0/10) — the bounded
    re-verify times out and the action returns `status: rejected` (`targetVerified: false`) with
    **nothing delivered** and the prior app **undisturbed** (fails safe every run). So the
    `allow-brief-focus` / `foreground-takeover` *positive* path is currently **non-functional
    from the server process** on macOS 26; the cause appears to be process context / activation
    policy (a background, non-`.app` helper cannot change the system foreground) and will most
    likely require packaging as a foreground-capable `.app` bundle to resolve. Recorded honestly:
    the *mechanism* is correct and unit-proven; the *positive outcome* is OS-gated and, from the
    server process, currently negative (PROTOCOL §16.7).
- **Residual adversarial review of the fallback focus/restore + chord path — all findings
  applied.** A follow-up reviewer found three residual issues after Findings A/B landed; all fixed
  (behavior-only, clean-room, no wire change):
  - **Finding C — brief-focus RESTORE must be symmetric with the forward AX raise (major).** The
    restore branch relied solely on `activate(prior)` (the call FIX B documents as unreliable from
    a non-frontmost helper) with no AX-raise fallback and no frontmost re-check, and derived
    `focusRestored` from `restoreFocusedElement` (a `kAXFocused` set that can succeed on a
    background element) — so a delivered brief-focus action whose restore silently failed could
    report `focusChanged=true` AND `focusRestored=true` while actually leaving the target frontmost
    (a takeover masquerading as a restore). **Fix:** the restore now mirrors the forward path —
    `activate(prior)`, and if `waitUntilFrontmost(prior)` is still false, the same
    `raiseViaAccessibility(prior)`; `focusRestored` is derived from the **actual `frontmost ==
    prior` re-check** (AND the best-effort element restore), so it is `false` honestly when the
    prior app cannot be refronted. Unit-tested over the workspace seam
    (`testActivateRestoreUsesAXRaiseToRestorePriorWhenActivateCannotForeground` — restore also
    attempts the AX raise and reports restored only when the prior is truly frontmost again;
    `testActivateRestoreReportsNotRestoredWhenPriorCannotRegainForeground` — `focusRestored=false`
    when the prior never returns, even though `restoreFocusedElement` "succeeded").
  - **Finding D — modifier release must not be skippable by a per-event nil (minor, safety).**
    `CGEventSynthesizer.postKey` silently `return`ed if `CGEvent(...)` yielded nil; a dropped
    modifier `keyUp` (after its `keyDown` posted) would strand a modifier held at the OS level and
    corrupt all subsequent USER input. **Fix:** `postKey` falls back to a **source-less** `CGEvent`
    construction (still tagged, so no self-interruption) and logs to stderr on the doubly-nil case,
    rather than dropping the release; `emit()`'s release loop remains unconditional straight-line
    code (no early return between the modifier keyDowns and their keyUps), so a modifier release is
    always attempted. Successful-path behavior unchanged; the emit ordering/release is covered by
    the existing chord tests.
  - **Finding 2 (doc) — brief-focus mislabel corrected.** §16.7 no longer says a focus-changing
    mode that cannot foreground the target returns `focus_required`; per frozen §16.4 it returns
    `status: rejected` (`targetVerified: false`). `focus_required` is exclusively the
    `background-only` pre-transaction outcome. The confirmed server-process limitation above is now
    stated honestly in §16.7 + §14.
- Gate after the residual fixes: full `swift build` + `swift test` green (**448 tests**, was 446).
  No new TCC permission; clean-room (PUBLIC Apple APIs only); stdout stays protocol-only.
- Resolves the Stage I "Deferred (need an unlocked console)" item for Phases 3/4/5; the Phase-4
  cross-app *foregrounding* efficacy is OS-gated and, from the server process on macOS 26,
  **confirmed non-functional** (fails safe) per Finding B — likely unblocked only by
  foreground-capable `.app` packaging.

### Stage K — v1.5 web content + verified transitions (real-world browser feedback)

Driven by a failed real-world OMP test ("browse to Home Depot and report pine 4x4 prices"
against the Aside Chromium-shell browser): webview content was invisible to AX, `set_value`
on the address bar never navigated, action results read as false successes, windows were not
enumerable, and the ghost cursor confused more than it helped. PROTOCOL §18 (v1.5) freezes the
remedy; docs/USAGE.md, the skills, and packaging were updated in step.

- [x] §18.1 web-content AX enablement: `AXManualAccessibility`/`AXEnhancedUserInterface` set
  best-effort once per session (reset on end/shutdown only when we flipped them;
  `SEMANTOUCH_WEB_AX=off` opt-out; new `web_content_enabled` warning + forced settle on the
  enabling snapshot). Live finding frozen in §18.1: a Chromium shell can return
  `cannotComplete` (-25208) for the set while the write TAKES EFFECT — classification
  verifies by re-read (live-proven against Aside: 0 → 578-node web tree, x.com).
- [x] §18.2 scoped/bounded snapshots: `scopeElementId` (current-table resolve → subtree walk,
  full/no-diff/lineage-broken, `scope` echo) + `maxNodes` (clamped 1…2000; validator now
  honors schema `maximum`).
- [x] §18.3 `AppState.windows` (id/title/frame/focused/main/onScreen) + §18.4
  `window.document` `{url,title}` from the principal `AXWebArea` (CFURL-safe `AXURL` read).
- [x] §18.5 `set_value` `commit`: pre-focus → write → `AXConfirm` iff advertised;
  `committed` result field; advisory warning steers to the keyboard commit when
  unadvertised (Aside's omnibox advertises only Press/ShowMenu — observed live).
- [x] §18.6 element-targeted `press_key`/`type_text`: optional `revision`+`elementId`
  (both-or-neither → -32602), §13.2 validation in-lane, AXFocused set + bounded confirm
  inside the focus transaction, `elementFocused` result field.
- [x] §18.7 `wait_for` (13th tool): title/url/element conditions, `all|any`, bounded poll
  over a raw AX walk (never touches the element table), expired deadline = normal
  `satisfied:false`, §17 cooperative cancellation.
- [x] §18.8 pointer restore (behavior-only): coordinate pointer actions record and return
  the physical cursor after delivery (skipped on interruption/foreground loss) — public
  CGEvent delivery necessarily moves it (§16.7); full independence (SAI) stays out of scope.
- [x] Ghost-cursor anchoring (user feedback round 2): location-less actions keep the last
  cursor point (no more yank-to-centre); semantic actions anchor at the target element's
  frame centre (`CursorReflection.elementAnchor`, best-effort resolve in `runSemantic`).
- [x] Doc bug fixed: `press_key` examples taught space-joined chords (`"cmd shift a"`);
  correct grammar is `+`-joined chords, space-separated sequence (`"cmd+shift+a"`,
  `"cmd+a cmd+c"`) — was plausibly contributing to failed keyboard commits in OMP.
- [x] serverVersion 0.2.0 (wire id unchanged `semantouch/1`); tools/list = 13;
  packaging manifests regenerated; helper reinstalled to `~/.omp/bin` (grants carried).
- Gate: `swift build` clean, `swift test` **519 tests, 0 failures** (was 456 pre-stage).
- Live acceptance (Aside, macOS 26.5.1, unlocked console): web tree + `document.url` +
  `windows` + scoped reads proven; `set_value commit:true` → honest `committed:false` +
  warning; element-targeted Return `elementFocused:true`; one run `interrupted` by GENUINE
  user input (safety tap correct); retry delivered and `wait_for url_changed` reported
  `satisfied:true` (navigation verified). False-success failure mode is closed: delivery
  and outcome are now separately observable.
- [x] Follow-up (live OMP session, GPT-5.6 driver): a scoped `get_app_state` before any
  unscoped snapshot trapped agents in an error loop — the first scoped call created a
  half-session as a side effect, so retries decayed from `stale_revision` into repeated
  `stale_element` against an empty table while every message said "Refresh with
  get_app_state" (which the agent believed it was doing). Fixed: the scoped-vs-fresh-session
  guard now runs before the element table / web-AX / observers and ENDS the just-created
  session before throwing (§18.2 clarification frozen: a failed scoped request never creates
  a session), `scopeElementId`/`maxNodes` gained in-schema descriptions stating "never on a
  session's first snapshot; on stale_*, retry WITHOUT this field", and the skill reference
  spells out the unscoped-then-rescope recovery. Live-verified: scoped→scoped→unscoped
  against a fresh app now yields stale_revision, stale_revision, success. 519 tests green.
- [x] Follow-up 2 (second live OMP round): the consistent-error fix was not enough — the
  driver agent looped NINE scoped calls (s1…s9) against the stable `stale_revision`, proving
  it neither reads in-schema property descriptions nor can act on an error whose remedy
  ("refresh with get_app_state") is indistinguishable from what it is already doing. §18.2
  REVISED (supersedes the create/discard + error approach above): an unhonorable
  `scopeElementId` now NEVER errors — it degrades to a full unscoped snapshot with the new
  advisory warning `scope_ignored` (message names the id, the reason, and the recovery),
  no `scope` echo, and normal unscoped id/diff semantics. `stale_revision`/`stale_element`
  are no longer `get_app_state` outcomes at all. Schema + skill guidance rewritten to match;
  get_app_state's top-level description (which the driver demonstrably DOES see) now says
  when to omit the field. Live-verified: scoped-on-fresh-session and guessed-id (`e9999`)
  both return usable full trees with `scope_ignored`; the loop is structurally impossible.
  519 tests green; packaging regenerated; helper reinstalled.

### Stage L — `screenshot` tool (user request: cheap visual peek)

User asked to let the agent choose between a full AX tree and just seeing the screen —
cheaper in the common "did it work / what does it look like" case, and it should be the
recommended path for visual questions. §18.9 frozen + implemented.

- [x] 14th tool `screenshot { app, windowId? }` → `ScreenshotResult { sessionId, window,
  screenshot, warnings }` + the JPEG as the §5 image block. Reuses the byte-identical
  `AppStateBuilder.capture` (made internal) — no duplicate SCK/encoder pipeline.
- [x] Cheaper by construction: NO settle wait, NO tree walk, and — the key property — NO
  revision advance and NO id mint/retire. `ScreenshotService.capture` only
  ensureSession + storeWindowGeometry; it never touches the revision, element table, diff
  base, lineage, or web-AX state. A session's current ids stay valid across any number of
  screenshot calls (unit-guaranteed; verifiable by reading the service).
- [x] Hard `permission_denied(screenRecording)` when SR is not granted (unlike
  get_app_state's soft degrade — the image is the product). Refreshes §16.5
  `space:"screenshot"` coordinate geometry so pixel clicks track the latest image.
- [x] Ordered at catalog position 4 (phase:1, grouped with get_app_state — the two
  window-observation tools); tools/list = 14. Golden tool-count tests renamed
  count-agnostic (testAllDefinedToolsAreEnabled / testCatalogCoversAllDefinedTools) so
  future additions stop churning names.
- [x] Recommended in guidance: skill core-workflow step, a new "Choosing between
  screenshot and get_app_state" section, the tool-selection table, USAGE §4, and the
  tool's own top-level schema description all steer visual questions to screenshot and
  reserve get_app_state for acquiring targets.
- [x] Gate: swift build clean, `swift test` **529 tests, 0 failures** (was 519).
  Packaging regenerated; helper reinstalled to ~/.omp/bin (0.2.0).
- [!] Live capture NOT proven from this session's CLI harness: ScreenCaptureKit capture
  hangs when the `mcp` server is a bare Popen child of the headless Bash/daemon context
  (no proper GUI/window-server session) — `get_app_state`+capture hangs IDENTICALLY there,
  since both share `AppStateBuilder.capture`, so it is an environmental harness limit, not
  a tool defect. The same capture path is proven working inside OMP (the user's live OMP
  screenshots delivered ~111 KB JPEG image blocks via get_app_state). The screenshot
  tool's non-capture surface (schema, ordering, revision-invariance) is unit-verified;
  live end-to-end capture confirmation is the user's next OMP run.

### Stage M — lifelike flying arrow cursor (user feedback round 3)

User wants a ChatGPT-style cursor: a proper macOS arrow (reference: chunky charcoal NW
arrow, white rounded outline), still per-thread color-distinct, an expanding+fading click
bubble, and ANIMATED travel that "feels alive" (translation + a little rotation + skew),
not a teleport.

- [x] Root cause: the on-screen cursor was TELEPORTING — the pure `CursorAnimator.tick`
  easing model existed but the live presenter never drove it (`applyLatest` snapped to each
  point and drew a disc+tail). No display loop.
- [x] Pure model (`CursorArt.swift` new + `CursorAnimator` evolved): arrow outline polygon
  (tip = hotspot at origin) + `outlinePath(pose:)` transform; `CursorPose`/`RippleFrame`/
  `CursorRenderFrame`; `tickRender(dt:)` does exponential position ease → smoothed velocity
  → velocity-derived lean/skew/stretch + press squash + click ripples (spawned on the
  transition into `.pressed`). `tick`/`CursorFrame` retained for back-compat.
- [x] Presenter rewrite (`CursorPanel.swift`): ~60fps main-thread display Timer ticks the
  model and renders cheap CAShapeLayers; parks itself when settled (zero idle cost). Arrow =
  round-join white outline + soft shadow, fill = identity hue darkened ×0.34 (cursor-like
  but tinted); ripple pool drawn in the bright full identity colour. `show()` snaps a
  fresh/switched session in place; moves fly. Tunables in `CursorMotionConfig`.
- [x] Tests: CursorMotionTests (9) — rest/settle, lean+skew on fast travel + settle upright,
  lean clamp, press ripple expand/fade, distinct presses, ripple expiry, tip-tracks-pose,
  neutral-outline. Existing 25 controller / 7 animator / plan tests still green.
- [x] Static art preview rendered + checked (arrow matches reference; per-thread colors;
  lean/skew + ripple read well). Gate: `swift test` **538 tests, 0 failures** (was 529).
  Helper reinstalled 0.2.0.
- [~] LIVE animation FEEL is the user's to judge in OMP (can't watch the animation from this
  session). Motion constants are centralized in `CursorMotionConfig` for quick iteration on
  feedback.
- [x] Arrival-ripple fix: the click bubble was spawning at the DEPARTURE point (ripple fired
  on the retarget→pressed transition, at the cursor's pre-flight position) then the cursor
  flew away, leaving the bubble at the wrong end. Now the pure model LATCHES the press and
  fires the ripple when the tip ARRIVES at the click target (blooms under the click, like
  ChatGPT). The follow-up finish→idle at the same target keeps the pending press alive; a
  redirect before arrival fires it at the intended location. `settled` gates on `!pendingPress`
  so the display timer never parks before the bubble blooms. 540 tests green (+2).
