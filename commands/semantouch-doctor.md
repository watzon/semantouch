---
description: Diagnose the Semantouch OMP integration, MCP connection, permissions, and app policy.
---

Invoke the `semantouch` MCP server's `doctor` tool immediately with `requestOnboarding: false`. Use the returned exact helper path to run that helper's `doctor --json` command, which adds the read-only GitHub release check. If the MCP tool is unavailable or the server cannot start, read `skill://semantouch-setup`, resolve the exact installed helper, and run its `doctor --json` command directly.

Inspect `update.status` before performing any other diagnosis, remediation, setup, or app interaction.

If `update.status` is `available`, **stop the current workflow immediately**. Do not install the update, continue diagnosing, remediate permissions, or proceed with the user's original task. A request to run doctor, set up Semantouch, or use computer control is not authorization to update. Ask the user one blocking question with these two choices:

- **Update now** — follow the `/semantouch-update` workflow, restart affected Semantouch clients, re-run doctor, and only then resume the interrupted workflow.
- **Continue without updating** — keep the current version and resume the interrupted workflow from the doctor result.

Wait for the user's explicit choice. Never infer consent, select an option on the user's behalf, or update before receiving the answer. If an interactive question tool is unavailable, ask the same question in chat and end the turn.

When `update.status` is `up_to_date`, or after the user explicitly chooses **Continue without updating**, report:

- the exact helper path and version;
- Accessibility and Screen Recording status independently;
- update status, including the latest version when known;
- MCP discovery or launch failures separately from macOS permission failures;
- app-policy failures separately from both;
- the smallest concrete remediation step.

An `unknown` update status is not a permission or readiness failure; report the GitHub check failure and continue the diagnosis without offering an update. Do not trigger permission prompts, install an update, modify the app denylist, or automate System Settings unless the user explicitly requests the corresponding change.
