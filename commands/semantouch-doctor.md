---
description: Diagnose the Semantouch OMP integration, MCP connection, permissions, and app policy.
---

Invoke the `semantouch` MCP server's `doctor` tool immediately with `requestOnboarding: false`. If the tool is unavailable or the server cannot start, read `skill://semantouch-setup` and diagnose only that connection failure. Report:

- the exact helper path and version;
- Accessibility and Screen Recording status independently;
- MCP discovery or launch failures separately from macOS permission failures;
- app-policy failures separately from both;
- the smallest concrete remediation step.

Do not trigger permission prompts, modify the app denylist, or automate System Settings unless the user explicitly requests the corresponding change.
