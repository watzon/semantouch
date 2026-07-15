'use strict';

const path = require('node:path');
const { APP_BUNDLE_NAME, RELAY_RELATIVE_PATH } = require('./constants');
const { defaultFs, isInstalledApp } = require('./fs');

/**
 * @typedef {object} InstallSelection
 * @property {string | null} systemApp
 * @property {string | null} userApp
 * @property {string | null} preferredApp
 * @property {string | null} preferredRelay
 * @property {boolean} hasDuplicates
 * @property {string | null} warning
 */

/**
 * Deterministic discovery of the two canonical install locations.
 * Preference: /Applications before ~/Applications. Warn when both exist.
 *
 * @param {{
 *   homedir?: () => string,
 *   systemApplicationsDir?: string,
 *   fs?: import('./fs').FsApi,
 * }} [options]
 * @returns {InstallSelection}
 */
function discoverInstalls(options = {}) {
  const api = options.fs ?? defaultFs;
  const home = (options.homedir ?? api.homedir)();
  const systemDir = options.systemApplicationsDir ?? '/Applications';
  const systemApp = path.join(systemDir, APP_BUNDLE_NAME);
  const userApp = path.join(home, 'Applications', APP_BUNDLE_NAME);

  const systemOk = isInstalledApp(systemApp, api);
  const userOk = isInstalledApp(userApp, api);

  /** @type {InstallSelection} */
  const result = {
    systemApp: systemOk ? systemApp : null,
    userApp: userOk ? userApp : null,
    preferredApp: null,
    preferredRelay: null,
    hasDuplicates: systemOk && userOk,
    warning: null,
  };

  if (systemOk && userOk) {
    result.warning =
      `warning: both ${systemApp} and ${userApp} are installed; preferring ${systemApp}`;
    result.preferredApp = systemApp;
  } else if (systemOk) {
    result.preferredApp = systemApp;
  } else if (userOk) {
    result.preferredApp = userApp;
  }

  if (result.preferredApp) {
    result.preferredRelay = path.join(result.preferredApp, RELAY_RELATIVE_PATH);
  }

  return result;
}

/**
 * Fresh-download destination is always the per-user Applications path.
 * Never writes to /Applications without an existing writable install there.
 *
 * @param {{
 *   homedir?: () => string,
 *   fs?: import('./fs').FsApi,
 * }} [options]
 */
function userInstallDestination(options = {}) {
  const api = options.fs ?? defaultFs;
  const home = (options.homedir ?? api.homedir)();
  return path.join(home, 'Applications', APP_BUNDLE_NAME);
}

/**
 * @param {string} appPath
 */
function relayPathForApp(appPath) {
  return path.join(appPath, RELAY_RELATIVE_PATH);
}

module.exports = {
  discoverInstalls,
  userInstallDestination,
  relayPathForApp,
};
