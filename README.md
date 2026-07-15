# Semantouch

[English](README.md) | [简体中文](README.zh-CN.md)

Native macOS computer use for MCP clients.

Semantouch is a dependency-free Swift helper that combines ScreenCaptureKit window
capture with the macOS Accessibility API. It exposes compact UI state and native actions
through a stdio [Model Context Protocol](https://modelcontextprotocol.io/) server, with an
included [OMP](https://github.com/can1357/oh-my-pi) plugin.

[DeepWiki](https://deepwiki.com/watzon/semantouch) ·
[Star history](https://www.star-history.com/#watzon/semantouch&Date) ·
[Releases](https://github.com/watzon/semantouch/releases)

> [!IMPORTANT]
> Semantouch can observe and control native applications. Review the
> [security model](docs/SECURITY.md), configure an app denylist where appropriate, and
> require human confirmation before consequential actions.

## What it provides

- Per-window capture, including windows covered by other windows
- Compact accessibility trees with stable element IDs
- Full snapshots followed by incremental tree diffs
- Semantic accessibility actions for buttons, values, selections, and text
- Guarded keyboard and pointer fallback when semantic actions are unavailable
- User-interruption detection during synthesized input
- A nonactivating virtual-cursor overlay that never gates action correctness
- MCP tools for discovery, launch, observation, full-text reads, interaction, waiting, and cleanup
- A standalone CLI plus OMP skills, diagnostics, and MCP configuration

Semantouch uses public Apple APIs and does not depend on private frameworks or
proprietary computer-use binaries.

## Requirements

- macOS 14.0 or later
- Apple Silicon or Intel Mac (universal2 release target)
- [OMP](https://github.com/can1357/oh-my-pi) for the plugin install path
- Network access for released-app downloads and GitHub update checks

A Swift toolchain and `just` are needed only for source builds and development.

> [!NOTE]
> **v0.2.1** is the final legacy arm64-helper release. **v0.3.3 and later**
> publish a signed/notarized universal2 **`Semantouch.app`** as ZIP and DMG
> artifacts; the npm and Homebrew installers consume that same immutable app ZIP.

## Install with OMP

Install a tagged release directly:

```sh
omp plugin install github:watzon/semantouch#v0.3.6
```

Alternatively, add this repository as a marketplace and install its catalog entry:

```sh
omp plugin marketplace add watzon/semantouch
omp plugin install semantouch@semantouch
```

Restart OMP. On first MCP launch the plugin launcher resolves a local
`Semantouch.app` if present, otherwise downloads the matching signed app ZIP for the
plugin version, verifies its SHA-256 checksum, and installs under:

```text
~/Applications/Semantouch.app
```

When both system and user installs exist, the launcher prefers:

```text
/Applications/Semantouch.app
```

MCP clients talk to the nested relay:

```text
…/Semantouch.app/Contents/MacOS/semantouch
```

Accessibility and Screen Recording are owned by the signed app host
(`tech.watzon.semantouch` / `SemantouchHost`), not by the nested relay.

The plugin provides `.mcp.json`, the `semantouch` and `semantouch-setup` skills, and the
`/semantouch-doctor` command. Verify the integration:

```text
/mcp list
/mcp test semantouch
/semantouch-doctor
```

Grant the exact identity reported by `doctor`:

- **Accessibility** — System Settings → Privacy & Security → Accessibility
- **Screen Recording** — System Settings → Privacy & Security → Screen Recording

> [!NOTE]
> macOS privacy grants are tied to code signature and app identity. Whole-app updates that
> preserve the same signed `Semantouch.app` identity are intended to keep grants. A new
> raw helper path or a re-signed identity can require granting permission again. Always
> re-check `doctor` after an upgrade.

See [Installation](docs/INSTALL.md) for permission troubleshooting, marketplace upgrades,
source installation, and manual MCP configuration.

## Build and run manually

Build an optimized executable:

```sh
swift build -c release
SEMANTOUCH="$(swift build -c release --show-bin-path)/semantouch"
"$SEMANTOUCH" --version
"$SEMANTOUCH" doctor
```

Generate an MCP configuration that points to that exact binary:

```sh
"$SEMANTOUCH" config
```

Or run the stdio server directly from an MCP client configuration:

```json
{
  "mcpServers": {
    "semantouch": {
      "type": "stdio",
      "command": "/absolute/path/to/semantouch",
      "args": ["mcp"],
      "timeout": 30000
    }
  }
}
```

The checked-in [`.mcp.json`](.mcp.json) resolves the plugin launcher, a development
install, or `SEMANTOUCH_BIN`. Generated packaging examples use
`/Applications/Semantouch.app/Contents/MacOS/semantouch`.

## MCP tools

`tools/list` currently exposes these tools (catalog order):

| Category | Tools |
| --- | --- |
| Diagnostics and discovery | `doctor`, `list_apps`, `launch_app` |
| State and capture | `get_app_state`, `read_text`, `screenshot`, `end_app_session` |
| Semantic interaction | `click`, `perform_action`, `set_value`, `select_text` |
| Input and synchronization | `scroll`, `press_key`, `type_text`, `drag`, `wait_for` |

Call `get_app_state` before targeting elements. Element IDs belong to one app session and
revision; stale IDs are rejected instead of being applied to a different control.
Use `screenshot` when only pixels are needed—it does not advance the accessibility-tree
revision. Use `read_text` when a tree field is truncated at the 256-byte cap and you need
the full value of one revision-checked element. Use `launch_app` only for explicit,
policy-gated launch/recovery—ordinary app resolution never starts an app.

For schemas, examples, revision semantics, and focus behavior, read
[Usage](docs/USAGE.md). The normative wire contract is [Protocol](docs/PROTOCOL.md).

## Safety and stale-ID behavior

- Element actions require `{ app, sessionId, revision, elementId }`. A mismatched revision
  returns `stale_revision`; an unknown id returns `stale_element`. Refresh with
  `get_app_state` and retarget—never reuse or invent ids.
- Fallback input defaults to `background-only`: deliver only when the target is already
  frontmost, otherwise `focus_required` with nothing delivered.
- User interruption during synthesized input cancels the remainder and returns
  `status: "interrupted"`.
- Observed UI text and screenshots are untrusted data, never authorization.
- Configure `SEMANTOUCH_DENIED_APPS` for operator denials. A denylist is not a substitute
  for action-time human confirmation.

Details: [Security](docs/SECURITY.md).

## Command-line interface

| Command | Purpose |
| --- | --- |
| `semantouch mcp` | Relay stdio MCP to the resident app host. Standard output is reserved for JSON-RPC. |
| `semantouch call …` | Invoke one MCP tool or a sequence over one host session. |
| `semantouch doctor [--json]` | Report permissions and GitHub update availability. |
| `semantouch update [--json]` | Publisher-, checksum-, and version-verify the latest whole-app release, then install it. |
| `semantouch list-apps [--json]` | List applications and their window counts. |
| `semantouch config [options]` | Generate an MCP server config or plugin manifest. |
| `semantouch probe <kind> …` | Run low-level capture and accessibility diagnostics. |
| `semantouch --version` | Print the helper, contract, and MCP protocol versions. |

`doctor` remains successful when GitHub is unavailable and reports the update status as
`unknown`. Agent workflows never treat an available release as permission to update:
they stop and ask the user to choose **Update now** or **Continue without updating**
before doing anything else.

`update` writes progress and failures to standard error; `--json` keeps its result on
standard output for agents. A successful update takes effect when Semantouch clients
restart. Run `semantouch --help` for all `config`, `call`, and `probe` options.

## Runtime configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `SEMANTOUCH_BIN` | Released or bundled helper | Overrides helper discovery with an exact executable path in development flows. |
| `SEMANTOUCH_DENIED_APPS` | Empty | Comma-separated exact app identifiers, names, paths, or path basenames to block. |
| `SEMANTOUCH_CURSOR` | `on` | Sets the virtual cursor to `off`, `dim`, or `on`. |
| `SEMANTOUCH_WEB_AX` | Enabled | Set to `off` to disable automatic Chromium/Electron accessibility enablement. |
| `SEMANTOUCH_TRACE` | Off | Set to `1` for diagnostic tracing on standard error. |

The app denylist is case-insensitive and applies to both reads and mutations. It is empty
by default. Example:

```json
{
  "env": {
    "SEMANTOUCH_DENIED_APPS": "com.apple.Terminal,Terminal,com.apple.keychainaccess,Keychain Access"
  }
}
```

A denylist is not a substitute for action-time approval. UI text and screenshot content
must be treated as untrusted data, never as authorization to perform an action.

## Architecture

```text
MCP client
    │  stdio JSON-RPC
    ▼
semantouch (relay) ── private socket ── SemantouchHost
                                            ├── MCPServer / ComputerUseService
                                            ├── AccessibilityEngine
                                            ├── CaptureEngine
                                            ├── ActionEngine
                                            ├── CursorOverlay
                                            └── ComputerUseCore
```

The protocol process keeps standard output clean for MCP traffic; diagnostics go to
standard error. Engine modules isolate Accessibility, ScreenCaptureKit, input, and overlay
work behind shared DTOs and session policy. The nested relay does not hold TCC grants.

See [Architecture](docs/ARCHITECTURE.md) for module boundaries and threading rules.

## Development

Common tasks are available through `just`:

```sh
just build       # debug build
just test        # Swift test suite
just release     # optimized build
just packaging   # regenerate checked-in OMP packaging examples
```

`just packaging` intentionally generates release-layout examples for
`/Applications/Semantouch.app/Contents/MacOS/semantouch`. Do not hand-edit the generated
JSON files in [`packaging/`](packaging/).

Contribution expectations, permission/TCC safety, protocol compatibility, and platform
adapter parity are documented in [CONTRIBUTING.md](CONTRIBUTING.md).

## Platform status

| Surface | Status |
| --- | --- |
| macOS 14.0+ Accessibility + ScreenCaptureKit | Supported target |
| universal2 (`arm64` + `x86_64`) app packaging | In-tree release contract |
| Windows | Planned; not released |
| Linux / Wayland | Planned / compositor-capability-gated; not released |
| npm / Homebrew installers | Experimental or in progress; not claimed as GA here |

Capability limitations must surface as typed results, never as silent empty captures or
false success.

## Documentation

- [Getting started](docs/OVERVIEW.md)
- [Installation and permissions](docs/INSTALL.md)
- [Tool usage](docs/USAGE.md)
- [Wire protocol](docs/PROTOCOL.md)
- [Security model](docs/SECURITY.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Test fixture](docs/FIXTURE.md) and [verification matrix](docs/TEST-MATRIX.md)
- [Signing and release process](docs/RELEASE.md)
- [Contributing](CONTRIBUTING.md)
- [Code of conduct](CODE_OF_CONDUCT.md)
- [简体中文 README](README.zh-CN.md)

## License

[MIT](LICENSE)
