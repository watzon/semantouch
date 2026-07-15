'use strict';

const { spawn } = require('node:child_process');

/**
 * Forward process signals to a child.
 * @param {import('node:child_process').ChildProcess} child
 * @param {NodeJS.Process} [proc]
 * @returns {() => void} detach
 */
function forwardSignals(child, proc = process) {
  /** @type {NodeJS.Signals[]} */
  const signals = ['SIGINT', 'SIGTERM', 'SIGHUP', 'SIGQUIT'];
  /** @type {Partial<Record<NodeJS.Signals, () => void>>} */
  const handlers = {};

  for (const signal of signals) {
    const handler = () => {
      try {
        child.kill(signal);
      } catch {
        // ignore
      }
    };
    handlers[signal] = handler;
    proc.on(signal, handler);
  }

  return () => {
    for (const signal of signals) {
      const handler = handlers[signal];
      if (handler) {
        proc.off(signal, handler);
      }
    }
  };
}

/**
 * Spawn the nested relay with full stdio inheritance and exit-code/signal forwarding.
 * Never uses a shell.
 *
 * @param {string} relayPath
 * @param {string[]} argv
 * @param {{
 *   spawn?: typeof spawn,
 *   process?: NodeJS.Process,
 *   env?: NodeJS.ProcessEnv,
 *   onExit?: (code: number | null, signal: NodeJS.Signals | null) => void,
 * }} [options]
 * @returns {import('node:child_process').ChildProcess}
 */
function execRelay(relayPath, argv, options = {}) {
  const spawnImpl = options.spawn ?? spawn;
  const proc = options.process ?? process;
  const env = options.env ?? proc.env;

  const child = spawnImpl(relayPath, argv, {
    stdio: 'inherit',
    env,
    // Absolute path, no shell.
    shell: false,
    windowsHide: true,
  });

  const detach = forwardSignals(child, proc);

  child.on('error', (error) => {
    detach();
    const message = error && error.message ? error.message : String(error);
    proc.stderr.write(`semantouch: failed to exec ${relayPath}: ${message}\n`);
    if (typeof options.onExit === 'function') {
      options.onExit(1, null);
    } else {
      proc.exit(1);
    }
  });

  child.on('exit', (code, signal) => {
    detach();
    if (typeof options.onExit === 'function') {
      options.onExit(code, signal);
      return;
    }
    if (signal) {
      // Re-raise the same signal so shells see the correct termination cause.
      try {
        proc.kill(proc.pid, signal);
      } catch {
        proc.exit(1);
      }
      return;
    }
    proc.exit(code == null ? 1 : code);
  });

  return child;
}

module.exports = {
  forwardSignals,
  execRelay,
};
