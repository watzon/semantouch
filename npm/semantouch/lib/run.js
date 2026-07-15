'use strict';

const { spawnSync } = require('node:child_process');

/**
 * @typedef {object} RunResult
 * @property {number | null} status
 * @property {string} stdout
 * @property {string} stderr
 * @property {Error | null} error
 */

/**
 * @param {string} command
 * @param {string[]} args
 * @param {{
 *   run?: (command: string, args: string[], options?: object) => RunResult,
 *   env?: NodeJS.ProcessEnv,
 *   cwd?: string,
 *   encoding?: BufferEncoding,
 * }} [options]
 * @returns {RunResult}
 */
function runCommand(command, args, options = {}) {
  if (typeof options.run === 'function') {
    return options.run(command, args, options);
  }

  const result = spawnSync(command, args, {
    encoding: options.encoding ?? 'utf8',
    env: options.env ?? process.env,
    cwd: options.cwd,
    // Never use a shell — no interpolation of untrusted paths.
    shell: false,
    maxBuffer: 16 * 1024 * 1024,
  });

  return {
    status: result.status,
    stdout: result.stdout == null ? '' : String(result.stdout),
    stderr: result.stderr == null ? '' : String(result.stderr),
    error: result.error ?? null,
  };
}

/**
 * @param {string} command
 * @param {string[]} args
 * @param {Parameters<typeof runCommand>[2]} [options]
 * @returns {string}
 */
function runChecked(command, args, options = {}) {
  const result = runCommand(command, args, options);
  if (result.error) {
    throw new Error(`${command} failed to start: ${result.error.message}`);
  }
  if (result.status !== 0) {
    const detail = [result.stderr, result.stdout]
      .map((part) => part.trim())
      .filter(Boolean)
      .join(' ');
    throw new Error(
      detail
        ? `${command} ${args.join(' ')} failed: ${detail}`
        : `${command} ${args.join(' ')} exited ${result.status}`,
    );
  }
  return result.stdout;
}

module.exports = {
  runCommand,
  runChecked,
};
