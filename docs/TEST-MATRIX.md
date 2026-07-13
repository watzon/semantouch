# Test Matrix

Concrete verification matrix for the protocol and implementation. `kind` is one of:

- **unit** — pure logic, no OS permission, no live app; runs in `swift test`
  unconditionally.
- **contract** — MCP protocol/schema behavior against `PROTOCOL.md`; may use
  a fake/stub engine, no OS permission required.
- **runtime** — exercises real AX/ScreenCaptureKit/input APIs against the
  fixture app or a real app; requires the stated OS grant(s) and runs
  best-effort per `docs/PLAN.md` ("Runtime proofs ... report `blocked` with
  exact remediation instead of guessing").

`status` is a placeholder (`pending`, `blocked`, `pass`, `fail`) updated as
tests are implemented and run; this document does not itself assert current
status beyond `pending`.

## 1. Protocol contract tests (`Tests/ProtocolContractTests`)

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| `initialize` returns `protocolVersion: 2025-06-18` regardless of client-proposed version | contract | none | 1 | pending |
| `tools/list` before `initialize` is rejected | contract | none | 1 | pending |
| `tools/list` after `initialize` lists only enabled tools for current phase | contract | none | 1 | pending |
| Disabled tool call returns `policy_denied`/`tool_disabled`, not `-32601` | contract | none | 1 | pending |
| Unknown method returns JSON-RPC `-32601` | contract | none | 1 | pending |
| Malformed JSON line returns `-32700` | contract | none | 1 | pending |
| Missing/invalid required param returns `-32602` | contract | none | 1 | pending |
| stdout contains only newline-delimited JSON-RPC frames under load (no stray logs) | contract | none | 1 | pending |
| Request `id` echoed exactly; notifications get no reply | contract | none | 1 | pending |
| `doctor` never prompts when `requestOnboarding` omitted/false | contract | none | 1 | pending |
| `doctor` result schema matches `DoctorResult` incl. `remediation` naming `helper.path` | contract | none | 1 | pending |
| `list_apps` result matches `AppSummary[]` schema; no recent-use DB scan | contract | none | 1 | pending |
| `app_not_found` / `ambiguous_app` on synthetic resolver fixtures | unit | none | 1 | pending |
| `window_not_found` / `ambiguous_window` / `uncorrelated_window` / `uncapturable_window` on synthetic correlator fixtures | unit | none | 1 | pass |
| Omitted or `0` `get_app_state.windowId` selects automatically; positive ids remain explicit WindowServer ids, never `list_apps.windows` ordinals | unit + contract | none | 1 | pass |
| `get_app_state` result matches `AppState` schema; Phase 1 always `revision:1, full:true` | contract | none | 1 | pending |
| Screenshot delivered as separate image block, `AppState.screenshot` metadata-only, JPEG mimeType | contract | none | 1 | pending |
| `includeScreenshot: never` omits image block and adds `screenshot_omitted` | contract | none | 1 | pending |
| `end_app_session` unknown id returns `ended:false`, not an error | contract | none | 1 | pending |
| `end_app_session` known id is idempotent (`ended:false` on repeat) | unit | none | 1 | pending |
| Stale `revision` on an action-shaped request returns `stale_revision` with `{sessionId,provided,current}` | contract | none | 2 | pending |
| Unresolvable `elementId` returns `stale_element` with `{sessionId,elementId,revision}` | contract | none | 2 | pending |
| Session cancellation (`notifications/cancelled` or stdin EOF mid-request) yields a typed `cancelled` result; cooperative in-flight work is cancelled at the next checkpoint (an already-started ScreenCaptureKit capture may run to completion but is surfaced as `cancelled` at the post-capture checkpoint, not a partial success; SCK teardown is best-effort). A cancelled build leaves the session untouched (revision + element table). | contract | none | 1 | pass |
| Session lifecycle: lazy create on `get_app_state`, ids never reused within process | unit | none | 1 | pending |

## 2. Tree grammar tests (`Tests/AccessibilityEngineTests`)

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| Fixed key order `value,placeholder,desc,enabled,focused,selected,frame,actions` with correct presence rules | unit | none | 1 | pending |
| Role/subrole emitted verbatim; action names `AX`-stripped | unit | none | 1 | pending |
| Escaping: `\ " \n \r \t` and `\u00XX` for other C0 controls, single-line output | unit | none | 1 | pending |
| Per-field cap 256 UTF-8 bytes with `…` suffix, independent of node/byte budget | unit | none | 1 | pending |
| Node cap default 600, hard ceiling 2000, exact single pre-order truncation marker `… +<N> nodes omitted` | unit | none | 1 | pending |
| Tree text byte cap 120 KB enforced with correct `truncated`/`nodeCount` | unit | none | 1 | pending |
| `frame=?` sentinel when no frame resolvable | unit | none | 1 | pending |
| Byte-for-byte deterministic output across two renders of identical synthetic tree | unit | none | 1 | pending |
| Worked examples (PROTOCOL §7.6, §7.7) reproduced exactly from fixture input | unit | none | 1 | pending |
| Pruning: empty structural groups removed, disabled controls retained, title-association preserved | unit | none | 1 | pending |
| Fixture app: button press counter — `AXPress` observably increments counter | runtime | Accessibility | 0/2 | pending |
| Fixture app: settable text field — `AXValue` set is reflected in fixture state-file event log | runtime | Accessibility | 0/2 | pending |
| Fixture app: nonsettable field rejects `set_value` with `unsupported_action` | runtime | Accessibility | 2 | pending |
| Fixture app: nested scroll area — semantic scroll changes visible offset | runtime | Accessibility | 2 | pending |
| Fixture app: secondary action (disclosure/menu) via `perform_action` | runtime | Accessibility | 2 | pending |
| Fixture app: dynamically inserted/removed rows produce correct add/remove without stale ids reused | runtime | Accessibility | 1/3 | pending |
| Fixture app: duplicate labels resolve to distinct stable element ids | runtime | Accessibility | 1 | pending |
| Fixture app: sheet/popover appears in tree with correct parent lineage | runtime | Accessibility | 1 | pending |
| AX child order is stable across repeated reads of unchanged fixture state | runtime | Accessibility | 1 | pending |

## 3. Capture and coordinate tests (`Tests/CaptureEngineTests`)

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| AX↔`SCWindow` correlation across ≥25 fixture-window configurations, zero wrong matches | unit | none | 0 | pass (32 synthetic configs) |
| Correlation returns `ambiguous_window`/`uncorrelated_window` on conflicting signals instead of guessing | unit | none | 0 | pass |
| Decided signals recorded per successful match (pid/frame/title/layer/order) | unit | none | 0 | pass |
| Covered-window capture: opaque cover above fixture window, captured image contains only target content | runtime | Accessibility, Screen Recording | 0/1 | pending |
| `SCContentFilter(desktopIndependentWindow:)` used, never full-display screenshot + crop | unit | none | 0 | pending |
| Minimized window → `uncapturable_window` reason `minimized` | runtime | Screen Recording | 1 | pending |
| Offscreen/off-Space window → `uncapturable_window` reason `offscreen` | runtime | Screen Recording | 1 | pending |
| Screenshot encoding: JPEG q0.75, long edge ≤1568px, ≤3MB (shrink dimension, never raise quality) | unit | none | 1 | pending |
| Coordinate round-trip G↔W↔S across multiple displays and scale factors | unit | none | 1 | pass (left/above-primary neg origins, 2x/1x, downscale) |
| Coordinate round-trip on a scaled/Retina screenshot matches `kx`/`ky` derived from delivered pixel dims | unit | none | 1 | pass |
| `window.framePoints` reported in global points (G); tree `frame=` reported in window points (W) | runtime | Accessibility, Screen Recording | 1 | pending |
| PNG output only reachable via CLI probe path, never via MCP `tools/call` result | unit | none | 1 | pending |

## 4. Action and interference tests (`Tests/ActionEngineTests`)

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| Covered `AXPress` on fixture button does not change frontmost app | runtime | Accessibility | 0/2 | pending |
| Covered `AXValue` set on fixture text field does not change frontmost app | runtime | Accessibility | 0/2 | pending |
| Policy denial occurs before any dispatch to AX/input APIs (mock engine call count = 0) | unit | none | 2 | pending |
| Per-app actions serialize; two concurrent actions on same session never interleave | runtime | Accessibility | 2 | pending |
| Two sessions on different apps proceed independently (no cross-app blocking) | runtime | Accessibility | 2 | pending |
| Stale/replaced element cannot receive an action within the same session | runtime | Accessibility | 2/3 | pending |
| `select_text` with `length:0` places caret at `start`, no selection | runtime | Accessibility | 2 | pending |
| `press_key` combo grammar parses/rejects per PROTOCOL §4.3 (valid and malformed combos) | unit | none | 4 | pass |
| `press_key` modifier chord (e.g. `cmd+a`) posts a REAL modifier key-down/up (`flagsChanged`) wrapping the main key, mask on both, nested/reverse for multi-mod (FIX A) | unit | none | 4 | pass; live select-all re-verified in Stage J Verify |
| `type_text` emits literal text into fixture field, verified via state-file log | runtime | Accessibility | 4 | pass (live: deliver-in-background, `targetVerified:true`) |
| Coordinate `drag`/`click` fallback in `window` vs `screenshot` space maps correctly | runtime | Accessibility, Screen Recording | 4 | pass (live) |
| Noninterference: observer app stays frontmost/focused during covered-target semantic action | runtime | Accessibility | 2/4 | pass (live) |
| Noninterference: system pointer does not move for semantic (non-fallback) actions | runtime | Accessibility | 2 | pass (live: 0px) |
| Focus transaction restores prior user focus after a fallback action completes | runtime | Accessibility | 4 | pass for deliver-in-background; brief-focus restore gated on foregrounding (see FIX B row) |
| Brief-focus RESTORE is symmetric with the forward AX raise: after `activate(prior)`, if still not frontmost, `raiseViaAccessibility(prior)` is tried; `focusRestored` reflects the ACTUAL `frontmost==prior` re-check (NOT `restoreFocusedElement`'s return), so it is `false` honestly when the prior app cannot be refronted (Finding C) | unit | none (fake workspace) | 4 | pass (`testActivateRestoreUsesAXRaiseToRestorePriorWhenActivateCannotForeground`, `testActivateRestoreReportsNotRestoredWhenPriorCannotRegainForeground`) |
| Modifier `keyUp` is never skipped by a per-event nil `CGEvent`: `postKey` falls back to a source-less (still-tagged) construction + stderr log instead of silently returning, so a modifier is never stranded held-down (Finding D) | unit | none | 4 | pass (emit ordering/release covered by chord tests; live path source-less fallback is construction-infallible) |
| `allow-brief-focus`/`foreground-takeover`: on failed `NSRunningApplication.activate()`, a PUBLIC Accessibility fallback (`kAXFrontmost` + raise main window) is tried, then frontmost re-verified; delivers only if confirmed, else `status: rejected` (`targetVerified:false`) — NOT `focus_required` (that is the `background-only` pre-check only) — NO new TCC (FIX B) | unit | Accessibility (already granted) | 4 | unit pass; **live: `focusFallbackWorks=no` from the server process on macOS 26 (0/10; identical AX calls work 5/5 from a plain CLI)** — positive path non-functional from the server process, fails safe every run, likely needs foreground-capable `.app` packaging (PROTOCOL §16.7) |
| User interruption: injected real input cancels remaining queued actions | runtime | Accessibility | 4 | pass (live: `interrupted` at 952/15000 chars) |
| User interruption: helper's own synthetic events do not self-trigger `user_interrupted` | runtime | Accessibility | 4 | pass (live: tagged events never self-interrupt) |
| Interruption response returns `interrupted`/`user_interrupted` and requires fresh `get_app_state` before resuming | runtime | Accessibility | 4 | pass (live: `status: interrupted`, `targetVerified:false`) |
| Action-time confirmation gate: unconfirmed mutating action returns `policy_denied`/`action_confirmation_required` | unit | none | 2 | pending |
| Deny-listed app (OMP/ChatGPT self, terminals, security processes) rejects session before any AX call | unit | none | 1/2 | pending |

## 5. Incremental state tests (Phase 3, `Tests/AccessibilityEngineTests` + `Tests/ActionEngineTests`)

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| Diff (`~` attribute lines) reconstructs identical state to a full-tree re-render (base + 3 diffs == fresh full tree, byte-identical) | runtime | Accessibility | 3 | pass (live) |
| Diff `+`/`−` STRUCTURAL add/remove reconstructs identical state | runtime | Accessibility | 3 | offline-only (proven in `AXTreeDiff` suite); fixture Add/Remove Row calls `reloadData()` → re-mints ids → correct `diff_reset`, so the live path emits a full tree, not a structural delta (fixture-coverage limitation) |
| `AXObserver` debounce coalesces notification bursts into one revision | runtime | Accessibility | 3 | pass (live) |
| Rapidly changing layout never produces a tree that mixes two lineages | runtime | Accessibility | 3 | pass (live) |
| Adaptive settle detector respects normal/loading deadlines and returns `possibly_unsettled` on deadline expiry | runtime | Accessibility | 3 | pass (live) |
| Full rebuild fallback triggers when element lineage is uncertain (`diff_reset`) | runtime | Accessibility | 3 | pass (live: fixture `reloadData()` re-mint → `diff_reset`) |
| Measured payload reduction: diff bytes < full-tree bytes for a representative UI change | runtime | Accessibility | 3 | pass (live: 99.1% reduction) |

## 6. Safety and isolation (all suites)

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| No destructive action ever targets a non-fixture, non-allow-listed app in CI | contract | none | all | pending |
| Persistent app-decision store isolated under a dedicated test app-group/container | unit | none | 1 | pending |
| Network access disabled/unreachable during test runs (no external calls attempted) | contract | none | all | pending |
| `doctor` with permission denied returns `permission_denied` naming exact helper binary, no partial success | runtime | none (denied state) | 1 | pending |
| stdout byte stream never contains a raw, unescaped newline inside a message | contract | none | 1 | pending |

## 7. Benchmark matrix (performance, non-blocking for correctness gates)

Representative apps: Calculator, Finder, TextEdit, Safari, Chrome, Slack,
Xcode, Music, a SwiftUI sample app, and a canvas/custom-rendered test app.
Results are measured and recorded, not asserted, until a later phase promotes
specific numbers to correctness gates.

| Metric | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| `list_apps` warm latency | runtime | none | 1 | pending |
| AX-only `get_app_state` warm latency | runtime | Accessibility | 1 | pending |
| AX + still screenshot warm latency | runtime | Accessibility, Screen Recording | 1 | pending |
| Semantic action dispatch latency (pre-app-work) | runtime | Accessibility | 2 | pending |
| Diff generation latency | runtime | Accessibility | 3 | pending |
| User interruption cancellation latency | runtime | Accessibility | 4 | pending |
| Boundary tracing scaffold (`SEMANTOUCH_TRACE=1`): span/aggregation logic (injected clock), stderr-only sink by construction (unit-tested via injected sink), zero-overhead when off | unit | none | 1 | pass |
| Instrumented boundaries emit spans: `get_app_state` (ax_tree/screenshot marks, node/byte counts), action executor, MCP request dispatch | contract | none | 1 | pass (unit-tested via injected sink; live stdout-clean smoke test pending; get_app_state/action need grants) |

## 8. Virtual cursor overlay (Phase 5, `Tests/CursorOverlayTests` + live)

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| Overlay panel is nonactivating (`canBecomeKey` / `canBecomeMain` both false) | unit + runtime | none | 5 | pass (live) |
| Overlay is click-through (ignores mouse events; never steals input) | runtime | none | 5 | pass (live) |
| Drawing the virtual cursor moves the SYSTEM pointer 0px | runtime | none | 5 | pass (live: 0px) |
| Overlay hides on session end | runtime | none | 5 | pass (live) |
| Overlay follows the target window as it moves | runtime | none | 5 | pass (live) |
| Overlay is decorative-only: never fails, delays, or gates an action | unit + runtime | none | 5 | pass (live) |
