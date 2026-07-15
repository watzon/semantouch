#!/usr/bin/env node
/**
 * Focused behavioral tests for scripts/semantouch launcher hardening.
 *
 * Proves fail-closed behavior for:
 * - mismatched/unverified canonical installs (no silent replacement / no exec)
 * - ZIP traversal / unexpected top-level / symlink preflight rejection
 * - version mismatch on an existing install
 *
 * Uses fake app layouts and archives; skips real codesign via
 * SEMANTOUCH_SKIP_CODESIGN=1 (test-only).
 */
import { spawn, spawnSync, execFileSync } from "node:child_process";
import {
  createHash,
  randomBytes,
} from "node:crypto";
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, "../..");
const launcherSrc = join(repoRoot, "scripts/semantouch");
const packageVersion = JSON.parse(
  readFileSync(join(repoRoot, "package.json"), "utf8"),
).version;

function sha256File(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function makePluginRoot(
  root,
  version = packageVersion,
  { testSeams = true } = {},
) {
  mkdirSync(join(root, "scripts"), { recursive: true });
  cpSync(launcherSrc, join(root, "scripts/semantouch"));
  chmodSync(join(root, "scripts/semantouch"), 0o755);
  if (testSeams) {
    mkdirSync(join(root, "scripts/tests"), { recursive: true });
    writeFileSync(
      join(root, "scripts/tests/launcher-hardening.test.mjs"),
      "// Test-harness marker; production plugin archives omit this file.\n",
    );
  }
  writeFileSync(
    join(root, "package.json"),
    JSON.stringify({ name: "semantouch", version }, null, 2) + "\n",
  );
  return join(root, "scripts/semantouch");
}

function writeInfoPlist(appPath, {
  version = packageVersion,
  bundleId = "tech.watzon.semantouch",
  executable = "SemantouchHost",
  minOs = "14.0",
} = {}) {
  const contents = join(appPath, "Contents");
  mkdirSync(join(contents, "MacOS"), { recursive: true });
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>${bundleId}</string>
  <key>CFBundleExecutable</key>
  <string>${executable}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${version}</string>
  <key>CFBundleVersion</key>
  <string>${version}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${minOs}</string>
</dict>
</plist>
`;
  writeFileSync(join(contents, "Info.plist"), plist);
}

function makeFakeApp(appPath, {
  version = packageVersion,
  bundleId = "tech.watzon.semantouch",
  marker = "ok",
  executable = true,
} = {}) {
  writeInfoPlist(appPath, { version, bundleId });
  const host = join(appPath, "Contents/MacOS/SemantouchHost");
  const relay = join(appPath, "Contents/MacOS/semantouch");
  // Placeholder executables (codesign skipped in tests).
  writeFileSync(
    host,
    `#!/bin/sh\necho "host-${marker}"\n`,
  );
  writeFileSync(
    relay,
    `#!/bin/sh\necho "relay-${marker}"\nprintf '%s\\n' "$*"\n`,
  );
  if (executable) {
    chmodSync(host, 0o755);
    chmodSync(relay, 0o755);
  }
}

function runLauncher(launcher, {
  home,
  env = {},
  args = ["--ping"],
  baseUrl,
} = {}) {
  const result = spawnSync(launcher, args, {
    env: {
      ...process.env,
      HOME: home,
      PATH: process.env.PATH,
      SEMANTOUCH_ENABLE_TEST_SEAMS: "1",
      SEMANTOUCH_SKIP_CODESIGN: "1",
      SEMANTOUCH_SKIP_NOTARIZATION: "1",
      SEMANTOUCH_LOCK_DIR: join(home, "Library/Caches/semantouch-test-locks"),
      SEMANTOUCH_LOCK_ATTEMPTS: "50",
      ...(baseUrl ? { SEMANTOUCH_RELEASE_BASE_URL: baseUrl } : {}),
      ...env,
    },
    encoding: "utf8",
  });
  return result;
}

function zipApp(appPath, zipPath) {
  // ditto creates a zip with Semantouch.app as top-level when given the app.
  execFileSync("/usr/bin/ditto", ["-c", "-k", "--keepParent", appPath, zipPath], {
    stdio: "pipe",
  });
}

function writeSidecar(zipPath, sidecarPath, basename) {
  const digest = sha256File(zipPath);
  writeFileSync(sidecarPath, `${digest}  ${basename}\n`);
  return digest;
}

function serveReleaseDir(dir) {
  // Use a simple python http.server in the background for curl downloads.
  const port = 18000 + (randomBytes(2).readUInt16BE(0) % 2000);
  const server = spawn(
    "/usr/bin/python3",
    ["-m", "http.server", String(port), "--bind", "127.0.0.1"],
    {
      cwd: dir,
      stdio: "ignore",
      detached: true,
    },
  );
  server.unref();
  // Brief wait for bind.
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 200);
  return {
    baseUrl: `http://127.0.0.1:${port}`,
    stop() {
      try {
        process.kill(-server.pid, "SIGTERM");
      } catch {
        try {
          process.kill(server.pid, "SIGTERM");
        } catch {
          // ignore
        }
      }
    },
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test("rejects unverified existing user install (version mismatch) without exec", () => {
  const root = mkdtempSync(join(tmpdir(), "st-launch-"));
  try {
    const home = join(root, "home");
    mkdirSync(join(home, "Applications"), { recursive: true });
    const launcher = makePluginRoot(join(root, "plugin"), packageVersion);
    const app = join(home, "Applications/Semantouch.app");
    makeFakeApp(app, { version: "0.0.1", marker: "bad-version" });

    const result = runLauncher(launcher, { home });
    assert.notEqual(result.status, 0, "launcher must fail closed");
    assert.match(
      `${result.stderr}${result.stdout}`,
      /version 0\.0\.1 does not match plugin version|user version/i,
    );
    assert.doesNotMatch(`${result.stdout}`, /relay-bad-version/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("rejects existing install with wrong bundle id without silent replacement", () => {
  const root = mkdtempSync(join(tmpdir(), "st-launch-"));
  try {
    const home = join(root, "home");
    mkdirSync(join(home, "Applications"), { recursive: true });
    const launcher = makePluginRoot(join(root, "plugin"), packageVersion);
    const app = join(home, "Applications/Semantouch.app");
    makeFakeApp(app, {
      version: packageVersion,
      bundleId: "com.evil.not-semantouch",
      marker: "evil",
    });

    const result = runLauncher(launcher, { home });
    assert.notEqual(result.status, 0);
    assert.match(
      `${result.stderr}`,
      /CFBundleIdentifier=com\.evil\.not-semantouch|expected tech\.watzon\.semantouch/,
    );
    // Must not have replaced the evil install via bootstrap.
    assert.equal(
      existsSync(join(app, "Contents/Info.plist")),
      true,
    );
    const plist = readFileSync(join(app, "Contents/Info.plist"), "utf8");
    assert.match(plist, /com\.evil\.not-semantouch/);
    assert.doesNotMatch(`${result.stdout}`, /relay-evil/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("rejects ZIP with path traversal before extraction/exec", () => {
  const root = mkdtempSync(join(tmpdir(), "st-launch-"));
  let server;
  try {
    const home = join(root, "home");
    mkdirSync(join(home, "Applications"), { recursive: true });
    const launcher = makePluginRoot(join(root, "plugin"), packageVersion);

    const releaseDir = join(root, "release");
    mkdirSync(releaseDir, { recursive: true });
    const asset = `Semantouch-v${packageVersion}-macos-universal2.zip`;
    const zipPath = join(releaseDir, asset);

    // Build a malicious zip with a traversal member via python zipfile.
    execFileSync(
      "/usr/bin/python3",
      [
        "-c",
        `
import zipfile, pathlib
z = zipfile.ZipFile(${JSON.stringify(zipPath)}, "w")
z.writestr("../evil.txt", "pwned")
z.writestr("Semantouch.app/Contents/Info.plist", "not-a-plist")
z.close()
`,
      ],
      { stdio: "pipe" },
    );
    writeSidecar(zipPath, join(releaseDir, `${asset}.sha256`), asset);

    server = serveReleaseDir(releaseDir);
    const result = runLauncher(launcher, {
      home,
      baseUrl: server.baseUrl,
    });
    assert.notEqual(result.status, 0);
    assert.match(
      `${result.stderr}`,
      /escapes extraction root|unexpected top-level|ZIP/i,
    );
    assert.equal(existsSync(join(home, "Applications/Semantouch.app")), false);
    assert.equal(existsSync(join(home, "evil.txt")), false);
  } finally {
    server?.stop?.();
    rmSync(root, { recursive: true, force: true });
  }
});

test("rejects ZIP with unexpected top-level entry", () => {
  const root = mkdtempSync(join(tmpdir(), "st-launch-"));
  let server;
  try {
    const home = join(root, "home");
    mkdirSync(join(home, "Applications"), { recursive: true });
    const launcher = makePluginRoot(join(root, "plugin"), packageVersion);

    const releaseDir = join(root, "release");
    mkdirSync(releaseDir, { recursive: true });
    const asset = `Semantouch-v${packageVersion}-macos-universal2.zip`;
    const zipPath = join(releaseDir, asset);

    const appStage = join(root, "appstage/Semantouch.app");
    makeFakeApp(appStage, { marker: "extra" });
    // Zip app + extra top-level file.
    execFileSync(
      "/usr/bin/python3",
      [
        "-c",
        `
import zipfile, pathlib, os
root = ${JSON.stringify(join(root, "appstage"))}
zpath = ${JSON.stringify(zipPath)}
with zipfile.ZipFile(zpath, "w") as z:
    for dirpath, _, files in os.walk(root):
        for name in files:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            z.write(full, rel)
    z.writestr("not-the-app.txt", "nope")
`,
      ],
      { stdio: "pipe" },
    );
    writeSidecar(zipPath, join(releaseDir, `${asset}.sha256`), asset);
    server = serveReleaseDir(releaseDir);

    const result = runLauncher(launcher, { home, baseUrl: server.baseUrl });
    assert.notEqual(result.status, 0);
    assert.match(`${result.stderr}`, /unexpected top-level entry/i);
    assert.equal(existsSync(join(home, "Applications/Semantouch.app")), false);
  } finally {
    server?.stop?.();
    rmSync(root, { recursive: true, force: true });
  }
});

test("rejects ZIP containing symlink members", () => {
  const root = mkdtempSync(join(tmpdir(), "st-launch-"));
  let server;
  try {
    const home = join(root, "home");
    mkdirSync(join(home, "Applications"), { recursive: true });
    const launcher = makePluginRoot(join(root, "plugin"), packageVersion);

    const releaseDir = join(root, "release");
    mkdirSync(releaseDir, { recursive: true });
    const asset = `Semantouch-v${packageVersion}-macos-universal2.zip`;
    const zipPath = join(releaseDir, asset);

    execFileSync(
      "/usr/bin/python3",
      [
        "-c",
        `
import zipfile
z = zipfile.ZipFile(${JSON.stringify(zipPath)}, "w")
# symlink member
info = zipfile.ZipInfo("Semantouch.app/Contents/MacOS/semantouch")
info.create_system = 3
info.external_attr = (0o120755 << 16)
z.writestr(info, "/etc/passwd")
z.writestr("Semantouch.app/Contents/Info.plist", "x")
z.close()
`,
      ],
      { stdio: "pipe" },
    );
    writeSidecar(zipPath, join(releaseDir, `${asset}.sha256`), asset);
    server = serveReleaseDir(releaseDir);

    const result = runLauncher(launcher, { home, baseUrl: server.baseUrl });
    assert.notEqual(result.status, 0);
    assert.match(`${result.stderr}`, /symlink/i);
    assert.equal(existsSync(join(home, "Applications/Semantouch.app")), false);
  } finally {
    server?.stop?.();
    rmSync(root, { recursive: true, force: true });
  }
});

test("installs and executes a valid downloaded release", () => {
  const root = mkdtempSync(join(tmpdir(), "st-launch-"));
  let server;
  try {
    const home = join(root, "home");
    mkdirSync(join(home, "Applications"), { recursive: true });
    const launcher = makePluginRoot(join(root, "plugin"), packageVersion);

    const releaseDir = join(root, "release");
    mkdirSync(releaseDir, { recursive: true });
    const asset = `Semantouch-v${packageVersion}-macos-universal2.zip`;
    const zipPath = join(releaseDir, asset);
    const appStage = join(root, "appstage/Semantouch.app");
    makeFakeApp(appStage, { marker: "downloaded" });
    zipApp(appStage, zipPath);
    writeSidecar(zipPath, join(releaseDir, `${asset}.sha256`), asset);
    server = serveReleaseDir(releaseDir);

    const result = runLauncher(launcher, {
      home,
      args: ["--version"],
      baseUrl: server.baseUrl,
    });

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /relay-downloaded/);
    assert.match(result.stdout, /--version/);
    assert.equal(
      existsSync(join(home, "Applications/Semantouch.app/Contents/MacOS/semantouch")),
      true,
    );
  } finally {
    server?.stop?.();
    rmSync(root, { recursive: true, force: true });
  }
});

test("workflow strict-version / digest / immutability guards are present", () => {
  const release = readFileSync(join(repoRoot, ".github/workflows/release.yml"), "utf8");
  const npm = readFileSync(join(repoRoot, ".github/workflows/npm.yml"), "utf8");
  const homebrew = readFileSync(join(repoRoot, ".github/workflows/homebrew.yml"), "utf8");

  assert.match(release, /environment:\s*release-signing/);
  assert.match(release, /refusing delete\/recreate to preserve immutability/);
  assert.doesNotMatch(release, /gh release delete/);
  assert.match(release, /not on approved main history/);
  assert.match(release, /strict semver/);
  assert.match(release, /attestations:\s*write/);
  assert.match(release, /id-token:\s*write/);
  assert.match(release, /actions\/attest@[0-9a-f]{40}/);

  assert.match(npm, /environment:\s*npm-publish/);
  assert.match(npm, /release-digest\.json/);
  assert.match(npm, /verify-app-release/);
  assert.match(npm, /not on approved main history/);
  assert.match(npm, /strict semver/);

  assert.match(homebrew, /environment:\s*homebrew-publish/);
  assert.match(homebrew, /group:\s*homebrew-publish/);
  assert.match(homebrew, /refusing downgrade/);
  assert.match(homebrew, /replace\('@VERSION@'|replace\("@VERSION@"/);
  assert.match(homebrew, /no injectable sed/);
  assert.doesNotMatch(homebrew, /sed\s+\\\s*\n\s*-e\s+"s\/@VERSION@/);
  assert.match(homebrew, /git pull --rebase/);
  assert.match(homebrew, /strict semver/);
  assert.match(homebrew, /HOMEBREW_TAP_DEPLOY_KEY/);
  assert.match(homebrew, /StrictHostKeyChecking=yes/);
  assert.doesNotMatch(homebrew, /HOMEBREW_TAP_TOKEN/);
});

test("release-style launcher copy refuses test-only verification bypasses", () => {
  const root = mkdtempSync(join(tmpdir(), "st-launch-production-"));
  try {
    const home = join(root, "home");
    mkdirSync(join(home, "Applications"), { recursive: true });
    const launcher = makePluginRoot(
      join(root, "plugin"),
      packageVersion,
      { testSeams: false },
    );

    const result = runLauncher(launcher, { home });

    assert.notEqual(result.status, 0);
    assert.match(`${result.stderr}`, /test-only verification bypass refused/i);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("launcher syntax is valid POSIX sh", () => {
  const result = spawnSync("/bin/sh", ["-n", launcherSrc], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
});
