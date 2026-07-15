# @watzon/semantouch

Thin zero-dependency npm bootstrap for the signed **Semantouch.app** macOS helper.

This package never ships a nested TCC-owning binary. On first use it either:

1. selects an existing whole-app install (`/Applications/Semantouch.app`, then `~/Applications/Semantouch.app`), or
2. downloads the immutable GitHub Release ZIP for this package version, verifies its SHA-256 sidecar, validates the app bundle, installs the **whole** bundle under `~/Applications`, and execs `Contents/MacOS/semantouch`.

## Requirements

- macOS 14.0+
- Apple Silicon (arm64) or Intel (x64)
- Node.js 18+

## Install

```sh
npm install -g @watzon/semantouch
```

## Usage

```sh
semantouch --version
semantouch doctor
semantouch mcp
```

All arguments, exit codes, and signals are forwarded to the nested relay inside the installed app.

## Install locations

| Preference | Path |
|---|---|
| 1 (preferred) | `/Applications/Semantouch.app` |
| 2 | `~/Applications/Semantouch.app` |

If both are present, the CLI warns and uses `/Applications`. Fresh downloads always install to `~/Applications/Semantouch.app` and never mutate signed bundle contents after install.

## Release artifact

For package version `X.Y.Z` the bootstrap fetches:

```text
https://github.com/watzon/semantouch/releases/download/vX.Y.Z/Semantouch-vX.Y.Z-macos-universal2.zip
https://github.com/watzon/semantouch/releases/download/vX.Y.Z/Semantouch-vX.Y.Z-macos-universal2.zip.sha256
```

The checksum sidecar is `lowercase-64-hex` + two spaces + the exact ZIP basename. Verification happens before extraction. Bundle identity must be `tech.watzon.semantouch` / team `MB5789APU7`, and every nested Mach-O must be universal2 (`arm64` + `x86_64`).

## Environment

| Variable | Effect |
|---|---|
| `SEMANTOUCH_RELEASE_BASE_URL` | Override the release download base (tests / mirrors). Default: GitHub Releases for this version. |

## Trust model

- No `postinstall` download.
- No nested helper replacement.
- No shell interpolation of untrusted paths (`execFile` / `spawn` only).
- npm publishes with OIDC provenance (`npm publish --provenance`).
