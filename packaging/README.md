# packaging/

OMP-facing packaging artifacts for the `semantouch` helper. Everything here is
**generated from the built binary** — the binary is the single source of truth for the
version (`MCPServer.serverVersion`), the tool list (`ToolCatalog`), and the required TCC
permissions. Do not hand-edit; regenerate with the commands below.

## Files

| File | What it is | Regenerate with |
|---|---|---|
| `semantouch.plugin.json` | Plugin manifest: identity, version, tool list, minimum macOS, required TCC grants, and the stdio launch shape. | `semantouch config --manifest --path "<install path>"` |
| `omp-mcp-config.example.json` | Example OMP `mcpServers` block a user merges into their OMP config. | `semantouch config --path "<install path>"` |

The checked-in copies are pretty-printed (2-space indent, sorted keys) for readability.
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

## Bundle id is a placeholder

`bundleId` in the manifest is `dev.watzon.semantouch` — a **neutral placeholder**.
It is deliberately not `com.openai.*` or `com.apple.*` (clean-room / no-masquerade,
SECURITY.md §5). Replace it with the real publisher identity when a signing certificate
exists; see docs/RELEASE.md. `bundleIdIsPlaceholder: true` flags this in the manifest.
