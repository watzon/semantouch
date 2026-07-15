'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { resolveRelayPath } = require('../lib/bootstrap');
const { BootstrapError } = require('../lib/errors');
const { appZipAssetName } = require('../lib/constants');
const { sha256Hex } = require('../lib/download');
const {
  createMemoryFs,
  seedAppBundle,
  createSuccessfulVerifyRun,
  createCanonicalAppZip,
} = require('./helpers');

const DARWIN_OK = '23.6.0';

describe('resolveRelayPath', () => {
  it('returns existing system install after successful verification without downloading', async () => {
    const home = '/Users/tester';
    const version = '0.2.1';
    const api = createMemoryFs();
    const systemApp = '/Applications/Semantouch.app';
    seedAppBundle(api, systemApp);

    let fetched = 0;
    const relay = await resolveRelayPath({
      fs: api,
      homedir: () => home,
      systemApplicationsDir: '/Applications',
      version,
      platform: { platform: 'darwin', arch: 'arm64', release: DARWIN_OK },
      run: createSuccessfulVerifyRun(version),
      fetch: async () => {
        fetched += 1;
        return Buffer.alloc(0);
      },
      warn: () => {},
      log: () => {},
    });

    assert.equal(relay, path.join(systemApp, 'Contents', 'MacOS', 'semantouch'));
    assert.equal(fetched, 0);
  });

  it('warns when both installs exist, prefers system, and verifies the preferred app', async () => {
    const home = '/Users/tester';
    const version = '0.2.1';
    const api = createMemoryFs();
    const systemApp = '/Applications/Semantouch.app';
    const userApp = path.join(home, 'Applications', 'Semantouch.app');
    seedAppBundle(api, systemApp);
    seedAppBundle(api, userApp);

    /** @type {string[]} */
    const warnings = [];
    /** @type {string[]} */
    const verifiedTargets = [];
    const baseRun = createSuccessfulVerifyRun(version);
    const run = (command, args, options) => {
      if (command === '/usr/bin/codesign' && args[0] === '--verify') {
        verifiedTargets.push(args[args.length - 1]);
      }
      return baseRun(command, args, options);
    };

    const relay = await resolveRelayPath({
      fs: api,
      homedir: () => home,
      systemApplicationsDir: '/Applications',
      version,
      platform: { platform: 'darwin', arch: 'x64', release: DARWIN_OK },
      run,
      warn: (message) => warnings.push(message),
      log: () => {},
    });

    assert.equal(relay, path.join(systemApp, 'Contents', 'MacOS', 'semantouch'));
    assert.equal(warnings.length, 1);
    assert.match(warnings[0], /preferring \/Applications\/Semantouch\.app/);
    assert.ok(verifiedTargets.includes(systemApp));
    assert.ok(!verifiedTargets.includes(userApp));
  });

  it('fails closed on invalid existing canonical app without download or exec', async () => {
    const home = '/Users/tester';
    const version = '0.2.1';
    const api = createMemoryFs();
    const systemApp = '/Applications/Semantouch.app';
    seedAppBundle(api, systemApp);

    let fetched = 0;
    await assert.rejects(
      () =>
        resolveRelayPath({
          fs: api,
          homedir: () => home,
          systemApplicationsDir: '/Applications',
          version,
          platform: { platform: 'darwin', arch: 'arm64', release: DARWIN_OK },
          run: createSuccessfulVerifyRun(version, {
            bundleId: 'com.example.evil',
          }),
          fetch: async () => {
            fetched += 1;
            return Buffer.alloc(0);
          },
          warn: () => {},
          log: () => {},
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'IDENTITY_MISMATCH');
        return true;
      },
    );
    assert.equal(fetched, 0);
    assert.equal(api.existsSync(systemApp), true);
  });

  it('fails closed on version-mismatched existing app without silent replace', async () => {
    const home = '/Users/tester';
    const api = createMemoryFs();
    const userApp = path.join(home, 'Applications', 'Semantouch.app');
    seedAppBundle(api, userApp);

    let fetched = 0;
    await assert.rejects(
      () =>
        resolveRelayPath({
          fs: api,
          homedir: () => home,
          systemApplicationsDir: '/Applications',
          version: '0.2.1',
          platform: { platform: 'darwin', arch: 'arm64', release: DARWIN_OK },
          run: createSuccessfulVerifyRun('0.1.0'),
          fetch: async () => {
            fetched += 1;
            return Buffer.alloc(0);
          },
          warn: () => {},
          log: () => {},
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'VERSION_MISMATCH');
        return true;
      },
    );
    assert.equal(fetched, 0);
    assert.equal(api.existsSync(userApp), true);
  });

  it('fails closed on non-universal2 existing app', async () => {
    const home = '/Users/tester';
    const version = '0.2.1';
    const api = createMemoryFs();
    const systemApp = '/Applications/Semantouch.app';
    seedAppBundle(api, systemApp);

    await assert.rejects(
      () =>
        resolveRelayPath({
          fs: api,
          homedir: () => home,
          systemApplicationsDir: '/Applications',
          version,
          platform: { platform: 'darwin', arch: 'arm64', release: DARWIN_OK },
          run: createSuccessfulVerifyRun(version, { archs: 'arm64' }),
          fetch: async () => Buffer.alloc(0),
          warn: () => {},
          log: () => {},
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'ARCH_MISMATCH');
        return true;
      },
    );
  });

  it('downloads, verifies, and installs when missing', async () => {
    const home = '/Users/tester';
    const version = '0.2.1';
    const api = createMemoryFs();
    api.mkdirSync('/tmp', { recursive: true });
    api.mkdirSync(home, { recursive: true });

    const zipBuffer = createCanonicalAppZip();
    const zipName = appZipAssetName(version);
    const digest = sha256Hex(zipBuffer);
    const checksumText = `${digest}  ${zipName}\n`;

    const baseRun = createSuccessfulVerifyRun(version);
    const runWithExtract = (command, args, options) => {
      if (command === '/usr/bin/ditto' && args[0] === '-x') {
        const extractDir = args[3];
        const appPath = path.join(extractDir, 'Semantouch.app');
        seedAppBundle(api, appPath);
        return { status: 0, stdout: '', stderr: '', error: null };
      }
      if (command === '/usr/bin/ditto' && args[0] !== '-x') {
        seedAppBundle(api, args[1]);
        return { status: 0, stdout: '', stderr: '', error: null };
      }
      return baseRun(command, args, options);
    };

    const relay = await resolveRelayPath({
      fs: api,
      homedir: () => home,
      systemApplicationsDir: '/Applications',
      version,
      releaseBaseUrl: 'https://example.test/releases/v0.2.1',
      platform: { platform: 'darwin', arch: 'arm64', release: DARWIN_OK },
      pin: null,
      fetch: async (url) => {
        if (url.endsWith('.sha256')) return Buffer.from(checksumText);
        return zipBuffer;
      },
      run: runWithExtract,
      copyTree: (_src, dst) => {
        seedAppBundle(api, dst);
      },
      warn: () => {},
      log: () => {},
    });

    const expected = path.join(home, 'Applications', 'Semantouch.app', 'Contents', 'MacOS', 'semantouch');
    assert.equal(relay, expected);
    assert.equal(api.existsSync(path.join(home, 'Applications', 'Semantouch.app')), true);
  });

  it('rejects unsupported OS before any download', async () => {
    const api = createMemoryFs();
    let fetched = 0;
    await assert.rejects(
      () =>
        resolveRelayPath({
          fs: api,
          platform: { platform: 'win32', arch: 'x64', release: '10.0' },
          fetch: async () => {
            fetched += 1;
            return Buffer.alloc(0);
          },
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'UNSUPPORTED_PLATFORM');
        return true;
      },
    );
    assert.equal(fetched, 0);
  });

  it('rejects macOS older than 14 before any download', async () => {
    const api = createMemoryFs();
    let fetched = 0;
    await assert.rejects(
      () =>
        resolveRelayPath({
          fs: api,
          platform: { platform: 'darwin', arch: 'arm64', release: '22.6.0' },
          fetch: async () => {
            fetched += 1;
            return Buffer.alloc(0);
          },
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'UNSUPPORTED_OS_VERSION');
        return true;
      },
    );
    assert.equal(fetched, 0);
  });

  it('surfaces checksum mismatch from download', async () => {
    const home = '/Users/tester';
    const version = '0.2.1';
    const api = createMemoryFs();
    api.mkdirSync('/tmp', { recursive: true });
    const zipName = appZipAssetName(version);

    await assert.rejects(
      () =>
        resolveRelayPath({
          fs: api,
          homedir: () => home,
          systemApplicationsDir: '/Applications',
          version,
          releaseBaseUrl: 'https://example.test/v0.2.1',
          platform: { platform: 'darwin', arch: 'arm64', release: DARWIN_OK },
          pin: null,
          fetch: async (url) => {
            if (url.endsWith('.sha256')) {
              return Buffer.from(`${'f'.repeat(64)}  ${zipName}\n`);
            }
            return Buffer.from('content');
          },
          warn: () => {},
          log: () => {},
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'CHECKSUM_MISMATCH');
        return true;
      },
    );
  });
});
