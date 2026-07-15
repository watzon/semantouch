'use strict';

class BootstrapError extends Error {
  /**
   * @param {string} message
   * @param {{ exitCode?: number, code?: string }} [options]
   */
  constructor(message, options = {}) {
    super(message);
    this.name = 'BootstrapError';
    this.exitCode = options.exitCode ?? 1;
    this.code = options.code ?? 'BOOTSTRAP_ERROR';
  }
}

/**
 * @param {string} message
 * @param {{ exitCode?: number, code?: string }} [options]
 * @returns {never}
 */
function die(message, options = {}) {
  throw new BootstrapError(message, options);
}

module.exports = {
  BootstrapError,
  die,
};
