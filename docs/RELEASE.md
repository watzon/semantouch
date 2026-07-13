# Release: signing & notarization

The steps to produce a distributable, Gatekeeper-friendly build. **These are documented,
not executed here** — this environment has no Apple signing credentials, and the project
never performs real code-signing or notarization without them. Run these on a machine with
a Developer ID certificate in the login keychain and an App Store Connect API key (or an
app-specific password) for `notarytool`.

Prerequisites:

- An Apple Developer account and a **Developer ID Application** certificate.
- Xcode command-line tools (`codesign`, `notarytool`, `stapler`).
- The release binary from [INSTALL.md](INSTALL.md): `swift build -c release`.

## 0. Pick the real bundle identifier

The manifest ships `dev.watzon.semantouch` as a **placeholder**
(`bundleIdIsPlaceholder: true`). Before release, replace it with your real, owned
namespace. It must **not** be `com.openai.*` or `com.apple.*`, and must not masquerade as
any OpenAI/Apple binary name or IPC endpoint (SECURITY.md §5). Update:

- `Packaging.bundleIdPlaceholder` in `Sources/ComputerUseService/Packaging.swift`,
- the app bundle's `CFBundleIdentifier` (if shipping an `.app`),
- then regenerate `packaging/semantouch.plugin.json` (see `packaging/README.md`).

## 1. Choose a packaging shape

Two options; the TCC identity differs:

- **Single binary** — sign `semantouch` directly. Simplest; the granted item is the
  binary path.
- **`.app` bundle** — e.g. `Semantouch.app/Contents/MacOS/semantouch` with an
  `Info.plist`. The granted item is the bundle. Recommended for distribution because it
  carries an `Info.plist` (usage strings, `LSUIElement`, minimum-OS) and a stable identity.

Suggested `Info.plist` keys for the `.app`:

```xml
<key>CFBundleIdentifier</key>        <string>dev.watzon.semantouch</string>   <!-- your real id -->
<key>CFBundleExecutable</key>        <string>semantouch</string>
<key>CFBundleShortVersionString</key> <string>0.2.0</string>                        <!-- match MCPServer.serverVersion -->
<key>LSMinimumSystemVersion</key>    <string>14.4</string>
<key>LSUIElement</key>               <true/>   <!-- background/accessory: no Dock icon, no menu bar -->
```

## 2. Entitlements

Hardened Runtime is required for notarization. The two grants this helper needs —
**Accessibility** and **Screen Recording** — are *user-consented TCC permissions, not
entitlements*: there is no entitlement that grants them; the user approves the signed
binary at runtime (INSTALL.md §2). So the entitlements file is minimal.

`Release.entitlements` (a conservative starting point):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Add exceptions ONLY if a concrete need appears; the default is none. -->
</dict>
</plist>
```

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
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  --entitlements Release.entitlements \
  "$(swift build -c release --show-bin-path)/semantouch"

# Or an .app bundle (sign nested executable, then the bundle):
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  --entitlements Release.entitlements \
  "Semantouch.app/Contents/MacOS/semantouch"
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  --entitlements Release.entitlements \
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
  --key "AuthKey_XXXXXXXX.p8" --key-id "XXXXXXXX" --issuer "<issuer-uuid>" \
  --wait
# (or: --apple-id you@example.com --team-id TEAMID --password <app-specific-password>)
```

On success, inspect the log if needed:

```sh
xcrun notarytool log <submission-id> --key … --key-id … --issuer … notarize.log
```

## 5. Staple

Attach the notarization ticket so the artifact validates offline:

```sh
xcrun stapler staple "Semantouch.app"      # or the binary, if distributing bare
xcrun stapler validate "Semantouch.app"
```

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

(The version comes from `MCPServer.serverVersion`; bump that single constant to cut a new
release, and everything version-bearing — `--version`, `doctor`, `serverInfo`, and the
manifest — moves together.)
