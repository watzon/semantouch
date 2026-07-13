# Fixture app — `computer-use-fixture`

A deterministic, programmatic AppKit application (no xib) used by the Accessibility,
capture, and noninterference cases in [TEST-MATRIX.md](TEST-MATRIX.md).

It exposes a controlled UI surface where every control carries a stable
`AXIdentifier`, and it records every state-changing event as a line of JSON to an
optional `--state-file` so tests can assert observable state changes **without reading
pixels**.

Design constraints:

- Public AppKit APIs only; zero package dependencies.
- Activation policy is `.regular` (it needs real windows and a menu bar).
- The main window uses the normal window level.
- The app **never writes to stdout**; diagnostics go to stderr, state to the state file.
- The app does **not** steal foreground focus unless `--activate` is passed, so
  covered-window and noninterference tests stay honest.

## Build & run

```bash
# Compile-check the target (what CI verifies):
swift build --target computer-use-fixture --scratch-path .build-fix

# Link a runnable binary (the --target mode above compiles the module but does not
# link the executable product):
swift build --product computer-use-fixture --scratch-path .build-fix

# Launch:
.build-fix/arm64-apple-macosx/debug/computer-use-fixture --state-file /tmp/fixture.jsonl
```

## Flags

| Flag | Argument | Default | Effect |
|---|---|---|---|
| `--title` | `T` | `CU Fixture` | Title of the main window. |
| `--state-file` | `PATH` | none | Append one JSON event line per state change to `PATH` (truncated at startup). When omitted, event logging is a no-op. |
| `--frame` | `x,y,w,h` | `240,240,480,640` | Main-window frame in screen points (AppKit bottom-left origin). |
| `--cover` | `x,y,w,h` | none | Spawn an opaque, borderless, bright-orange `NSWindow` at `.floating` level with this frame — used to cover the main window for capture tests. |
| `--second-window` | — | off | Spawn a second titled window "CU Fixture B". |
| `--activate` | — | off | Call `NSApp.activate(...)` on launch. Default is **not** to steal focus. |

Both `--flag value` and `--flag=value` spellings are accepted. Malformed geometry and
unknown flags are reported on stderr and ignored (defaults are kept); the app still
launches.

## Controls, identifiers, and emitted events

Each interactive control below emits exactly one JSON line per activation. Display-only
elements emit nothing but still carry an identifier so the AX tree can be asserted.

| Control | `AXIdentifier` | Event `event` | `control` field | `value` |
|---|---|---|---|---|
| Button "Press Me" (press counter) | `fixture.button.press` | `press` | `fixture.button.press` | int — new press count |
| Label "Presses: N" | `fixture.label.count` | — (display only) | — | — |
| Editable text field | `fixture.field.text` | `textChanged` | `fixture.field.text` | string — current field text |
| Read-only mirror label | `fixture.label.mirror` | — (mirrors the field) | — | — |
| Static label "Static label" | `fixture.label.static` | — (display only) | — | — |
| Scrollable table, 50 rows "Row 1".."Row 50" | `fixture.table` | — (mutated via the buttons below) | — | — |
| Button "Add Row" | `fixture.button.addRow` | `addRow` | `fixture.button.addRow` | int — row count after add |
| Button "Remove Row" | `fixture.button.removeRow` | `removeRow` | `fixture.button.removeRow` | int — row count after remove |
| Button "Duplicate" (first) | `fixture.button.dup1` | `press` | `fixture.button.dup1` | — |
| Button "Duplicate" (second) | `fixture.button.dup2` | `press` | `fixture.button.dup2` | — |
| Popup button (Option 1/2/3) | `fixture.popup` | `select` | `fixture.popup` | string — selected item title |
| Checkbox | `fixture.checkbox` | `toggle` | `fixture.checkbox` | bool — `true` when checked |
| Button "Disabled" (permanently disabled) | `fixture.button.disabled` | `press`* | `fixture.button.disabled` | — |
| Menu Fixture ▸ "Ping" | `fixture.menu.ping` | `press` | `fixture.menu.ping` | int — new press count (shares the press counter) |
| Menu Fixture ▸ "Show Sheet" | `fixture.menu.showSheet` | `showSheet` | `fixture.menu.showSheet` | — |
| Sheet "OK" button | `fixture.sheet.ok` | `sheetOK` | `fixture.sheet.ok` | — |

\* The disabled button is permanently disabled, so its `press` event never actually
fires; the mapping is documented for completeness.

Two buttons share the visible title "Duplicate" but have distinct identifiers
(`fixture.button.dup1` / `fixture.button.dup2`) to stress element identity.

The two Fixture-menu items now carry the `fixture.menu.ping` / `fixture.menu.showSheet`
identifiers above (set via `NSMenuItem.setAccessibilityIdentifier`, Stage F cleanup), so
the table's identity column is accurate. Note that the menu bar is **not** part of the
window-rooted MCP accessibility tree, so those identifiers are visible to a menu-bar /
AppKit AX walk rather than to `get_app_state`; a window-scoped test still targets the
menu items by title ("Ping" / "Show Sheet").

### App- and auxiliary-level identifiers (no events except `ready`)

| Element | `AXIdentifier` | Notes |
|---|---|---|
| App ready marker | `fixture.app` | Emits one `ready` event (value = window title) once the UI is up. |
| Sheet body label | `fixture.sheet.label` | Present only while the sheet is shown. |
| Second-window label | `fixture.second.label` | Present only with `--second-window`. |

## Event log format

One JSON object per line (newline-delimited JSON), flushed immediately (an unbuffered
`write()` syscall) so a separate reader process observes each change as it happens.

```json
{"seq":1,"event":"ready","control":"fixture.app","value":"CU Fixture"}
{"seq":2,"event":"press","control":"fixture.button.press","value":1}
{"seq":3,"event":"textChanged","control":"fixture.field.text","value":"hello"}
{"seq":4,"event":"addRow","control":"fixture.button.addRow","value":51}
{"seq":5,"event":"toggle","control":"fixture.checkbox","value":true}
{"seq":6,"event":"select","control":"fixture.popup","value":"Option 2"}
{"seq":7,"event":"showSheet","control":"fixture.menu.showSheet"}
{"seq":8,"event":"sheetOK","control":"fixture.sheet.ok"}
```

Fields:

- `seq` — monotonically increasing 1-based integer, in emission order.
- `event` — the kind of state change.
- `control` — the `AXIdentifier` (or `fixture.app`) that produced it.
- `value` — optional; a JSON string, integer, or boolean depending on the event.

## Example invocations

```bash
# Basic run with an event log.
computer-use-fixture --state-file /tmp/fixture.jsonl

# Covered-window capture proof: place an opaque orange cover over the main window,
# without stealing focus.
computer-use-fixture \
  --frame 300,300,480,640 \
  --cover 320,320,440,560 \
  --state-file /tmp/fixture.jsonl

# Noninterference / multi-window: main window plus a second titled window, background.
computer-use-fixture --second-window --state-file /tmp/fixture.jsonl

# Foreground run that intentionally takes focus (interactive debugging).
computer-use-fixture --activate --title "CU Fixture (fg)"
```
