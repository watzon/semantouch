# Semantouch protocol v1

Frozen wire contract for the `semantouch` MCP server. This document is
normative and overrides non-normative usage or overview documentation on any
wire-level detail. Keywords **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**,
and **MAY** are used in the
RFC 2119 sense. Version identifier: `semantouch/1`.

## 1. Transport and framing

- The server is a child process speaking MCP over **stdio**, **JSON-RPC 2.0**,
  **newline-delimited**: exactly one JSON value per line terminated by a single
  `\n` (U+000A), **UTF-8**, no BOM. A message MUST NOT contain a raw newline
  (JSON escapes them inside strings), so line boundaries are unambiguous.
- **stdout carries protocol traffic only.** The server MUST NOT write anything to
  stdout that is not a framed JSON-RPC message. **All** logging and diagnostics
  MUST go to **stderr**.
- No line-length limit; a message MAY be several MB (a base64 screenshot).
  Requests carry an `id`; the server MUST echo it. Notifications omit `id`.

### MCP protocol version

The server implements MCP protocol version **`2025-06-18`**. On `initialize`
the server MUST report `protocolVersion: "2025-06-18"` regardless of the version
the client proposes.

### JSON-RPC (method-level) errors

Failures of the JSON-RPC/MCP layer itself use the standard `error` object with a
numeric `code`:

| Condition | code |
|---|---|
| Malformed JSON / not parseable | `-32700` (Parse error) |
| Unknown method | `-32601` (Method not found) |
| Missing/invalid params for a known method | `-32602` (Invalid params) |
| Unhandled server fault at the RPC layer | `-32603` (Internal error) |

These are distinct from **tool-level** failures (§6), which are delivered as a
successful `tools/call` result with `isError: true`.

## 2. Server methods and handshake

The server handles exactly these methods; any other method MUST return
`-32601`:

- `initialize`
- `notifications/initialized` (notification; no response)
- `ping`
- `tools/list`
- `tools/call`

Handshake sequence:

1. Client → `initialize` `{ protocolVersion, capabilities, clientInfo }`.
2. Server → result:
   ```jsonc
   {
     "protocolVersion": "2025-06-18",
     "capabilities": { "tools": {} },
     "serverInfo": { "name": "semantouch", "version": "<semver>" }
   }
   ```
3. Client → `notifications/initialized` (no reply).
4. `ping` → result `{}` at any time after initialize.
5. `tools/list` → `{ "tools": ToolDescriptor[] }`. **Only enabled tools appear.**
6. `tools/call` → tool result (§5/§6).

`tools/list` MUST NOT be answered before `initialize` succeeds. Each
`ToolDescriptor` is `{ name, description, inputSchema }`, where `inputSchema` is
the JSON Schema in §4.

## 3. Identifiers, sessions, revisions

- **Session ID**: string `s<N>`, `N` a decimal integer, monotonically increasing
  per **server process**, starting at `1`, never reused within the process
  lifetime. Pattern `^s[0-9]+$`.
- **Element ID**: string `e<N>`, `N` a decimal integer, monotonically increasing
  within a **single app session**, starting at `1`, never reused within that
  session. Pattern `^e[0-9]+$`. IDs are opaque; clients MUST NOT parse or order
  by them.
- **Revision**: integer starting at `1`, increasing on each state change within a
  session. **In Phase 1 the server always returns `revision: 1` and
  `full: true`** (no diffs are emitted; §7 diff markers are reserved).
- Every element-targeted action carries the triple `{ sessionId, revision,
  elementId }` (plus `app`). The server MUST reject a mismatched `revision` with
  `stale_revision` and an unresolvable `elementId` with `stale_element` (§6).
- A session is created lazily by `get_app_state` and destroyed by
  `end_app_session` or process exit. Element IDs and revisions are scoped to one
  session; they are meaningless across sessions.

## 4. Tools

All tools exist and have a frozen schema. A tool is **enabled** only in the phase
shown. **Disabled tools are omitted from `tools/list`**, and calling one returns
a tool-level `policy_denied` error (§6) with `data.reason = "tool_disabled"`.

| Tool | Phase | Enabled now |
|---|---|---|
| `doctor` | 1 | yes |
| `list_apps` | 1 | yes |
| `get_app_state` | 1 | yes |
| `end_app_session` | 1 | yes |
| `click` | 2 | no |
| `perform_action` | 2 | no |
| `set_value` | 2 | no |
| `select_text` | 2 | no |
| `scroll` | 2 | no |
| `press_key` | 4 | no |
| `type_text` | 4 | no |
| `drag` | 4 | no |

`ElementTarget` is the shared object `{ app: string, sessionId: ^s[0-9]+$,
revision: integer≥1, elementId: ^e[0-9]+$ }`; all four are required wherever it
appears. All schemas below set `"additionalProperties": false`.

### 4.1 Phase 1 tools

**`doctor`** — read-only permission report. It MUST NOT trigger any OS permission
prompt unless `requestOnboarding` is `true`.

```jsonc
// inputSchema
{ "type": "object", "additionalProperties": false,
  "properties": { "requestOnboarding": { "type": "boolean", "default": false } } }
```
Result payload (`DoctorResult`):
```jsonc
{
  "helper":   { "path": "string", "signed": true, "version": "string" },
  "accessibility":  "granted" | "denied" | "unknown",
  "screenRecording":"granted" | "denied" | "unknown",
  "ready": true,
  "remediation": ["string"]   // exact steps; names the binary at helper.path
}
```

**`list_apps`** — enumerate running and installed apps. It MUST NOT scan
recent-use databases.

```jsonc
{ "type": "object", "additionalProperties": false, "properties": {} }
```
Result payload: `{ "apps": AppSummary[] }` where `AppSummary` is:
```jsonc
{
  "id": "string",          // bundle id; else absolute path; else "pid:<pid>"
  "displayName": "string",
  "path": "string",        // optional, absolute .app path
  "pid": 1234,             // optional, present iff running
  "isRunning": true,
  "windows": 0,            // count of capturable windows (0 if not running)
  "lastUsedAt": "string"   // optional ISO-8601; omitted in Phase 1
}
```

**`get_app_state`** — resolve app+window, build the tree, optionally capture.
Creates a session if one does not exist for the resolved app.

```jsonc
{ "type": "object", "additionalProperties": false, "required": ["app"],
  "properties": {
    "app": { "type": "string" },
    "windowId": { "type": "integer", "minimum": 0,
      "description": "WindowServer id from an earlier get_app_state window.id; omit or pass 0 to auto-select. Not a list_apps count or ordinal." },
    "forceFullTree": { "type": "boolean", "default": false },
    "includeScreenshot": { "enum": ["auto","always","never"], "default": "auto" } } }
```

`list_apps.windows` is a **count**, not an identifier or zero-based index. On the first
`get_app_state` call, omit `windowId` (or pass `0`) to select the app's focused/main/best
window. Pass a positive `windowId` only when re-targeting a WindowServer id previously
returned as `AppState.window.id`.
Result payload (`AppState`), delivered as the JSON text block; when a screenshot
is produced it is delivered as a **separate image content block** (§5, §8):
```jsonc
{
  "sessionId": "s1",
  "app": AppSummary,
  "window": {
    "id": 123,                 // WindowServer window id
    "title": "string",         // optional
    "framePoints": { "x": 0, "y": 0, "width": 0, "height": 0 }, // GLOBAL points
    "screenshotPixels": { "width": 0, "height": 0 },            // optional
    "scale": 2                 // display backing scale (points -> backing px)
  },
  "revision": 1,
  "full": true,
  "baseRevision": 0,           // optional; omitted when full
  "tree": {
    "format": "semantouch-ax-tree-v1",
    "text": "string",
    "nodeCount": 0,
    "truncated": false
  },
  "screenshot": {              // METADATA ONLY; bytes are in the image block
    "mimeType": "image/jpeg",
    "width": 0, "height": 0, "byteLength": 0
  },
  "focusedElementId": "e3",    // optional
  "warnings": StateWarning[]
}
```
`StateWarning` is `{ "code": string, "message": string }`. Frozen codes:
`truncated_tree`, `screenshot_omitted`, `screenshot_unavailable`,
`possibly_unsettled` (Phase 3+), `low_correlation_confidence`.

`includeScreenshot`: `never` omits (adds `screenshot_omitted`); `always` MUST
capture or return `screenshot_unavailable` with no image block; `auto` is server
discretion (Phase 1: capture iff Screen Recording is granted, else
`screenshot_omitted`). When no screenshot is delivered, `AppState.screenshot`
and the image block are both absent.

**`end_app_session`** — release a session and its AX observers/caches.
```jsonc
{ "type": "object", "additionalProperties": false, "required": ["sessionId"],
  "properties": { "sessionId": { "type": "string", "pattern": "^s[0-9]+$" } } }
```
Result payload: `{ "sessionId": "s1", "ended": true }`. Ending an unknown
session returns `ended: false` (not an error).

### 4.2 Phase 2 tools (defined, disabled)

All return `ActionResult` (§5). All take `ElementTarget` plus:

- **`click`** — no extra fields. Invokes the element's primary activation
  (`AXPress`, or its default action).
- **`perform_action`** — `"action": string` (required): a name from the element's
  emitted `actions=[…]` list.
- **`set_value`** — `"value": string | number | boolean` (required). Sets
  `AXValue`.
- **`select_text`** — `"start": integer≥0` and `"length": integer≥0` (both
  required). `length: 0` places the caret at `start`.
- **`scroll`** — `"direction": "up"|"down"|"left"|"right"` (required),
  `"by": "line"|"page"` (default `"line"`), `"count": integer≥1` (default `1`).

### 4.3 Phase 4 tools (defined, disabled)

All return `ActionResult`. These target an app/session, not an element:

- **`press_key`** — `{ app, sessionId, combo }` (all required). `combo` grammar:
  one or more chords separated by a single space; a chord is zero or more
  modifiers from `cmd|ctrl|opt|shift|fn` followed by one key token, joined by
  `+`. Key tokens are lowercase named keys (`a`..`z`, `0`..`9`, `enter`, `esc`,
  `tab`, `space`, `left`, `right`, `up`, `down`, `delete`, `f1`..`f12`, …).
  Example: `"cmd+shift+4"`, `"cmd+a cmd+c"`.
- **`type_text`** — `{ app, sessionId, text }` (all required). Emits literal text.
- **`drag`** — `{ app, sessionId, from, to, space? }`. `from`/`to` are
  `{ x: number, y: number }` (required). `space` is `"window"|"screenshot"`,
  default `"window"` (§9).

### 4.4 Shared result payloads

`ActionResult`:
```jsonc
{
  "status": "completed" | "rejected" | "interrupted",
  "method": "accessibility" | "keyboard" | "pointer",
  "stateChanged": true,
  "refreshRecommended": true,
  "warning": "string"   // optional
}
```
A tool SHOULD NOT return full state after an action; the client requests a
refresh via `get_app_state`.

## 5. `tools/call` result envelope

On success the result is:
```jsonc
{ "content": [ { "type": "text", "text": "<JSON payload>" } ], "isError": false }
```
`text` is the canonical machine-readable JSON payload for that tool (§4).
`get_app_state` additionally appends, when a screenshot is delivered, an image
block second (base64 of the JPEG):
```jsonc
{ "type": "image", "data": "<base64>", "mimeType": "image/jpeg" }
```

On tool-level failure the result is:
```jsonc
{ "content": [ { "type": "text", "text": "<JSON error>" } ], "isError": true }
```
where the JSON error is `{ "code": <error code>, "message": string, "data": {…}? }`
using the codes in §6. Tool-level failures are **never** JSON-RPC `error`
objects.

## 6. Error codes

Exactly these codes exist. Each is a string in the tool-level error payload
`{ code, message, data? }`. `WindowRef` = `{ windowId?: number, title?: string,
framePoints?: Rect, pid?: number, source: "ax"|"screencapturekit" }`.

| code | Fires when | Required `data` |
|---|---|---|
| `permission_denied` | An operation needs a macOS grant that is not `granted`. | `{ permission: "accessibility"｜"screenRecording", helperPath, remediation: string[] }` |
| `app_not_found` | No app matches `app` (§10). | `{ query }` |
| `ambiguous_app` | More than one app matches `app`. | `{ query, candidates: AppSummary[] }` |
| `window_not_found` | Explicit `windowId` not among the app's windows, or the app exposes no capturable window. | `{ app, windowId? }` |
| `ambiguous_window` | Multiple windows equally satisfy the selection heuristic with no deterministic tiebreak. | `{ app, candidates: WindowRef[] }` |
| `uncorrelated_window` | A window was identified on one side (AX or ScreenCaptureKit) but could not be matched to its counterpart with sufficient confidence. | `{ app, ax?: WindowRef, sc?: WindowRef, signalsTried: string[] }` |
| `uncapturable_window` | Correlated but not capturable. | `{ app, windowId, reason: "minimized"｜"offscreen"｜"protected"｜"stale"｜"unsupported_surface" }` |
| `stale_revision` | Action `revision` != current session revision. | `{ sessionId, provided, current }` |
| `stale_element` | `elementId` does not resolve in the current tree/revision. | `{ sessionId, elementId, revision }` |
| `unsupported_action` | The element does not expose the requested action or the attribute is not settable. | `{ elementId, action?, supported: string[] }` |
| `focus_required` | (v1.3, §16) A fallback action under `background-only` needs the target frontmost to deliver input safely, but it is not. | `{ app?, frontmostApp? }` |
| `user_interrupted` | Physical user input aborted the action. | `{ at? }` (ISO-8601) |
| `policy_denied` | App/action denied by policy, or the tool is disabled in the current phase. | `{ reason: "tool_disabled"｜"app_denied"｜"recursive_control"｜"action_confirmation_required", app?, tool? }` |
| `timeout` | Operation exceeded its deadline. | `{ operation, deadlineMs }` |
| `cancelled` | (v1.4, §17) The client cancelled the in-flight request (`notifications/cancelled`), or the process is shutting down (stdin EOF / SIGTERM). | `{ reason? }` |
| `internal_error` | Unexpected fault handled at the tool layer. | `{ detail? }` |

`Rect` = `{ x, y, width, height }` (numbers); `Size` = `{ width, height }`.

## 7. Tree grammar `semantouch-ax-tree-v1`

`AppState.tree.text` is UTF-8 text. **One emitted element per line**, lines
separated by `\n`, no trailing newline after the final line.

### 7.1 Line shape

```
<indent>[<eID>] <Role>(.<Subrole>)? (" <"title">")? (<k=v> …)* ( actions=[<a>,…])?
```
- `<indent>` — **two spaces per depth**; the window element is the single root at
  depth 0.
- `[<eID>]` — element id, e.g. `[e42]`; always present.
- `<Role>` — AX role **verbatim** (`AXButton`, `AXTextField`, `AXWebArea`);
  always present. `.<Subrole>` — AX subrole verbatim when present
  (`AXTextField.AXSecureTextField`); omitted when absent.
- `"<title>"` — quoted title, when nonempty (§7.3).
- `<k=v>` — key/value pairs in the fixed order of §7.2.
- `actions=[…]` — action names, comma-separated, no spaces, when ≥1; else omitted.

Any Role/Subrole/action token containing whitespace, `"`, `[`, or `]`
(non-conforming custom roles) has those characters replaced with `_`.

### 7.2 Fixed key/value order and presence

Emit only when the presence rule holds, always in this order:

1. `value="…"` — only when the rendered value is nonempty.
2. `placeholder="…"` — only when nonempty (`AXPlaceholderValue`).
3. `desc="…"` — only when nonempty (`AXDescription`).
4. `enabled=false` — only when the element is disabled (never `enabled=true`).
5. `focused=true` — only when focused (never `focused=false`).
6. `selected=true` — only when selected (never `selected=false`).
7. `frame=<x>,<y>,<w>,<h>` — always. Window points (§9), integers, rounded to
   nearest with ties away from zero. When no frame is resolvable, emit
   `frame=?`.

**Action names** are emitted with the leading `AX` stripped (`AXPress` → `Press`,
`AXShowMenu` → `ShowMenu`); non-`AX` action names are verbatim.

**Sources.** `title` = `AXTitle` if nonempty, else the `AXValue`/`AXTitle` of the
element referenced by `AXTitleUIElement`. `value` renders `AXValue`: strings as
text; booleans/toggle states as `0`/`1`; numbers as the shortest round-tripping
decimal.

### 7.3 Quoting and escaping

`title`, `value`, `placeholder`, and `desc` are **double-quoted single-line**
strings. Inside a quoted string, apply exactly these escapes: `\` → `\\`, `"` →
`\"`, newline → `\n`, carriage return → `\r`, tab → `\t`; any other C0 control
(< U+0020) → `\u00XX` (lowercase hex). No other characters are escaped. Emitted
strings never contain a literal newline, so lines stay single.

### 7.4 Ordering and determinism

Children are emitted in the order returned by `AXChildren` after pruning, never
re-sorted. Traversal is **pre-order** (parent line, then each child subtree in
order). For identical UI state the output MUST be byte-for-byte identical;
determinism relies on AX returning a stable child order, which fixtures verify.

### 7.5 Limits and truncation

- Max **emitted nodes**: default **600**; hard ceiling **2000** that no
  configuration may exceed (Phase 1 uses 600).
- Max **tree text**: **120 KB** of UTF-8 (`tree.text` byte length).
- Each rendered string field (`title`/`value`/`placeholder`/`desc`) is capped at
  **256 UTF-8 bytes** of its escaped form; if exceeded it is cut to fit and
  suffixed with `…` (U+2026). This is independent of node/byte budgeting.

Node/byte truncation is deterministic: traverse pre-order, emitting nodes while
both budgets hold; the server reserves capacity for one marker line. When the
next node would exceed the node cap **or** the byte cap, stop and emit exactly
one marker line at the depth of the first omitted node:

```
… +<N> nodes omitted
```

`<N>` = (total pruned nodes) − (emitted nodes). Because a pre-order cut removes a
single contiguous suffix, there is exactly one marker. Set `tree.truncated=true`
and add a `truncated_tree` warning. `tree.nodeCount` counts emitted element
lines (the marker line is not an element).

### 7.6 Worked example — full, untruncated

```
[e1] AXWindow "Sign In" frame=0,0,420,300
  [e2] AXStaticText "Email" frame=24,28,60,18
  [e3] AXTextField value="ada@example.com" focused=true frame=92,24,304,26 actions=[ConfirmText]
  [e4] AXStaticText "Password" frame=24,66,60,18
  [e5] AXTextField.AXSecureTextField placeholder="Required" frame=92,62,304,26 actions=[ConfirmText]
  [e6] AXCheckBox "Remember me" value="0" frame=24,104,150,22 actions=[Press]
  [e7] AXButton "Sign In" enabled=false frame=92,150,120,32 actions=[Press]
  [e8] AXButton "Cancel" frame=224,150,120,32 actions=[Press]
```
`focusedElementId` is `"e3"`; `e7` is disabled; `e6` renders its toggle as `"0"`.

### 7.7 Worked example — subroles, long value, truncation

```
[e1] AXWindow "Docs — Safari" frame=0,0,1200,760
  [e2] AXToolbar frame=0,0,1200,52
    [e3] AXButton "Back" enabled=false frame=12,12,28,28 actions=[Press]
    [e4] AXButton "Forward" enabled=false frame=44,12,28,28 actions=[Press]
    [e5] AXTextField.AXSearchField value="developer.apple.com/documentation" focused=true frame=180,12,840,28 actions=[ConfirmText]
  [e6] AXWebArea "ScreenCaptureKit" frame=0,52,1200,708
    [e7] AXHeading "Overview" frame=40,80,320,40
    [e8] AXStaticText value="ScreenCaptureKit gives your app the ability to add efficient screen capture…" frame=40,130,900,120
    … +142 nodes omitted
```
`e7` exposes no actions so `actions=[…]` is omitted; `e8`'s value exceeded the
per-field cap and was suffixed with `…`; the final line is the omission marker
(`tree.truncated=true`).

## 8. Screenshot policy

- Encoding on the MCP path: **JPEG**, quality **0.75**.
- Max **long edge 1568 px** (longer of width/height after backing-scale render).
- Byte cap **3 MB** for the encoded JPEG. If the image still exceeds 3 MB at
  quality 0.75 and 1568 px, the server MUST reduce the long-edge dimension until
  it fits (never raise quality above 0.75).
- Delivery: a base64 **image content block** in the `tools/call` result
  (`{ type:"image", data, mimeType:"image/jpeg" }`), alongside the JSON text
  block. `AppState.screenshot` carries **metadata only** (`mimeType`, `width`,
  `height`, `byteLength`) — never the bytes and never a URI.
- **PNG is allowed only for CLI probe output** (Phase-0 spike drivers writing to
  a file), never on the MCP path.
- No screenshot URIs are minted; there is no URI lifetime to manage.

## 9. Coordinate spaces

Three spaces, all with **top-left origin**, `+x` right, `+y` down:

- **Global points (G)** — CoreGraphics global display coordinates in points.
  `AppState.window.framePoints` is in **G**. AX frames are read in G and
  converted to window points before emission.
- **Window points (W)** — origin at the target window's top-left, i.e.
  `window.framePoints.origin`. **Every `frame=` in the tree is in W** (rounded
  integers).
- **Screenshot pixels (S)** — origin at the top-left of the delivered image; unit
  is pixels of `window.screenshotPixels`.

Let `F = window.framePoints`, backing scale `s = window.scale`, and downscale
`d = min(1, 1568 / max(F.width·s, F.height·s))`. Then
`screenshotPixels = { round(F.width·s·d), round(F.height·s·d) }`, and the
authoritative pixels-per-point ratios (using the rounded pixel dims to avoid
drift) are `kx = screenshotPixels.width / F.width`,
`ky = screenshotPixels.height / F.height`.

Mappings:

```
G → W:  wx = gx − F.x           wy = gy − F.y
W → G:  gx = wx + F.x           gy = wy + F.y
W → S:  sx = wx · kx            sy = wy · ky
S → W:  wx = sx / kx            wy = sy / ky
G → S:  compose G→W then W→S
```

`scale` is informational (points→backing pixels before the fit-downscale); the
screenshot mapping MUST use `kx`/`ky` derived from delivered pixel dimensions,
not `scale` alone.

## 10. App and window resolution

### 10.1 App resolution

`app` is a string. Resolution stops at the first matching rule:

0. If `app` matches `^pid:[0-9]+$`, resolve directly to that process.
1. Exact bundle identifier (case-insensitive) of an installed or running app.
2. Exact absolute `.app` path that exists on disk.
3. Exact localized display name.
4. Unique case-insensitive display-name match.

If rule 4 yields more than one candidate → `ambiguous_app` with
`data.candidates: AppSummary[]`. If nothing matches → `app_not_found`.

### 10.2 Window resolution

Within the resolved app, stops at the first rule that yields a single window:

1. Explicit `windowId` (WindowServer id). If it is not among the app's windows →
   `window_not_found`. If found but not correlatable to an AX window →
   `uncorrelated_window`.
2. The app's AX **focused** window; else its AX **main** window.
3. The **largest normal visible** window (subrole `AXStandardWindow`, on-screen,
   not minimized) by frame area.
4. The **most recently active capturable** window (from `SCShareableContent`
   on-screen ordering).
5. Otherwise → `window_not_found`.

If two windows tie under rule 3 with no deterministic tiebreak →
`ambiguous_window`. If the chosen window cannot be captured (minimized,
offscreen, protected, stale, or an unsupported surface) → `uncapturable_window`.

### 10.3 AX ↔ SCWindow correlation

Correlate the AX window with its `SCWindow` using **public signals only**:
owner **PID** (required), then **frame** equality/overlap (rounded), **title**
equality, window **layer**, and on-screen **ordering**. The server MUST record
which signals decided each match and MUST return `ambiguous_window` or
`uncorrelated_window` rather than choosing approximately when signals conflict.
Wrong matches are unacceptable (zero-wrong-match acceptance in Phase 0).

## 11. Reserved (later phases)

Reserved now, **not emitted in Phase 1**:

- **Diff mode** (Phase 3): header `UI revision <r>, based on <b>` then lines
  prefixed `~ ` (changed), `+ ` (added), `- ` (removed). Phase 1 is full-only
  (`full: true`, `revision: 1`), so these prefixes never begin a v1 line.
- **Element ID reuse across revisions** (Phase 3): governed by a structural
  fingerprint (role, subrole, `AXIdentifier`, owner PID, window id, parent
  fingerprint, like-role sibling ordinal, frame, normalized title/value). **Phase
  2 does not yet reuse ids across revisions** — it mints fresh ids per snapshot
  and retires the previous snapshot's ids (now normative in §13.1). A
  removed/replaced element MUST NOT inherit a live id within a session.
- **Settle timings** (Phase 3): adaptive; not part of the wire contract.

## 12. Decisions (choices this document fixed)

1. Element ids `e<N>` (session-local counter from 1); session ids `s<N>` (per-process counter from 1); both never reused in scope.
2. Revisions start at 1; Phase 1 is always `full: true`, `revision: 1`.
3. Roles/subroles emitted **verbatim** (`AXButton`); action names **`AX`-stripped** (`Press`) to keep repeated action lists compact.
4. Canonical key order `value, placeholder, desc, enabled, focused, selected, frame`, then `actions`; presence per §7.2.
5. `frame` always present, window points, integers rounded nearest/ties-away; sentinel `frame=?` when unresolvable.
6. Escaping set `\\ \" \n \r \t` plus `\u00XX` for other C0 controls; strings double-quoted, single-line.
7. Child order = AX child order verbatim; pre-order traversal; determinism assumption documented.
8. Node cap 600 (hard 2000), text cap 120 KB, per-field cap 256 bytes with `…`; single pre-order marker `… +<N> nodes omitted`, capacity reserved.
9. Screenshot JPEG q0.75, long edge 1568 px, 3 MB cap (shrink dimension, never raise quality); image content block; `AppState.screenshot` metadata-only, no URI; PNG only for CLI probes.
10. Coordinate mapping uses `kx/ky` from delivered pixel dims vs `framePoints`; window-points origin = window frame top-left; `scale` informational.
11. `app` accepts `pid:<n>`; bundle-id match case-insensitive; `AppSummary.id` falls back path → `pid:<pid>`.
12. Window selection order and the ambiguous/uncorrelated/uncapturable split per §10.2–10.3.
13. `policy_denied` (`reason: "tool_disabled"`) answers a phase-disabled tool; disabled tools absent from `tools/list`.
14. `doctor.requestOnboarding` gates any OS prompt (default no prompt).
15. `select_text` uses `{ start, length }` (length 0 = caret); `press_key` uses a `combo` chord grammar; `drag` defaults to `space: "window"`.
16. `end_app_session` keys on `sessionId`; unknown session → `ended: false`.
17. MCP screenshots always `image/jpeg`; `serverInfo.name` = `semantouch`; `StateWarning` code set frozen (§4.1).

## 13. Phase 2 semantics (v1.1 — normative)

Phase 2 enables the five element-targeted mutation tools `click`, `perform_action`,
`set_value`, `select_text`, and `scroll`, and freezes the semantics reserved in §11.
These rules are **additive** to the frozen v1 wire contract (§1–§10): no v1 field is
removed or repurposed, and the wire identifier stays `semantouch/1`. Two frozen
§6 payloads gain an optional value, called out below as additive-field clarifications.

### 13.1 Revisions and element-id freshness

- Phase 1's "always `revision: 1`" rule (§3) applies **only to Phase 1**. In Phase 2,
  within one app session **every `get_app_state` snapshot advances the revision**: the
  first snapshot of a newly created session reports `revision: 1`, and each subsequent
  snapshot of that same session reports `2`, `3`, … `full` stays `true` and
  `baseRevision` stays omitted for every Phase 2 snapshot (diffs are Phase 3).
- **Element ids stay fresh per snapshot.** Phase 2 does not reuse an id across
  revisions: each snapshot mints ids from the session's monotonic `e<N>` counter (§3)
  and retires the previous snapshot's ids. An id observed at revision `r` therefore
  never resolves once the session has advanced past `r`. A removed/replaced element
  MUST NOT inherit a live id within the session (§11).

### 13.2 Action validation order

Every element-targeted action carries the `ElementTarget` quadruple
`{ app, sessionId, revision, elementId }` (§4). The server validates it in this fixed
order and stops at the first failure:

1. **Policy gate (before any resolution).** The target `app` is resolved and checked
   against mutation policy (§13.5). A denied app → `policy_denied` (§6) before any AX
   call.
2. **Session existence.** If `sessionId` names no live session (never created, or
   already ended) → `stale_revision` with `data.current = null`.
3. **Revision match.** If the session's current revision ≠ `revision` → `stale_revision`
   with `data.current` = the session's current revision (an integer).
4. **Element resolution.** If `elementId` does not resolve in the current revision's
   element table (retired, unknown, or backed by a dead element) → `stale_element` (§6).

Steps 2–4 run inside the session's serial lane (§13.6).

> Additive-field clarification (v1.1): `stale_revision.data.current` (frozen §6 as an
> integer) MAY be `null`, and is `null` exactly when the session is unknown or ended
> (step 2); otherwise it is the session's current revision.

### 13.3 Action mechanism ladder (no input fallback)

Phase 2 actions are **semantic only**. Each uses AX-native mechanisms in this
precedence and, when none applies, returns `unsupported_action` (§6). It MUST NOT fall
back to synthesized keyboard or pointer input — that is Phase 4:

1. a native AX **action** on the resolved element (`AXPress`, a named action);
2. a settable AX **attribute** (`AXValue`, `AXSelectedTextRange`, a scrollbar's `AXValue`);
3. for `scroll` only, an `AXScrollToVisible`-style action on a scrollable descendant.

Per tool:

- **`click`** — invokes the element's primary activation. Phase 2 maps this to `AXPress`;
  an element that does not expose `AXPress` → `unsupported_action` (`data.supported` =
  the element's raw action names). `click` has no coordinate form in Phase 2; a
  coordinate-based click is deferred to Phase 4 and, if requested, returns
  `unsupported_action`.
- **`perform_action`** — performs the named action after validating it against the
  element's advertised actions. The name is matched against both the `AX`-stripped form
  emitted in the tree (§7.2, e.g. `ShowMenu`) and the raw AX form (`AXShowMenu`); an
  unknown name → `unsupported_action` with `data.supported` = the element's raw actions.
- **`set_value`** — requires `AXValue` to be settable (else `unsupported_action`),
  writes it, and re-reads for `stateChanged`.
- **`select_text`** — requires a settable `AXSelectedTextRange` (a text element; a
  non-text element → `unsupported_action`), sets the selection from `{ start, length }`
  via an `AXValue`-wrapped `CFRange`, and re-reads the selected text for `stateChanged`.
- **`scroll`** — tries, in order: (a) set the relevant scrollbar's settable `AXValue`;
  (b) a by-page scroll action on the scroll area (`AXScrollUpByPage` / `…DownByPage` /
  `…LeftByPage` / `…RightByPage`); (c) `AXScrollToVisible` on a scrollable descendant.
  When none applies → `unsupported_action`. `ActionResult.warning` names the method that
  ran.

> Additive-field clarification (v1.1): `unsupported_action.data` (frozen §6 as
> `{ elementId, action?, supported }`) MAY carry an optional `reason` string explaining
> why no mechanism applied (used chiefly by `scroll`). It is omitted when absent, so
> existing consumers are unaffected.

### 13.4 ActionResult

Every Phase 2 action returns `ActionResult` (§4.4). Phase 2 fixes:

- `status` = `completed` on success (a rejected action surfaces as a tool-level error,
  not a `rejected` result, in Phase 2).
- `method` = `accessibility` (always; Phase 2 never uses keyboard/pointer).
- `refreshRecommended` = `true` (always — the client SHOULD call `get_app_state`, which
  advances the revision and invalidates the ids the action used).
- `stateChanged` = a **best-effort** post-action re-read comparing a cheap before/after
  snapshot (the element's `AXValue`, its selected text, or the scrollbar value, as
  applicable). When no snapshot is observable it is `false` (null-equivalent). It is
  advisory, never authoritative.
- `warning` = optional advisory note (e.g. which scroll method ran).

### 13.5 App policy gate

Read and mutation tools that target an application must pass app policy **before** any
AX/CG dispatch (docs/SECURITY.md §2):

- The only server-side app gate is the operator denylist from **`SEMANTOUCH_DENIED_APPS`**
  (comma-separated exact, case-insensitive tokens: bundle id, display name, full path, or
  path basename). Unset or empty → deny nothing.
- A denylist match → `policy_denied` with `data.reason = app_denied` **before** any AX/CG
  call. The denylist applies to **both reads and mutations**.
- There is no mutation allowlist and no built-in hard-denied application set.

`doctor`, `list_apps`, and `end_app_session` do not target an application UI surface for
tree/action work; `get_app_state` and every mutating tool do, and they consult the denylist.

### 13.6 Per-session serial execution

Mutations are serialized per app session: each session has one FIFO lane; a mutation is
fully resolved, validated, and performed on that lane before the next mutation on the
same session begins. Distinct sessions execute concurrently. The policy gate (§13.5)
runs before a mutation is enqueued; session/revision validation and element resolution
(§13.2 steps 2–4) run inside the lane.

## 14. Changelog

- **v1.5** — Web content and verified transitions made normative (§18), closing the two
  systemic gaps a live Chromium-shell browser test exposed (web content invisible to AX;
  delivery-level results misread as outcome-level). (1) **Web-content accessibility
  enablement** (§18.1): `get_app_state` best-effort sets `AXManualAccessibility` /
  `AXEnhancedUserInterface` on the target app element (once per session, reset on
  `end_app_session` only when this server flipped it, `SEMANTOUCH_WEB_AX=off` opt-out), with a
  settle wait and the new advisory `StateWarning` code **`web_content_enabled`** on the
  enabling snapshot. (2) **Scoped/bounded snapshots** (§18.2): optional `get_app_state`
  fields `scopeElementId` (subtree walk rooted at a current-table element; result echo
  `scope`; never diffs; an unhonorable id DEGRADES to a full unscoped snapshot with the
  advisory warning **`scope_ignored`**, never an error) and `maxNodes` (per-snapshot node
  budget, clamped to the frozen 2000 ceiling). (3) **Window enumeration** (§18.3): optional
  `AppState.windows` array (id/title/frame/focused/main/onScreen per AX window).
  (4) **Document observability** (§18.4): optional `AppState.window.document`
  (`url`/`title` from the principal `AXWebArea`). (5) **`set_value` commit** (§18.5):
  optional `commit` field — pre-focus, write, then `AXConfirm` when advertised; new
  optional `ActionResult.committed`. (6) **Element-targeted fallback keys** (§18.6):
  optional `revision`+`elementId` pair on `press_key`/`type_text` sets `AXFocused` on the
  target before synthesis; new optional `ActionResult.elementFocused`. (7) **`wait_for`**
  (§18.7): new read-only polling tool (`tools/list` now returns **13**) over
  title/url/element conditions with `mode`/`timeoutMs`; expired deadline is a normal
  `satisfied: false` result, never a `timeout` error. (8) **Pointer restore** (§18.8,
  behavior-only): a coordinate pointer action records and returns the user's physical
  cursor after delivery (skipped on interruption/foreground loss). (9) **`screenshot`**
  (§18.9): new read-only capture-only tool (`tools/list` now returns **14**) — the
  resolved window's JPEG with no settle/tree/revision cost; element ids stay valid; hard
  `permission_denied` without Screen Recording; refreshes §16.5 coordinate geometry.
  Additive and
  backward-compatible: all new request fields are optional and omitting them reproduces
  v1.4 byte-for-byte; all new result fields are omitted when inapplicable; no field was
  removed or repurposed; the wire identifier remains `semantouch/1`.
- **v1.4 — implementation note (fallback focus/restore hardening + macOS-26 live finding; no
  wire change).** Follow-up to the two live-verified refinements below, from an adversarial
  residual review — all behavior-only (no field, error, or `tools/list` change; wire identifier
  remains `semantouch/1`): (1) `allow-brief-focus` **restore is now symmetric with the
  forward activation** — after re-activating the prior app the transaction also tries the same
  PUBLIC Accessibility raise, and `focusRestored` is derived from an **actual `frontmost ==
  prior` re-check** (no longer from a `kAXFocused` set, which can succeed against a background
  element and misreport a restore that never happened); if the prior app cannot be refronted,
  `focusRestored` is reported `false` honestly (§16.5/§16.7). (2) The **modifier-key release is
  hardened** so a per-event `nil` `CGEvent` can never strand a held modifier down at the OS
  level — the synthesizer falls back to a source-less `CGEvent` construction (still tagged) and
  logs to stderr rather than silently dropping a modifier `keyUp` (§16.6). **Live finding
  (macOS 26.5.1):** the §16.7 AX foreground fallback does **not** bring a background target
  frontmost when run from the MCP **server process** (0/10), though the identical AX calls do
  from a plain background CLI (5/5); it fails safe every run (nothing delivered, prior app
  undisturbed), so the focus-changing *positive* path is currently non-functional from the
  server process on this OS and likely needs foreground-capable `.app` packaging (§16.7).
- **v1.4 — implementation note (fallback input, macOS-26 empirical; no wire change).** Two
  live-verified refinements to Phase 4 delivery, both **additive** and behavior-only (no
  field, error, or `tools/list` change; wire identifier remains `semantouch/1`):
  (1) **Modifier chords are synthesized correctly** — a chord such as `cmd+a` now posts a real
  modifier-key down/up (which emits the `flagsChanged` responders require) wrapping the main
  key, instead of only setting the modifier flag on the main key event; the flag-only form was
  found on macOS 26 not to trigger chorded commands like select-all (§16.6).
  (2) **Focus-changing modes gained a bounded PUBLIC Accessibility foreground fallback** — when
  `NSRunningApplication.activate()` returns `true` but does not actually bring a background
  target frontmost (observed on macOS 14+/26 from a background helper), the server additionally
  tries setting the app `AXUIElement`'s `kAXFrontmost` / raising its main window via the
  already-granted Accessibility permission, then re-verifies frontmost. **No new TCC
  permission** is used (no Apple Events / Automation, no `osascript`). The fail-safe contract is
  unchanged: input is delivered only if the target is confirmed frontmost, else `focus_required`
  / `rejected` with nothing delivered (§16.7). Cross-app foregrounding from a background helper
  remains platform-restricted; the fallback's efficacy on a given OS is verified separately.
- **v1.4** — Request cancellation and process shutdown made normative (§17). The server now
  understands the MCP `notifications/cancelled` `{ requestId, reason? }` client notification and
  cooperatively cancels the in-flight request it names — the potentially-slow `get_app_state`
  capture + AX tree build is checked at await/loop boundaries and its async ScreenCaptureKit
  call is signalled via best-effort `Task` cancellation (a completed capture is still turned
  into `cancelled` at the checkpoint) — returning the new tool-level error code
  **`cancelled`** (§6). Process
  shutdown (stdin EOF / SIGTERM) cancels any in-flight work before exiting. Additive and
  backward-compatible: the new error row is purely additive; no v1/v1.1/v1.2/v1.3 field was
  removed or repurposed; a client that never sends `notifications/cancelled` is unaffected; the
  wire identifier remains `semantouch/1`. (Deliberate deviation from bare MCP, frozen in
  §17: a cancelled `tools/call` still receives a *typed result* — a successful envelope with
  `isError: true` and `code: "cancelled"` — rather than a dropped response, so the OMP host
  always closes the request by id.) Additive §17.2 refinement (implementation clarification, no
  wire change): the cancellation checks now include a **post-capture** boundary (a cancel caught
  while a valid screenshot is being assembled surfaces as `cancelled`, not a partial success), the
  settle wait polls the token between sleep slices, and a cancelled build is guaranteed to leave
  the session untouched — the revision bump and element-table swap are committed only after that
  post-capture checkpoint, so the ids observed at revision `N` keep resolving at revision `N`
  (§13.1). Process shutdown drains are bounded and symmetric across stdin-EOF and SIGTERM (§17.4).
- **v1.3** — Phase 4 native fallback input made normative (§16). Enables the three
  app-targeted input tools `press_key`, `type_text`, `drag`, and turns on the **coordinate
  fallback path** of `click` and `scroll` (`tools/list` now returns **12**). Adds the
  optional per-call **`interference`** field to every fallback action (`press_key`,
  `type_text`, `drag`, coordinate `click`, coordinate `scroll`) with values
  `background-only` (**default**), `allow-brief-focus`, `foreground-takeover`; semantic
  element actions (§13) are unchanged and remain background-safe. Adds the new error code
  **`focus_required`** (§6) for a `background-only` action whose target is not frontmost.
  Extends `ActionResult` (§4.4) with the optional `focusChanged` / `focusRestored` /
  `targetVerified` booleans and activates the `keyboard` / `pointer` `method` values and the
  `interrupted` `status`. Freezes coordinate spaces for coordinate actions (window points
  by default, screenshot pixels optional; mapped to global points before a CGEvent),
  `press_key`'s chord grammar (§4.3), `type_text`'s Unicode delivery via
  `CGEventKeyboardSetUnicodeString`, and drag button/modifier semantics. Additive and
  backward-compatible: no v1 field was removed or repurposed; `interference` omitted means
  `background-only`; a client that only uses semantic actions is unaffected. Wire identifier
  remains `semantouch/1`.
- **v1.2** — Phase 3 incremental state made normative (§15). Freezes the diff mode
  reserved in §11: `get_app_state` may now return a **diff** (`full: false`,
  `baseRevision` set) in the `semantouch-ax-tree-v1` diff grammar (§15.3) instead of a full
  tree. Adds the request field `disableDiff` (companion to `forceFullTree`; either
  suppresses the diff) and extends the frozen `StateWarning` set (§4.1) with
  `diff_reset` (lineage broke → full tree) and activates `possibly_unsettled` (settle
  deadline expired). Turns on cross-revision element-id reuse (§15.2): a matched element
  keeps its id, a removed/replaced element's id is retired and never reused. Adds bounded
  adaptive settle timings (§15.4). Additive and backward-compatible: no v1 field was
  removed or repurposed; a client that never sets `disableDiff` and treats any `full`
  response as authoritative is unaffected. Wire identifier remains `semantouch/1`.
- **v1.1** — Phase 2 semantic actions made normative (§13). Enables `click`,
  `perform_action`, `set_value`, `select_text`, `scroll` (`tools/list` now returns 9).
  Additive, backward-compatible clarifications to two frozen §6 error payloads:
  `stale_revision.data.current` MAY be `null` (unknown/ended session);
  `unsupported_action.data` MAY carry an optional `reason`. Revision now advances per
  `get_app_state` snapshot within a session (Phase 2), still `full: true`. No v1 field
  was removed or repurposed; the wire identifier remains `semantouch/1`.
- **v1** — Initial frozen contract (§1–§12): transport, handshake, Phase-1 tools, tree
  grammar `semantouch-ax-tree-v1`, error codes, coordinate spaces, resolution.

## 15. Phase 3 incremental state (v1.2 — normative)

Phase 3 turns the diff mode reserved in §11 into a working contract. `get_app_state`
may now return an incremental **diff** against the previous snapshot instead of a full
tree, element ids are stable across revisions for matched elements, and a snapshot taken
after a mutation waits — bounded — for the UI to settle. These rules are **additive** to
the frozen v1/v1.1 contract (§1–§13): no field is removed or repurposed, the wire
identifier stays `semantouch/1`, and every diff response can be reconstructed into
the exact full tree it stands for. Where this section conflicts with §3's Phase-1
revision rule or §13.1's Phase-2 id-freshness rule, **§15 governs in Phase 3**.

### 15.1 Full vs diff, and `disableDiff`

`get_app_state` gains one request field (frozen §4.1 schema, additive):

- **`disableDiff`** — boolean, default `false`. A companion to `forceFullTree`: **either
  one true suppresses the diff** and forces a full tree for that snapshot. They differ
  only in intent (`forceFullTree` = "rebuild ids too"; `disableDiff` = "send the whole
  tree text"); the server treats a full tree that either one requested as **deliberate**
  and does **not** attach a `diff_reset` warning.

Response shape uses the already-frozen `AppState.full` / `AppState.baseRevision` fields:

- A **full** snapshot reports `full: true` and omits `baseRevision`; `tree.text` is the
  `semantouch-ax-tree-v1` full tree (§7). The **first** snapshot of a session is always full.
- A **diff** snapshot reports `full: false` and `baseRevision: <M>` (the revision the
  diff is based on); `tree.text` is the diff grammar of §15.3; `revision` is `<N> = M+1`.

The server returns a **diff** when **all** hold: a previous snapshot exists for the
session; it is for the **same window** (same WindowServer id); neither the previous nor
the current full tree was truncated (§7.5) — the client must have received the base in
full; lineage is intact (§15.2); and the request did not suppress the diff (§15.1).
Otherwise it returns a **full** tree.

When a usable base existed but the server **could not** build on it because the window
changed or lineage broke (§15.2), the full response carries a `diff_reset` **StateWarning**
(code added to the frozen §4.1 set). `diff_reset` is **not** emitted for a first snapshot,
for a truncated base, or for a caller-requested full tree — only for lineage that broke
unexpectedly. On `diff_reset` the client MUST treat all element ids as fresh.

### 15.2 Element identity across revisions

Phase 3 turns on cross-revision id reuse (superseding §13.1's per-snapshot freshness).
Within one session:

- **Ids are stable for matched elements.** An element that reappears with the same
  structural fingerprint keeps its id across snapshots, so a diff can be keyed by id.
  The fingerprint is exactly: **role, subrole, `AXIdentifier`, parent fingerprint,
  sibling ordinal among same-role siblings, and normalized title**. Reuse is
  additionally gated by a **live-element check** (the prior
  reference must still be addressable) so a destroyed element cannot lend its id to a
  look-alike.
- **A removed or replaced element MUST NOT inherit a live id.** Its id is retired and the
  monotonic counter never rewinds (§3), so the id is never reused within the session. A
  replaced element at the same position (same role/parent/ordinal, different title) gets
  a **new** id.
- `stale_element` (§6) still fires for any `elementId` absent from the **current**
  revision's element table (retired or unknown). Action validation order (§13.2) is
  unchanged: a mismatched `revision` is `stale_revision` before element resolution, so an
  id is only ever resolved against the revision it was observed in.

**Diff-correctness requirement.** Applying a diff based on revision `M` to a client's
revision-`M` tree MUST reconstruct revision `N` exactly — every added element carries its
parent id and child index, every removed id is listed, and every changed element carries
its attribute deltas, so no structural ambiguity remains. (The reference implementation
proves `apply(compute(prev, next)) == next` for arbitrary trees.)

### 15.3 Diff text grammar (`semantouch-ax-tree-v1`, diff mode)

`tree.text` for a diff snapshot is UTF-8, lines separated by `\n`, **no trailing
newline**, deterministic for identical input. It reuses §7.3 escaping, §7.2.7 frame
rounding, and §7.2 action `AX`-stripping/sanitization.

```
UI revision <N>, based on <M>
~ <changed entry>
+ <added entry>
- [<removed ids>]
```

- **Header** (always, exactly one): `UI revision <N>, based on <M>` where `<N>` =
  `revision` and `<M>` = `baseRevision`.
- **Changed** (`~ `), one per changed element, sorted by id ascending: the element's
  identity segment (`[e<id>] Role(.Subrole)? (" <title>")?`) as context, then the
  changed attribute tokens with their **actual** value on each side, `<old> → <new>`, in
  the §7.2 key order (`value, placeholder, desc, enabled, focused, selected, frame,
  actions`). Unlike the full grammar, a delta shows default values too, so a toggle reads
  `enabled=false → enabled=true`. A side with no tokens (an attribute appeared or
  disappeared) is elided, leaving the bare arrow. Only non-identity attributes appear in
  a `~` entry; any change to role, subrole, title, parent, or child position is a
  removal + addition instead.
- **Added** (`+ `), one per added element, sorted by id ascending: the element's full
  self line (`[e<id>] Role … frame=… actions=[…]`, the §7 line at depth 0) followed by a
  placement suffix `@<parent>:<index>`, where `<parent>` is `e<parentId>` (or `root` for
  the window) and `<index>` is the 0-based child index under that parent in the current
  revision. A subtree add emits one `+` line per node, each addressing its own parent.
- **Removed** (`- `), a single line when non-empty: `- [<ids>]`, ids ascending and
  comma-joined, with **consecutive runs of length ≥ 3 collapsed** to `e<first>..e<last>`
  (e.g. `- [e3,e51..e55]`). Shorter runs are listed individually. Omitted entirely when
  nothing was removed.

Entry order is fixed: header, then all `~`, then all `+`, then the single `-` line. An
empty diff (nothing changed) is the header line alone.

`tree.nodeCount` on a diff response counts the **current** revision's emitted element
lines (the tree the diff reconstructs to), not the number of diff entries.
`tree.truncated` reflects whether the underlying current tree exceeded a budget (§7.5);
a diff is never itself truncated (it is computed over the complete pruned trees, which is
why a truncated base disqualifies diffing — see §15.1).

### 15.4 Settle semantics

After a mutation dirties a session, the next `get_app_state` waits — bounded — for the AX
hierarchy to go quiet before it walks the tree, so the returned state reflects the
mutation's effect. The policy is adaptive: a short minimum delay, then a required quiet
window, extended while a busy/progress indicator is active, under a hard deadline.

Frozen initial values (one tunable struct in the implementation):

| Parameter | Value |
|---|---:|
| minimum post-action delay | 75 ms |
| quiet window | 150 ms |
| normal deadline | 1 s |
| loading deadline (busy/progress active) | 5 s |

If the deadline expires while activity is still ongoing, the server returns the current
state anyway with a `possibly_unsettled` **StateWarning** (activated from the reserved
§4.1 code). The first snapshot of a session never waits. Settle timings are an
implementation policy, not a wire field; only the resulting `possibly_unsettled` warning
is observable.

Event-driven invalidation backs this: the server subscribes one `AXObserver`
per observed app to the minimal invalidation set (element destroyed/created, value/title
changed, layout/resize/move, focus, window/sheet lifecycle) on a dedicated run-loop
thread; notifications only mark dirty state and activity timestamps. If observer
registration fails, the app degrades to always-dirty (full rebuilds) with a logged
warning — never a crash, and never stale state.

## 16. Phase 4 native fallback input (v1.3 — normative)

Phase 4 adds synthesized keyboard and pointer input as an explicit, opt-in **fallback** to
the Phase 2 semantic ladder. These rules are **additive** to the frozen v1/v1.1/v1.2
contract (§1–§15): no field is removed or repurposed, the wire identifier stays
`semantouch/1`, and semantic element actions (§13) are unchanged. Where this section
references the §4 enablement table's "Enabled now" column, **§16 governs**: all twelve
defined tools are enabled.

### 16.1 Enabled surface

- `press_key`, `type_text`, and `drag` (§4.3) are **enabled**.
- `click` and `scroll` (§4.2) gain a **coordinate fallback path** selected by the presence
  of an `at` point. Without `at` they behave exactly as in Phase 2 (semantic element path);
  with `at` they synthesize pointer input. The engine **never** auto-escalates from a failed
  semantic action to coordinate input — the caller opts in by passing `at`.
- `tools/list` now returns **12** tools.

**Fallback actions** are: `press_key`, `type_text`, `drag`, coordinate `click`, and
coordinate `scroll`. Only these carry the interference field and can synthesize input.

### 16.2 The `interference` field

Every fallback action accepts an optional `interference` string (schema §4, additive):

| value | meaning |
|---|---|
| `background-only` (**default**) | Deliver input only if the target is already frontmost. If not, **reject** with `focus_required` — never change focus, never risk input reaching the user's app. |
| `allow-brief-focus` | If the target is not frontmost, run a bounded focus transaction: record the user's frontmost app + system-wide focused element → activate the target → deliver → restore the prior foreground/focus (best-effort). |
| `foreground-takeover` | Activate the target and **leave it activated**; deliver. |

Omitting `interference` means `background-only`. The agent **MUST NOT** silently escalate;
raising the interference level is always the caller's explicit choice. Semantic element
actions (§13) ignore this field entirely and remain background-safe.

**Decision table** (target-is-frontmost × mode). If the target is already frontmost, every
mode delivers directly with no focus change. Otherwise: `background-only` → `focus_required`;
`allow-brief-focus` → brief transaction; `foreground-takeover` → activate-and-leave.

### 16.3 Validation and delivery order

A fallback action carries `{ app, sessionId, interference? }` plus its own parameters. The
server processes it in this fixed order (stop at first failure):

1. **App policy gate** (§13.5), *before* enqueue — a denied app → `policy_denied`
   before any input is synthesized. (Fallback input is a mutation; the denylist applies.)
2. Inside the session's serial lane (§13.6):
   1. **Session existence** — an unknown/ended session → `stale_revision` with
      `current: null` (a fallback action carries no revision; `provided` is `0`).
   2. **Confused-deputy guard** (§13.5) — the session must be owned by the gated `app`
      (bound on pid); a foreign session → `policy_denied` (`app_denied`).
   3. **Coordinate mapping** — for a coordinate action, map `at`/`from`/`to` to global
      points (§16.5) *before* any focus change, so an unmappable point fails without
      disturbing the user's foreground.
   4. **Interference decision** (§16.2) — `background-only` + not-frontmost → `focus_required`.
   5. **Focus transaction + delivery** — under the chosen focus mode, deliver the tagged
      CGEvents (§16.6). For a focus-changing mode, input is delivered **only** if the target
      actually became frontmost; if activation fails to foreground it, no input is delivered
      and the result is `status: rejected` with `targetVerified: false`.
   6. **Target verification** — after delivery, confirm via frontmost that the intended
      target (not the user's app) held the foreground during delivery; report as
      `targetVerified`.

### 16.4 `ActionResult` for fallback actions

Fallback actions return `ActionResult` (§4.4) with these Phase 4 additions (all optional and
omitted for semantic actions, so Phase 2/3 results are byte-identical):

- `method` is `keyboard` (`press_key`, `type_text`) or `pointer` (coordinate `click`,
  `drag`, coordinate `scroll`).
- `status`: `completed` when input was delivered; `interrupted` when genuine physical user
  input cancelled the remaining input mid-action (**frozen semantics**: a user-interruption
  is a *successful* `tools/call` result with `status: interrupted`, not the `user_interrupted`
  error); `rejected` when a focus-changing mode could not bring the target frontmost and so
  no input was delivered.
- `focusChanged` — whether the foreground app was changed by a focus transaction.
- `focusRestored` — whether the user's prior foreground/focus was restored (meaningful for
  `allow-brief-focus`).
- `targetVerified` — whether the intended target was confirmed frontmost during delivery.
- `stateChanged` is best-effort `false` (fallback input is not cheaply re-read);
  `refreshRecommended` is `true`. `warning` carries advisory notes (e.g. interruption
  monitoring unavailable, or the target could not be foregrounded).

### 16.5 Coordinate spaces (fallback)

Coordinate actions (`drag`, coordinate `click`, coordinate `scroll`) express points in a
`space` (§9), default **`window`** (window points); `screenshot` (screenshot pixels) is also
accepted. The service maps the client's point to **global points** and posts the CGEvent
there:

- `window` → global: `gx = wx + F.x`, `gy = wy + F.y` (needs only the window frame).
- `screenshot` → global: `S → W` using `kx/ky` from the delivered pixel size vs. the window
  frame (§9), then `W → G`. Requires that a screenshot was delivered for the session;
  otherwise → `window_not_found`.

The mapping source is the window geometry captured by the most recent `get_app_state` for
the session. With no prior `get_app_state` (no known window) a coordinate action →
`window_not_found`. `drag` interpolates between `from` and `to`; `button` (`left`|`right`,
default `left`) and `modifiers` (`cmd|ctrl|opt|shift|fn`) apply to `click` and `drag`.

### 16.6 Input synthesis, tagging, and interruption

- Input is synthesized with the **public CGEvent API** only (clean-room: no SAI / private
  frameworks). `press_key` uses the §4.3 chord grammar and the Phase-1 token table
  (modifiers + one key per chord, chords separated by a single space); a malformed `combo`
  is JSON-RPC `-32602`. `type_text` delivers literal Unicode via
  `CGEventKeyboardSetUnicodeString` (layout-independent), one character per event.
- A modified chord (e.g. `cmd+a`) is delivered as a **real modifier-key sequence**, not merely
  a flag bit on the main key: the modifier key is posted **down** (producing the
  `flagsChanged` that responders require to recognize a chord) *before* the main key, the
  modifier mask is set on both the modifier and the main key-down/up events, and the modifier
  key is posted **up** *after* the main key. Multiple modifiers nest (each pressed carrying
  the modifiers held at that instant, released in reverse). A chord is emitted atomically —
  interruption/target checks fall on chord boundaries — so a modifier is never left stuck
  down. (Empirical macOS-26 finding: a flag-only `cmd+a` did **not** trigger select-all,
  because no modifier `flagsChanged` reached the responder.)
- **Every** synthesized event is tagged as ours (a distinctive value in
  `CGEventField.eventSourceUserData`), so the passive interruption tap never mistakes our own
  input for the user's.
- A passive, listen-only session-tap observes physical input on a dedicated run-loop thread.
  A genuine (untagged) event during an armed fallback action sets an interrupted flag the
  executor polls between input units, cancelling the remainder and returning
  `status: interrupted` (a drag additionally releases the button so no stuck drag is left).
  Tap-creation failure degrades to "no interruption detection" (logged warning + a `warning`
  on affected actions), never a crash.

### 16.7 Background-only feasibility conclusion

With **public APIs only**, truly-background coordinate/keyboard injection into a
**non-frontmost** app is not reliably achievable: the proprietary background-injection
mechanism (SAI / private frameworks) is out of scope, and public `CGEvent` delivery targets
the frontmost app / the point under the cursor. Therefore `background-only` is defined to
**require the target to already be frontmost** and to return `focus_required` otherwise —
rather than send input to the wrong app. Delivering to a non-frontmost target is possible
only by explicitly opting into `allow-brief-focus` (a bounded, restored focus change) or
`foreground-takeover`. This is a deliberate safety boundary, not a limitation to work around.

**Empirical finding (macOS 26; applies to macOS 14+).** Cross-app *foregrounding* from a
**background helper process** is itself restricted by the OS. When the helper is not the
frontmost application, `NSRunningApplication.activate()` /
`.activate(options: .activateIgnoringOtherApps)` / `.activateAllWindows` all return `true`
but the target frequently **never actually reaches frontmost** (the bounded activation wait
times out). So the `allow-brief-focus` / `foreground-takeover` *positive path* — bring a
background app forward, then deliver — cannot be assumed to succeed on this platform from a
background server. To make the attempt as strong as the public surface allows, a
focus-changing mode now proceeds in two bounded stages:

1. `NSRunningApplication.activate()`, then poll `frontmostApplication` up to the activation
   deadline.
2. **If (and only if) that did not foreground the target**, a best-effort PUBLIC
   **Accessibility** fallback using the *already-granted* Accessibility permission — set the
   application `AXUIElement`'s `kAXFrontmost` attribute to `true` and raise its main/focused
   window (`kAXRaise`) — then re-poll `frontmostApplication`. This uses **no additional TCC
   permission** (no Apple Events / Automation, no `osascript`; those would require a third
   grant and a process-per-action shell-out, both out of scope).

Delivery still happens **only** if the target is confirmed frontmost after these attempts;
if neither route foregrounds it, **both** `allow-brief-focus` and `foreground-takeover`
return `status: rejected` with `targetVerified: false` and **deliver nothing**. `focus_required`
is **not** an outcome of these attempts: it is exclusively the `background-only` pre-check
result (§16.2/§16.4), thrown in the interference decision *before* any activation / AX-raise is
attempted, and never involves them. The fail-safe direction is unchanged (never wrong-target
input). Whether the AX fallback actually
foregrounds a background app on a given macOS version is a **platform-dependent** outcome
verified separately (live acceptance), not a guarantee of this protocol. The
**deliver-in-background** path (target already frontmost) is unaffected and fully functional;
it remains the only path guaranteed to deliver on macOS 14+.

**Live finding (macOS 26.5.1 — server-process activation limitation, stated honestly).** The
stage-2 AX foreground fallback above was probed live. From a **plain background CLI** the
identical public AX calls (`kAXFrontmost` + `kAXRaise`) **do** bring the target frontmost
(5/5 runs). From **this helper running as the MCP server process**, the same calls do **not**
foreground the target (**0/10 runs**) — the bounded re-verification times out and the action
returns `status: rejected` with `targetVerified: false`, delivering nothing and leaving the
user's prior foreground undisturbed (it **fails safe on every run**). So on macOS 26 the
`allow-brief-focus` / `foreground-takeover` **positive path is non-functional from the server
process**; the cause appears to be process context / activation policy (a background,
non-`.app` helper is not permitted to change the system foreground), and it will most likely
be resolved only by packaging the helper as a proper foreground-capable `.app` bundle. The
safety contract is unaffected — input is never delivered to the wrong app — but on this
platform callers should treat the higher focus modes as *best-effort and currently expected to
be rejected from the server process*, and rely on the deliver-in-background path.

## 17. Cancellation and shutdown (v1.4 — normative)

Cancellation must close capture work and return a typed result. This section
freezes how the server cancels an in-flight request and how
it shuts down. These rules are **additive** to the frozen v1–v1.3 contract (§1–§16): no field
is removed or repurposed, and the wire identifier stays `semantouch/1`.

### 17.1 `notifications/cancelled`

The server accepts the MCP client notification:

```jsonc
{ "jsonrpc": "2.0", "method": "notifications/cancelled",
  "params": { "requestId": <id>, "reason"?: <string> } }
```

- `requestId` MUST equal the `id` of a previously-sent request. It is matched by canonical
  JSON form, so a string id (`"abc-1"`) and a numeric id (`7`) are distinguished exactly.
- As a notification it carries no `id` and never receives a reply.
- An unknown or already-completed `requestId` is a **safe no-op**.

The server's read loop runs concurrently with request execution (execution itself remains
strictly serial — one handler at a time — so replies stay ordered and deterministic). This is
what lets a `notifications/cancelled` for the request that is *currently executing* be observed
and routed to that request while it is still running.

### 17.2 Cooperative cancellation of `get_app_state`

`get_app_state` is the one long-running read. When its request is cancelled:

- an ambient cancellation token is checked at boundaries — before app resolution, after the
  (bounded) settle wait, before the ScreenCaptureKit capture, and once more **after** the capture
  block completes (the post-capture checkpoint) — so the work stops promptly rather than paying
  for the full tree build + screenshot, and a cancel that arrives while a valid image is being
  assembled is caught at that post-capture boundary. The settle wait itself also polls the token
  between its sleep slices, so a cancel during a multi-second settle breaks the wait early;
- the in-flight async ScreenCaptureKit call is signalled via `Task` cancellation on a
  best-effort basis; because ScreenCaptureKit does not document honoring `Task` cancellation,
  an already-started capture MAY run to completion, in which case the checkpoint token turns
  that completed capture into `cancelled` at the next boundary;
- a cancellation is **never** silently swallowed into a partial success — in particular a
  cancel that lands during screenshot capture surfaces as `cancelled`, not a
  `screenshot_unavailable` warning on an otherwise-successful state;
- a cancelled build leaves the session **untouched**: the revision bump and the element-table
  swap (the diff base, the dirty/lineage flags, and the id-table retirement/mint) are committed
  only after the post-capture checkpoint passes, so a build that ends in `cancelled` neither
  advances the revision nor retires the element ids the client already holds — the ids observed
  at revision `N` continue to resolve at revision `N` (§13.1). Any ids minted during the abandoned
  pass are retired forever (the monotonic counter never rewinds, §3), leaving only a permitted gap.

Actions (Phase 2 / Phase 4) are short and serialized per session; they are not separately
cancellable mid-flight, but a cancel issued while one is queued still resolves the request.

### 17.3 The cancelled result is typed

Bare MCP says a receiver SHOULD NOT respond to a cancelled request. This server **deliberately
deviates**: a cancelled `tools/call` receives a typed tool-level result — a successful
`tools/call` envelope with `isError: true` whose single text block is
`{ "code": "cancelled", "message", "data"?: { "reason"? } }` (§5, §6). `reason` echoes the
notification's `reason` when supplied and is omitted otherwise. Returning a typed result (not a
dropped response) lets the OMP host always close the request by id and surface why it ended.

### 17.4 Process shutdown

On **stdin EOF** or **SIGTERM**, the server cancels every in-flight request's token (so no
capture / tree-build work is orphaned) and exits cleanly. EOF additionally drains the execution
queue — each cancelled handler unwinds to its `cancelled` result — before `run()` returns.
Locked-screen operation remains a non-goal; nothing here changes that.

## 18. Web content and verified transitions (v1.5 — normative)

Live testing against a Chromium-shell browser exposed two systemic gaps: (1) Chromium/Electron
applications do not expose their web-content accessibility tree to a background AX reader until
an assistive client announces itself, so snapshots contained only browser chrome; (2) action
results report **delivery**, not **outcome** — `completed` + `targetVerified: true` meant "the
input reached the app while it was frontmost", which callers misread as "the intended UI
transition happened". v1.5 closes both: it enables web-content exposure, adds scoped/bounded
reads so web trees are usable, gives `set_value` a semantic commit, lets fallback keyboard input
target an element's keyboard focus, adds a `wait_for` verification tool, and surfaces window
lists and document URLs so outcomes are observable.

These rules are **additive** to the frozen v1–v1.4 contract (§1–§17): no field is removed or
repurposed, and the wire identifier stays `semantouch/1`. All new request fields are
optional (omitting every one of them reproduces v1.4 behavior byte-for-byte); all new result
fields are omitted when not applicable, so existing consumers are unaffected.

### 18.1 Web-content accessibility enablement

Chromium renders its accessibility tree lazily: until an assistive technology is detected, the
web area exposes no descendants. Electron additionally gates this behind the app-element
attribute `AXManualAccessibility`; Chromium browsers use `AXEnhancedUserInterface`. Both are
public AX attributes settable with the already-granted Accessibility permission (no new TCC).

- During `get_app_state`, after the Accessibility preflight and **before** window resolution,
  the server best-effort sets `AXManualAccessibility = true` and
  `AXEnhancedUserInterface = true` on the target **application** AX element.
- The attempt is made **once per app session** (re-attempted on the next snapshot if the write
  faulted). `attributeUnsupported` / `noValue` and other per-attribute failures are silent
  (stderr log only) — for a non-web app this is a no-op.
- When at least one attribute **transitions to enabled** (it was not already `true`), the
  session is treated as **dirty** for this snapshot (the §15.4 settle wait runs with the
  loading deadline, even for a session's first snapshot) — the web tree is built
  asynchronously by the target app and needs the settle window to appear. The snapshot gains
  the new advisory **StateWarning `web_content_enabled`**: "Web-content accessibility was just
  enabled for this app; if expected web content is missing from this tree, request another
  snapshot." (Additive §4.1 warning code; clients MUST ignore unknown warning codes.)
- `end_app_session` (and process shutdown) best-effort resets to `false` **only** the
  attributes this server itself flipped, never one that was already `true` (e.g. VoiceOver's).
- The operator can disable the whole mechanism with **`SEMANTOUCH_WEB_AX=off`** (default: enabled).

**Empirical finding (macOS 26, Chromium shell).** Setting `AXEnhancedUserInterface` on a
Chromium-based browser can return `cannotComplete` (-25208) even though the write **takes
effect** — the attribute re-reads `true` and the web-content tree materializes. A set-error
return is therefore verified by an immediate re-read: when the attribute now holds the
requested value the write is classified as **set** (driving the warning, the settle wait,
and the reset bookkeeping); only a re-read that does not confirm the value is a genuine
fault (re-attempted next snapshot). Non-Electron Chromium shells report
`AXManualAccessibility` as unsupported — expected and silent.

### 18.2 Scoped and bounded snapshots

Web areas produce trees that dwarf the §7.5 budgets; a pre-order cut then discards exactly the
content behind the chrome. Two additive `get_app_state` request fields make large trees
navigable:

```jsonc
"scopeElementId": { "type": "string", "pattern": "^e[0-9]+$" },  // optional
"maxNodes":       { "type": "integer", "minimum": 1, "maximum": 2000 } // optional
```

- **`scopeElementId`** roots the walk at an element of the session's **current** snapshot
  instead of the window. An id that cannot be honored **never errors** — the request
  **degrades to a full unscoped snapshot** carrying the new advisory **StateWarning
  `scope_ignored`** (message names the requested id and the reason), with no `scope` echo.
  Degradation cases: no live session / no prior snapshot to scope into; an id that does not
  resolve in the current element table (retired, unknown, dead); a resolved element belonging
  to a different window than the resolved one. A degraded request behaves **exactly** like an
  unscoped snapshot (normal id stability, diff eligibility, diff-base storage). Rationale
  (live finding, two driver-agent rounds): a scoped misuse answered with
  `stale_revision`/`stale_element` produced an unrecoverable retry loop — the error message's
  "refresh with get_app_state" is precisely what the agent believed it was doing — whereas a
  full tree with fresh ids self-corrects on the next call. `stale_revision`/`stale_element`
  are therefore **not** `get_app_state` outcomes; they remain action/`wait_for` errors
  (§13.2, §16.3, §18.7). The scoped element becomes the single depth-0 root of `tree.text`; frames
  remain **window points** (§9). The snapshot otherwise behaves normally: the revision
  advances, **all** prior ids are retired (§13.1), and the new element table covers exactly the
  scoped subtree — an element outside the scope must be re-acquired via an unscoped snapshot.
  An **honored** scoped result echoes the request in a new optional field
  `scope: { "elementId": "<requested>" }` (the echoed id is the *retired* id the caller sent,
  for correlation only). Honored scoped snapshots never participate in diffing: they are
  always `full: true`, are never stored as a diff base, and the next unscoped snapshot is a
  full tree (with `diff_reset` when a base had existed). Window selection and screenshot
  behavior are unchanged (the screenshot remains the whole window). `scopeElementId` composes
  with `windowId` only if the scoped element belongs to the resolved window; a scoped element
  in a different window degrades per the `scope_ignored` rule above.
- **`maxNodes`** overrides the §7.5 default node budget (600) for this snapshot, clamped to
  the frozen hard ceiling (2000). The 120 KB byte cap and all other §7.5 rules are unchanged.

### 18.3 Window enumeration — `AppState.windows`

`AppState` gains an optional additive array so a caller can see and re-target every window
without guessing:

```jsonc
"windows": [ {
  "id": 123,                  // optional — WindowServer id, when correlated (§10.3)
  "title": "string",          // optional
  "framePoints": Rect,        // GLOBAL points (§9)
  "focused": true,            // AXFocusedWindow match
  "main": false,              // AXMainWindow match
  "onScreen": true            // correlates to a normal, visible CG window
} ]
```

Best-effort: gathered from `AXWindows` during window resolution; omitted entirely if gathering
fails. The selected window (`AppState.window.id`) also appears in the list. A caller re-targets
another window by passing its `id` as `windowId` — entries without an `id` are not targetable
this snapshot.

### 18.4 Document observability — `AppState.window.document`

When the selected window's built tree contains at least one `AXWebArea`, `AppState.window`
gains an optional additive field read from the **principal web area** (the one with the
largest `width × height` frame area in the built tree; ties break to the first in pre-order):

```jsonc
"document": {
  "url": "string",    // optional — the web area's AXURL, absolute string form
  "title": "string"   // optional — the web area's nonempty AXTitle/AXDescription
}
```

`document` is omitted when no web area is in the tree or neither field is readable. This is
the observable "where is the browser now" signal that `wait_for`'s `url_*` conditions (§18.7)
poll. Web-page text remains **untrusted data** (docs/SECURITY.md §2) — `document.url` /
`document.title` are state observations, never instructions.

### 18.5 `set_value` commit

Writing `AXValue` does not run the target's commit path — a browser address bar shows the URL
but never navigates. `set_value` gains an optional additive field:

```jsonc
"commit": { "type": "boolean", "default": false }
```

With `commit: true`, `set_value` (still semantic-only — §13.3's no-input-fallback rule is
unchanged):

1. best-effort sets `AXFocused = true` on the element **before** the write (when settable), so
   the app's editing session targets the field and a later keyboard commit lands there;
2. writes `AXValue` exactly as v1.1;
3. performs **`AXConfirm`** when (and only when) the element advertises it, matching both the
   raw (`AXConfirm`) and stripped (`Confirm`) forms per §13.3.

`ActionResult` gains the optional additive field **`committed`** (boolean, present only when
`commit: true` was requested): `true` iff `AXConfirm` was advertised and performed
successfully. When the element does not advertise `AXConfirm`, the result is still
`completed` (the value was written) with `committed: false` and a `warning` advising a
keyboard commit (§18.6: `press_key` `"enter"` with `elementId`). `commit: false` (or omitted)
is byte-identical to v1.1.

### 18.6 Element-targeted fallback keyboard input

Synthesized keys land in whatever holds the app's keyboard focus, which after a semantic
`set_value` is usually **not** the edited field — the classic failure is Return never reaching
the address bar. `press_key` and `type_text` gain two optional additive fields, valid **only
together** (one without the other → JSON-RPC `-32602`):

```jsonc
"revision":  { "type": "integer", "minimum": 1 },
"elementId": { "type": "string", "pattern": "^e[0-9]+$" }
```

When present, after the §16.3 app-policy/session steps the pair is validated per §13.2 steps
3–4 (revision match → `stale_revision`; element resolution → `stale_element`). During
delivery — inside the focus transaction, after the interference decision, immediately before
event synthesis — the server best-effort sets `AXFocused = true` on the resolved element and
re-reads the application's `AXFocusedUIElement` once (bounded, ≤ 150 ms) to confirm the focus
landed. `ActionResult` gains the optional additive field **`elementFocused`** (boolean, present
only when `elementId` was provided): `true` iff the re-read confirmed the target element (or a
descendant of it) holds keyboard focus. Delivery proceeds even when `elementFocused` is
`false` (the caller opted into fallback input; the field makes the risk observable). All §16
interference rules are unchanged — element targeting never escalates focus by itself.

### 18.7 `wait_for` (new tool)

Explicit post-action outcome verification. `tools/list` now returns **13** tools. `wait_for`
polls observable state until a set of conditions holds or a deadline expires. It is
**read-only**: it never advances the revision, never mints or retires element ids, and never
synthesizes input.

```jsonc
// inputSchema
{ "type": "object", "additionalProperties": false,
  "required": ["app", "sessionId", "conditions"],
  "properties": {
    "app": { "type": "string" },
    "sessionId": { "type": "string", "pattern": "^s[0-9]+$" },
    "conditions": { "type": "array", "minItems": 1, "maxItems": 4,
                    "items": { "$ref": "#/definitions/Condition" } },
    "mode": { "enum": ["all", "any"], "default": "all" },
    "timeoutMs": { "type": "integer", "minimum": 100, "maximum": 30000, "default": 5000 } } }
```

`Condition` is a discriminated object; exactly these kinds exist (an unknown `kind` →
JSON-RPC `-32602`):

| kind | fields | satisfied when |
|---|---|---|
| `title_changed` | `from: string` | the window's `AXTitle` ≠ `from` |
| `title_contains` | `value: string` | the window's `AXTitle` contains `value` (Unicode case-insensitive) |
| `url_changed` | `from: string` | the §18.4 document URL ≠ `from` |
| `url_contains` | `value: string` | the §18.4 document URL contains `value` (case-insensitive) |
| `element_exists` | `role?`, `titleContains?`, `valueContains?` (≥ 1 required) | some element in the window's live hierarchy matches every given matcher (role exact; text matchers case-insensitive contains on title/value) |
| `element_gone` | same as `element_exists` | no element matches |

Processing order: read-side app policy gate (§13.5) → session existence (unknown/ended →
`stale_revision`, `current: null`) → window re-resolution by the session's bound window id
(gone → `window_not_found`) → poll. Polling walks the live AX hierarchy **without touching
the element table**, bounded by the §7.5-equivalent build ceilings, roughly every 150 ms.
Cancellation is cooperative per §17 (checkpoint between polls). An expired deadline is a
**normal result** with `satisfied: false` — not a `timeout` error; `timeout` remains reserved
for internal operation deadlines.

Result payload (`WaitForResult`):

```jsonc
{
  "satisfied": true,             // mode-combined outcome
  "elapsedMs": 640,
  "conditions": [ { "kind": "url_contains", "satisfied": true } ],  // request order
  "observed": {                  // best-effort, at the final poll
    "windowTitle": "string",     // optional
    "url": "string"              // optional (§18.4 source)
  },
  "refreshRecommended": true     // always — poll results are not a snapshot
}
```

The intended idiom, replacing "assume `completed` means it worked":

```
set_value(url field, value, commit: true)
wait_for(url_changed from the old URL, title_changed from the old title; mode any)
get_app_state(...)   // only now retarget elements
```

### 18.8 Pointer restore (implementation note; no wire change)

Public CGEvent pointer delivery routes by screen location and **moves the physical
cursor** (§16.7) — full pointer independence is a private-API capability (SAI) that stays
out of scope. To keep coordinate actions minimally intrusive, the server records the
pointer's location before a coordinate `click` / `drag` / coordinate `scroll` and, after
delivery completes, returns the cursor there with a tagged `.mouseMoved` (never mistaken
for user input by the interruption tap). The restore is **skipped** when the action ended
`interrupted` or the target lost the foreground mid-delivery — the user's hand is on the
mouse, and warping would fight it. Keyboard actions never move the pointer. Semantic
actions (§13) remain the zero-pointer-motion path and are always preferred; the drawn
overlay cursor (see ARCHITECTURE.md) is a separate, click-through visual that never moves the
physical pointer.

### 18.9 `screenshot` (new tool)

A cheap "just look" primitive. `get_app_state` couples pixels to a full snapshot — settle
wait, tree walk, revision advance, and the retirement of every element id — which is the
wrong cost when the caller only needs to see the window. `screenshot` captures the target
window **now** and changes nothing else. `tools/list` returns **14** tools.

```jsonc
// inputSchema
{ "type": "object", "additionalProperties": false, "required": ["app"],
  "properties": {
    "app": { "type": "string" },
    "windowId": { "type": "integer", "minimum": 0 } } }  // §10.2 semantics, as get_app_state
```

Processing order: read-side app policy gate (§13.5) → app resolution (§10.1) →
Accessibility preflight (window resolution reads AX) → window resolution (§10.2–10.3) →
**Screen Recording gate** → capture (§8: the single resolved window, JPEG) → assemble.
Unlike `get_app_state`'s §8 soft degradation, a missing Screen Recording grant is a hard
`permission_denied` (`permission: "screenRecording"`) — the image is the product. A
correlated-but-uncapturable window → `uncapturable_window` (§6). Cancellation is
cooperative per §17.

Semantics:

- **No settle wait, no tree walk.** The capture reflects the instant of the call.
- **The session's snapshot state is untouched**: the revision does not advance and no
  element id is minted or retired — the current snapshot's ids remain valid across any
  number of `screenshot` calls. (A session is created if none exists, exactly as
  `get_app_state` would.)
- **Coordinate-mapping geometry updates** (§16.5): the session's stored window frame,
  `screenshotPixels`, and scale are refreshed, so `space: "screenshot"` coordinates always
  refer to the most recently delivered image regardless of which tool delivered it.

Result payload (`ScreenshotResult`), delivered as the JSON text block with the JPEG as the
§5 image content block:

```jsonc
{
  "sessionId": "s1",
  "window": {
    "id": 123, "title": "string",                       // title optional
    "framePoints": Rect, "screenshotPixels": Size, "scale": 2
  },
  "screenshot": { "mimeType": "image/jpeg", "width": 0, "height": 0, "byteLength": 0 },
  "warnings": StateWarning[]                             // e.g. low_correlation_confidence
}
```

Intended division of labor: `screenshot` when the question is "what does it look like /
did something visibly change"; `get_app_state` when the caller needs elements to act on or
a settled post-mutation tree. `wait_for` (§18.7) remains the cheap non-visual poll.

### 18.10 Result-field summary (additive)

`ActionResult` gains: `committed?` (§18.5, `set_value` with `commit: true` only) and
`elementFocused?` (§18.6, element-targeted `press_key`/`type_text` only). Both are omitted
otherwise, so every pre-v1.5 result stays byte-identical. `WaitForResult` (§18.7) is new.
`AppState` gains `windows?` (§18.3), `window.document?` (§18.4), and `scope?` (§18.2).
`StateWarning` gains the advisory codes `web_content_enabled` (§18.1) and `scope_ignored`
(§18.2). Semantics of existing
fields are unchanged — in particular `targetVerified` still means exactly "the intended target
held the foreground during delivery" (§16.3) and is **not** an outcome claim; outcome
verification is `wait_for`.
