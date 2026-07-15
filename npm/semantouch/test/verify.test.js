'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { verifyAppBundle } = require('../lib/verify');
const { BootstrapError } = require('../lib/errors');
const {
  createMemoryFs,
  seedAppBundle,
  createSuccessfulVerifyRun,
  createRunFake,
} = require('./helpers');

describe('verifyAppBundle', () => {
  const version = '0.2.1';
  const appPath = '/tmp/stage/Semantouch.app';

  it('accepts a valid universal2 signed layout', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    assert.doesNotThrow(() =>
      verifyAppBundle(appPath, version, {
        fs: api,
        run: createSuccessfulVerifyRun(version),
      }),
    );
  });

  it('rejects identity mismatch', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    assert.throws(
      () =>
        verifyAppBundle(appPath, version, {
          fs: api,
          run: createSuccessfulVerifyRun(version, {
            bundleId: 'com.example.wrong',
          }),
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'IDENTITY_MISMATCH');
        return true;
      },
    );
  });

  it('rejects version mismatch', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    assert.throws(
      () =>
        verifyAppBundle(appPath, version, {
          fs: api,
          run: createSuccessfulVerifyRun('9.9.9'),
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'VERSION_MISMATCH');
        return true;
      },
    );
  });

  it('rejects architecture mismatch (non-universal2)', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    assert.throws(
      () =>
        verifyAppBundle(appPath, version, {
          fs: api,
          run: createSuccessfulVerifyRun(version, { archs: 'arm64' }),
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'ARCH_MISMATCH');
        assert.match(error.message, /universal2/i);
        return true;
      },
    );
  });

  it('rejects extra architecture slices', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    assert.throws(
      () =>
        verifyAppBundle(appPath, version, {
          fs: api,
          run: createSuccessfulVerifyRun(version, { archs: 'arm64 x86_64 arm64e' }),
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'ARCH_MISMATCH');
        assert.match(error.message, /unexpected architecture/i);
        return true;
      },
    );
  });

  it('rejects team identifier mismatch via codesign', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    assert.throws(
      () =>
        verifyAppBundle(appPath, version, {
          fs: api,
          run: createSuccessfulVerifyRun(version, { team: 'WRONGTEAM1' }),
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'IDENTITY_MISMATCH');
        assert.match(error.message, /TeamIdentifier/);
        return true;
      },
    );
  });

  it('rejects missing authority metadata', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    assert.throws(
      () =>
        verifyAppBundle(appPath, version, {
          fs: api,
          run: createSuccessfulVerifyRun(version, { authority: '' }),
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.ok(
          error.code === 'IDENTITY_MISMATCH' || error.code === 'INVALID_SIGNATURE',
        );
        return true;
      },
    );
  });

  it('rejects missing Hardened Runtime flags', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    assert.throws(
      () =>
        verifyAppBundle(appPath, version, {
          fs: api,
          run: createSuccessfulVerifyRun(version, { flags: '0x0' }),
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_SIGNATURE');
        assert.match(error.message, /Hardened Runtime/i);
        return true;
      },
    );
  });

  it('rejects missing secure timestamp', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    assert.throws(
      () =>
        verifyAppBundle(appPath, version, {
          fs: api,
          run: createSuccessfulVerifyRun(version, { timestamp: null }),
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_SIGNATURE');
        assert.match(error.message, /timestamp/i);
        return true;
      },
    );
  });

  it('rejects missing designated requirement team binding', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    assert.throws(
      () =>
        verifyAppBundle(appPath, version, {
          fs: api,
          run: createSuccessfulVerifyRun(version, {
            requirement: 'designated => identifier "tech.watzon.semantouch"',
          }),
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_SIGNATURE');
        assert.match(error.message, /team/i);
        return true;
      },
    );
  });

  it('rejects wrong bundle leaf name', () => {
    const api = createMemoryFs();
    const wrong = '/tmp/stage/Wrong.app';
    seedAppBundle(api, wrong);
    assert.throws(
      () =>
        verifyAppBundle(wrong, version, {
          fs: api,
          run: createSuccessfulVerifyRun(version),
          skipSignature: true,
          skipNotarization: true,
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_BUNDLE');
        return true;
      },
    );
  });

  it('rejects raw helper nested inside the bundle', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    api.writeFileSync(
      path.join(appPath, 'Contents', 'MacOS', 'semantouch-macos-arm64'),
      'raw',
    );
    assert.throws(
      () =>
        verifyAppBundle(appPath, version, {
          fs: api,
          run: createSuccessfulVerifyRun(version),
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_BUNDLE');
        assert.match(error.message, /raw helper/);
        return true;
      },
    );
  });

  it('rejects unexpected nested Mach-O', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    api.writeFileSync(
      path.join(appPath, 'Contents', 'MacOS', 'evil-helper'),
      'macho-bytes',
    );
    assert.throws(
      () =>
        verifyAppBundle(appPath, version, {
          fs: api,
          run: createSuccessfulVerifyRun(version, { extraMachO: true }),
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_BUNDLE');
        assert.match(error.message, /unexpected nested Mach-O/i);
        return true;
      },
    );
  });

  it('rejects failed stapler validation', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    assert.throws(
      () =>
        verifyAppBundle(appPath, version, {
          fs: api,
          run: createSuccessfulVerifyRun(version, { staplerStatus: 1 }),
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'NOTARIZATION_FAILED');
        assert.match(error.message, /stapled notarization ticket/i);
        return true;
      },
    );
  });

  it('rejects failed Gatekeeper assessment', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    assert.throws(
      () =>
        verifyAppBundle(appPath, version, {
          fs: api,
          run: createSuccessfulVerifyRun(version, { spctlStatus: 3 }),
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'NOTARIZATION_FAILED');
        return true;
      },
    );
  });

  it('rejects missing CFBundlePackageType', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    const base = createSuccessfulVerifyRun(version);
    const run = createRunFake((command, args) => {
      if (command === '/usr/bin/plutil' && args[1] === 'CFBundlePackageType') {
        return { status: 1, stderr: 'key not found' };
      }
      return base(command, args);
    });
    assert.throws(
      () =>
        verifyAppBundle(appPath, version, {
          fs: api,
          run,
          skipSignature: true,
          skipNotarization: true,
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_BUNDLE');
        return true;
      },
    );
  });

  it('can skip signature checks for layout-only unit tests', () => {
    const api = createMemoryFs();
    seedAppBundle(api, appPath);
    const run = createRunFake((command, args) => {
      if (command === '/usr/bin/plutil') {
        const key = args[1];
        const map = {
          CFBundleIdentifier: 'tech.watzon.semantouch',
          CFBundleExecutable: 'SemantouchHost',
          CFBundlePackageType: 'APPL',
          CFBundleShortVersionString: version,
          CFBundleVersion: version,
          LSMinimumSystemVersion: '14.0',
        };
        return { status: 0, stdout: `${map[key]}\n` };
      }
      if (command === '/usr/bin/file') {
        return { status: 0, stdout: 'Mach-O universal binary\n' };
      }
      if (command === '/usr/bin/lipo') {
        return { status: 0, stdout: 'x86_64 arm64\n' };
      }
      if (
        command === '/usr/bin/codesign'
        || command === '/usr/sbin/spctl'
        || command === '/usr/bin/xcrun'
      ) {
        return { status: 1, stderr: 'should not be called' };
      }
      return null;
    });

    assert.doesNotThrow(() =>
      verifyAppBundle(appPath, version, {
        fs: api,
        run,
        skipSignature: true,
        skipNotarization: true,
      }),
    );
  });
});
