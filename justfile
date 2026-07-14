set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Build a debug binary.
build:
    swift build

# Build the optimized binary used by OMP.
release:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! swift build -c release; then
      echo "release build failed; clearing SwiftPM scratch and retrying once" >&2
      swift package clean
      swift build -c release
    fi

# Build and sign the distributable binary with a local Developer ID identity.
signed-release identity="Developer ID Application": release
    #!/usr/bin/env bash
    set -euo pipefail
    source_binary="$(swift build -c release --show-bin-path)/semantouch"
    signed_binary="dist/semantouch-macos-arm64"
    mkdir -p dist
    install -m 0755 "$source_binary" "$signed_binary"
    scripts/sign-release "$signed_binary" "{{identity}}"

# Submit the locally signed binary using a notarytool keychain profile.
notarize-release profile="notarytool-password":
    #!/usr/bin/env bash
    set -euo pipefail
    signed_binary="dist/semantouch-macos-arm64"
    test -x "$signed_binary" || { echo "error: run 'just signed-release' first" >&2; exit 1; }
    scripts/notarize-release "$signed_binary" "{{profile}}"

# Verify the local release binary's Developer ID signature.
verify-signed-release:
    codesign --verify --strict --verbose=2 dist/semantouch-macos-arm64
    codesign --display --verbose=4 dist/semantouch-macos-arm64

# Run the Swift package test suite.
test:
    swift test

# Regenerate the checked-in packaging examples from the release binary.
packaging: release
    #!/usr/bin/env bash
    set -euo pipefail
    binary="$(swift build -c release --show-bin-path)/semantouch"
    installed_path="/Applications/Semantouch.app/Contents/MacOS/semantouch"
    "$binary" config --manifest --path "$installed_path" \
      | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), indent=2, sort_keys=True, ensure_ascii=False))' \
      > packaging/semantouch.plugin.json
    "$binary" config --path "$installed_path" \
      | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), indent=2, sort_keys=True, ensure_ascii=False))' \
      > packaging/omp-mcp-config.example.json

# Build, install the helper at a stable TCC path, and link this package into OMP.
omp-install: release
    #!/usr/bin/env bash
    set -euo pipefail
    command -v omp >/dev/null || { echo "error: omp is not installed or not on PATH" >&2; exit 1; }
    source_binary="$(swift build -c release --show-bin-path)/semantouch"
    install_dir="$HOME/.omp/bin"
    installed_binary="$install_dir/semantouch"
    mkdir -p "$install_dir"
    install -m 0755 "$source_binary" "$installed_binary"
    omp plugin link .
    echo "Installed helper: $installed_binary"
    echo "Linked plugin:    $(pwd)"
    "$installed_binary" doctor
