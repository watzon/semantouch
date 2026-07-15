'use strict';

const os = require('node:os');
const { MINIMUM_DARWIN_MAJOR, MINIMUM_SYSTEM_VERSION, SUPPORTED_NODE_ARCHES } = require('./constants');
const { die } = require('./errors');

/**
 * Parse a Darwin kernel release (e.g. "23.6.0") into a major version number.
 * @param {string} release
 * @returns {number}
 */
function darwinMajorFromRelease(release) {
  const major = Number.parseInt(String(release).split('.')[0] ?? '', 10);
  return Number.isFinite(major) ? major : 0;
}

/**
 * Reject non-macOS hosts, unsupported CPU arches, and macOS older than 14.
 * Must run before any network I/O.
 *
 * @param {{
 *   platform?: string,
 *   arch?: string,
 *   release?: string,
 * }} [env]
 */
function assertSupportedPlatform(env = {}) {
  const platform = env.platform ?? process.platform;
  const arch = env.arch ?? process.arch;
  const release = env.release ?? os.release();

  if (platform !== 'darwin') {
    die(
      `unsupported platform ${platform}: @watzon/semantouch only supports macOS (darwin)`,
      { exitCode: 1, code: 'UNSUPPORTED_PLATFORM' },
    );
  }

  if (!SUPPORTED_NODE_ARCHES.includes(arch)) {
    die(
      `unsupported architecture ${arch}: Semantouch.app requires arm64 or x64 (Intel) on macOS`,
      { exitCode: 1, code: 'UNSUPPORTED_ARCH' },
    );
  }

  const darwinMajor = darwinMajorFromRelease(release);
  if (darwinMajor < MINIMUM_DARWIN_MAJOR) {
    die(
      `unsupported macOS kernel ${release}: Semantouch requires macOS ${MINIMUM_SYSTEM_VERSION}+ (Darwin ${MINIMUM_DARWIN_MAJOR}+)`,
      { exitCode: 1, code: 'UNSUPPORTED_OS_VERSION' },
    );
  }
}

module.exports = {
  assertSupportedPlatform,
  darwinMajorFromRelease,
};
