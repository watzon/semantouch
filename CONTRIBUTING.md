# Contributing to Semantouch

Thanks for helping improve Semantouch. This document is the contributor workflow
and the acceptance bar for changes. English `README.md` is canonical product docs;
`README.zh-CN.md` must keep section-level parity when README content changes.

## Before you start

1. Read [docs/OVERVIEW.md](docs/OVERVIEW.md), [docs/SECURITY.md](docs/SECURITY.md), and
   the normative wire contract [docs/PROTOCOL.md](docs/PROTOCOL.md).
2. Prefer a focused change with a clear observable contract.
3. Do not invent platform support, installers, or security guarantees. If evidence is
   missing, say so or leave the claim out.

## Development setup

```sh
swift build
swift test
just build
just test
```

A Swift 6 toolchain and `just` are enough for ordinary offline work. Live Accessibility /
Screen Recording proofs need an interactive macOS session and explicit grants to the
identity reported by `semantouch doctor`.

## Contribution workflow

1. Branch from current `main` (or the active integration branch for multi-agent work).
2. Keep changes scoped. Avoid drive-by refactors, dependency additions, and unrelated
   formatting churn.
3. Update docs only when behavior users rely on actually changes.
4. If you change the public MCP surface, update protocol goldens, schemas, packaging
   tool lists, and both README languages in the same change set when those files are in
   scope.
5. Open a pull request with:
   - what changed and why
   - how you verified it
   - any intentional doc/code lag (for example concurrent packaging work)
   - risk notes for permissions, input delivery, or release assets

Use the pull request template. Prefer issue templates when filing bugs or features.

## Focused acceptance expectations

Every non-trivial PR should defend an observable contract:

- **Behavior, not plumbing.** Tests fail on a plausible bug in the user-visible or
  wire-visible outcome.
- **Stale IDs and revisions.** Element actions remain bound to `sessionId` + `revision` +
  `elementId`. Stale cases reject; they do not guess.
- **Diff integrity.** Where diffs exist, `apply(base, diff) == fresh` remains true.
- **Policy before dispatch.** Denylist / confirmation / tool-disabled checks happen before
  AX, capture, or input work.
- **Evidence honesty.** Fallback input reports real lane, interruption, focus change,
  restoration, and target verification. No acknowledgement must not be reported as
  confirmed delivery.
- **Permission-free default suite.** Ordinary CI tests must not require TCC grants.
  Permission-dependent proofs are separate and must report blocked remediation clearly.

Run the smallest focused tests that cover your change, then the permission-free package
suite when the surface is shared.

## Protocol compatibility

- `docs/PROTOCOL.md` wins on wire detail.
- Additive changes are preferred over renames or silent meaning shifts.
- Disabled tools are omitted from `tools/list` and answer with the structured
  `policy_denied` / `tool_disabled` shape when called.
- Keep stdout reserved for framed JSON-RPC on `semantouch mcp`. Generator/CLI result
  payloads may use stdout only for non-`mcp` subcommands.

## Permission and TCC safety

- Only the signed app host is allowed to own Accessibility and Screen Recording work.
- Do not move TCC-owning calls into the nested relay, ad-hoc scripts, or temporary helper
  paths without an explicit packaging design review.
- `doctor` must remain the sanctioned grant reporter and must name the exact identity to
  authorize.
- Do not trigger OS permission prompts unless the caller explicitly requests onboarding.
- Never claim grants persist across identities or raw helper path changes.

## Hard rules

- **No stdout diagnostics on the MCP channel.** Logging goes to stderr.
- **No private APIs.** Public Apple APIs and documentation only. No SkyLight, no
  undocumented `CGS*`, no `_AXUIElementGetWindow`, no private SPI.
- **No destructive git.** Do not force-push shared branches, rewrite published history,
  or delete user work. Do not commit or push unless the maintainer workflow asks for it.
- **No secret leakage.** Redact tokens, app-specific passwords, notary credentials, and
  local absolute home paths in issues, logs, and fixtures.
- **No silent capability lies.** Capture/input limitations return typed errors or
  capability results; never black frames or false `completed` success.

## Platform adapter parity

Windows and Linux work, when added, must implement the same public contract as macOS:

- the full enabled tool surface, not a reduced subset
- stable IDs, revision checks, reconstructable diffs, waits, policy, and interference
  evidence
- typed capability gaps for compositor/session limitations (especially Wayland)

A platform PR that cannot meet parity should land behind an explicit experimental flag and
must not weaken the macOS contract.

## Documentation parity

When editing user-facing README content:

1. Update `README.md` first (canonical).
2. Mirror the same major sections, warnings, tool list, install paths, links, and
   behavioral caveats in `README.zh-CN.md`.
3. Keep bidirectional language navigation near the top of both files.
4. Do not claim npm, Homebrew, Intel-only caveats, Windows, or Linux GA without current
   release/install evidence.

## Reporting security issues

Prefer private maintainer contact for exploitable local-privilege or supply-chain issues.
For ordinary permission bugs, use the macOS/runtime issue form and omit secrets.

## License

By contributing, you agree that your contributions are licensed under the MIT License
covering this repository.
