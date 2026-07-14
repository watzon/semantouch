---
name: semantouch-setup
description: This skill should be used when the user asks to "install Semantouch", "set up macOS computer use", "fix Semantouch permissions", "debug a permission_denied error", "run semantouch doctor", or troubleshoot why the Semantouch MCP server will not start in OMP.
version: 0.2.1
---

# Semantouch Setup

Install and diagnose the Semantouch OMP integration without weakening its permission or app-policy boundaries.

## Install the released plugin

Install a tagged release directly:

```sh
omp plugin install github:watzon/semantouch#v0.2.1
```

Alternatively, install through the repository marketplace:

```sh
omp plugin marketplace add watzon/semantouch
omp plugin install semantouch@semantouch
```

Restart OMP after installation. The first MCP launch downloads the matching macOS arm64
release binary, verifies its SHA-256 checksum, and caches it below
`~/Library/Application Support/Semantouch/<version>/`.

For development from a checkout, `just omp-install` builds the optimized Swift executable
at `~/.omp/bin/semantouch`, links the repository with `omp plugin link .`, and runs the
non-prompting `doctor` check.

## Resolve the helper when MCP is unavailable

Use the same launcher precedence as `.mcp.json`; do not choose the newest-looking cache directory:

1. Select the first plugin root whose `scripts/semantouch` launcher is executable: `OMP_PLUGIN_ROOT`, then `CLAUDE_PLUGIN_ROOT`, then the real (non-symlink) directory `~/.omp/plugins/node_modules/semantouch`.
2. If a launcher was selected, run `<plugin-root>/scripts/semantouch doctor --json`. The launcher itself selects `SEMANTOUCH_BIN` when set, then `<plugin-root>/bin/semantouch`, then the version from `<plugin-root>/package.json` under `${SEMANTOUCH_INSTALL_ROOT:-$HOME/Library/Application Support/Semantouch}/<version>/semantouch`. It downloads that pinned release when the cache is absent. Trust the returned `helper.path` as the exact executable.
3. If no plugin launcher exists, run `${SEMANTOUCH_BIN}` when it names an executable; otherwise try `~/.omp/bin/semantouch`. Verify the chosen executable with `--version`, then run its `doctor --json`.
4. If none of these candidates is runnable, report that update status cannot yet be checked. Perform only the minimum plugin/helper connection repair needed to obtain a runnable doctor, then return to this gate immediately before permissions or other setup work.

## Mandatory update-consent gate

Inspect `update.status` before debugging, changing permissions, restarting clients, or continuing setup. If it is `available`, stop the setup workflow immediately and ask one blocking question with exactly two choices: **Update now** or **Continue without updating**. A setup request or doctor invocation is not authorization to update.

Wait for the user's explicit answer. On **Update now**, follow `/semantouch-update`, restart affected clients, re-run doctor, and only then resume setup. On **Continue without updating**, resume with the current helper. Never infer consent, choose for the user, update automatically, or continue setup while the question is unanswered. If no interactive question tool is available, ask in chat and end the turn. An `unknown` status is not a permission or readiness failure; report the failed GitHub check and continue using the local result.

## Diagnose in order

1. Run `/semantouch-doctor` immediately. If the MCP server is unavailable, use the helper-resolution procedure above and run `doctor --json`.
2. Complete the mandatory update-consent gate before doing anything else.
3. Only after the gate allows continuation, confirm the plugin is installed and enabled with `omp plugin list`.
4. Restart OMP if needed so it rediscovers the plugin's MCP definition.
5. Use `/mcp list` to confirm the `semantouch` server source and `/mcp test semantouch` to exercise its stdio handshake.
6. Use `doctor.helper.path` as the authoritative executable path for direct `--version`, later doctor checks, and TCC grants.

Do not debug tool behavior until the gate allows continuation, the server connects, and doctor reports the required grants independently.

## macOS permissions

The helper requires:

- **Accessibility** to read the target application's accessibility hierarchy and perform semantic actions.
- **Screen Recording** to capture target-window images through ScreenCaptureKit.

Run `doctor` without onboarding first. Read `helper.path`, `accessibility`, `screenRecording`, `ready`, and `remediation`. Grant permissions to the exact path reported by `helper.path` under **System Settings → Privacy & Security**.

Do not attempt to automate System Settings privacy panes. Security and authentication surfaces are intentionally outside the Semantouch automation boundary.

After changing a grant, fully restart OMP so the MCP child process is relaunched. Re-run `doctor` until both grants are `granted` and `ready` is `true`.

TCC associates grants with the executable path and code identity. Each released version
uses a versioned cache path; rebuilding, upgrading, moving the binary, or changing its
signature can require the grant to be toggled or re-added. Trust the current
`doctor.helper.path`, not a remembered path.

## Distinguish permission, connection, and policy failures

| Symptom | Meaning | Action |
|---|---|---|
| MCP server absent | Plugin discovery/link problem | Check `omp plugin list`, `.mcp.json`, then restart OMP. |
| MCP server fails to start | Missing or non-executable helper, or stdio launch failure | Run the selected binary directly and use `/mcp test semantouch`. |
| `permission_denied` | Accessibility or Screen Recording grant missing for this helper identity | Follow `doctor.remediation` for the exact helper path. |
| `policy_denied` | Target app matches the operator denylist (`SEMANTOUCH_DENIED_APPS`), or another policy reason | Do not treat this as a TCC issue; inspect the denial reason. |
| `focus_required` | Fallback input requires the target to be frontmost | Prefer a semantic action or ask the user to foreground the target. |
| `stale_revision` / `stale_element` | Cached session state is obsolete | Refresh with `get_app_state` and retarget. |

## Operator denylist

The server is permissive by default: unset or empty `SEMANTOUCH_DENIED_APPS` denies no apps.
Operators may start OMP with `SEMANTOUCH_DENIED_APPS` set to a comma-separated list of exact,
case-insensitive tokens (bundle identifier, display name, full path, or path basename).
A match blocks both reads and mutations with `policy_denied` / `app_denied` before any
AX/CG call. There is no mutation allowlist and no built-in hard-denied app set.

Do not add an app to the denylist merely to clear an error, and do not remove a deny token
merely to silence `policy_denied`. Explain the requested capability and have the user
explicitly approve the policy change.

## Verification target

Consider setup complete only when all of these hold:

- OMP lists the installed and enabled `semantouch` plugin.
- OMP discovers and connects the `semantouch` MCP server.
- The server exposes its fourteen expected tools.
- `doctor` reports the installed helper path and both required grants accurately.
- A read-only `list_apps` call succeeds.

Treat app mutation as a separate, explicit operator-policy decision rather than an installation check.
