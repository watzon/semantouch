'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { APP_BUNDLE_NAME, INSTALL_LOCK_NAME, RELAY_RELATIVE_PATH } = require('./constants');
const { runChecked } = require('./run');

/**
 * @typedef {object} FsApi
 * @property {(p: string) => boolean} existsSync
 * @property {(p: string, mode?: number) => boolean} accessSync
 * @property {(p: string) => import('node:fs').Stats} statSync
 * @property {(p: string) => import('node:fs').Stats} [lstatSync]
 * @property {(p: string, options?: object) => string[]} readdirSync
 * @property {(p: string, options?: object) => void} mkdirSync
 * @property {(p: string, options?: object) => void} rmSync
 * @property {(src: string, dest: string) => void} renameSync
 * @property {(p: string, data: string | Buffer, options?: object) => void} writeFileSync
 * @property {(p: string, options?: object) => Buffer | string} readFileSync
 * @property {(p: string, options?: object) => string} mkdtempSync
 * @property {(p: string, flags: string | number, mode?: number) => number} [openSync]
 * @property {(fd: number) => void} [closeSync]
 * @property {(fd: number, data: string | Buffer, offset?: number, length?: number, position?: number) => number} [writeSync]
 * @property {() => string} tmpdir
 * @property {() => string} homedir
 */

/** @type {FsApi} */
const defaultFs = {
  existsSync: (p) => fs.existsSync(p),
  accessSync: (p, mode) => {
    fs.accessSync(p, mode);
    return true;
  },
  statSync: (p) => fs.statSync(p),
  lstatSync: (p) => fs.lstatSync(p),
  readdirSync: (p, options) => fs.readdirSync(p, options),
  mkdirSync: (p, options) => {
    fs.mkdirSync(p, options);
  },
  rmSync: (p, options) => {
    fs.rmSync(p, options);
  },
  renameSync: (src, dest) => {
    fs.renameSync(src, dest);
  },
  writeFileSync: (p, data, options) => {
    fs.writeFileSync(p, data, options);
  },
  readFileSync: (p, options) => fs.readFileSync(p, options),
  mkdtempSync: (prefix) => fs.mkdtempSync(prefix),
  openSync: (p, flags, mode) => fs.openSync(p, flags, mode),
  closeSync: (fd) => {
    fs.closeSync(fd);
  },
  writeSync: (fd, data, offset, length, position) =>
    fs.writeSync(fd, data, offset, length, position),
  tmpdir: () => os.tmpdir(),
  homedir: () => os.homedir(),
};

/**
 * @param {string} appPath
 * @param {FsApi} [api]
 */
function isExecutableRelay(appPath, api = defaultFs) {
  const relay = path.join(appPath, RELAY_RELATIVE_PATH);
  if (!api.existsSync(relay)) {
    return false;
  }
  try {
    api.accessSync(relay, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/**
 * @param {string} appPath
 * @param {FsApi} [api]
 */
function isInstalledApp(appPath, api = defaultFs) {
  if (!api.existsSync(appPath)) {
    return false;
  }
  try {
    const st = api.statSync(appPath);
    if (!st.isDirectory()) {
      return false;
    }
  } catch {
    return false;
  }
  return isExecutableRelay(appPath, api);
}

/**
 * @param {string} destination
 * @param {FsApi} [api]
 */
function isWritableDestination(destination, api = defaultFs) {
  const parent = path.dirname(destination);
  if (api.existsSync(destination)) {
    try {
      api.accessSync(destination, fs.constants.W_OK);
      api.accessSync(parent, fs.constants.W_OK);
      return true;
    } catch {
      return false;
    }
  }

  let cursor = parent;
  for (let i = 0; i < 6; i += 1) {
    if (api.existsSync(cursor)) {
      try {
        api.accessSync(cursor, fs.constants.W_OK);
        return true;
      } catch {
        return false;
      }
    }
    const next = path.dirname(cursor);
    if (next === cursor) {
      break;
    }
    cursor = next;
  }
  return false;
}

/**
 * @param {string} directory
 * @param {FsApi} [api]
 * @returns {string}
 */
function locateExactlyOneApp(directory, api = defaultFs) {
  const entries = api.readdirSync(directory, { withFileTypes: true });
  const visible = entries.filter((entry) => !entry.name.startsWith('.'));
  const apps = visible.filter(
    (entry) => entry.name === APP_BUNDLE_NAME && (entry.isDirectory?.() ?? true),
  );

  if (apps.length === 1 && visible.length === 1) {
    return path.join(directory, APP_BUNDLE_NAME);
  }

  if (apps.length > 1) {
    throw new Error(`archive contains multiple ${APP_BUNDLE_NAME} bundles`);
  }

  if (visible.length === 1) {
    const only = visible[0];
    const onlyPath = path.join(directory, only.name);
    let isDir = false;
    try {
      isDir = only.isDirectory?.() ?? api.statSync(onlyPath).isDirectory();
    } catch {
      isDir = false;
    }
    if (isDir) {
      const nested = api.readdirSync(onlyPath, { withFileTypes: true }).filter(
        (entry) => !entry.name.startsWith('.'),
      );
      const nestedApps = nested.filter((entry) => entry.name === APP_BUNDLE_NAME);
      if (nestedApps.length === 1 && nested.length === 1) {
        return path.join(onlyPath, APP_BUNDLE_NAME);
      }
    }
  }

  if (apps.length === 1) {
    throw new Error(`archive must contain exactly one ${APP_BUNDLE_NAME} and nothing else`);
  }

  throw new Error(`archive must contain exactly one ${APP_BUNDLE_NAME}`);
}

/**
 * Default whole-tree staging via /usr/bin/ditto (preserves metadata better than fs.cpSync).
 * @param {string} src
 * @param {string} dest
 * @param {{ run?: Function }} [options]
 */
function dittoCopyTree(src, dest, options = {}) {
  runChecked('/usr/bin/ditto', [src, dest], { run: options.run });
}

/**
 * Acquire an exclusive install lock in `parentDir`. Fail closed on contention.
 *
 * @param {string} parentDir
 * @param {FsApi} [api]
 * @param {{ pid?: number, now?: () => number }} [options]
 * @returns {{ lockPath: string, release: () => void }}
 */
function acquireInstallLock(parentDir, api = defaultFs, options = {}) {
  const lockPath = path.join(parentDir, INSTALL_LOCK_NAME);
  const pid = options.pid ?? process.pid;
  const now = options.now ?? (() => Date.now());
  const payload = `${pid}\n${now()}\n`;

  api.mkdirSync(parentDir, { recursive: true });

  if (typeof api.openSync === 'function' && typeof api.closeSync === 'function') {
    let fd;
    try {
      fd = api.openSync(lockPath, 'wx', 0o644);
    } catch (error) {
      if (error && (error.code === 'EEXIST' || /EEXIST|file already exists/i.test(String(error.message)))) {
        const err = new Error(
          `another Semantouch install is in progress (lock: ${lockPath})`,
        );
        err.code = 'INSTALL_LOCK_HELD';
        throw err;
      }
      throw error;
    }
    try {
      if (typeof api.writeSync === 'function') {
        api.writeSync(fd, payload);
      } else {
        api.writeFileSync(lockPath, payload);
      }
    } finally {
      try {
        api.closeSync(fd);
      } catch {
        // ignore
      }
    }
  } else {
    // Fallback for memory fs tests: exclusive create via existence check + write.
    if (api.existsSync(lockPath)) {
      const err = new Error(
        `another Semantouch install is in progress (lock: ${lockPath})`,
      );
      err.code = 'INSTALL_LOCK_HELD';
      throw err;
    }
    api.writeFileSync(lockPath, payload);
  }

  let released = false;
  return {
    lockPath,
    release() {
      if (released) return;
      released = true;
      try {
        api.rmSync(lockPath, { force: true });
      } catch {
        // ignore
      }
    },
  };
}

/**
 * Best-effort cleanup of leftover candidate/backup/lock artifacts in parent.
 * @param {string} parent
 * @param {FsApi} api
 * @param {string[]} [extraPaths]
 */
function cleanupInstallArtifacts(parent, api, extraPaths = []) {
  for (const extra of extraPaths) {
    try {
      api.rmSync(extra, { recursive: true, force: true });
    } catch {
      // ignore
    }
  }
  try {
    const names = api.readdirSync(parent);
    for (const name of names) {
      if (
        name === INSTALL_LOCK_NAME
        || name.startsWith('.Semantouch.app.incoming-')
        || name.startsWith('.Semantouch.app.backup-')
        || name.startsWith('.Semantouch.app.candidate-')
      ) {
        try {
          api.rmSync(path.join(parent, name), { recursive: true, force: true });
        } catch {
          // ignore
        }
      }
    }
  } catch {
    // ignore
  }
}

/**
 * Atomic whole-app install with backup/rollback and install lock.
 * Never mutates bundle contents. Staging uses /usr/bin/ditto by default.
 *
 * When `ops.verify` is provided, the previous install is preserved until that
 * callback succeeds against the newly cut-over destination. Any verification
 * failure restores the previous app byte-for-byte and removes candidate/backup/lock.
 *
 * @param {string} sourceApp
 * @param {string} destinationApp
 * @param {FsApi} [api]
 * @param {{
 *   copyTree?: (src: string, dest: string) => void,
 *   run?: Function,
 *   verify?: (installedApp: string) => void,
 *   pid?: number,
 *   now?: () => number,
 *   lock?: { release: () => void, lockPath: string } | null,
 *   acquireLock?: boolean,
 * }} [ops]
 */
function atomicInstallApp(sourceApp, destinationApp, api = defaultFs, ops = {}) {
  if (path.basename(destinationApp) !== APP_BUNDLE_NAME) {
    throw new Error(`destination must be named ${APP_BUNDLE_NAME}`);
  }

  const parent = path.dirname(destinationApp);
  api.mkdirSync(parent, { recursive: true });

  const token = `${ops.pid ?? process.pid}-${(ops.now ?? Date.now)()}`;
  const incoming = path.join(parent, `.Semantouch.app.incoming-${token}`);
  const backup = path.join(parent, `.Semantouch.app.backup-${token}`);

  const acquireLock = ops.acquireLock !== false;
  const lock =
    ops.lock
    ?? (acquireLock ? acquireInstallLock(parent, api, { pid: ops.pid, now: ops.now }) : null);

  const copyTree =
    ops.copyTree
    ?? ((src, dest) => {
      dittoCopyTree(src, dest, { run: ops.run });
    });

  const cleanupTemps = () => {
    for (const p of [incoming, backup]) {
      try {
        api.rmSync(p, { recursive: true, force: true });
      } catch {
        // ignore
      }
    }
  };

  try {
    try {
      api.rmSync(incoming, { recursive: true, force: true });
    } catch {
      // ignore
    }
    try {
      api.rmSync(backup, { recursive: true, force: true });
    } catch {
      // ignore
    }

    try {
      copyTree(sourceApp, incoming);
    } catch (error) {
      cleanupTemps();
      throw new Error(`failed to stage ${APP_BUNDLE_NAME}: ${error.message}`);
    }

    const hadExisting = api.existsSync(destinationApp);
    if (hadExisting) {
      try {
        api.renameSync(destinationApp, backup);
      } catch (error) {
        cleanupTemps();
        throw new Error(`failed to move existing install aside: ${error.message}`);
      }
    }

    try {
      api.renameSync(incoming, destinationApp);
    } catch (error) {
      if (hadExisting) {
        try {
          api.renameSync(backup, destinationApp);
        } catch {
          // best-effort rollback
        }
      }
      cleanupTemps();
      throw new Error(`failed to install ${destinationApp}: ${error.message}`);
    }

    // Keep previous app until verification callback succeeds (if provided).
    const runPostVerify = () => {
      if (typeof ops.verify === 'function') {
        ops.verify(destinationApp);
      }
      if (!isInstalledApp(destinationApp, api)) {
        throw new Error(
          `installed app is missing executable relay at ${path.join(destinationApp, RELAY_RELATIVE_PATH)}`,
        );
      }
    };

    try {
      runPostVerify();
    } catch (error) {
      // Roll back candidate; restore previous bytes; remove artifacts.
      try {
        api.rmSync(destinationApp, { recursive: true, force: true });
      } catch {
        // ignore
      }
      if (hadExisting) {
        try {
          api.renameSync(backup, destinationApp);
        } catch {
          // best-effort
        }
      }
      cleanupTemps();
      const wrapped = new Error(
        `post-install verification failed; previous install restored: ${error.message}`,
      );
      wrapped.code = error.code ?? 'INSTALL_VERIFY_FAILED';
      wrapped.cause = error;
      throw wrapped;
    }

    // Success: drop backup and any leftover temps.
    try {
      api.rmSync(backup, { recursive: true, force: true });
    } catch {
      // ignore leftover backup
    }
    try {
      api.rmSync(incoming, { recursive: true, force: true });
    } catch {
      // ignore
    }
  } finally {
    if (lock && typeof lock.release === 'function') {
      lock.release();
    }
  }
}

module.exports = {
  defaultFs,
  isExecutableRelay,
  isInstalledApp,
  isWritableDestination,
  locateExactlyOneApp,
  dittoCopyTree,
  acquireInstallLock,
  cleanupInstallArtifacts,
  atomicInstallApp,
};
