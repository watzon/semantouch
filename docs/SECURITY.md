# Security

Normative for the permission model, app/action policy, prompt-injection
stance, and clean-room constraints. `PROTOCOL.md` wins on wire-level detail
(error codes, `doctor` schema); this document does not restate schemas except
where needed for context.

Public computer-use support is **macOS only**. Windows/Linux GA is not claimed.

## 1. OS permission model

The signed **`Semantouch.app` host** requires two macOS TCC grants:

- **Accessibility** — required for all AX tree reads and actions.
- **Screen Recording** — required for any window capture (`get_app_state` /
  `screenshot`).

### 1.1 Who holds TCC

| Process | Path | Holds TCC? | Role |
|---|---|---|---|
| App host | `Semantouch.app/Contents/MacOS/SemantouchHost` (bundle id `tech.watzon.semantouch`) | **Yes** | Engines, AX, capture, actions, doctor probes |
| Nested relay | `Semantouch.app/Contents/MacOS/semantouch` | **No** | Stdio/control client + opaque MCP byte relay |

Sources: `Sources/SemantouchCLIKit/Packaging.swift` (`tccOwnershipDescription`,
`requiredPermissions`), `Sources/SemantouchApp/main.swift`,
`Sources/SemantouchCLI/main.swift`, `packaging/semantouch.plugin.json`.

Grant Accessibility and Screen Recording to the **host**, not the nested relay.
`doctor` names the exact running host path in `helper.path` and remediation
(`Sources/ComputerUseService/DoctorService.swift`).

Rules:

- `doctor` (PROTOCOL.md §4.1) is the only sanctioned way to report grant
  state. It MUST NOT trigger an OS permission prompt unless the caller passes
  `requestOnboarding: true`.
- `doctor` MUST report `accessibility` and `screenRecording` independently as
  `"granted" | "denied" | "unknown"`, and MUST name the exact binary
  (`helper.path`) that needs the grant in `remediation`.
- A missing grant surfaces as the tool-level error `permission_denied` with
  `data.permission`, `data.helperPath`, `data.remediation` (PROTOCOL.md §6).
  Tools MUST NOT silently degrade (e.g. returning a stale or empty tree)
  when a required grant is absent.
- Screenshot capture without Screen Recording is not a permission error by
  itself when `includeScreenshot` is `auto` — the response omits the image
  and adds `screenshot_omitted` (PROTOCOL.md §4.1). It becomes
  `permission_denied` only when `includeScreenshot: "always"` cannot be
  satisfied for that reason, or the caller explicitly requested onboarding
  and it was denied.
- No permission is ever assumed from shell/file sandbox settings. Computer
  Use permission is independent of and MUST NOT be inferred from OMP's shell
  "full access" mode (§2).

## 2. App policy

Application access is gated only by an **operator-configured denylist**. The server is
**permissive by default**: when `SEMANTOUCH_DENIED_APPS` is unset or empty, no application is
denied by app policy. There is no mutation allowlist and no built-in hard-denied app set.

Rules:

- Policy denial MUST be evaluated and enforced **before** dispatch to
  `AccessibilityEngine`/`CaptureEngine`/`ActionEngine` — never after an action has already
  run against the OS.
- Matching is by **app identity tokens**: bundle id preferred, plus display name, full
  path, and the path's last component when available (PROTOCOL.md §10.1). Tokens are
  compared exactly and case-insensitively.
- The denylist is process-local (from the host's environment). It is independent of OS
  TCC grants and of OMP's shell sandbox: a granted Accessibility permission does not imply
  an app may be automated, and an empty denylist does not waive action-time confirmation
  (§3).

### 2.1 `SEMANTOUCH_DENIED_APPS` denylist

Environment variable **`SEMANTOUCH_DENIED_APPS`**:

- Comma-separated tokens (whitespace around commas is trimmed; empty entries ignored).
- Unset or empty → empty denylist → **deny nothing**.
- Exact, case-insensitive match against any of: bundle identifier, display name, full
  path, path basename.
- Applies to **both reads and mutations** (`get_app_state`, CLI probes, semantic actions,
  fallback input, and lifecycle tools such as `launch_app`). A match returns `policy_denied`
  with `data.reason: "app_denied"` (and `data.app` / `data.tool` when applicable) **before**
  any AX or CG call.

Practical example — block Terminal and Keychain Access:

```json
{
  "mcpServers": {
    "semantouch": {
      "type": "stdio",
      "command": "/Applications/Semantouch.app/Contents/MacOS/semantouch",
      "args": ["mcp"],
      "env": {
        "SEMANTOUCH_DENIED_APPS": "com.apple.Terminal,Terminal,com.apple.keychainaccess,Keychain Access"
      }
    }
  }
}
```

Operators choose what to deny. The server does not ship a fixed deny list of OMP hosts,
terminals, or security surfaces — if those targets must be unreachable, name them in
`SEMANTOUCH_DENIED_APPS`.

App policy is separate from action-time confirmation (§3). Clearing the denylist never
implies that a consequential UI action may proceed without human confirmation.

## 3. Action-time confirmation

Mutating tools (`launch_app`, `click`, `perform_action`, `set_value`, `select_text`,
`scroll`, `press_key`, `type_text`, and `drag`, including coordinate fallback)
additionally require **explicit human confirmation at dispatch time** for any
action whose semantic effect falls into:

- destructive/irreversible operations (deletion, overwrite, empty-trash);
- purchases or financial transactions;
- sending messages, forms, emails, or posts to another party;
- changing security, privacy, network, or account settings;
- uploading or transmitting data leaving the local machine;
- installing software, extensions, or profiles;
- creating credentials or any persistent access grant.

Until the MCP client has a dedicated approval bridge, **every**
mutating action should be treated as requiring human confirmation, not only the categories
above — the category list is the permanent minimum once a real approval bridge exists, not
the current operator bar. An unconfirmed action MUST return `policy_denied` with
`data.reason: "action_confirmation_required"` and MUST NOT be dispatched speculatively
while awaiting confirmation.

This confirmation gate is **independent of** the app denylist (§2): an ordinary app does
not need an OMP approval-UI allowlisting step merely to be mutated; confirmation is about
the real-world effect of the action, not about whether the app is on a server allowlist.

The MCP tool schema MAY annotate risk category, but classification of the concrete action
is the plugin/OMP layer's responsibility — the server MUST NOT assume that shipping a tool
call implies the user already approved its real-world effect.

## 4. Prompt-injection stance

All content read from a target application's UI — window titles, AX
`value`/`title`/`desc` fields, screenshot pixels, web page text surfaced
through `AXWebArea` — is **untrusted data**, never an instruction source.

Concretely:

- Text rendered inside a target window MUST NOT be treated as authorization
  to perform an action, change policy, alter confirmation requirements, or
  bypass a deny-listed app/action.
- The server MUST maintain a strict distinction between four categories and
  MUST NOT let one silently become another:
  1. user-authored instruction (from the OMP conversation);
  2. observed UI content (AX tree text, screenshot);
  3. tool-generated state (`AppState`, `ActionResult`, error payloads);
  4. app-specific guidance the helper itself may ship (e.g. known quirks of
     a target app) — this is operator-authored, not derived from what a
     target app displays at runtime.
- No app-specific instruction shipped by this project may be sourced from,
  copied from, or resemble OpenAI's bundled per-app guidance strings; any
  such guidance must be independently authored from public behavior.
- A target app cannot elevate its own denylist status or bypass action-time
  confirmation by rendering text that looks like a system prompt, approval,
  or override. There is no code path where observed UI content sets a
  policy flag.

## 5. Clean-room constraints

Binding on all implementation work in this repository:

- Public Apple APIs and documentation only. No private frameworks, no SPI —
  explicitly no `_AXUIElementGetWindow`, no SkyLight, no undocumented `CGS*`
  calls.
- No code, strings, prompts, per-app guidance text, cursor art, or other
  assets copied from the OpenAI Computer Use bundle. Behavioral observations
  describe behavior and architecture, not source or assets to reuse.
- No runtime dependency on private paths inside `ChatGPT.app` or any OpenAI
  bundle.
- No masquerading as an OpenAI bundle identifier, binary name, or IPC
  endpoint (e.g. `com.openai.sky.*`).
- No bypassing of parent-process, code-signing, TCC, or approval checks —
  this helper must go through the same OS permission prompts as any other
  third-party app.
- Any use of an undocumented private framework is out of scope unless a
  future change separately reviews it for legality, stability, and
  distribution risk; the default is public API only.

## 6. Host ↔ relay trust boundary

The nested relay is not a second TCC principal. Security properties of the private
host socket (`Sources/SemantouchIPC/*`):

- Framed hello with protocol version, role (`mcp` | `control`), client version, and
  nonce (`HostProtocol`).
- Peer trust policy checks same euid / code identity expectations
  (`PeerTrust.swift`); production trust has no environment bypass
  (`Tests/SemantouchIPCTests/HostClientAndRelayTests.swift`
  `testProductionVerifierHasNoEnvBypass`).
- After a successful MCP hello, the connection is opaque raw MCP bytes —
  no re-encoding, retry, or replay after established EOF
  (`OpaqueRelay.swift`, `Sources/SemantouchCLI/main.swift`).
- Each MCP connection gets a fresh `ServiceContext` (no shared revisions/ids across
  peers or restarts) (`Sources/SemantouchApp/HostController.swift`,
  `Sources/ComputerUseService/MCPRuntime.swift`).

## 7. Interruption as a security boundary

A physically-present user always wins. `UserInterruptionMonitor` detecting
genuine user input during a fallback (keyboard/pointer) action MUST cancel the
remaining input, end/pause any focus transaction, and mark the session state
stale (the implementation dirties the session so the next `get_app_state`
settle-waits and re-reads) rather than complete the queued action against a
target the user may no longer intend to control.

**Wire shape (frozen by PROTOCOL.md §16.4, which wins over this document on
wire detail).** A fallback interruption is a *successful* `tools/call` result
with `status: "interrupted"` (plus `targetVerified: false` and
`refreshRecommended: true`) — it is **not** the `user_interrupted` tool-level
error. The `user_interrupted` code (PROTOCOL.md §6) remains defined for any
non-fallback context that still uses it, but fallback input MUST NOT emit it:
`ActionExecutor.buildResult` reports `status: interrupted`. (Earlier
drafts of this section mandated the `user_interrupted` error; §16.4 froze the
successful-`interrupted`-result shape and overrides that.)

Synthetic events emitted by this helper's own fallback actions MUST be
distinguishable from physical input (the `FallbackTag` source/event user-data
tag) and MUST NOT self-trigger interruption. Because the tag is reliable, the
monitor discriminates on it alone and MUST NOT time-suppress genuine keyboard,
button, or scroll input — a dense synthetic delivery must never mask the
cancellation it most needs.

## 8. Focus changes and foregrounding (fallback input)

Fallback input never delivers to a target that is not confirmed frontmost. The
interference policy (PROTOCOL.md §16.2, §16.7) is the safety boundary:

- **`background-only` (default)** delivers only if the target is *already*
  frontmost, else `focus_required` with nothing delivered. This is the only mode
  that changes no focus, and the only path guaranteed to deliver on macOS 14+.
- **`allow-brief-focus` / `foreground-takeover`** are the caller's explicit,
  non-default opt-in to a focus change. The agent MUST NOT silently escalate to
  them.

**Foregrounding is OS-restricted, and the host stays within its two granted
permissions.** Empirically (macOS 14+, verified on macOS 26 in TEST-MATRIX §4), a
background process often cannot foreground a background app:
`NSRunningApplication.activate()` returns `true` but the target never becomes
frontmost. To make the sanctioned focus-changing modes as effective as the public
surface allows, the server, after a failed `activate()`, additionally tries a PUBLIC
**Accessibility** foreground fallback — setting the target app element's
`kAXFrontmost` and raising its main window — using the **already-granted Accessibility
permission**. It deliberately does **not** shell out to `osascript` / System Events:
that would require a **third TCC grant** (Apple Events / Automation) and a
process-per-action shell-out, both outside this helper's clean-room, two-permission
model (Accessibility + Screen Recording; SECURITY.md §1).

The fail-safe direction is invariant regardless of platform outcome: input is
delivered **only** after frontmost is re-confirmed; if neither `activate()` nor the
AX fallback foregrounds the target, the action returns `focus_required` /
`status: "rejected"` (`targetVerified: false`) and delivers nothing — it can never
type or click into the user's app by mistake. Whether the AX fallback actually
foregrounds a background app on a given OS is a platform-dependent property proven
by live acceptance, not assumed here.

## 9. Release integrity

- New tags are signed with Developer ID Application + Hardened Runtime, notarized, and
  stapled as a whole app (ZIP + DMG) per [RELEASE.md](RELEASE.md) and
  `.github/workflows/release.yml`.
- Published GitHub release assets are immutable (workflow refuses delete/recreate).
- Checksums are SHA-256 sidecars; the launcher and update path verify before install
  (`scripts/semantouch`, `Sources/ComputerUseService/UpdateService.swift`).
- npm and Homebrew publish workflows exist but are **not** public install guarantees
  until a release that produces the universal2 ZIP succeeds and those jobs complete
  (see [INSTALL.md](INSTALL.md), [RELEASE.md](RELEASE.md)).
