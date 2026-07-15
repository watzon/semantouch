'use strict';

const path = require('node:path');
const {
  PACKAGE_VERSION,
  APP_BUNDLE_NAME,
  defaultReleaseBaseUrl,
} = require('./constants');
const { BootstrapError, die } = require('./errors');
const { defaultFs, atomicInstallApp } = require('./fs');
const { discoverInstalls, userInstallDestination, relayPathForApp } = require('./paths');
const { assertSupportedPlatform } = require('./platform');
const { downloadVerifiedZip } = require('./download');
const { extractAppZip, writeZipFile } = require('./extract');
const { verifyAppBundle } = require('./verify');

/**
 * @typedef {object} BootstrapDeps
 * @property {import('./fs').FsApi} [fs]
 * @property {() => string} [homedir]
 * @property {string} [systemApplicationsDir]
 * @property {string} [version]
 * @property {string} [releaseBaseUrl]
 * @property {(url: string) => Promise<Buffer>} [fetch]
 * @property {Function} [run]
 * @property {(message: string) => void} [warn]
 * @property {(message: string) => void} [log]
 * @property {boolean} [skipSignature]
 * @property {boolean} [skipNotarization]
 * @property {(src: string, dest: string) => void} [copyTree]
 * @property {{ platform?: string, arch?: string, release?: string }} [platform]
 * @property {{ version?: string, sha256?: string, asset?: string } | null} [pin]
 * @property {boolean} [requirePin]
 */

/**
 * Shared verification options for installed and freshly extracted bundles.
 * @param {BootstrapDeps} deps
 * @param {import('./fs').FsApi} api
 */
function bundleVerifyOptions(deps, api) {
  return {
    fs: api,
    run: deps.run,
    skipSignature: deps.skipSignature === true,
    skipNotarization: deps.skipNotarization === true,
  };
}

/**
 * Resolve an installed Semantouch.app or download/install the package-version ZIP.
 * Returns the absolute path to Contents/MacOS/semantouch (never mutates bundle contents).
 *
 * An existing canonical install is always re-validated against this package version,
 * bundle/relay identity, Team/authority, universal2 slices, codesign, stapled ticket,
 * and Gatekeeper before exec. Invalid/mismatched installs fail closed — they are neither
 * executed nor silently replaced by a download.
 *
 * Fresh installs keep the previous app until post-cutover verification succeeds, hold an
 * install lock against concurrent first-run cutovers, and stage via /usr/bin/ditto.
 *
 * @param {BootstrapDeps} [deps]
 * @returns {Promise<string>} absolute relay path
 */
async function resolveRelayPath(deps = {}) {
  // Platform / OS version gate before any network I/O.
  assertSupportedPlatform(deps.platform ?? {});

  const api = deps.fs ?? defaultFs;
  const version = deps.version ?? PACKAGE_VERSION;
  const warn = deps.warn ?? ((message) => {
    process.stderr.write(`semantouch: ${message}\n`);
  });
  const log = deps.log ?? ((message) => {
    process.stderr.write(`semantouch: ${message}\n`);
  });
  const verifyOptions = bundleVerifyOptions(deps, api);

  const selection = discoverInstalls({
    fs: api,
    homedir: deps.homedir ?? api.homedir,
    systemApplicationsDir: deps.systemApplicationsDir,
  });

  if (selection.warning) {
    warn(selection.warning);
  }

  if (selection.preferredApp && selection.preferredRelay) {
    // Fail closed on an invalid/mismatched canonical install. Do not exec it and
    // do not silently download over it — the operator must fix or remove the app.
    verifyAppBundle(selection.preferredApp, version, verifyOptions);
    return selection.preferredRelay;
  }

  // Neither canonical install is present — bootstrap the signed app ZIP into
  // ~/Applications/Semantouch.app (never /Applications without an existing install).
  const baseUrl =
    deps.releaseBaseUrl
    ?? process.env.SEMANTOUCH_RELEASE_BASE_URL
    ?? defaultReleaseBaseUrl(version);

  log(`downloading ${APP_BUNDLE_NAME} v${version} (macos-universal2)`);

  const downloadOptions = {
    baseUrl,
    fetch: deps.fetch,
  };
  if (Object.prototype.hasOwnProperty.call(deps, 'pin')) {
    downloadOptions.pin = deps.pin;
  }
  if (deps.requirePin === true) {
    downloadOptions.requirePin = true;
  }

  const { zipBuffer, zipName } = await downloadVerifiedZip(version, downloadOptions);

  const stagingRoot = api.mkdtempSync(path.join(api.tmpdir(), 'semantouch-npm-'));
  const cleanup = () => {
    try {
      api.rmSync(stagingRoot, { recursive: true, force: true });
    } catch {
      // ignore
    }
  };

  try {
    const zipPath = path.join(stagingRoot, zipName);
    const extractDir = path.join(stagingRoot, 'extract');
    writeZipFile(zipBuffer, zipPath, api);

    const extractedApp = extractAppZip(zipPath, extractDir, {
      fs: api,
      run: deps.run,
      zipBuffer,
    });

    verifyAppBundle(extractedApp, version, verifyOptions);

    const destination = userInstallDestination({
      fs: api,
      homedir: deps.homedir ?? api.homedir,
    });

    atomicInstallApp(extractedApp, destination, api, {
      copyTree: deps.copyTree,
      run: deps.run,
      // Keep previous install until full verification of the cut-over destination succeeds.
      verify: (installedApp) => {
        verifyAppBundle(installedApp, version, verifyOptions);
      },
    });

    const relay = relayPathForApp(destination);
    if (!api.existsSync(relay)) {
      die(`installed app is missing executable relay at ${relay}`, {
        code: 'INSTALL_FAILED',
      });
    }
    return relay;
  } catch (error) {
    cleanup();
    if (error instanceof BootstrapError) {
      throw error;
    }
    // Preserve structured codes from install lock / verify failures when present.
    const code =
      (error && typeof error === 'object' && 'code' in error && error.code)
        ? String(error.code)
        : 'BOOTSTRAP_FAILED';
    die(error.message || String(error), { code });
  } finally {
    cleanup();
  }
}

module.exports = {
  resolveRelayPath,
};
