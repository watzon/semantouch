# Getting started

Semantouch is a native macOS computer-use helper: a single, dependency-free Swift binary
that any compatible harness can launch as a **stdio MCP server** (`semantouch mcp`). It gives
an agent per-window screen capture (including covered windows), a compact accessibility
tree with stable element ids, semantic accessibility actions, incremental tree diffs,
guarded native input fallback, and a decorative virtual-cursor overlay.

The project [`README.md`](../README.md) covers the product, quick start, and
main workflows. The documents below provide installation, usage, protocol, and
implementation detail.

## Read in this order

1. **[INSTALL.md](INSTALL.md)** — released OMP plugin installation, the verified helper
   download, Accessibility + Screen Recording grants, and the manual source-build / MCP
   configuration fallback.
2. **[USAGE.md](USAGE.md)** — the fourteen MCP tools with request/response examples, the
   `get_app_state`-once-per-turn discipline, the revision / stale-id contract, the
   interference policy, and the optional app denylist (`SEMANTOUCH_DENIED_APPS`).
3. **[PROTOCOL.md](PROTOCOL.md)** — the frozen wire contract (`semantouch/1`). This is
   normative and **overrides the README** on any wire-level detail.

## Reference

- **[SECURITY.md](SECURITY.md)** — permission model, app/action policy, the operator
  denylist, prompt-injection stance, and clean-room constraints.
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — module layout and how capture / accessibility /
  action / overlay engines fit together.
- **[RELEASE.md](RELEASE.md)** — Developer ID signing, notarization credentials, local
  Pindrop-style recipes, and the signed GitHub release workflow.
- **[FIXTURE.md](FIXTURE.md)** / **[TEST-MATRIX.md](TEST-MATRIX.md)** — the test fixture app
  and the verification matrix.
- **[`../packaging/`](../packaging/)** — the generated OMP plugin manifest and example MCP
  config, and how to regenerate them.

## Command-line interface

```
semantouch mcp                 # run the stdio MCP server
semantouch doctor [--json]     # report Accessibility / Screen Recording status
semantouch list-apps [--json]  # list running apps and window counts
semantouch config [options]    # print an MCP server config / plugin manifest
semantouch probe <kind> ...    # run low-level capture and accessibility diagnostics
semantouch --version           # print the helper version
```

`mcp` owns stdout for framed JSON-RPC only; every other subcommand writes its result to
stdout and logs to stderr. `config` is the one generator that prints JSON to stdout by
design (it is not the MCP channel).
