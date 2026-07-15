# Install

Install, permission, and register Semantouch with OMP. See
[USAGE.md](USAGE.md) for the 16-tool surface and [RELEASE.md](RELEASE.md) for release,
signing, and notarization details.

## Requirements

- macOS **14.0** or later (`Package.swift` platforms, `Sources/SemantouchCLIKit/Packaging.swift` `minimumMacOS`).
- Apple Silicon **or** Intel Mac (released app is **universal2**: `arm64` + `x86_64`;
  `Packaging.architectures`, `.github/workflows/release.yml`).
- OMP (or another stdio MCP client).
- Network access when a released app ZIP is downloaded or checked for updates.

A Swift 6 toolchain (Xcode matching the local SDK) and `just` are required only for
source builds. The Swift package has zero external dependencies.

Public computer-use support is **macOS only**. Windows/Linux are not GA.

## Published vs next-release assets (important)

Current package/app version is **`0.3.2`**
(`Sources/MCPServer/MCPServer.swift` `serverVersion`, `package.json`,
`.claude-plugin/plugin.json`).

### Currently published GitHub release `v0.2.1` (verified 2026-07-14)

`gh release view v0.2.1` lists these assets only:

| Asset | Role |
|---|---|
| `semantouch-macos-arm64` | Legacy standalone helper binary |
| `semantouch-macos-arm64.sha256` | Checksum |
| `semantouch-plugin-v0.2.1-macos-arm64.tar.gz` | Plugin archive for that helper |
| `semantouch-plugin-v0.2.1-macos-arm64.tar.gz.sha256` | Checksum |

That published release is **arm64 helper-shaped**, not the universal2 app host. Install
commands that pin `#v0.2.1` therefore download the **legacy arm64 helper path**, not
`Semantouch.app`.

### Next-release / current workflow contract (source of truth for new tags)

`.github/workflows/release.yml` and `Sources/SemantouchCLIKit/Packaging.swift` now build
and publish **only** whole-app universal2 artifacts (raw helpers are refused):

| Asset | Role |
|---|---|
| `Semantouch-v<version>-macos-universal2.zip` | Signed/notarized/stapled `Semantouch.app` |
| `Semantouch-v<version>-macos-universal2.zip.sha256` | Checksum |
| `Semantouch-v<version>-macos-universal2.dmg` | Signed/notarized/stapled DMG |
| `Semantouch-v<version>-macos-universal2.dmg.sha256` | Checksum |
| `semantouch-plugin-v<version>-macos-universal2.tar.gz` | Script/config plugin archive (no Mach-O) |
| `semantouch-plugin-v<version>-macos-universal2.tar.gz.sha256` | Checksum |

Until a tag is published with those names, treat universal2 ZIP/DMG install paths as
**next-release** behavior.

### npm / Homebrew

Workflows exist (`.github/workflows/npm.yml`, `.github/workflows/homebrew.yml`) and wait
for the universal2 ZIP + checksum on a published tag. There is **no** checked-in
`npm/semantouch/release-digest.json` pin in this worktree, and public npm/Homebrew
availability is **unproven until a release that publishes those assets succeeds**. Do not
document `npm i -g @watzon/semantouch` or `brew install --cask semantouch` as current
public install methods.

## Recommended: install the OMP plugin

Install a specific release tag:

```sh
omp plugin install github:watzon/semantouch#v0.3.2
```

Or use the repository's OMP/Claude-compatible marketplace catalog:

```sh
omp plugin marketplace add watzon/semantouch
omp plugin install semantouch@semantouch
```

Restart OMP.

### What the plugin launcher does

The plugin launcher is `scripts/semantouch` (shipped in the plugin archive). For the
**app-host** contract it:

1. Prefers a verified `/Applications/Semantouch.app`, else `~/Applications/Semantouch.app`.
2. Otherwise downloads the versioned **universal2 app ZIP** for the plugin version,
   verifies SHA-256, extracts with containment checks, verifies codesign/notarization/
   Gatekeeper, and installs to `~/Applications/Semantouch.app`.
3. Execs only `Contents/MacOS/semantouch` (nested stdio relay).
4. **Never** falls back to a raw TCC-capable helper binary in production
   (`scripts/semantouch` header comments; release workflow refuses raw helpers).

**Unproven on published `v0.2.1`:** that tag's assets are still the arm64 raw helper +
arm64 plugin archive, so a plugin pinned to `#v0.2.1` will not find
`Semantouch-v0.2.1-macos-universal2.zip` on the GitHub release. Use a later tag that
publishes the universal2 ZIP, install a signed app manually (below), or build from
source.

Then check:

```text
/mcp list
/mcp test semantouch
/semantouch-doctor
```

Grant **Accessibility** and **Screen Recording** to the signed **Semantouch.app** host
reported by `doctor` (bundle id `tech.watzon.semantouch`, executable `SemantouchHost`).
Do not grant the nested `Contents/MacOS/semantouch` relay — it is stdio/control only
(`Sources/SemantouchCLIKit/Packaging.swift` `tccOwnershipDescription`).

### Check for and install updates

The CLI doctor report can check GitHub's latest published release without changing its
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

Whole-app updates replace the entire `Semantouch.app` bundle after checksum + app
verification; nested Mach-O replacement is refused
(`Sources/ComputerUseService/UpdateService.swift`). Preference order for installs is
`/Applications/Semantouch.app` then `~/Applications/Semantouch.app`. Restart OMP after an
update.

For local development, `just omp-install` (when present) builds the release products,
links the checkout with `omp plugin link .`, and runs the read-only doctor check.

## Manual install of the next-release app ZIP

When a release publishes `Semantouch-v<version>-macos-universal2.zip`:

```sh
# Example for a future tag that ships the universal2 ZIP:
gh release download vX.Y.Z \
  --pattern 'Semantouch-v*-macos-universal2.zip' \
  --pattern 'Semantouch-v*-macos-universal2.zip.sha256'
shasum -a 256 -c Semantouch-vX.Y.Z-macos-universal2.zip.sha256
ditto -x -k "Semantouch-vX.Y.Z-macos-universal2.zip" "$HOME/Applications"
# optional system-wide:
# sudo ditto -x -k "Semantouch-vX.Y.Z-macos-universal2.zip" /Applications
```

Then register the nested relay path (see §3).

## 1. Build from source

```sh
swift build -c release --product SemantouchHost
swift build -c release --product semantouch
```

Optimized binaries land under the release bin directory:

```sh
swift build -c release --show-bin-path
# e.g. /path/to/semantouch/.build/arm64-apple-macosx/release
```

Products:

- `SemantouchHost` — resident app host (TCC owner; engines).
- `semantouch` — nested stdio/control relay (no engines, no TCC frameworks;
  `Package.swift`).

Verify:

```sh
"$(swift build -c release --show-bin-path)/semantouch" --version
# semantouch 0.3.2 (contract semantouch/1, MCP 2025-06-18)
```

For a distribution-shaped layout, assemble/sign with the release scripts
(`scripts/assemble-app`, `scripts/sign-release`, `scripts/verify-app-release`) — see
[RELEASE.md](RELEASE.md). Local `swift build` products are not notarized.

### Where to put the binary / app

TCC grants are keyed to the **signed app host identity** (bundle id + code signature),
not the nested relay path. Preferred install locations:

- `/Applications/Semantouch.app`
- `~/Applications/Semantouch.app`

OMP's MCP `command` must still point at the nested public relay:

```text
…/Semantouch.app/Contents/MacOS/semantouch
```

If you later move, re-copy, or re-sign the app, macOS may treat it as a new item and you
will need to re-grant.

## 2. Grant the two macOS permissions

The signed **app host** needs two TCC grants (see [SECURITY.md](SECURITY.md) §1):

- **Accessibility** — read the target window's accessibility tree and perform AX actions.
- **Screen Recording** — capture a still of the target window (including covered windows).

Ask the host (via the relay CLI, which forwards control calls) which binary that is:

```sh
/Applications/Semantouch.app/Contents/MacOS/semantouch doctor
# or, from a release bin path during development:
"$(swift build -c release --show-bin-path)/semantouch" doctor
```

Example shape (paths vary by install):

```
helper:          /Applications/Semantouch.app/Contents/MacOS/SemantouchHost
  signed:        true
  version:       0.3.2
accessibility:   denied
screenRecording: denied
ready:           false
remediation:
  - Grant Accessibility: open System Settings › Privacy & Security › Accessibility and enable "…/SemantouchHost".
  - Grant Screen Recording: open System Settings › Privacy & Security › Screen Recording and enable "…/SemantouchHost".
  - Restart "…/SemantouchHost" so the new grants take effect.
```

`doctor` is **read-only** by default: it reports status without triggering an OS prompt
(preflight APIs only; `Sources/ComputerUseService/DoctorService.swift`). Follow the
`remediation` lines exactly — the `helper:` path is the item to add under each pane:

1. Open **System Settings › Privacy & Security › Accessibility**, click **+**, and add
   the reported host path (or the `Semantouch.app` bundle; in the file picker, press ⌘⇧G
   and paste the path).
2. Do the same under **System Settings › Privacy & Security › Screen Recording**.
3. Fully quit and relaunch the host (or restart OMP) so the grants take effect.

Re-run `doctor` until it reads:

```
accessibility:   granted
screenRecording: granted
ready:           true
```

`doctor` (CLI subcommand and MCP `doctor` tool) is the sanctioned onboarding check. When
a required grant is missing at call time, tools fail with the structured
`permission_denied` error naming the exact host path — they never silently degrade.

> If a grant that you added does not "stick", it is almost always because the granted path
> or signature no longer matches the running host. Re-check `doctor`'s `helper:` line
> against what you granted. Granting only the nested `semantouch` relay is incorrect for
> the app-host model.

## 3. Register with OMP

OMP launches stdio MCP servers described by an `MCPStdioServerConfig`
(`{ type?, command, args?, env?, cwd? }` plus an optional `timeout`). Generate the block
for your install with the helper itself:

```sh
/Applications/Semantouch.app/Contents/MacOS/semantouch config
```

```json
{"mcpServers":{"semantouch":{"args":["mcp"],"command":"/Applications/Semantouch.app/Contents/MacOS/semantouch","timeout":30000,"type":"stdio"}}}
```

The `command` is auto-resolved to the running relay binary (absolute, symlink-resolved).
To pin a specific install path instead, pass `--path`:

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

Once OMP launches the relay as `semantouch mcp`, it speaks MCP over stdio to the host.
Confirm OMP lists the **sixteen** tools:

`doctor`, `list_apps`, `launch_app`, `get_app_state`, `read_text`, `screenshot`,
`end_app_session`, `click`, `perform_action`, `set_value`, `select_text`, `scroll`,
`press_key`, `type_text`, `drag`, `wait_for`

— see [USAGE.md](USAGE.md) and `Sources/MCPServer/ToolCatalog.swift`.

## 4. (Optional) Deny apps

By default the server is **permissive**: no application is denied by app policy. To
block specific apps for both reads and mutations, set `SEMANTOUCH_DENIED_APPS`
(comma-separated exact, case-insensitive tokens: bundle id, display name, full path, or
path basename) in the server's `env`. Unset or empty denies nothing. There is no mutation
allowlist and no built-in hard-denied app set. See [USAGE.md](USAGE.md) "App policy" and
[SECURITY.md](SECURITY.md) §2.
