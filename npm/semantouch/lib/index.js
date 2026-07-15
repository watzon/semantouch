'use strict';

const constants = require('./constants');
const { BootstrapError } = require('./errors');
const { resolveRelayPath } = require('./bootstrap');
const { discoverInstalls, userInstallDestination, relayPathForApp } = require('./paths');
const { assertSupportedPlatform } = require('./platform');
const {
  parseChecksumSidecar,
  sha256Hex,
  assertChecksumMatch,
  assertHttpsUrl,
  loadReleaseDigestPin,
  downloadVerifiedZip,
  releaseAssetUrls,
  downloadBuffer,
} = require('./download');
const { verifyAppBundle } = require('./verify');
const {
  atomicInstallApp,
  locateExactlyOneApp,
  acquireInstallLock,
  dittoCopyTree,
} = require('./fs');
const {
  preflightZipBuffer,
  extractAppZip,
  assertExtractedTreeContained,
} = require('./extract');
const { execRelay } = require('./exec');

module.exports = {
  ...constants,
  BootstrapError,
  resolveRelayPath,
  discoverInstalls,
  userInstallDestination,
  relayPathForApp,
  assertSupportedPlatform,
  parseChecksumSidecar,
  sha256Hex,
  assertChecksumMatch,
  assertHttpsUrl,
  loadReleaseDigestPin,
  downloadVerifiedZip,
  releaseAssetUrls,
  downloadBuffer,
  verifyAppBundle,
  atomicInstallApp,
  locateExactlyOneApp,
  acquireInstallLock,
  dittoCopyTree,
  preflightZipBuffer,
  extractAppZip,
  assertExtractedTreeContained,
  execRelay,
};
