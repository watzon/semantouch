'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const {
  preflightZipBuffer,
  resolveContainedEntryPath,
  assertExtractedTreeContained,
  extractAppZip,
} = require('../lib/extract');
const { BootstrapError } = require('../lib/errors');
const {
  createMemoryFs,
  createZipBuffer,
  createCanonicalAppZip,
  seedAppBundle,
  createSuccessfulVerifyRun,
} = require('./helpers');

describe('preflightZipBuffer', () => {
  it('accepts a canonical Semantouch.app archive', () => {
    const zip = createCanonicalAppZip();
    const result = preflightZipBuffer(zip, { extractDir: '/tmp/extract' });
    assert.equal(result.appEntryPrefix, 'Semantouch.app/');
    assert.ok(result.entries.length >= 1);
  });

  it('rejects absolute paths before extraction', () => {
    const zip = createZipBuffer({
      '/tmp/evil': 'x',
    });
    assert.throws(
      () => preflightZipBuffer(zip, { extractDir: '/tmp/extract' }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_ARCHIVE');
        assert.match(error.message, /absolute/i);
        return true;
      },
    );
  });

  it('rejects .. traversal entries', () => {
    const zip = createZipBuffer({
      'Semantouch.app/../../etc/passwd': 'x',
    });
    assert.throws(
      () => preflightZipBuffer(zip, { extractDir: '/tmp/extract' }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_ARCHIVE');
        assert.match(error.message, /\.\./);
        return true;
      },
    );
  });

  it('rejects NUL in entry names', () => {
    // Craft via buffer mutation: create valid zip then inject NUL into central name is hard;
    // use a direct name with escaped sequence by building custom name bytes.
    const base = createZipBuffer({ 'Semantouch.app/ok': 'x' });
    // Replace "ok" in central directory name with "o\0" is fragile; instead build entry with literal NUL via Buffer name.
    const evilName = Buffer.from([0x53, 0x00, 0x41]); // S\0A — but createZipBuffer uses utf8 strings.
    // Use createZipBuffer with a name that includes \0 via Object key:
    const files = {};
    files[`Semantouch.app/bad${'\0'}name`] = 'x';
    const zip = createZipBuffer(files);
    assert.throws(
      () => preflightZipBuffer(zip, { extractDir: '/tmp/extract' }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_ARCHIVE');
        assert.match(error.message, /NUL/i);
        return true;
      },
    );
    void evilName;
    void base;
  });

  it('rejects symlink entries (Unix mode)', () => {
    const zip = createZipBuffer(
      {
        'Semantouch.app/link': 'target',
      },
      {
        unixModeFor: (name) => (name.endsWith('link') ? 0o120755 : 0o100644),
      },
    );
    assert.throws(
      () => preflightZipBuffer(zip, { extractDir: '/tmp/extract' }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_ARCHIVE');
        assert.match(error.message, /symlink/i);
        return true;
      },
    );
  });

  it('rejects special device entries', () => {
    const zip = createZipBuffer(
      {
        'Semantouch.app/dev': '',
      },
      {
        unixModeFor: (name) => (name.endsWith('dev') ? 0o020666 : 0o100644),
      },
    );
    assert.throws(
      () => preflightZipBuffer(zip, { extractDir: '/tmp/extract' }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_ARCHIVE');
        assert.match(error.message, /special/i);
        return true;
      },
    );
  });

  it('rejects duplicate entries', () => {
    // createZipBuffer overwrites keys; craft two same-name central entries manually via concat of two single-file zips is hard.
    // Build by creating zip with one file then duplicating central directory entry.
    const zip = createZipBuffer({
      'Semantouch.app/Contents/Info.plist': 'a',
      'Semantouch.app/Contents/Info.plist': 'b',
    });
    // Object keys collapse — force duplicates by composing two central entries.
    const one = createZipBuffer({ 'Semantouch.app/file': 'a' });
    // Parse and rebuild: easiest path — createZipBuffer can't emit dupes, so inject by appending a second CD entry.
    // Instead, call parse path with two identical names via low-level builder:
    const dup = createZipBufferWithDuplicateNames();
    assert.throws(
      () => preflightZipBuffer(dup, { extractDir: '/tmp/extract' }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_ARCHIVE');
        assert.match(error.message, /duplicate/i);
        return true;
      },
    );
    void zip;
    void one;
  });

  it('rejects case-fold collisions', () => {
    const zip = createZipBuffer({
      'Semantouch.app/Contents/MacOS/Foo': 'a',
      'Semantouch.app/Contents/MacOS/foo': 'b',
    });
    assert.throws(
      () => preflightZipBuffer(zip, { extractDir: '/tmp/extract' }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_ARCHIVE');
        assert.match(error.message, /case-fold/i);
        return true;
      },
    );
  });

  it('rejects noncanonical top-level shape (sibling files)', () => {
    const zip = createZipBuffer({
      'Semantouch.app/Contents/Info.plist': 'x',
      'README.txt': 'nope',
    });
    assert.throws(
      () => preflightZipBuffer(zip, { extractDir: '/tmp/extract' }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_ARCHIVE');
        assert.match(error.message, /top-level/i);
        return true;
      },
    );
  });

  it('rejects wrong top-level app name', () => {
    const zip = createZipBuffer({
      'Evil.app/Contents/Info.plist': 'x',
    });
    assert.throws(
      () => preflightZipBuffer(zip, { extractDir: '/tmp/extract' }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_ARCHIVE');
        assert.match(error.message, /Semantouch\.app/);
        return true;
      },
    );
  });
});

describe('resolveContainedEntryPath', () => {
  it('resolves safe relative paths inside extract root', () => {
    const resolved = resolveContainedEntryPath('/tmp/extract', 'Semantouch.app/Contents/Info.plist');
    assert.equal(resolved, path.resolve('/tmp/extract/Semantouch.app/Contents/Info.plist'));
  });

  it('rejects escape attempts', () => {
    assert.throws(
      () => resolveContainedEntryPath('/tmp/extract', '../outside'),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_ARCHIVE');
        return true;
      },
    );
  });
});

describe('assertExtractedTreeContained', () => {
  it('accepts a clean tree', () => {
    const api = createMemoryFs();
    const root = '/tmp/extract';
    seedAppBundle(api, path.join(root, 'Semantouch.app'));
    assert.doesNotThrow(() => assertExtractedTreeContained(root, api));
  });

  it('rejects materialised symlinks', () => {
    const api = createMemoryFs();
    const root = '/tmp/extract';
    seedAppBundle(api, path.join(root, 'Semantouch.app'));
    const linkPath = path.join(root, 'Semantouch.app', 'Contents', 'evil-link');
    api._nodes.set(path.resolve(linkPath), { type: 'symlink', target: '/etc/passwd' });
    assert.throws(
      () => assertExtractedTreeContained(root, api),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_EXTRACTION');
        assert.match(error.message, /symlink/i);
        return true;
      },
    );
  });
});

describe('extractAppZip', () => {
  it('preflights before ditto and returns the app path', () => {
    const api = createMemoryFs();
    const zip = createCanonicalAppZip();
    const zipPath = '/tmp/stage/app.zip';
    const extractDir = '/tmp/stage/extract';
    api.mkdirSync('/tmp/stage', { recursive: true });
    api.writeFileSync(zipPath, zip);

    let dittoCalled = false;
    const run = (command, args) => {
      if (command === '/usr/bin/ditto' && args[0] === '-x') {
        dittoCalled = true;
        seedAppBundle(api, path.join(extractDir, 'Semantouch.app'));
        return { status: 0, stdout: '', stderr: '', error: null };
      }
      return createSuccessfulVerifyRun('0.2.1')(command, args);
    };

    const appPath = extractAppZip(zipPath, extractDir, { fs: api, run, zipBuffer: zip });
    assert.equal(appPath, path.join(extractDir, 'Semantouch.app'));
    assert.equal(dittoCalled, true);
  });

  it('does not call ditto when preflight fails', () => {
    const api = createMemoryFs();
    const zip = createZipBuffer({ 'Evil.app/x': '1' });
    const zipPath = '/tmp/stage/bad.zip';
    api.mkdirSync('/tmp/stage', { recursive: true });
    api.writeFileSync(zipPath, zip);

    let dittoCalled = false;
    assert.throws(
      () =>
        extractAppZip(zipPath, '/tmp/stage/extract', {
          fs: api,
          zipBuffer: zip,
          run: (command) => {
            if (command === '/usr/bin/ditto') {
              dittoCalled = true;
            }
            return { status: 0, stdout: '', stderr: '', error: null };
          },
        }),
      (error) => {
        assert.ok(error instanceof BootstrapError);
        assert.equal(error.code, 'INVALID_ARCHIVE');
        return true;
      },
    );
    assert.equal(dittoCalled, false);
  });
});

/**
 * Build a ZIP whose central directory lists the same name twice.
 * @returns {Buffer}
 */
function createZipBufferWithDuplicateNames() {
  const name = 'Semantouch.app/file';
  const data = Buffer.from('a');
  const nameBuf = Buffer.from(name, 'utf8');
  const flags = 0x0800;
  const crc = require('./helpers').crc32(data);

  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0);
  local.writeUInt16LE(20, 4);
  local.writeUInt16LE(flags, 6);
  local.writeUInt16LE(0, 8);
  local.writeUInt32LE(crc, 14);
  local.writeUInt32LE(data.length, 18);
  local.writeUInt32LE(data.length, 22);
  local.writeUInt16LE(nameBuf.length, 26);

  const makeCentral = (localOffset) => {
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(flags, 8);
    central.writeUInt16LE(0, 10);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt32LE(localOffset, 42);
    return Buffer.concat([central, nameBuf]);
  };

  const localBlob = Buffer.concat([local, nameBuf, data]);
  const cd = Buffer.concat([makeCentral(0), makeCentral(0)]);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(2, 8);
  eocd.writeUInt16LE(2, 10);
  eocd.writeUInt32LE(cd.length, 12);
  eocd.writeUInt32LE(localBlob.length, 16);
  return Buffer.concat([localBlob, cd, eocd]);
}
