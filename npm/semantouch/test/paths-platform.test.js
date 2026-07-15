'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { assertSupportedPlatform } = require('../lib/platform');
const { discoverInstalls, userInstallDestination, relayPathForApp } = require('../lib/paths');
const { BootstrapError } = require('../lib/errors');
const { createMemoryFs, seedAppBundle } = require('./helpers');

describe('assertSupportedPlatform', () => {
  it('accepts darwin arm64 and x64 on macOS 14+', () => {
    assert.doesNotThrow(() =>
      assertSupportedPlatform({ platform: 'darwin', arch: 'arm64', release: '23.0.0' }),
    );
    assert.doesNotThrow(() =>
      assertSupportedPlatform({ platform: 'darwin', arch: 'x64', release: '24.1.0' }),
    );
  });

  it('rejects non-darwin platforms clearly', () => {
    assert.throws(
      () => assertSupportedPlatform({ platform: 'linux', arch: 'arm64', release: '6.0' }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'UNSUPPORTED_PLATFORM');
        return true;
      },
    );
  });

  it('rejects unsupported architectures clearly', () => {
    assert.throws(
      () => assertSupportedPlatform({ platform: 'darwin', arch: 'ia32', release: '23.0.0' }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'UNSUPPORTED_ARCH');
        return true;
      },
    );
  });

  it('rejects macOS older than 14 (Darwin < 23)', () => {
    assert.throws(
      () => assertSupportedPlatform({ platform: 'darwin', arch: 'arm64', release: '22.6.0' }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'UNSUPPORTED_OS_VERSION');
        assert.match(error.message, /macOS 14/);
        return true;
      },
    );
  });
});

describe('discoverInstalls precedence', () => {
  it('prefers /Applications over ~/Applications and warns when both exist', () => {
    const home = '/Users/tester';
    const api = createMemoryFs();
    api.homedir = () => home;

    const systemApp = '/Applications/Semantouch.app';
    const userApp = path.join(home, 'Applications', 'Semantouch.app');
    seedAppBundle(api, systemApp);
    seedAppBundle(api, userApp);

    const selection = discoverInstalls({
      fs: api,
      homedir: () => home,
      systemApplicationsDir: '/Applications',
    });

    assert.equal(selection.hasDuplicates, true);
    assert.equal(selection.preferredApp, systemApp);
    assert.equal(selection.preferredRelay, path.join(systemApp, 'Contents', 'MacOS', 'semantouch'));
    assert.match(selection.warning, /preferring \/Applications\/Semantouch\.app/);
  });

  it('uses ~/Applications when system install is missing', () => {
    const home = '/Users/tester';
    const api = createMemoryFs();
    const userApp = path.join(home, 'Applications', 'Semantouch.app');
    seedAppBundle(api, userApp);

    const selection = discoverInstalls({
      fs: api,
      homedir: () => home,
      systemApplicationsDir: '/Applications',
    });

    assert.equal(selection.preferredApp, userApp);
    assert.equal(selection.hasDuplicates, false);
  });

  it('returns null preferred when neither install exists', () => {
    const api = createMemoryFs();
    const selection = discoverInstalls({
      fs: api,
      homedir: () => '/Users/tester',
      systemApplicationsDir: '/Applications',
    });
    assert.equal(selection.preferredApp, null);
    assert.equal(selection.preferredRelay, null);
  });

  it('userInstallDestination is always ~/Applications/Semantouch.app', () => {
    const api = createMemoryFs();
    assert.equal(
      userInstallDestination({ fs: api, homedir: () => '/Users/tester' }),
      '/Users/tester/Applications/Semantouch.app',
    );
  });

  it('relayPathForApp joins Contents/MacOS/semantouch', () => {
    assert.equal(
      relayPathForApp('/Applications/Semantouch.app'),
      path.join('/Applications/Semantouch.app', 'Contents', 'MacOS', 'semantouch'),
    );
  });
});
