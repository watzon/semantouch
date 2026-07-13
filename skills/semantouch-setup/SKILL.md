---
name: semantouch-setup
description: This skill should be used when the user asks to "install Semantouch", "set up macOS computer use", "fix Semantouch permissions", "debug a permission_denied error", "run semantouch doctor", or troubleshoot why the Semantouch MCP server will not start in OMP.
version: 0.1.0
---

# Semantouch Setup

Install and diagnose the Semantouch OMP integration without weakening its permission or app-policy boundaries.

## Local OMP installation

From the repository root, run:

```sh
just omp-install
```

Expect this recipe to:

1. Build the optimized Swift executable.
2. Install it at the stable path `~/.omp/bin/semantouch`.
3. Link the repository as the `semantouch` plugin with `omp plugin link .`.
4. Run the installed binary's non-prompting `doctor` check.

Restart OMP after installing or changing `.mcp.json`, then inspect `/mcp list` and run `/mcp test semantouch` when interactive MCP diagnostics are available.

The plugin's `.mcp.json` starts the default binary at `~/.omp/bin/semantouch`. To use another binary without editing the plugin, start OMP with `SEMANTOUCH_BIN` set to that executable's absolute path.

## Diagnose in order

1. Confirm the plugin is linked with `omp plugin list`.
2. Confirm the executable exists at the path selected by `.mcp.json`.
3. Run the exact executable directly:

   ```sh
   ~/.omp/bin/semantouch --version
   ~/.omp/bin/semantouch doctor
   ```

4. Restart or reload OMP so it rediscovers the plugin's MCP definition.
5. Use `/mcp list` to confirm the `semantouch` server source and `/mcp test semantouch` to exercise its stdio handshake.
6. Call the MCP server's `doctor` tool and compare its `helper.path` with the executable that received macOS permissions.

Do not debug tool behavior until the server connects and `doctor` reports the required grants independently.

## macOS permissions

The helper requires:

- **Accessibility** to read the target application's accessibility hierarchy and perform semantic actions.
- **Screen Recording** to capture target-window images through ScreenCaptureKit.

Run `doctor` without onboarding first. Read `helper.path`, `accessibility`, `screenRecording`, `ready`, and `remediation`. Grant permissions to the exact path reported by `helper.path` under **System Settings → Privacy & Security**.

Do not attempt to automate System Settings privacy panes. Security and authentication surfaces are intentionally outside the Semantouch automation boundary.

After changing a grant, fully restart OMP so the MCP child process is relaunched. Re-run `doctor` until both grants are `granted` and `ready` is `true`.

TCC associates grants with the executable path and code identity. Rebuilding elsewhere, moving the binary, or changing its signature can invalidate an earlier grant. The `omp-install` recipe preserves a stable installed path, but a new build may still require the grant to be toggled or re-added. Trust the current `doctor.helper.path`, not a remembered build path.

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

- OMP lists the linked `semantouch` plugin.
- OMP discovers and connects the `semantouch` MCP server.
- The server exposes its fourteen expected tools.
- `doctor` reports the installed helper path and both required grants accurately.
- A read-only `list_apps` call succeeds.

Treat app mutation as a separate, explicit operator-policy decision rather than an installation check.
