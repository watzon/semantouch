# Release

GitHub releases are tag-driven. The
[`Release` workflow](../.github/workflows/release.yml) tests the tagged commit on a
macOS arm64 runner, imports the publisher's Developer ID certificate into an ephemeral
keychain, signs with Hardened Runtime, notarizes the executable, and publishes only after
Apple returns `Accepted`.

## Automated GitHub release

Before tagging, update the release version in:

- `MCPServer.serverVersion` in `Sources/MCPServer/MCPServer.swift`,
- `package.json`,
- `.claude-plugin/plugin.json`,
- `.claude-plugin/marketplace.json` (`metadata.version` and the plugin entry).

Regenerate the binary-derived files in `packaging/` with `just packaging`, then verify the
mirrored distribution metadata against the built executable:

```sh
swift build -c release --product semantouch
scripts/verify-release-metadata "$(swift build -c release --show-bin-path)/semantouch"
```

Create and push a matching `v<version>` tag:

```sh
git tag v0.2.1
git push origin v0.2.1
```

The workflow rejects a tag that does not exactly match the package and binary version.
It publishes four assets:

- `semantouch-macos-arm64` — the executable used by the plugin launcher,
- `semantouch-macos-arm64.sha256` — its checksum,
- `semantouch-plugin-v<version>-macos-arm64.tar.gz` — a self-contained plugin bundle,
- `semantouch-plugin-v<version>-macos-arm64.tar.gz.sha256` — the bundle checksum.

Published release assets are immutable. A retry may replace an unpublished draft left by
a failed upload, but it refuses to overwrite an existing published version. Fixes that
change release bytes require a new version and tag.

The regular [`CI` workflow](../.github/workflows/ci.yml) builds, tests, and checks the
same version invariant on pull requests and pushes to `main`.

## Signing credentials

The release workflow requires five GitHub Actions secrets:

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
base64 < DeveloperIDApplication.p12 | gh secret set DEVELOPER_ID_CERTIFICATE_P12_BASE64
gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD
gh secret set APPLE_NOTARY_APPLE_ID
gh secret set APPLE_NOTARY_APP_SPECIFIC_PASSWORD
gh secret set APPLE_NOTARY_TEAM_ID
```

The workflow creates a temporary keychain, imports the `.p12`, sets the codesign
partition list, and deletes the keychain and decoded credentials even after a failure.
Missing credentials fail the release; it never falls back to an ad-hoc build.

## Local Pindrop-style signing

The local flow mirrors Pindrop's Developer ID and Apple Account
`notarytool` keychain-profile setup:

```sh
security find-identity -v -p codesigning
xcrun notarytool store-credentials notarytool-password \
  --apple-id you@example.com \
  --team-id MB5789APU7 \
  --password <app-specific-password>

just signed-release
just notarize-release
just verify-signed-release
```

`just signed-release` uses the generic `Developer ID Application` selector by default;
pass the exact identity as its argument if codesign reports an ambiguous match. The
signed binary is `dist/semantouch-macos-arm64`.

## 0. Publisher identity

The manifest uses the owned `tech.watzon.semantouch` identifier and reports
`bundleIdIsPlaceholder: false`. The workflow and local signing helper pass the same
identifier to `codesign`. It must remain aligned with
`Packaging.bundleId` in `Sources/ComputerUseService/Packaging.swift`.

## 1. Choose a packaging shape

Two options; the TCC identity differs:

- **Single binary** — sign `semantouch` directly. Simplest; the granted item is the
  binary path.
- **`.app` bundle** — e.g. `Semantouch.app/Contents/MacOS/semantouch` with an
  `Info.plist`. The granted item is the bundle. Recommended for distribution because it
  carries an `Info.plist` (usage strings, `LSUIElement`, minimum-OS) and a stable identity.

Suggested `Info.plist` keys for the `.app`:

```xml
<key>CFBundleIdentifier</key>        <string>tech.watzon.semantouch</string>
<key>CFBundleExecutable</key>        <string>semantouch</string>
<key>CFBundleShortVersionString</key> <string>0.2.1</string>                        <!-- match MCPServer.serverVersion -->
<key>LSMinimumSystemVersion</key>    <string>14.4</string>
<key>LSUIElement</key>               <true/>   <!-- background/accessory: no Dock icon, no menu bar -->
```

## 2. Entitlements

Hardened Runtime is required for notarization. Accessibility and Screen Recording are
user-consented TCC permissions, not entitlements; no entitlement can grant either one.
The user still approves the signed binary at runtime (INSTALL.md §2).

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

Sign inner Mach-O first (if an `.app`), then the bundle, with a secure timestamp and the
runtime option:

```sh
# Single binary:
scripts/sign-release \
  "$(swift build -c release --show-bin-path)/semantouch" \
  "Developer ID Application: Watzon Ventures LLc (MB5789APU7)"

# Or an .app bundle (sign nested executable, then the bundle):
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  --entitlements packaging/Release.entitlements \
  "Semantouch.app/Contents/MacOS/semantouch"
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  --entitlements packaging/Release.entitlements \
  "Semantouch.app"
```

Verify:

```sh
codesign --verify --strict --verbose=2 "Semantouch.app"
codesign --display --entitlements - "Semantouch.app/Contents/MacOS/semantouch"
spctl --assess --type execute --verbose "Semantouch.app"   # after notarization
```

## 4. Notarize with notarytool

Zip the signed artifact, submit, and wait:

```sh
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

Stapling is supported for the `.app` distribution:

```sh
xcrun stapler staple "Semantouch.app"
xcrun stapler validate "Semantouch.app"
```

A standalone executable may be submitted inside an archive, but the executable itself
cannot carry a stapled ticket; Gatekeeper must retrieve its notarization result online.
If offline validation is required, distribute and staple a supported `.app`, `.pkg`, or
`.dmg` container.

## 6. The signed binary is the one that gets the TCC grants

**Critical:** macOS keys Accessibility and Screen Recording to the binary's *code
signature and path*. An ad-hoc `swift build` binary and the signed release are different
identities — a grant given to the dev build does **not** carry over. After installing the
signed build:

1. Run `semantouch doctor` and read the `helper:` path and `signed: true`.
2. Grant **that** signed binary/bundle Accessibility and Screen Recording (INSTALL.md §2).
3. Re-sign ⇒ re-grant: any change that alters the signature (a new build, a new
   certificate) can invalidate the existing grant; re-check `doctor` and re-add if needed.

## 7. Update the packaging artifacts

After the release identity is final, regenerate the manifest and example config so they
carry the real bundle id, version, and install path (see `packaging/README.md`):

```sh
semantouch config --manifest --path "/Applications/Semantouch.app/Contents/MacOS/semantouch" > packaging/semantouch.plugin.json
semantouch config            --path "/Applications/Semantouch.app/Contents/MacOS/semantouch" > packaging/omp-mcp-config.example.json
```

`MCPServer.serverVersion` remains the runtime source for `--version`, `doctor`,
`serverInfo`, and the generated packaging manifest. The distribution manifests mirror
that value; `scripts/verify-release-metadata` and both workflows reject drift.
