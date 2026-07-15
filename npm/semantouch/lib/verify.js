'use strict';

const path = require('node:path');
const {
  APP_BUNDLE_NAME,
  BUNDLE_ID,
  EXPECTED_PACKAGE_TYPE,
  HOST_EXECUTABLE_NAME,
  HOST_RELATIVE_PATH,
  INFO_PLIST_RELATIVE_PATH,
  MINIMUM_SYSTEM_VERSION,
  RELAY_CODE_IDENTIFIER,
  RELAY_EXECUTABLE_NAME,
  RELAY_RELATIVE_PATH,
  REQUIRED_ARCHITECTURES,
  SIGNING_AUTHORITY,
  TEAM_IDENTIFIER,
} = require('./constants');
const { die } = require('./errors');
const { defaultFs } = require('./fs');
const { runChecked, runCommand } = require('./run');

/**
 * Compare dotted version strings: returns negative/zero/positive.
 * @param {string} a
 * @param {string} b
 */
function compareDottedVersions(a, b) {
  const pa = String(a).split('.').map((part) => Number.parseInt(part, 10) || 0);
  const pb = String(b).split('.').map((part) => Number.parseInt(part, 10) || 0);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i += 1) {
    const da = pa[i] ?? 0;
    const db = pb[i] ?? 0;
    if (da !== db) {
      return da < db ? -1 : 1;
    }
  }
  return 0;
}

/**
 * @param {string} appPath
 * @param {string} key
 * @param {{ run?: Function }} [deps]
 */
function readPlistString(appPath, key, deps = {}) {
  const plist = path.join(appPath, INFO_PLIST_RELATIVE_PATH);
  const stdout = runChecked('/usr/bin/plutil', ['-extract', key, 'raw', plist], {
    run: deps.run,
  });
  return stdout.trim();
}

/**
 * @param {string} machoPath
 * @param {{ run?: Function }} [deps]
 * @returns {string[]}
 */
function readMachOArchitectures(machoPath, deps = {}) {
  const stdout = runChecked('/usr/bin/lipo', ['-archs', machoPath], { run: deps.run });
  return stdout
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .sort();
}

/**
 * Ensure nested Mach-O contains exactly the required universal2 arches (no extras).
 * @param {string} machoPath
 * @param {string} label
 * @param {{ run?: Function }} [deps]
 */
function assertUniversal2(machoPath, label, deps = {}) {
  // Confirm Mach-O via /usr/bin/file when available.
  const fileResult = runCommand('/usr/bin/file', ['-b', machoPath], { run: deps.run });
  if (!fileResult.error && fileResult.status === 0) {
    const info = `${fileResult.stdout} ${fileResult.stderr}`.trim();
    if (info && !/Mach-O/i.test(info)) {
      die(`${label} is not a Mach-O executable: ${machoPath} (${info})`, {
        code: 'INVALID_BUNDLE',
      });
    }
  }

  const archs = readMachOArchitectures(machoPath, deps);
  const required = [...REQUIRED_ARCHITECTURES].sort();
  const sorted = [...archs].sort();

  const unexpected = sorted.filter((arch) => !required.includes(arch));
  if (unexpected.length > 0) {
    die(
      `${label} has unexpected architecture slice(s): ${unexpected.join(' ')} (${machoPath}; archs=${sorted.join(' ')})`,
      { code: 'ARCH_MISMATCH' },
    );
  }

  const missing = required.filter((arch) => !sorted.includes(arch));
  if (missing.length > 0) {
    die(
      `${label} must include architectures ${REQUIRED_ARCHITECTURES.join('+')} (universal2); got: ${sorted.join(' ') || '<none>'}`,
      { code: 'ARCH_MISMATCH' },
    );
  }

  if (sorted.length !== required.length) {
    die(
      `${label} must contain exactly ${required.length} architecture slices, got: ${sorted.join(' ') || '<none>'}`,
      { code: 'ARCH_MISMATCH' },
    );
  }
}

/**
 * @param {string} details
 * @param {string} field
 */
function codesignField(details, field) {
  const prefix = `${field}=`;
  for (const line of details.split(/\r?\n/)) {
    if (line.startsWith(prefix)) {
      return line.slice(prefix.length).trim();
    }

    const embeddedIndex = line.indexOf(` ${prefix}`);
    if (embeddedIndex >= 0) {
      return line
        .slice(embeddedIndex + prefix.length + 1)
        .trim()
        .split(/\s+/, 1)[0];
    }
  }
  return '';
}

/**
 * Validate signature identity via platform codesign (no shell interpolation).
 * Requires authority, team, identifier, Hardened Runtime, secure timestamp,
 * and designated requirement binding identifier + team.
 *
 * @param {string} targetPath
 * @param {string} expectedIdentifier
 * @param {{ deep?: boolean, run?: Function }} [options]
 */
function validateCodesign(targetPath, expectedIdentifier, options = {}) {
  const deep = options.deep === true;
  const verifyArgs = deep
    ? ['--verify', '--deep', '--strict', '--verbose=2', targetPath]
    : ['--verify', '--strict', '--verbose=2', targetPath];

  const verify = runCommand('/usr/bin/codesign', verifyArgs, { run: options.run });
  if (verify.error || verify.status !== 0) {
    const detail = [verify.stderr, verify.stdout].map((s) => s.trim()).filter(Boolean).join(' ');
    die(
      `codesign verification failed for ${targetPath}${detail ? `: ${detail}` : ''}`,
      { code: 'INVALID_SIGNATURE' },
    );
  }

  // codesign --display writes metadata to stderr.
  const display = runCommand('/usr/bin/codesign', ['--display', '--verbose=4', targetPath], {
    run: options.run,
  });
  const details = `${display.stderr}\n${display.stdout}`;
  if (display.error || (display.status !== 0 && !details.includes('Identifier='))) {
    die(`codesign display failed for ${targetPath}`, { code: 'INVALID_SIGNATURE' });
  }

  const identifier = codesignField(details, 'Identifier');
  const team = codesignField(details, 'TeamIdentifier');
  const flags = codesignField(details, 'flags');
  const timestamp = codesignField(details, 'Timestamp');
  const authority = codesignField(details, 'Authority');

  if (!identifier) {
    die(`codesign metadata missing Identifier for ${targetPath}`, {
      code: 'INVALID_SIGNATURE',
    });
  }
  if (identifier !== expectedIdentifier) {
    die(
      `identity mismatch for ${targetPath}: Identifier=${identifier || '<none>'} expected ${expectedIdentifier}`,
      { code: 'IDENTITY_MISMATCH' },
    );
  }
  if (!team) {
    die(`codesign metadata missing TeamIdentifier for ${targetPath}`, {
      code: 'INVALID_SIGNATURE',
    });
  }
  if (team !== TEAM_IDENTIFIER) {
    die(
      `identity mismatch for ${targetPath}: TeamIdentifier=${team || '<none>'} expected ${TEAM_IDENTIFIER}`,
      { code: 'IDENTITY_MISMATCH' },
    );
  }

  const authorities = details
    .split(/\r?\n/)
    .filter((line) => line.startsWith('Authority='))
    .map((line) => line.slice('Authority='.length).trim());
  if (!authority && authorities.length === 0) {
    die(`codesign metadata missing Authority for ${targetPath}`, {
      code: 'INVALID_SIGNATURE',
    });
  }
  if (!authorities.includes(SIGNING_AUTHORITY) && authority !== SIGNING_AUTHORITY) {
    die(
      `identity mismatch for ${targetPath}: missing authority ${SIGNING_AUTHORITY}`,
      { code: 'IDENTITY_MISMATCH' },
    );
  }

  if (!flags) {
    die(`codesign metadata missing flags for ${targetPath}`, {
      code: 'INVALID_SIGNATURE',
    });
  }
  if (!flags.includes('runtime')) {
    die(
      `Hardened Runtime missing for ${targetPath} (flags=${flags})`,
      { code: 'INVALID_SIGNATURE' },
    );
  }

  if (!timestamp) {
    die(`secure timestamp missing for ${targetPath}`, {
      code: 'INVALID_SIGNATURE',
    });
  }

  const requirement = runCommand('/usr/bin/codesign', ['--display', '-r-', targetPath], {
    run: options.run,
  });
  const reqText = `${requirement.stderr}\n${requirement.stdout}`;
  if (requirement.error || (requirement.status !== 0 && !/designated/i.test(reqText) && !reqText.includes('identifier'))) {
    die(`codesign designated requirement display failed for ${targetPath}`, {
      code: 'INVALID_SIGNATURE',
    });
  }
  if (!reqText.includes(`identifier "${expectedIdentifier}"`) && !reqText.includes(`identifier ${expectedIdentifier}`)) {
    // Accept both quoted forms commonly emitted by codesign.
    const hasIdent =
      reqText.includes(`"${expectedIdentifier}"`)
      || new RegExp(`identifier\\s+"?${expectedIdentifier.replace(/\./g, '\\.')}"?`).test(reqText);
    if (!hasIdent) {
      die(
        `designated requirement missing identifier "${expectedIdentifier}" for ${targetPath}`,
        { code: 'INVALID_SIGNATURE' },
      );
    }
  }
  if (!reqText.includes(TEAM_IDENTIFIER)) {
    die(
      `designated requirement missing team ${TEAM_IDENTIFIER} for ${targetPath}`,
      { code: 'INVALID_SIGNATURE' },
    );
  }
}

/**
 * Refuse unexpected nested Mach-O files under Contents/MacOS.
 * @param {string} appPath
 * @param {import('./fs').FsApi} api
 * @param {{ run?: Function }} [options]
 */
function assertNoUnexpectedMachOs(appPath, api, options = {}) {
  const macosDir = path.join(appPath, 'Contents', 'MacOS');
  if (!api.existsSync(macosDir)) {
    die('missing Contents/MacOS directory', { code: 'INVALID_BUNDLE' });
  }

  let names;
  try {
    names = api.readdirSync(macosDir);
  } catch (error) {
    die(`failed to read Contents/MacOS: ${error.message}`, { code: 'INVALID_BUNDLE' });
  }

  const allowed = new Set([HOST_EXECUTABLE_NAME, RELAY_EXECUTABLE_NAME]);
  for (const name of names) {
    if (allowed.has(name)) continue;
    const candidate = path.join(macosDir, name);
    let st;
    try {
      st = typeof api.lstatSync === 'function' ? api.lstatSync(candidate) : api.statSync(candidate);
    } catch {
      continue;
    }
    if (typeof st.isDirectory === 'function' && st.isDirectory()) {
      die(`unexpected directory nested under Contents/MacOS: ${candidate}`, {
        code: 'INVALID_BUNDLE',
      });
    }

    const fileResult = runCommand('/usr/bin/file', ['-b', candidate], { run: options.run });
    if (!fileResult.error && fileResult.status === 0) {
      const info = `${fileResult.stdout} ${fileResult.stderr}`;
      if (/Mach-O/i.test(info)) {
        die(`unexpected nested Mach-O inside app bundle: ${candidate}`, {
          code: 'INVALID_BUNDLE',
        });
      }
    }
  }
}

/**
 * Layout + identity + version + architecture + notarization validation for a whole app bundle.
 * Mirrors scripts/verify-app-release (fail closed). Does not mutate the bundle.
 *
 * @param {string} appPath
 * @param {string} expectedVersion
 * @param {{
 *   fs?: import('./fs').FsApi,
 *   run?: Function,
 *   skipSignature?: boolean,
 *   skipNotarization?: boolean,
 * }} [options]
 */
function verifyAppBundle(appPath, expectedVersion, options = {}) {
  const api = options.fs ?? defaultFs;

  if (path.basename(appPath) !== APP_BUNDLE_NAME) {
    die(
      `expected bundle named ${APP_BUNDLE_NAME} (got: ${path.basename(appPath)})`,
      { code: 'INVALID_BUNDLE' },
    );
  }
  if (!api.existsSync(appPath)) {
    die(`app bundle not found: ${appPath}`, { code: 'INVALID_BUNDLE' });
  }

  const infoPlist = path.join(appPath, INFO_PLIST_RELATIVE_PATH);
  const host = path.join(appPath, HOST_RELATIVE_PATH);
  const relay = path.join(appPath, RELAY_RELATIVE_PATH);

  if (!api.existsSync(infoPlist)) {
    die('missing Contents/Info.plist', { code: 'INVALID_BUNDLE' });
  }
  if (!api.existsSync(host)) {
    die(`missing host executable at ${HOST_RELATIVE_PATH}`, { code: 'INVALID_BUNDLE' });
  }
  if (!api.existsSync(relay)) {
    die(`missing relay executable at ${RELAY_RELATIVE_PATH}`, { code: 'INVALID_BUNDLE' });
  }

  const bundleId = readPlistString(appPath, 'CFBundleIdentifier', options);
  if (bundleId !== BUNDLE_ID) {
    die(
      `CFBundleIdentifier ${bundleId} != ${BUNDLE_ID}`,
      { code: 'IDENTITY_MISMATCH' },
    );
  }

  const executable = readPlistString(appPath, 'CFBundleExecutable', options);
  if (executable !== HOST_EXECUTABLE_NAME) {
    die(
      `CFBundleExecutable ${executable} != ${HOST_EXECUTABLE_NAME}`,
      { code: 'INVALID_BUNDLE' },
    );
  }

  let packageType = EXPECTED_PACKAGE_TYPE;
  try {
    packageType = readPlistString(appPath, 'CFBundlePackageType', options);
  } catch {
    die('missing CFBundlePackageType', { code: 'INVALID_BUNDLE' });
  }
  if (packageType !== EXPECTED_PACKAGE_TYPE) {
    die(
      `CFBundlePackageType ${packageType} != ${EXPECTED_PACKAGE_TYPE}`,
      { code: 'INVALID_BUNDLE' },
    );
  }

  const shortVersion = readPlistString(appPath, 'CFBundleShortVersionString', options);
  if (shortVersion !== expectedVersion) {
    die(
      `app version ${shortVersion} does not match expected ${expectedVersion}`,
      { code: 'VERSION_MISMATCH' },
    );
  }

  let bundleVersion = shortVersion;
  try {
    bundleVersion = readPlistString(appPath, 'CFBundleVersion', options);
  } catch {
    die('missing CFBundleVersion', { code: 'VERSION_MISMATCH' });
  }
  if (bundleVersion !== expectedVersion) {
    die(
      `CFBundleVersion ${bundleVersion} does not match expected ${expectedVersion}`,
      { code: 'VERSION_MISMATCH' },
    );
  }
  if (shortVersion !== bundleVersion) {
    die(
      `CFBundleShortVersionString (${shortVersion}) != CFBundleVersion (${bundleVersion})`,
      { code: 'VERSION_MISMATCH' },
    );
  }

  const minOs = readPlistString(appPath, 'LSMinimumSystemVersion', options);
  if (!minOs || minOs !== MINIMUM_SYSTEM_VERSION) {
    // Fail closed: require exact supported floor, matching verify-app-release.
    if (!minOs || compareDottedVersions(minOs, MINIMUM_SYSTEM_VERSION) !== 0) {
      die(
        `LSMinimumSystemVersion ${minOs || '<none>'} must be exactly ${MINIMUM_SYSTEM_VERSION}`,
        { code: 'INVALID_BUNDLE' },
      );
    }
  }

  assertUniversal2(host, 'host executable', options);
  assertUniversal2(relay, 'relay executable', options);

  const rawHelpers = [
    path.join(appPath, 'Contents', 'MacOS', 'semantouch-macos-arm64'),
    path.join(appPath, 'Contents', 'MacOS', 'semantouch-macos-universal2'),
  ];
  for (const rawHelper of rawHelpers) {
    if (api.existsSync(rawHelper)) {
      die('raw helper binary must not be nested inside the app bundle', {
        code: 'INVALID_BUNDLE',
      });
    }
  }

  assertNoUnexpectedMachOs(appPath, api, options);

  if (!options.skipSignature) {
    validateCodesign(appPath, BUNDLE_ID, { deep: true, run: options.run });
    validateCodesign(host, BUNDLE_ID, { deep: false, run: options.run });
    validateCodesign(relay, RELAY_CODE_IDENTIFIER, { deep: false, run: options.run });
  }

  if (!options.skipNotarization) {
    const stapler = runCommand('/usr/bin/xcrun', ['stapler', 'validate', appPath], {
      run: options.run,
    });
    if (stapler.error || stapler.status !== 0) {
      const detail = [stapler.stderr, stapler.stdout].map((s) => s.trim()).filter(Boolean).join(' ');
      die(
        `app bundle is missing a valid stapled notarization ticket${detail ? `: ${detail}` : ''}`,
        { code: 'NOTARIZATION_FAILED' },
      );
    }

    const assess = runCommand(
      '/usr/sbin/spctl',
      ['--assess', '--type', 'execute', '--verbose=4', appPath],
      { run: options.run },
    );
    if (assess.error || assess.status !== 0) {
      const detail = [assess.stderr, assess.stdout].map((s) => s.trim()).filter(Boolean).join(' ');
      die(
        `Gatekeeper assessment failed for ${appPath}${detail ? `: ${detail}` : ''}`,
        { code: 'NOTARIZATION_FAILED' },
      );
    }
  }
}

module.exports = {
  compareDottedVersions,
  readPlistString,
  readMachOArchitectures,
  assertUniversal2,
  validateCodesign,
  verifyAppBundle,
  codesignField,
  assertNoUnexpectedMachOs,
};
