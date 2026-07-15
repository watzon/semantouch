'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const {
  atomicInstallApp,
  isInstalledApp,
  acquireInstallLock,
} = require('../lib/fs');
const { INSTALL_LOCK_NAME } = require('../lib/constants');
const { createMemoryFs, seedAppBundle } = require('./helpers');

describe('atomicInstallApp', () => {
  it('installs a whole app bundle to the destination', () => {
    const api = createMemoryFs();
    const source = '/tmp/extract/Semantouch.app';
    const dest = '/Users/tester/Applications/Semantouch.app';
    seedAppBundle(api, source);

    atomicInstallApp(source, dest, api, {
      copyTree: (_src, dst) => {
        seedAppBundle(api, dst);
      },
    });

    assert.equal(isInstalledApp(dest, api), true);
    assert.equal(
      api.existsSync(path.join(dest, 'Contents', 'MacOS', 'semantouch')),
      true,
    );
    assert.equal(api.existsSync(path.join(path.dirname(dest), INSTALL_LOCK_NAME)), false);
  });

  it('replaces an existing install and removes backup after success', () => {
    const api = createMemoryFs();
    const source = '/tmp/extract/Semantouch.app';
    const dest = '/Users/tester/Applications/Semantouch.app';
    seedAppBundle(api, source);
    seedAppBundle(api, dest);
    api.writeFileSync(path.join(dest, 'Contents', 'MacOS', 'semantouch'), 'old-relay');

    let copied = false;
    atomicInstallApp(source, dest, api, {
      copyTree: (_src, dst) => {
        copied = true;
        seedAppBundle(api, dst);
        api.writeFileSync(path.join(dst, 'Contents', 'MacOS', 'semantouch'), 'new-relay');
      },
    });

    assert.equal(copied, true);
    assert.equal(
      api.readFileSync(path.join(dest, 'Contents', 'MacOS', 'semantouch'), 'utf8').toString(),
      'new-relay',
    );
    const parent = path.dirname(dest);
    const leftovers = api.readdirSync(parent).filter((name) => name.startsWith('.Semantouch.app.'));
    assert.deepEqual(leftovers, []);
  });

  it('rolls back when cutover rename fails', () => {
    const api = createMemoryFs();
    const source = '/tmp/extract/Semantouch.app';
    const dest = '/Users/tester/Applications/Semantouch.app';
    seedAppBundle(api, source);
    seedAppBundle(api, dest);
    api.writeFileSync(path.join(dest, 'Contents', 'MacOS', 'semantouch'), 'original');

    const originalRename = api.renameSync.bind(api);
    let renameCount = 0;
    api.renameSync = (src, dst) => {
      renameCount += 1;
      if (renameCount === 2) {
        throw new Error('simulated rename failure');
      }
      return originalRename(src, dst);
    };

    assert.throws(
      () =>
        atomicInstallApp(source, dest, api, {
          copyTree: (_src, dst) => {
            seedAppBundle(api, dst);
            api.writeFileSync(path.join(dst, 'Contents', 'MacOS', 'semantouch'), 'incoming');
          },
        }),
      /failed to install/,
    );

    assert.equal(
      api.readFileSync(path.join(dest, 'Contents', 'MacOS', 'semantouch'), 'utf8').toString(),
      'original',
    );
  });

  it('restores previous install byte-for-byte when post-verify fails', () => {
    const api = createMemoryFs();
    const source = '/tmp/extract/Semantouch.app';
    const dest = '/Users/tester/Applications/Semantouch.app';
    seedAppBundle(api, source, { relayContent: 'new-relay-bytes' });
    seedAppBundle(api, dest, { relayContent: 'old-relay-bytes' });

    assert.throws(
      () =>
        atomicInstallApp(source, dest, api, {
          copyTree: (_src, dst) => {
            seedAppBundle(api, dst, { relayContent: 'new-relay-bytes' });
          },
          verify: () => {
            throw Object.assign(new Error('stapler failed'), { code: 'NOTARIZATION_FAILED' });
          },
        }),
      (error) => {
        assert.match(error.message, /post-install verification failed/i);
        assert.match(error.message, /previous install restored/i);
        return true;
      },
    );

    assert.equal(
      api.readFileSync(path.join(dest, 'Contents', 'MacOS', 'semantouch'), 'utf8').toString(),
      'old-relay-bytes',
    );
    const parent = path.dirname(dest);
    const leftovers = api.readdirSync(parent).filter(
      (name) =>
        name.startsWith('.Semantouch.app.incoming-')
        || name.startsWith('.Semantouch.app.backup-')
        || name === INSTALL_LOCK_NAME,
    );
    assert.deepEqual(leftovers, []);
  });

  it('removes candidate and leaves no install when verify fails without previous app', () => {
    const api = createMemoryFs();
    const source = '/tmp/extract/Semantouch.app';
    const dest = '/Users/tester/Applications/Semantouch.app';
    seedAppBundle(api, source);

    assert.throws(
      () =>
        atomicInstallApp(source, dest, api, {
          copyTree: (_src, dst) => seedAppBundle(api, dst),
          verify: () => {
            throw new Error('gatekeeper rejected');
          },
        }),
      /post-install verification failed/,
    );

    assert.equal(api.existsSync(dest), false);
    const parent = path.dirname(dest);
    const leftovers = api.readdirSync(parent).filter(
      (name) => name.startsWith('.Semantouch.app.') || name === INSTALL_LOCK_NAME,
    );
    assert.deepEqual(leftovers, []);
  });

  it('refuses destinations not named Semantouch.app', () => {
    const api = createMemoryFs();
    const source = '/tmp/extract/Semantouch.app';
    seedAppBundle(api, source);
    assert.throws(
      () =>
        atomicInstallApp(source, '/Users/tester/Applications/Other.app', api, {
          copyTree: (_src, dst) => seedAppBundle(api, dst),
        }),
      /destination must be named Semantouch\.app/,
    );
  });

  it('uses ditto for staging when copyTree is not provided', () => {
    const api = createMemoryFs();
    const source = '/tmp/extract/Semantouch.app';
    const dest = '/Users/tester/Applications/Semantouch.app';
    seedAppBundle(api, source);

    /** @type {string[][]} */
    const dittoArgs = [];
    atomicInstallApp(source, dest, api, {
      run: (command, args) => {
        if (command === '/usr/bin/ditto') {
          dittoArgs.push(args);
          seedAppBundle(api, args[1]);
          return { status: 0, stdout: '', stderr: '', error: null };
        }
        return { status: 1, stdout: '', stderr: 'unexpected', error: null };
      },
    });

    assert.equal(dittoArgs.length, 1);
    assert.equal(dittoArgs[0][0], source);
    assert.match(dittoArgs[0][1], /\.Semantouch\.app\.incoming-/);
    assert.equal(isInstalledApp(dest, api), true);
  });
});

describe('acquireInstallLock', () => {
  it('prevents concurrent first-run cutovers', () => {
    const api = createMemoryFs();
    const parent = '/Users/tester/Applications';
    api.mkdirSync(parent, { recursive: true });

    const first = acquireInstallLock(parent, api, { pid: 111, now: () => 1 });
    assert.equal(api.existsSync(path.join(parent, INSTALL_LOCK_NAME)), true);

    assert.throws(
      () => acquireInstallLock(parent, api, { pid: 222, now: () => 2 }),
      (error) => {
        assert.equal(error.code, 'INSTALL_LOCK_HELD');
        assert.match(error.message, /another Semantouch install is in progress/i);
        return true;
      },
    );

    first.release();
    assert.equal(api.existsSync(path.join(parent, INSTALL_LOCK_NAME)), false);

    const second = acquireInstallLock(parent, api, { pid: 222, now: () => 3 });
    second.release();
  });

  it('atomicInstallApp fails closed when lock is already held', () => {
    const api = createMemoryFs();
    const source = '/tmp/extract/Semantouch.app';
    const dest = '/Users/tester/Applications/Semantouch.app';
    seedAppBundle(api, source);
    api.mkdirSync(path.dirname(dest), { recursive: true });
    const held = acquireInstallLock(path.dirname(dest), api, { pid: 9, now: () => 1 });

    assert.throws(
      () =>
        atomicInstallApp(source, dest, api, {
          copyTree: (_src, dst) => seedAppBundle(api, dst),
        }),
      (error) => {
        assert.equal(error.code, 'INSTALL_LOCK_HELD');
        return true;
      },
    );

    assert.equal(api.existsSync(path.join(path.dirname(dest), INSTALL_LOCK_NAME)), true);
    held.release();
  });
});
