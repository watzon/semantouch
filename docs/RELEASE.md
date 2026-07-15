# Release

GitHub releases are tag-driven. The
[`Release` workflow](../.github/workflows/release.yml) tests the tagged commit on a
macOS arm64 runner, builds **universal2** host + relay slices, assembles
`Semantouch.app`, imports the publisher's Developer ID certificate into an ephemeral
keychain, signs with Hardened Runtime, notarizes and staples the app, packages
immutable ZIP + DMG (+ SHA-256 sidecars) and a script-only plugin archive, and publishes
only after Apple returns `Accepted`.

Public computer-use support remains **macOS only**. Windows/Linux GA is not claimed.

## Version and identity (current)

| Field | Value | Source |
|---|---|---|
| Version | `0.3.6` | `Sources/MCPServer/MCPServer.swift` `serverVersion`, `package.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` |
| Bundle id | `tech.watzon.semantouch` | `Sources/SemantouchCLIKit/Packaging.swift` `bundleId` |
| Host executable | `SemantouchHost` | `Packaging.hostExecutableName` |
| Nested relay | `semantouch` | `Packaging.relayExecutableName` |
| Team | `MB5789APU7` | `Packaging.teamIdentifier` |
| Min macOS | `14.0` | `Packaging.minimumMacOS`, `Package.swift` `.macOS(.v14)` |
| Architectures | `arm64`, `x86_64` (universal2) | `Packaging.architectures`, release workflow lipo steps |
| MCP protocol | `2025-06-18` | `MCPServer.mcpProtocolVersion` |
| Contract | `semantouch/1` | `MCPServer.contractVersion` |

## Automated GitHub release

Before tagging, update the release version in:

- `MCPServer.serverVersion` in `Sources/MCPServer/MCPServer.swift`,
- `package.json`,
- `.claude-plugin/plugin.json`,
- `.claude-plugin/marketplace.json` (`metadata.version` and the plugin entry),
- and keep `npm/semantouch/package.json` aligned if the npm workflow will run.

Regenerate the binary-derived files in `packaging/` with `just packaging` (or the
`semantouch config` generators), then verify mirrored distribution metadata against the
built relay:

```sh
swift build -c release --product semantouch
scripts/verify-release-metadata "$(swift build -c release --show-bin-path)/semantouch"
```

Create and push a matching `v<version>` tag:

```sh
git tag v0.3.6
git push origin v0.3.6
```

The workflow rejects a tag that does not exactly match the package and binary version,
and refuses tags that are not on approved `main` history
(`.github/workflows/release.yml`).

### Assets published by the current workflow

For a successful new tag, the workflow uploads exactly these six files
(`.github/workflows/release.yml` "Create GitHub release and upload assets"):

- `Semantouch-v<version>-macos-universal2.zip`
- `Semantouch-v<version>-macos-universal2.zip.sha256`
- `Semantouch-v<version>-macos-universal2.dmg`
- `Semantouch-v<version>-macos-universal2.dmg.sha256`
- `semantouch-plugin-v<version>-macos-universal2.tar.gz`
- `semantouch-plugin-v<version>-macos-universal2.tar.gz.sha256`

Asset names are also encoded in `Packaging.appZipAssetName` /
`appDmgAssetName` (`Sources/SemantouchCLIKit/Packaging.swift`).

The workflow **refuses** to emit or publish a raw helper such as
`semantouch-macos-arm64` or `semantouch-macos-universal2`. The plugin archive is
script/config-only and is checked for absence of Mach-O binaries.

### Immutable release contract

Published release assets are immutable. The workflow never deletes/recreates an existing
draft or published release for the same tag (fails closed if the tag already has a
release). Fixes that change release bytes require a new version and tag.

### Published `v0.2.1` mismatch (do not paper over)

`gh release view v0.2.1` currently lists the **legacy** assets:

- `semantouch-macos-arm64`
- `semantouch-macos-arm64.sha256`
- `semantouch-plugin-v0.2.1-macos-arm64.tar.gz`
- `semantouch-plugin-v0.2.1-macos-arm64.tar.gz.sha256`

Those match an earlier arm64-helper packaging shape, **not** the universal2 app assets
named above. Install docs distinguish that published tag from next-release artifacts
([INSTALL.md](INSTALL.md)). Do not claim that `v0.2.1` already ships the universal2 ZIP/DMG.

### Downstream publish workflows (unproven until ZIP exists)

| Workflow | Trigger | Requirement | Public status |
|---|---|---|---|
| [`.github/workflows/npm.yml`](../.github/workflows/npm.yml) | tag / dispatch | waits for published `Semantouch-v*-macos-universal2.zip` + `.sha256`, verifies app, pins digest, `npm publish --provenance` | **Unproven public** until a tag with those assets is published and the job succeeds |
| [`.github/workflows/homebrew.yml`](../.github/workflows/homebrew.yml) | release published / dispatch | same ZIP + checksum; renders cask; pushes tap | **Unproven public** until a successful cask publish |

Do not document npm or Homebrew as current public install channels before that proof.

The regular [`CI` workflow](../.github/workflows/ci.yml) builds, tests, and checks version
invariants on pull requests and pushes to `main`.

## Signing credentials

The release workflow requires five secrets scoped to the protected
`release-signing` environment. Do not store these as repository-level secrets:
that wider scope would let an unrelated workflow request them without crossing
the release environment's reviewer and `v*` tag policy.

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | Base64-encoded `.p12` containing the Developer ID Application certificate and private key. |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12`. |
| `APPLE_NOTARY_APPLE_ID` | Apple Account email used by the working `notarytool-password` profile. |
| `APPLE_NOTARY_APP_SPECIFIC_PASSWORD` | App-specific password used by that notarization profile. |
| `APPLE_NOTARY_TEAM_ID` | Apple Developer team identifier (`MB5789APU7`). |

Export the existing **Developer ID Application: Watzon Ventures LLc (MB5789APU7)**
identity from Keychain Access as a password-protected `.p12`. The notarization values
mirror Pindrop's working Apple Account and app-specific-password authentication:

```sh
base64 < DeveloperIDApplication.p12 \
  | gh secret set DEVELOPER_ID_CERTIFICATE_P12_BASE64 \
      --env release-signing --repo watzon/semantouch
gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD --env release-signing --repo watzon/semantouch
gh secret set APPLE_NOTARY_APPLE_ID --env release-signing --repo watzon/semantouch
gh secret set APPLE_NOTARY_APP_SPECIFIC_PASSWORD --env release-signing --repo watzon/semantouch
gh secret set APPLE_NOTARY_TEAM_ID --env release-signing --repo watzon/semantouch
```

After all five environment secrets are present, delete any same-named
repository-level copies and confirm `gh secret list --env release-signing
--repo watzon/semantouch` lists exactly the five names before tagging.

The workflow creates a temporary keychain, imports the `.p12`, sets the codesign
partition list, and deletes the keychain and decoded credentials even after a failure
(`.github/workflows/release.yml` cleanup step). Missing credentials fail the release; it
never falls back to an ad-hoc build.

## Local Pindrop-style signing

The local flow mirrors Pindrop's Developer ID and Apple Account `notarytool`
keychain-profile setup:

```sh
security find-identity -v -p codesigning
xcrun notarytool store-credentials notarytool-password \
  --apple-id you@example.com \
  --team-id MB5789APU7 \
  --password <app-specific-password>

# Build host + relay, assemble app, sign, notarize, package — use the scripts
# exercised by .github/workflows/release.yml:
scripts/assemble-app dist/SemantouchHost dist/semantouch dist/Semantouch.app
scripts/sign-release dist/Semantouch.app "Developer ID Application: Watzon Ventures LLc (MB5789APU7)"
scripts/notarize-release dist/Semantouch.app
SEMANTOUCH_REQUIRE_NOTARIZATION=1 scripts/verify-app-release dist/Semantouch.app 0.3.6
scripts/package-app-release dist/Semantouch.app dist 0.3.6 \
  "Developer ID Application: Watzon Ventures LLc (MB5789APU7)"
```

If local `just` recipes still name arm64 helper paths, prefer the scripts above for the
app-host contract. Exact recipe names may lag; the workflow is normative for asset shape.

## 0. Publisher identity

The manifest uses the owned `tech.watzon.semantouch` identifier and reports
`bundleIdIsPlaceholder: false` (`packaging/semantouch.plugin.json`). The workflow and
local signing helper pass the same identifier to `codesign`. It must remain aligned with
`Packaging.bundleId` in `Sources/SemantouchCLIKit/Packaging.swift`. Nested relay code
identifier is `tech.watzon.semantouch.cli`.

## 1. Packaging shape: whole app + nested relay

The supported distribution shape is **`Semantouch.app`**:

```text
Semantouch.app/
  Contents/
    Info.plist
    MacOS/
      SemantouchHost     # TCC owner, engines, host socket
      semantouch         # public stdio/control relay (OMP command)
```

TCC identity is the **app host** (bundle id + `SemantouchHost`), not the nested relay
(`Packaging.tccOwnershipDescription`). The release workflow packages that app into ZIP and
DMG; it does not publish a raw helper.

Suggested `Info.plist` keys (assembled by `scripts/assemble-app`; values must match
packaging constants):

```xml
<key>CFBundleIdentifier</key>        <string>tech.watzon.semantouch</string>
<key>CFBundleExecutable</key>        <string>SemantouchHost</string>
<key>CFBundleShortVersionString</key> <string>0.3.6</string>   <!-- match MCPServer.serverVersion -->
<key>LSMinimumSystemVersion</key>    <string>14.0</string>
<key>LSUIElement</key>               <true/>   <!-- accessory: no Dock icon, no menu bar -->
```

## 2. Entitlements

Hardened Runtime is required for notarization. Accessibility and Screen Recording are
user-consented TCC permissions, not entitlements; no entitlement can grant either one.
The user still approves the signed app at runtime ([INSTALL.md](INSTALL.md) §2).

The checked-in [`packaging/Release.entitlements`](../packaging/Release.entitlements) is
intentionally empty. Hardened Runtime is enabled with the `codesign --options runtime`
flag rather than an entitlement.

Do **not** add Hardened Runtime exceptions speculatively. In particular this helper does
not load third-party plugins, so `com.apple.security.cs.disable-library-validation` is not
needed. If a future capability requires an entitlement, review it before adding.

> Apple Events / AppleScript automation would require `NSAppleEventsUsageDescription` in
> the `Info.plist` and possibly the automation entitlement — this helper drives apps via
> the Accessibility and ScreenCaptureKit APIs, not Apple Events, so neither is required.

## 3. Sign with Hardened Runtime

Sign nested Mach-Os first, then the bundle, with a secure timestamp and the runtime
option (`scripts/sign-release` is the preferred entry; the release workflow calls it):

```sh
# Preferred: whole app (inside-out)
scripts/sign-release \
  "dist/Semantouch.app" \
  "Developer ID Application: Watzon Ventures LLc (MB5789APU7)"
```

Manual equivalent shape:

```sh
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Watzon Ventures LLc (MB5789APU7)" \
  --entitlements packaging/Release.entitlements \
  "Semantouch.app/Contents/MacOS/semantouch"
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Watzon Ventures LLc (MB5789APU7)" \
  --entitlements packaging/Release.entitlements \
  "Semantouch.app/Contents/MacOS/SemantouchHost"
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Watzon Ventures LLc (MB5789APU7)" \
  --entitlements packaging/Release.entitlements \
  "Semantouch.app"
```

Verify:

```sh
codesign --verify --strict --verbose=2 "Semantouch.app"
codesign --display --entitlements - "Semantouch.app/Contents/MacOS/SemantouchHost"
SEMANTOUCH_REQUIRE_NOTARIZATION=1 scripts/verify-app-release "Semantouch.app" "0.3.6"
spctl --assess --type execute --verbose "Semantouch.app"   # after notarization/staple
```

## 4. Notarize with notarytool

The release workflow calls `scripts/notarize-release` on the app (and again on the DMG).
Locally:

```sh
scripts/notarize-release "Semantouch.app"
# or manually:
ditto -c -k --keepParent "Semantouch.app" "Semantouch.zip"
xcrun notarytool submit "Semantouch.zip" \
  --keychain-profile notarytool-password \
  --wait
```

On success, inspect the log if needed:

```sh
xcrun notarytool log <submission-id> \
  --keychain-profile notarytool-password \
  notarize.log
```

## 5. Staple

Stapling is supported for the `.app` and `.dmg` containers:

```sh
xcrun stapler staple "Semantouch.app"
xcrun stapler validate "Semantouch.app"
xcrun stapler staple "Semantouch-v0.3.6-macos-universal2.dmg"
xcrun stapler validate "Semantouch-v0.3.6-macos-universal2.dmg"
```

A standalone executable may be submitted inside an archive, but the executable itself
cannot carry a stapled ticket; Gatekeeper must retrieve its notarization result online.
New releases intentionally distribute the stapled `.app` (ZIP) and stapled `.dmg` instead
of a raw helper.

## 6. The signed app host is the one that gets the TCC grants

**Critical:** macOS keys Accessibility and Screen Recording to the host process's *code
signature / bundle identity*. An ad-hoc `swift build` host and the signed release are
different identities — a grant given to the dev build does **not** carry over. After
installing the signed app:

1. Run `semantouch doctor` and read the `helper:` path (should be `…/SemantouchHost`) and
   `signed: true`.
2. Grant **that** signed host/bundle Accessibility and Screen Recording
   ([INSTALL.md](INSTALL.md) §2).
3. Re-sign ⇒ re-grant: any change that alters the signature (a new build, a new
   certificate) can invalidate the existing grant; re-check `doctor` and re-add if needed.

The nested relay does not hold TCC (`Packaging.tccOwnershipDescription`).

## 7. Update the packaging artifacts

After the release identity is final, regenerate the manifest and example config so they
carry the real bundle id, version, and install path (see `packaging/README.md`):

```sh
semantouch config --manifest --path "/Applications/Semantouch.app/Contents/MacOS/semantouch" > packaging/semantouch.plugin.json
semantouch config            --path "/Applications/Semantouch.app/Contents/MacOS/semantouch" > packaging/omp-mcp-config.example.json
```

`MCPServer.serverVersion` remains the runtime source for `--version`, `doctor`,
`serverInfo`, and the generated packaging manifest. The distribution manifests mirror
that value; `scripts/verify-release-metadata` and the workflows reject drift. Tool list
in the manifest is `ToolCatalog.enabled` (16 tools).
