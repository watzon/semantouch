# Semantouch cross-platform runtime (Rust)

Self-contained Windows/Linux runtime foundation under `runtime/**`. macOS remains the Swift reference implementation; this workspace implements the **same 16-tool public contract** behind one coordinator and platform adapters.

## Crates

| Crate | Role |
|---|---|
| `semantouch-protocol` | Wire DTOs, 16-tool catalog, error codes, capabilities |
| `semantouch-adapter` | Neutral `PlatformAdapter` trait (discovery, tree, capture, input) |
| `semantouch-core` | Shared coordinator: sessions, revisions, stable IDs, diffs, policy, waits, action evidence |
| `semantouch-windows` | Real UI Automation observation/actions + native input (`cfg(windows)`); window capture remains capability-gated |
| `semantouch-linux` | Real AT-SPI observation/actions + X11 capture/input; Wayland portal paths remain capability-gated (`cfg(linux)`) |
| `semantouch-runtime` | Host facade that wires the coordinator to the active adapter |

## Host tests (this machine / macOS)

Shared semantics are exercised without Windows/Linux SDKs:

```bash
cd runtime
cargo test -p semantouch-protocol -p semantouch-core -p semantouch-adapter -p semantouch-runtime
```

`default-members` excludes the platform crates so macOS CI does not need Windows/Linux toolchains.

## Target compile checks

### Windows (x86_64 / aarch64)

Requires a Windows host or cross toolchain with the Windows SDK headers that the `windows` crate binds:

```bash
cd runtime
cargo check -p semantouch-windows --target x86_64-pc-windows-msvc
cargo check -p semantouch-windows --target aarch64-pc-windows-msvc
cargo check -p semantouch-runtime --target x86_64-pc-windows-msvc
```

Cross-compiling from macOS additionally needs the MSVC linker + Windows SDK (or `x86_64-pc-windows-gnu` with mingw). Without those, expect link errors — not source stubs.

### Linux (x86_64 / aarch64)

Requires AT-SPI/D-Bus development libraries for a full link (`libatspi`, `libdbus`), plus X11 headers when building the X11 capture/input path:

```bash
cd runtime
cargo check -p semantouch-linux --target x86_64-unknown-linux-gnu
cargo check -p semantouch-linux --target aarch64-unknown-linux-gnu
cargo check -p semantouch-runtime --target x86_64-unknown-linux-gnu
```

Wayland capture/input is **capability-gated** at runtime via XDG Desktop Portal probes. Unsupported portal/compositor operations return typed `CapabilityResult` / `unsupported_action` / `screenshot_unavailable` — never a black frame or fake success.

## Observation contract

- Windows discovers live HWNDs, keeps every `IUIAutomationElement` on one STA
  worker, and exposes only stable native tokens to the shared coordinator.
- Linux discovers applications from the AT-SPI registry, resolves their D-Bus
  owners to PIDs, and walks real Accessible/Component/Action/Text/Value
  interfaces.
- Both walkers stop at depth 40 or 2,000 nodes. A broken child is skipped
  without fabricating a node.
- `scopeElementId` re-roots a snapshot only when its native handle is still
  live. A stale, foreign, or unreachable scope degrades to an unscoped
  snapshot with `scope_ignored`; it never silently claims the scope was used.
- Scoped snapshots are full trees, retire the previous element-ID space, and
  break diff lineage so the next unscoped snapshot is a full reset.

## Support claims

- **Not GA.** This is a coordinator + adapter foundation.
- Public tool surface: the same 16 tools as macOS (`doctor` … `wait_for`).
- Cross-platform success may only be claimed for implemented/tested paths on interactive Windows/Linux fixtures.
- Wayland remains compositor/portal capability-gated until proven.
