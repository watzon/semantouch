'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');
const {
  parseChecksumSidecar,
  sha256Hex,
  assertChecksumMatch,
  assertHttpsUrl,
  downloadBuffer,
  downloadVerifiedZip,
  releaseAssetUrls,
  loadReleaseDigestPin,
} = require('../lib/download');
const { BootstrapError } = require('../lib/errors');
const { appZipAssetName, appZipChecksumAssetName } = require('../lib/constants');

describe('checksum helpers', () => {
  it('parses lowercase 64-hex plus two spaces plus basename', () => {
    const digest = 'a'.repeat(64);
    const name = appZipAssetName('0.2.1');
    const parsed = parseChecksumSidecar(`${digest}  ${name}\n`, name);
    assert.equal(parsed, digest);
  });

  it('rejects basename mismatch in sidecar', () => {
    const digest = 'b'.repeat(64);
    assert.throws(
      () => parseChecksumSidecar(`${digest}  wrong.zip\n`, 'right.zip'),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_CHECKSUM');
        return true;
      },
    );
  });

  it('assertChecksumMatch rejects mismatch', () => {
    assert.throws(
      () => assertChecksumMatch('a'.repeat(64), 'c'.repeat(64)),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'CHECKSUM_MISMATCH');
        assert.match(error.message, /SHA-256 verification/i);
        return true;
      },
    );
  });

  it('sha256Hex is stable', () => {
    const buf = Buffer.from('semantouch');
    assert.equal(
      sha256Hex(buf),
      crypto.createHash('sha256').update(buf).digest('hex'),
    );
  });
});

describe('assertHttpsUrl', () => {
  it('accepts https URLs', () => {
    assert.equal(assertHttpsUrl('https://example.test/a').protocol, 'https:');
  });

  it('rejects http and other schemes', () => {
    assert.throws(
      () => assertHttpsUrl('http://example.test/a'),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INSECURE_URL');
        return true;
      },
    );
    assert.throws(
      () => assertHttpsUrl('file:///tmp/x'),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INSECURE_URL');
        return true;
      },
    );
  });
});

describe('releaseAssetUrls', () => {
  it('uses universal2 canonical names and versioned tag base', () => {
    const urls = releaseAssetUrls('1.2.3');
    assert.equal(urls.zipName, 'Semantouch-v1.2.3-macos-universal2.zip');
    assert.equal(urls.checksumName, 'Semantouch-v1.2.3-macos-universal2.zip.sha256');
    assert.equal(
      urls.zipUrl,
      'https://github.com/watzon/semantouch/releases/download/v1.2.3/Semantouch-v1.2.3-macos-universal2.zip',
    );
    assert.equal(
      urls.checksumUrl,
      'https://github.com/watzon/semantouch/releases/download/v1.2.3/Semantouch-v1.2.3-macos-universal2.zip.sha256',
    );
  });
});

describe('loadReleaseDigestPin', () => {
  it('accepts a valid pin object', () => {
    const pin = loadReleaseDigestPin({
      version: '0.2.1',
      pin: {
        version: '0.2.1',
        sha256: 'a'.repeat(64),
        asset: appZipAssetName('0.2.1'),
      },
    });
    assert.deepEqual(pin, {
      version: '0.2.1',
      sha256: 'a'.repeat(64),
      asset: appZipAssetName('0.2.1'),
    });
  });

  it('rejects pin version mismatch', () => {
    assert.throws(
      () =>
        loadReleaseDigestPin({
          version: '0.2.1',
          pin: {
            version: '9.9.9',
            sha256: 'a'.repeat(64),
            asset: appZipAssetName('9.9.9'),
          },
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_RELEASE_DIGEST');
        return true;
      },
    );
  });
});

describe('downloadVerifiedZip', () => {
  it('verifies checksum before returning zip bytes', async () => {
    const version = '0.2.1';
    const zipName = appZipAssetName(version);
    const zipBuffer = Buffer.from('fake-zip-bytes');
    const digest = sha256Hex(zipBuffer);
    const checksumText = `${digest}  ${zipName}\n`;

    const fetched = [];
    const result = await downloadVerifiedZip(version, {
      baseUrl: 'https://example.test/v0.2.1',
      pin: null,
      fetch: async (url) => {
        fetched.push(url);
        if (url.endsWith('.sha256')) {
          return Buffer.from(checksumText);
        }
        return zipBuffer;
      },
    });

    assert.equal(result.zipName, zipName);
    assert.equal(result.checksum, digest);
    assert.deepEqual(result.zipBuffer, zipBuffer);
    assert.equal(fetched.length, 2);
  });

  it('rejects checksum mismatch', async () => {
    const version = '0.2.1';
    const zipName = appZipAssetName(version);
    const zipBuffer = Buffer.from('fake-zip-bytes');
    const bad = `${'0'.repeat(64)}  ${zipName}\n`;

    await assert.rejects(
      () =>
        downloadVerifiedZip(version, {
          baseUrl: 'https://example.test/v0.2.1',
          pin: null,
          fetch: async (url) => {
            if (url.endsWith('.sha256')) return Buffer.from(bad);
            return zipBuffer;
          },
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'CHECKSUM_MISMATCH');
        return true;
      },
    );
  });

  it('rejects pin mismatch against downloaded bytes', async () => {
    const version = '0.2.1';
    const zipName = appZipAssetName(version);
    const zipBuffer = Buffer.from('fake-zip-bytes');
    const digest = sha256Hex(zipBuffer);
    const checksumText = `${digest}  ${zipName}\n`;

    await assert.rejects(
      () =>
        downloadVerifiedZip(version, {
          baseUrl: 'https://example.test/v0.2.1',
          pin: {
            version,
            sha256: 'f'.repeat(64),
            asset: zipName,
          },
          fetch: async (url) => {
            if (url.endsWith('.sha256')) return Buffer.from(checksumText);
            return zipBuffer;
          },
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'CHECKSUM_MISMATCH');
        return true;
      },
    );
  });

  it('requires pin when requirePin is set', async () => {
    await assert.rejects(
      () =>
        downloadVerifiedZip('0.2.1', {
          baseUrl: 'https://example.test/v0.2.1',
          pin: null,
          requirePin: true,
          fetch: async () => Buffer.from('x'),
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_RELEASE_DIGEST');
        return true;
      },
    );
  });

  it('asset names match package constants helpers', () => {
    assert.equal(appZipChecksumAssetName('9.9.9'), `${appZipAssetName('9.9.9')}.sha256`);
  });
});

describe('downloadBuffer boundaries', () => {
  it('rejects oversized Content-Length', async () => {
    const transportGet = (_url, _opts, cb) => {
      const res = new EventEmitter();
      res.statusCode = 200;
      res.headers = { 'content-length': '999999' };
      res.resume = () => {};
      process.nextTick(() => cb(res));
      return Object.assign(new EventEmitter(), {
        on(event, handler) {
          EventEmitter.prototype.on.call(this, event, handler);
          return this;
        },
      });
    };

    await assert.rejects(
      () =>
        downloadBuffer('https://example.test/big', {
          maxBytes: 16,
          transportGet,
        }),
      (error) => {
        assert.equal(error.code, 'RESPONSE_TOO_LARGE');
        return true;
      },
    );
  });

  it('rejects too many redirects', async () => {
    let hops = 0;
    const transportGet = (_url, _opts, cb) => {
      hops += 1;
      const res = new EventEmitter();
      res.statusCode = 302;
      res.headers = { location: `https://example.test/r${hops}` };
      res.resume = () => {};
      process.nextTick(() => cb(res));
      return Object.assign(new EventEmitter(), {
        on(event, handler) {
          EventEmitter.prototype.on.call(this, event, handler);
          return this;
        },
      });
    };

    await assert.rejects(
      () =>
        downloadBuffer('https://example.test/start', {
          maxRedirects: 2,
          transportGet,
        }),
      (error) => {
        assert.equal(error.code, 'TOO_MANY_REDIRECTS');
        return true;
      },
    );
  });

  it('rejects HTTP redirect targets', async () => {
    const transportGet = (_url, _opts, cb) => {
      const res = new EventEmitter();
      res.statusCode = 302;
      res.headers = { location: 'http://evil.test/payload' };
      res.resume = () => {};
      process.nextTick(() => cb(res));
      return Object.assign(new EventEmitter(), {
        on(event, handler) {
          EventEmitter.prototype.on.call(this, event, handler);
          return this;
        },
      });
    };

    await assert.rejects(
      () =>
        downloadBuffer('https://example.test/start', {
          transportGet,
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INSECURE_URL');
        return true;
      },
    );
  });

  it('enforces overall timeout', async () => {
    let now = 0;
    const transportGet = (_url, _opts, cb) => {
      const res = new EventEmitter();
      res.statusCode = 200;
      res.headers = {};
      res.resume = () => {};
      process.nextTick(() => {
        now = 50_000;
        cb(res);
        res.emit('data', Buffer.from('x'));
      });
      return Object.assign(new EventEmitter(), {
        on(event, handler) {
          EventEmitter.prototype.on.call(this, event, handler);
          return this;
        },
        destroy() {},
      });
    };

    await assert.rejects(
      () =>
        downloadBuffer('https://example.test/slow', {
          overallTimeoutMs: 10,
          requestTimeoutMs: 60_000,
          now: () => now,
          transportGet,
        }),
      (error) => {
        assert.equal(error.code, 'DOWNLOAD_TIMEOUT');
        return true;
      },
    );
  });
});
