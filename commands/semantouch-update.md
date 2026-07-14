---
description: Update the Semantouch helper to the latest verified GitHub release.
---

Treat this command invocation as explicit authorization to replace the installed Semantouch helper binary with the latest published GitHub release.

Invoke the `semantouch` MCP server's `doctor` tool with `requestOnboarding: false` and copy its exact `helper.path`. Run that exact executable with `update --json`; do not substitute another Semantouch binary, download release assets manually, or modify the OMP plugin installation. If the MCP server is unavailable, read `skill://semantouch-setup`, resolve the installed helper path using the documented launcher order, verify it with `--version`, and then run its `update --json` command.

After a successful update, run the same helper path with `doctor --json`. Verify and report:

- whether a binary was installed or it was already current;
- previous and installed versions;
- the exact helper path;
- the follow-up update status (`up_to_date` is success; `unknown` means GitHub could not be rechecked);
- Accessibility and Screen Recording status independently;
- that OMP or any other running Semantouch client must be restarted to load an installed update.

On any network, checksum, version, execution, or replacement failure, stop and report the exact error. Do not fall back to `curl`, `sudo`, permission changes, a different install path, or an unverified binary.
