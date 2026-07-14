# packaging/

OMP-facing packaging artifacts for the `semantouch` helper. The JSON files are generated
from the built binary, which is the single source of truth for the version
(`MCPServer.serverVersion`), tool list (`ToolCatalog`), and required TCC permissions.
`Release.entitlements` is the small, hand-maintained signing input.

## Files

| File | What it is | Regenerate with |
|---|---|---|
| `semantouch.plugin.json` | Plugin manifest: identity, version, tool list, minimum macOS, required TCC grants, and the stdio launch shape. | `semantouch config --manifest --path "<install path>"` |
| `omp-mcp-config.example.json` | Example OMP `mcpServers` block a user merges into their OMP config. | `semantouch config --path "<install path>"` |
| `Release.entitlements` | Minimal Hardened Runtime entitlements used for Developer ID signing. This file is maintained by hand. | N/A |

The checked-in JSON files are pretty-printed (2-space indent, sorted keys) for readability.
The `config` subcommand itself emits **compact canonical JSON** (one line, sorted keys,
no trailing newline) — semantically identical. To reproduce a checked-in file exactly:

```sh
semantouch config --manifest --path "/Applications/Semantouch.app/Contents/MacOS/semantouch" \
  | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin),indent=2,sort_keys=True,ensure_ascii=False))'
```

## The `config` subcommand

```
semantouch config [options]
  --path FILE     command path to embed (default: this running binary, symlink-resolved)
  --cwd DIR       working directory field (default: omitted)
  --name KEY      mcpServers key (default: semantouch)
  --timeout MS    OMP client timeout in ms (default: 30000)
  --bare          emit just the MCPStdioServerConfig object (no mcpServers wrapper)
  --manifest      emit the plugin manifest instead of the server config
```

`config` is the **one** CLI path that prints JSON to stdout by design — it is an explicit
generator, not the MCP channel. The `mcp` subcommand still owns stdout for framed
JSON-RPC only; all logging goes to stderr (PROTOCOL.md §1).

## Publisher identity

`bundleId` in the manifest is the owned publisher identifier
`tech.watzon.semantouch`; `bundleIdIsPlaceholder` is `false`. Keep it aligned with the
`--identifier` value in `scripts/sign-release` and the release workflow. See
[`docs/RELEASE.md`](../docs/RELEASE.md) for certificate and notarization setup.
