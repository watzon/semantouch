'use strict';

const path = require('node:path');

const PACKAGE_NAME = '@watzon/semantouch';
// Keep in sync with package.json; read at runtime so tests can stub package.json if needed.
const PACKAGE_VERSION = require('../package.json').version;

const APP_BUNDLE_NAME = 'Semantouch.app';
const HOST_EXECUTABLE_NAME = 'SemantouchHost';
const RELAY_EXECUTABLE_NAME = 'semantouch';
const HOST_RELATIVE_PATH = path.join('Contents', 'MacOS', HOST_EXECUTABLE_NAME);
const RELAY_RELATIVE_PATH = path.join('Contents', 'MacOS', RELAY_EXECUTABLE_NAME);
const INFO_PLIST_RELATIVE_PATH = path.join('Contents', 'Info.plist');

const BUNDLE_ID = 'tech.watzon.semantouch';
const RELAY_CODE_IDENTIFIER = 'tech.watzon.semantouch.cli';
const TEAM_IDENTIFIER = 'MB5789APU7';
const SIGNING_AUTHORITY = 'Developer ID Application: Watzon Ventures LLc (MB5789APU7)';
const MINIMUM_SYSTEM_VERSION = '14.0';
/** Darwin kernel major for macOS 14 Sonoma (macOS major ≈ Darwin major − 9). */
const MINIMUM_DARWIN_MAJOR = 23;
const REQUIRED_ARCHITECTURES = Object.freeze(['arm64', 'x86_64']);
const SUPPORTED_NODE_ARCHES = Object.freeze(['arm64', 'x64']);
const EXPECTED_PACKAGE_TYPE = 'APPL';

const GITHUB_OWNER = 'watzon';
const GITHUB_REPO = 'semantouch';

/** Install mutex leaf under the destination Applications directory. */
const INSTALL_LOCK_NAME = '.Semantouch.app.install.lock';

/** Network / artifact bounds (fail closed). */
const MAX_REDIRECTS = 5;
const REQUEST_TIMEOUT_MS = 30_000;
const OVERALL_DOWNLOAD_TIMEOUT_MS = 120_000;
const MAX_CHECKSUM_BYTES = 16 * 1024;
const MAX_ZIP_BYTES = 250 * 1024 * 1024;

/**
 * Canonical immutable app ZIP asset for a release version.
 * @param {string} version
 */
function appZipAssetName(version) {
  return `Semantouch-v${version}-macos-universal2.zip`;
}

/**
 * SHA-256 sidecar for the canonical app ZIP.
 * @param {string} version
 */
function appZipChecksumAssetName(version) {
  return `${appZipAssetName(version)}.sha256`;
}

/**
 * Default GitHub Releases download base for a version tag.
 * @param {string} version
 */
function defaultReleaseBaseUrl(version) {
  return `https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/v${version}`;
}

module.exports = {
  PACKAGE_NAME,
  PACKAGE_VERSION,
  APP_BUNDLE_NAME,
  HOST_EXECUTABLE_NAME,
  RELAY_EXECUTABLE_NAME,
  HOST_RELATIVE_PATH,
  RELAY_RELATIVE_PATH,
  INFO_PLIST_RELATIVE_PATH,
  BUNDLE_ID,
  RELAY_CODE_IDENTIFIER,
  TEAM_IDENTIFIER,
  SIGNING_AUTHORITY,
  MINIMUM_SYSTEM_VERSION,
  MINIMUM_DARWIN_MAJOR,
  REQUIRED_ARCHITECTURES,
  SUPPORTED_NODE_ARCHES,
  EXPECTED_PACKAGE_TYPE,
  GITHUB_OWNER,
  GITHUB_REPO,
  INSTALL_LOCK_NAME,
  MAX_REDIRECTS,
  REQUEST_TIMEOUT_MS,
  OVERALL_DOWNLOAD_TIMEOUT_MS,
  MAX_CHECKSUM_BYTES,
  MAX_ZIP_BYTES,
  appZipAssetName,
  appZipChecksumAssetName,
  defaultReleaseBaseUrl,
};
