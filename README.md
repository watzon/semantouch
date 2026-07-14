# Semantouch

Native macOS computer use for MCP clients.

Semantouch is a dependency-free Swift helper that combines ScreenCaptureKit window
capture with the macOS Accessibility API. It exposes compact UI state and native actions
through a stdio [Model Context Protocol](https://modelcontextprotocol.io/) server, with an
included [OMP](https://github.com/can1357/oh-my-pi) plugin.

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
- Fourteen MCP tools for discovery, observation, interaction, waiting, and cleanup
- A standalone CLI plus OMP skills, diagnostics, and MCP configuration

Semantouch uses public Apple APIs and does not depend on private frameworks or
proprietary computer-use binaries.

## Requirements

- Apple Silicon Mac
- macOS 14.4 or later
- [OMP](https://github.com/can1357/oh-my-pi)
- Network access the first time a released helper version starts

A Swift toolchain and `just` are needed only for source builds and development.

## Install with OMP

Install a tagged release directly:

```sh
omp plugin install github:watzon/semantouch#v0.2.0
```

Alternatively, add this repository as a marketplace and install its catalog entry:

```sh
omp plugin marketplace add watzon/semantouch
omp plugin install semantouch@semantouch
```

Restart OMP. On the first MCP launch, the plugin downloads the matching Developer
ID-signed and notarized `semantouch-macos-arm64` release asset, verifies its SHA-256
checksum, and caches it at:

```text
~/Library/Application Support/Semantouch/0.2.0/semantouch
```

The plugin provides `.mcp.json`, the `semantouch` and `semantouch-setup` skills, and the
`/semantouch-doctor` command. Verify the integration:

```text
/mcp list
/mcp test semantouch
/semantouch-doctor
```

Grant the exact downloaded binary both permissions reported by `doctor`:

- **Accessibility** — System Settings → Privacy & Security → Accessibility
- **Screen Recording** — System Settings → Privacy & Security → Screen Recording

> [!NOTE]
> macOS privacy grants are tied to the executable's path and code signature. A new
> Semantouch release uses a versioned path and can require granting permission again.

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

The checked-in [`.mcp.json`](.mcp.json) resolves a bundled helper, downloads and verifies
the matching release helper, or uses the development install at `~/.omp/bin/semantouch`
as appropriate. Set `SEMANTOUCH_BIN` to force an exact executable path. The generated
release packaging examples use `/Applications/Semantouch.app/Contents/MacOS/semantouch`.

## MCP tools

| Category | Tools |
| --- | --- |
| Diagnostics and discovery | `doctor`, `list_apps` |
| State and capture | `get_app_state`, `screenshot`, `end_app_session` |
| Semantic interaction | `click`, `perform_action`, `set_value`, `select_text` |
| Input and synchronization | `scroll`, `press_key`, `type_text`, `drag`, `wait_for` |

Call `get_app_state` before targeting elements. Element IDs belong to one app session and
revision; stale IDs are rejected instead of being applied to a different control.
Use `screenshot` when only pixels are needed—it does not advance the accessibility-tree
revision.

For schemas, examples, revision semantics, and focus behavior, read
[Usage](docs/USAGE.md). The normative wire contract is [Protocol](docs/PROTOCOL.md).

## Command-line interface

| Command | Purpose |
| --- | --- |
| `semantouch mcp` | Run the stdio MCP server. Standard output is reserved for JSON-RPC. |
| `semantouch doctor [--json]` | Report Accessibility and Screen Recording status. |
| `semantouch list-apps [--json]` | List running applications and their window counts. |
| `semantouch config [options]` | Generate an MCP server config or plugin manifest. |
| `semantouch probe <kind> ...` | Run low-level capture and accessibility diagnostics. |
| `semantouch --version` | Print the helper, contract, and MCP protocol versions. |

Run `semantouch --help` for all `config` and `probe` options.

## Runtime configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `SEMANTOUCH_BIN` | Released or bundled helper | Overrides helper discovery with an exact executable path. |
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
SemantouchCLI ── MCPServer ── ComputerUseService
                                  ├── AccessibilityEngine
                                  ├── CaptureEngine
                                  ├── ActionEngine
                                  ├── CursorOverlay
                                  └── ComputerUseCore
```

The protocol process keeps standard output clean for MCP traffic; diagnostics go to
standard error. Engine modules isolate Accessibility, ScreenCaptureKit, input, and overlay
work behind shared DTOs and session policy.

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

## Documentation

- [Getting started](docs/OVERVIEW.md)
- [Installation and permissions](docs/INSTALL.md)
- [Tool usage](docs/USAGE.md)
- [Wire protocol](docs/PROTOCOL.md)
- [Security model](docs/SECURITY.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Test fixture](docs/FIXTURE.md) and [verification matrix](docs/TEST-MATRIX.md)
- [Signing and release process](docs/RELEASE.md)
