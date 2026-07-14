# Install

Install, permission, and register the `semantouch` helper with OMP. See
[USAGE.md](USAGE.md) for the tool surface and [RELEASE.md](RELEASE.md) for release,
signing, and notarization details.

## Requirements

- macOS **14.4** or later, Apple Silicon (arm64).
- OMP.
- Network access when a released helper is downloaded or checked for updates.

A Swift 6 toolchain (Xcode 16+ or matching Swift.org toolchain) and `just` are required
only for source builds. The Swift package has zero external dependencies.

## Recommended: install the released OMP plugin

Install a specific release:

```sh
omp plugin install github:watzon/semantouch#v0.2.1
```

Or use the repository's OMP/Claude-compatible marketplace catalog:

```sh
omp plugin marketplace add watzon/semantouch
omp plugin install semantouch@semantouch
```

Restart OMP. The first MCP launch downloads `semantouch-macos-arm64` and its checksum from
the matching GitHub release, verifies the binary, and installs it at the versioned path:

```text
~/Library/Application Support/Semantouch/0.2.1/semantouch
```

Then check:

```text
/mcp list
/mcp test semantouch
/semantouch-doctor
```

Grant Accessibility and Screen Recording to the exact helper path reported by `doctor`.
Each release has a new path and code signature, so macOS can require both grants again
after an upgrade.

### Check for and install updates

The CLI doctor report checks GitHub's latest published release without changing its
permission result:

```sh
semantouch doctor
semantouch doctor --json
```

If an update is available, install it with:

```sh
semantouch update
# Machine-readable result:
semantouch update --json
```

Agent-driven doctor workflows do not update automatically. When the report says an
update is available, the agent stops the active workflow and asks the user to choose
**Update now** or **Continue without updating**. Doctor, setup, and computer-use requests
do not imply update consent.

The updater downloads the release binary and its published SHA-256 checksum, verifies
the checksum, Developer ID publisher identity, and binary-reported version, and then
atomically replaces the exact helper executable that is running the command. The path
does not change, so existing Accessibility and Screen Recording entries normally
continue to identify the same helper. Restart OMP or any other Semantouch client after
an update. A later OMP
plugin upgrade can move the helper to a new versioned path; if it does, grant permissions
to the new path reported by `doctor`.

For local development, `just omp-install` still builds the release executable, installs
it at `~/.omp/bin/semantouch`, links the checkout with `omp plugin link .`, and runs the
read-only doctor check.

The remaining sections describe the manual binary and MCP configuration flow.

## 1. Build

```sh
swift build -c release
```

The optimized binary lands in the release bin directory. Get its exact path with:

```sh
swift build -c release --show-bin-path
# e.g. /path/to/semantouch/.build/arm64-apple-macosx/release
```

The helper is the single file `semantouch` inside that directory. A convenience
symlink also exists at `.build/release/semantouch`.

Verify the build:

```sh
"$(swift build -c release --show-bin-path)/semantouch" --version
# semantouch 0.2.1 (contract semantouch/1, MCP 2025-06-18)
```

### Where to put the binary

TCC grants (below) are keyed to the **exact binary path and its code signature**. Pick a
stable install location and grant *that* copy. Options:

- Run it in place from `.build/release/` (fine for development; the path is stable as long
  as you don't `swift package clean`).
- Copy it somewhere durable, e.g. `/usr/local/bin/semantouch` or inside an app
  bundle at `/Applications/Semantouch.app/Contents/MacOS/semantouch` (the
  layout the release flow targets).

Whichever you choose, **that path is the one you grant permissions to and the one you put
in the OMP config.** If you later move, re-copy, or re-sign the binary, macOS may treat it
as a new item and you will need to re-grant.

## 2. Grant the two macOS permissions

The helper needs two TCC grants (see [SECURITY.md](SECURITY.md) §1):

- **Accessibility** — read the target window's accessibility tree and perform AX actions.
- **Screen Recording** — capture a still of the target window (including covered windows).

Grant them to the **exact binary** the helper reports. Ask the helper which binary that is:

```sh
"$(swift build -c release --show-bin-path)/semantouch" doctor
```

Example output:

```
helper:          /Users/you/.../.build/arm64-apple-macosx/release/semantouch
  signed:        true
  version:       0.2.1
accessibility:   denied
screenRecording: denied
ready:           false
remediation:
  - Grant Accessibility: open System Settings › Privacy & Security › Accessibility and enable "…/semantouch".
  - Grant Screen Recording: open System Settings › Privacy & Security › Screen Recording and enable "…/semantouch".
  - Restart "…/semantouch" so the new grants take effect.
```

`doctor` is **read-only**: it reports status without triggering an OS prompt (it uses only
the non-prompting preflight APIs). Follow the `remediation` lines exactly — the `helper:`
path is the item to add under each pane:

1. Open **System Settings › Privacy & Security › Accessibility**, click **+**, and add the
   binary at the reported `helper:` path (in the file picker, press ⌘⇧G and paste it).
2. Do the same under **System Settings › Privacy & Security › Screen Recording**.
3. Fully quit and relaunch the helper (or restart OMP) so the grants take effect.

Re-run `doctor` until it reads:

```
accessibility:   granted
screenRecording: granted
ready:           true
next:            run `semantouch config` to generate an MCP server config.
```

`doctor` (both the CLI subcommand and the MCP `doctor` tool) is the sanctioned onboarding
check. When a required grant is missing at call time, tools fail with the structured
`permission_denied` error naming the exact binary — they never silently degrade.

> If a grant that you added does not "stick", it is almost always because the granted path
> or signature no longer matches the running binary. Re-check `doctor`'s `helper:` line
> against what you granted.

## 3. Register with OMP

OMP launches stdio MCP servers described by an `MCPStdioServerConfig`
(`{ type?, command, args?, env?, cwd? }` plus an optional `timeout`). Generate the block
for your install with the helper itself:

```sh
"$(swift build -c release --show-bin-path)/semantouch" config
```

```json
{"mcpServers":{"semantouch":{"args":["mcp"],"command":"/abs/path/to/semantouch","timeout":30000,"type":"stdio"}}}
```

The `command` is auto-resolved to the running binary (absolute, symlink-resolved). To pin
a specific install path instead, pass `--path`:

```sh
semantouch config --path "/Applications/Semantouch.app/Contents/MacOS/semantouch"
```

Merge the `mcpServers` entry into OMP's MCP configuration. A pretty-printed reference lives
at [`../packaging/omp-mcp-config.example.json`](../packaging/omp-mcp-config.example.json),
and the full plugin manifest at
[`../packaging/semantouch.plugin.json`](../packaging/semantouch.plugin.json).

Useful `config` options:

| Option | Effect |
|---|---|
| `--path FILE` | Embed a specific command path (default: the running binary). |
| `--cwd DIR` | Set the `cwd` field (default: omitted). |
| `--name KEY` | Change the `mcpServers` key (default: `semantouch`). |
| `--timeout MS` | Client timeout in ms (default: `30000`). |
| `--bare` | Emit just the inner `MCPStdioServerConfig` object. |
| `--manifest` | Emit the plugin manifest instead of the server config. |

Once OMP launches the helper as `semantouch mcp`, it speaks MCP over stdio. Confirm
OMP lists the fourteen tools (`doctor`, `list_apps`, `get_app_state`, `screenshot`,
`end_app_session`, `click`, `perform_action`, `set_value`, `select_text`, `scroll`,
`press_key`, `type_text`, `drag`, `wait_for`) — see [USAGE.md](USAGE.md).

## 4. (Optional) Deny apps

By default the server is **permissive**: no application is denied by app policy. To
block specific apps for both reads and mutations, set `SEMANTOUCH_DENIED_APPS` (comma-separated
exact, case-insensitive tokens: bundle id, display name, full path, or path basename) in
the server's `env`. Unset or empty denies nothing. There is no mutation allowlist and no
built-in hard-denied app set. See [USAGE.md](USAGE.md) "App policy" and
[SECURITY.md](SECURITY.md) §2.
