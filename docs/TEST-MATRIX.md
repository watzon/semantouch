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

`status` meanings:

- **pass** — implemented automated test and/or recorded live proof in this matrix.
- **pending** — intended gate not yet automated or not re-run recently.
- **unproven** — claimed only as a real-machine / release gate; not proven in CI here.
- **offline-only** — unit/synthetic proof only; live path has a known fixture limitation.

Public computer-use support is **macOS only**. Windows/Linux GA is not claimed.

## Suite inventory (current worktree)

Observed via `swift test --list-tests` (focused listing only; full suite not executed
by this docs task):

| Suite | Approx. cases | Notes |
|---|---:|---|
| `ProtocolContractTests` | 191 | Includes `LaunchToolContractTests`, `ReadTextToolTests`, `PackagingTests`, lifecycle |
| `ActionEngineTests` | 148 | Actions, focus, interruption, serialization |
| `AccessibilityEngineTests` | 130 | Tree, diff, settle, click target resolver |
| `ComputerUseCoreTests` | 94 | DTOs, errors, policy, encoding |
| `CursorOverlayTests` | 89 | Overlay geometry/lifecycle |
| `MCPServerTests` | 76 | Transport, cancellation, registry |
| `CaptureEngineTests` | 46 | Correlation, coords, capture encoding |
| `SemantouchIPCTests` | 40 | Host listener, peer trust, opaque relay |
| `SemantouchCLIKitTests` | 40 | `call` command sequencing |
| `SemantouchAppTests` | present | Permission presentation model |

Focused commands for doc-owned assertions (text/JSON only; do not run the project suite
for docs edits):

```sh
# Tool count / order truth
python3 - <<'PY'
import re
from pathlib import Path
text = Path('Sources/MCPServer/ToolCatalog.swift').read_text()
names = re.findall(r'name: "([^"]+)", phase: \d+, enabledNow: true', text)
assert len(names) == 16, names
print(names)
PY

# Published vs next-release assets
gh release view v0.2.1 --json assets --jq '.assets[].name'
```

## 1. Protocol contract tests (`Tests/ProtocolContractTests`)

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| `initialize` returns `protocolVersion: 2025-06-18` regardless of client-proposed version | contract | none | 1 | pass (suite present; `MCPServer.mcpProtocolVersion`) |
| `tools/list` before `initialize` is rejected | contract | none | 1 | pass (MCPServerTests / ProtocolContractTests coverage) |
| `tools/list` after `initialize` lists exactly the 16 enabled tools in catalog order | contract | none | 1 | pass (`ProtocolContractTests` golden list; `LaunchToolContractTests`/`ReadTextToolTests` assert count 16) |
| Disabled tool call returns `policy_denied`/`tool_disabled`, not `-32601` | contract | none | 1 | pass (registry filtering tests) |
| Unknown method returns JSON-RPC `-32601` | contract | none | 1 | pass |
| Malformed JSON line returns `-32700` | contract | none | 1 | pass |
| Missing/invalid required param returns `-32602` | contract | none | 1 | pass |
| stdout contains only newline-delimited JSON-RPC frames under load (no stray logs) | contract | none | 1 | pending (live stdout-clean smoke still noted as pending historically) |
| Request `id` echoed exactly; notifications get no reply | contract | none | 1 | pass |
| `doctor` never prompts when `requestOnboarding` omitted/false | contract | none | 1 | pass (DoctorService preflight path) |
| `doctor` result schema matches `DoctorResult` incl. `remediation` naming `helper.path` | contract | none | 1 | pass |
| `list_apps` result matches `AppSummary[]` schema; no recent-use DB scan; never launches | contract | none | 1 | pass (`AppLifecycleTests.testListAppsNeverLaunches`) |
| `launch_app` sits immediately after `list_apps`; schema strict; policy-gated | contract | none | 1 | pass (`LaunchToolContractTests`) |
| `read_text` sits immediately after `get_app_state`; revision gates; secure fields rejected | contract | none | 1 | pass (`ReadTextToolTests`) |
| Packaging manifest tool list equals `ToolCatalog.enabled` (16); app-host TCC ownership text | contract | none | 1 | pass (`PackagingTests`) |
| `app_not_found` / `ambiguous_app` on synthetic resolver fixtures | unit | none | 1 | pass (`AppResolverTests`) |
| `window_not_found` / `ambiguous_window` / `uncorrelated_window` / `uncapturable_window` on synthetic correlator fixtures | unit | none | 1 | pass |
| Omitted or `0` `get_app_state.windowId` selects automatically; positive ids remain explicit WindowServer ids, never `list_apps.windows` ordinals | unit + contract | none | 1 | pass |
| `get_app_state` result matches `AppState` schema; first snapshot full; later may diff | contract | none | 1 | pass (encoding + contract suite) |
| Screenshot delivered as separate image block, `AppState.screenshot` metadata-only, JPEG mimeType | contract | none | 1 | pass |
| `includeScreenshot: never` omits image block and adds `screenshot_omitted` | contract | none | 1 | pass |
| `end_app_session` unknown id returns `ended:false`, not an error | contract | none | 1 | pass |
| `end_app_session` known id is idempotent (`ended:false` on repeat) | unit | none | 1 | pass |
| Stale `revision` on an action-shaped request returns `stale_revision` with `{sessionId,provided,current}` | contract | none | 2 | pass (`ActionExecutorTests` + contract) |
| Unresolvable `elementId` returns `stale_element` with `{sessionId,elementId,revision}` | contract | none | 2 | pass |
| Session cancellation (`notifications/cancelled` or stdin EOF mid-request) yields a typed `cancelled` result; cooperative in-flight work is cancelled at the next checkpoint (an already-started ScreenCaptureKit capture may run to completion but is surfaced as `cancelled` at the post-capture checkpoint, not a partial success; SCK teardown is best-effort). A cancelled build leaves the session untouched (revision + element table). | contract | none | 1 | pass (`CancellationDispatchTests`) |
| Session lifecycle: lazy create on `get_app_state`, ids never reused within process | unit | none | 1 | pass |

## 2. Tree grammar tests (`Tests/AccessibilityEngineTests`)

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| Fixed key order `value,placeholder,desc,enabled,focused,selected,frame,actions` with correct presence rules | unit | none | 1 | pass (`AXTreeRendererTests`) |
| Role/subrole emitted verbatim; action names `AX`-stripped | unit | none | 1 | pass |
| Escaping: `\ " \n \r \t` and `\u00XX` for other C0 controls, single-line output | unit | none | 1 | pass |
| Per-field cap 256 UTF-8 bytes with `…` suffix, independent of node/byte budget | unit | none | 1 | pass |
| Node cap default 600, hard ceiling 2000, exact single pre-order truncation marker `… +<N> nodes omitted` | unit | none | 1 | pass |
| Tree text byte cap 120 KB enforced with correct `truncated`/`nodeCount` | unit | none | 1 | pass |
| `frame=?` sentinel when no frame resolvable | unit | none | 1 | pass |
| Byte-for-byte deterministic output across two renders of identical synthetic tree | unit | none | 1 | pass |
| Worked examples (PROTOCOL §7.6, §7.7) reproduced exactly from fixture input | unit | none | 1 | pass (`testGoldenSignInExample`) |
| Pruning: empty structural groups removed, disabled controls retained, title-association preserved | unit | none | 1 | pending |
| Fixture app: button press counter — `AXPress` observably increments counter | runtime | Accessibility | 0/2 | unproven (requires real-machine grant + fixture) |
| Fixture app: settable text field — `AXValue` set is reflected in fixture state-file event log | runtime | Accessibility | 0/2 | unproven |
| Fixture app: nonsettable field rejects `set_value` with `unsupported_action` | runtime | Accessibility | 2 | unproven |
| Fixture app: nested scroll area — semantic scroll changes visible offset | runtime | Accessibility | 2 | unproven |
| Fixture app: secondary action (disclosure/menu) via `perform_action` | runtime | Accessibility | 2 | unproven |
| Fixture app: dynamically inserted/removed rows produce correct add/remove without stale ids reused | runtime | Accessibility | 1/3 | unproven |
| Fixture app: duplicate labels resolve to distinct stable element ids | runtime | Accessibility | 1 | unproven |
| Fixture app: sheet/popover appears in tree with correct parent lineage | runtime | Accessibility | 1 | unproven |
| AX child order is stable across repeated reads of unchanged fixture state | runtime | Accessibility | 1 | unproven |

## 3. Capture and coordinate tests (`Tests/CaptureEngineTests`)

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| AX↔`SCWindow` correlation across ≥25 fixture-window configurations, zero wrong matches | unit | none | 0 | pass (32 synthetic configs) |
| Correlation returns `ambiguous_window`/`uncorrelated_window` on conflicting signals instead of guessing | unit | none | 0 | pass |
| Decided signals recorded per successful match (pid/frame/title/layer/order) | unit | none | 0 | pass |
| Covered-window capture: opaque cover above fixture window, captured image contains only target content | runtime | Accessibility, Screen Recording | 0/1 | unproven |
| `SCContentFilter(desktopIndependentWindow:)` used, never full-display screenshot + crop | unit | none | 0 | pending |
| Minimized window → `uncapturable_window` reason `minimized` | runtime | Screen Recording | 1 | unproven |
| Offscreen/off-Space window → `uncapturable_window` reason `offscreen` | runtime | Screen Recording | 1 | unproven |
| Screenshot encoding: JPEG q0.75, long edge ≤1568px, ≤3MB (shrink dimension, never raise quality) | unit | none | 1 | pending |
| Coordinate round-trip G↔W↔S across multiple displays and scale factors | unit | none | 1 | pass (left/above-primary neg origins, 2x/1x, downscale) |
| Coordinate round-trip on a scaled/Retina screenshot matches `kx`/`ky` derived from delivered pixel dims | unit | none | 1 | pass |
| `window.framePoints` reported in global points (G); tree `frame=` reported in window points (W) | runtime | Accessibility, Screen Recording | 1 | unproven |
| PNG output only reachable via CLI probe path, never via MCP `tools/call` result | unit | none | 1 | pending |

## 4. Action and interference tests (`Tests/ActionEngineTests`)

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| Covered `AXPress` on fixture button does not change frontmost app | runtime | Accessibility | 0/2 | unproven |
| Covered `AXValue` set on fixture text field does not change frontmost app | runtime | Accessibility | 0/2 | unproven |
| Policy denial occurs before any dispatch to AX/input APIs (mock engine call count = 0) | unit | none | 2 | pass (`ActionExecutorTests.testPolicyDenialWinsBeforeAnyResolutionOrDispatch`) |
| Per-app actions serialize; two concurrent actions on same session never interleave | unit/runtime | Accessibility | 2 | pass (unit serialization); live still grant-gated |
| Two sessions on different apps proceed independently (no cross-app blocking) | unit/runtime | Accessibility | 2 | pass (unit); live unproven |
| Stale/replaced element cannot receive an action within the same session | unit | none | 2/3 | pass (`testMatchedRevisionButUnknownElementYieldsStaleElement`) |
| `select_text` with `length:0` places caret at `start`, no selection | runtime | Accessibility | 2 | unproven |
| `press_key` combo grammar parses/rejects per PROTOCOL §4.3 (valid and malformed combos) | unit | none | 4 | pass |
| `press_key` modifier chord (e.g. `cmd+a`) posts a REAL modifier key-down/up (`flagsChanged`) wrapping the main key, mask on both, nested/reverse for multi-mod (FIX A) | unit | none | 4 | pass; live select-all re-verified historically in Stage J Verify |
| `type_text` emits literal text into fixture field, verified via state-file log | runtime | Accessibility | 4 | pass (historical live: deliver-in-background, `targetVerified:true`) |
| Coordinate `drag`/`click` fallback in `window` vs `screenshot` space maps correctly | runtime | Accessibility, Screen Recording | 4 | pass (historical live) |
| Noninterference: observer app stays frontmost/focused during covered-target semantic action | runtime | Accessibility | 2/4 | pass (historical live) |
| Noninterference: system pointer does not move for semantic (non-fallback) actions | runtime | Accessibility | 2 | pass (historical live: 0px) |
| Focus transaction restores prior user focus after a fallback action completes | runtime | Accessibility | 4 | pass for deliver-in-background; brief-focus restore gated on foregrounding (see FIX B row) |
| Brief-focus RESTORE is symmetric with the forward AX raise: after `activate(prior)`, if still not frontmost, `raiseViaAccessibility(prior)` is tried; `focusRestored` reflects the ACTUAL `frontmost==prior` re-check (NOT `restoreFocusedElement`'s return), so it is `false` honestly when the prior app cannot be refronted (Finding C) | unit | none (fake workspace) | 4 | pass (`testActivateRestoreUsesAXRaiseToRestorePriorWhenActivateCannotForeground`, `testActivateRestoreReportsNotRestoredWhenPriorCannotRegainForeground`) |
| Modifier `keyUp` is never skipped by a per-event nil `CGEvent`: `postKey` falls back to a source-less (still-tagged) construction + stderr log instead of silently returning, so a modifier is never stranded held-down (Finding D) | unit | none | 4 | pass (emit ordering/release covered by chord tests; live path source-less fallback is construction-infallible) |
| `allow-brief-focus`/`foreground-takeover`: on failed `NSRunningApplication.activate()`, a PUBLIC Accessibility fallback (`kAXFrontmost` + raise main window) is tried, then frontmost re-verified; delivers only if confirmed, else `status: rejected` (`targetVerified:false`) — NOT `focus_required` (that is the `background-only` pre-check only) — NO new TCC (FIX B) | unit | Accessibility (already granted) | 4 | unit pass; **live: `focusFallbackWorks=no` from the server process on macOS 26 (0/10; identical AX calls work 5/5 from a plain CLI)** — positive path non-functional from the server process, fails safe every run; app-host packaging is the intended foreground-capable shape (PROTOCOL §16.7). Re-prove on signed `Semantouch.app` — **unproven** in this docs pass. |
| User interruption: injected real input cancels remaining queued actions | runtime | Accessibility | 4 | pass (historical live: `interrupted` at 952/15000 chars) |
| User interruption: helper's own synthetic events do not self-trigger `user_interrupted` | runtime | Accessibility | 4 | pass (historical live: tagged events never self-interrupt) |
| Interruption response returns `interrupted`/`user_interrupted` and requires fresh `get_app_state` before resuming | runtime | Accessibility | 4 | pass (historical live: `status: interrupted`, `targetVerified:false`) |
| Action-time confirmation gate: unconfirmed mutating action returns `policy_denied`/`action_confirmation_required` | unit | none | 2 | pending |
| Deny-listed app rejects session before any AX call | unit | none | 1/2 | pass (policy tests + launch/read_text policy denial cases) |

## 5. Incremental state tests (Phase 3, `Tests/AccessibilityEngineTests` + `Tests/ActionEngineTests`)

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| Diff (`~` attribute lines) reconstructs identical state to a full-tree re-render (base + 3 diffs == fresh full tree, byte-identical) | runtime | Accessibility | 3 | pass (historical live) |
| Diff `+`/`−` STRUCTURAL add/remove reconstructs identical state | runtime | Accessibility | 3 | offline-only (proven in `AXTreeDiff` suite); fixture Add/Remove Row calls `reloadData()` → re-mints ids → correct `diff_reset`, so the live path emits a full tree, not a structural delta (fixture-coverage limitation) |
| `AXObserver` debounce coalesces notification bursts into one revision | runtime | Accessibility | 3 | pass (historical live) |
| Rapidly changing layout never produces a tree that mixes two lineages | runtime | Accessibility | 3 | pass (historical live) |
| Adaptive settle detector respects normal/loading deadlines and returns `possibly_unsettled` on deadline expiry | runtime | Accessibility | 3 | pass (historical live) |
| Full rebuild fallback triggers when element lineage is uncertain (`diff_reset`) | runtime | Accessibility | 3 | pass (historical live: fixture `reloadData()` re-mint → `diff_reset`) |
| Measured payload reduction: diff bytes < full-tree bytes for a representative UI change | runtime | Accessibility | 3 | pass (historical live: 99.1% reduction) |

## 6. Host / relay / packaging integrity

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| Opaque relay is exact byte transparent; half-close propagates EOF | unit | none | host | pass (`SemantouchIPCTests.HostClientAndRelayTests`) |
| Production peer verifier has no env bypass | unit | none | host | pass |
| Hello nonce/version mismatch rejected; second listener fails lock | unit | none | host | pass (`HostListenerTests`) |
| Manifest tool list = 16 enabled tools; min macOS 14.0; universal2 archs; app-host TCC ownership | contract | none | packaging | pass (`PackagingTests`) |
| Release workflow refuses raw helper assets; publishes ZIP+DMG+plugin only | workflow | none | release | pass (workflow source review: `.github/workflows/release.yml`) |
| Published GitHub `v0.2.1` assets match universal2 ZIP/DMG names | release | network | release | **fail / mismatch** — published assets are still arm64 helper + arm64 plugin (`gh release view v0.2.1`). Next tag must publish universal2 names. |
| npm trusted publish pins release ZIP digest and verifies notarized app | workflow | network | release | **unproven** (workflow exists; no `release-digest.json` in worktree; needs published ZIP) |
| Homebrew cask publish for universal2 ZIP | workflow | network | release | **unproven publish** — `watzon/homebrew-tap`, write-scoped deploy key, and `homebrew-publish` environment are configured; still needs a published universal2 ZIP and first workflow run |
| Universal2 lipo contains exactly arm64 + x86_64 for host and relay | workflow/unit | none | release | pass (`scripts/make-universal2`; local arm64+x86_64 host and relay assembled with this toolchain; release workflow repeats the check) |
| Gatekeeper/staple contract on extracted ZIP app | workflow/runtime | network | release | workflow requires `SEMANTOUCH_REQUIRE_NOTARIZATION=1 scripts/verify-app-release`; real public artifact **unproven** until next release |
| GitHub artifact attestations cover every release asset | workflow | network/OIDC | release | workflow contract pass (`actions/attest` pinned by commit); public attestation **unproven** until next immutable release |

## 7. Safety and isolation (all suites)

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| No destructive action ever targets a non-fixture, non-allow-listed app in CI | contract | none | all | pending |
| Persistent app-decision store isolated under a dedicated test app-group/container | unit | none | 1 | pending |
| Network access disabled/unreachable during pure unit/contract test runs (no external calls attempted) | contract | none | all | pending (update/doctor network paths are explicit CLI paths) |
| `doctor` with permission denied returns `permission_denied` naming exact host binary, no partial success | runtime | none (denied state) | 1 | unproven on real denied machine in this pass |
| stdout byte stream never contains a raw, unescaped newline inside a message | contract | none | 1 | pending |

## 8. Benchmark matrix (performance, non-blocking for correctness gates)

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

## 9. Virtual cursor overlay (Phase 5, `Tests/CursorOverlayTests` + live)

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| Overlay panel is nonactivating (`canBecomeKey` / `canBecomeMain` both false) | unit + runtime | none | 5 | pass (historical live) |
| Overlay is click-through (ignores mouse events; never steals input) | runtime | none | 5 | pass (historical live) |
| Drawing the virtual cursor moves the SYSTEM pointer 0px | runtime | none | 5 | pass (historical live: 0px) |
| Overlay hides on session end | runtime | none | 5 | pass (historical live) |
| Overlay follows the target window as it moves | runtime | none | 5 | pass (historical live) |
| Overlay is decorative-only: never fails, delays, or gates an action | unit + runtime | none | 5 | pass (historical live) |

## 10. Windows/Linux shared runtime

| Test | Kind | Permissions | Phase | Status |
|---|---|---|---|---|
| Swift and Rust enabled tool catalogs have identical 16-name order | contract | none | cross-platform | pass (`node scripts/verify-cross-platform-contract.mjs`) |
| Shared sessions, revisions, stable IDs, diffs, policy, waits, action evidence, scoped snapshots, and MCP framing | unit/integration | none | cross-platform | pass (`cargo +1.88.0 test --workspace`: 68 tests) |
| Windows UIA adapter + runtime compile for `x86_64-pc-windows-msvc` | target compile | none | cross-platform | pass (`cargo +1.88.0 check -p semantouch-windows -p semantouch-runtime --target x86_64-pc-windows-msvc`) |
| Linux AT-SPI adapter + runtime compile for `x86_64-unknown-linux-gnu` | target compile | none | cross-platform | pass (`cargo +1.88.0 check -p semantouch-linux -p semantouch-runtime --target x86_64-unknown-linux-gnu`) |
| Windows live UIA tree/action/scoped-snapshot fixture | runtime | Accessibility | cross-platform | **unproven** — target compiles; no interactive Windows runner was available |
| Linux live AT-SPI tree/action/scoped-snapshot fixture | runtime | AT-SPI desktop | cross-platform | **unproven** — target compiles; no interactive Linux desktop was available |
| Windows Graphics Capture | runtime | capture permission | cross-platform | **unproven / capability-gated** |
| Wayland capture and input by compositor/portal | runtime | portal/compositor | cross-platform | **unproven / capability-gated** |

## 11. Explicit unproven real-machine gates

The following release and live-OS gates remain **unproven**. macOS items require a
signed/notarized `Semantouch.app` with the named TCC grants:

1. End-to-end OMP install from a tag that publishes `Semantouch-v*-macos-universal2.zip`.
2. Plugin launcher download → verify → install → `doctor ready: true` → 16 tools listed.
3. Covered-window capture and semantic click with target not frontmost.
4. Brief-focus positive path from the **host** process (re-open FIX B after app packaging).
5. Whole-app `semantouch update` cutover with permissions retained on the same bundle id.
6. Intel (x86_64) slice smoke of the universal2 app.
7. npm `@watzon/semantouch` install and Homebrew cask install after first successful publish.
8. Windows UIA observation/action/scoping on an interactive Windows fixture.
9. Linux AT-SPI observation/action/scoping on supported X11 and Wayland desktops.
