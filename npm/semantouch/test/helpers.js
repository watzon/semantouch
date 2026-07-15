'use strict';

const path = require('node:path');
const {
  APP_BUNDLE_NAME,
  HOST_RELATIVE_PATH,
  RELAY_RELATIVE_PATH,
  INFO_PLIST_RELATIVE_PATH,
  INSTALL_LOCK_NAME,
} = require('../lib/constants');

/**
 * Minimal in-memory filesystem for deterministic unit tests.
 */
function createMemoryFs(initial = {}) {
  /** @type {Map<string, { type: 'file' | 'dir' | 'symlink' | 'special', content?: Buffer | string, mode?: number, target?: string }>} */
  const nodes = new Map();

  const norm = (p) => path.resolve(p);

  const ensureParents = (p) => {
    let cursor = path.dirname(p);
    const parts = [];
    while (cursor && cursor !== path.dirname(cursor)) {
      parts.push(cursor);
      cursor = path.dirname(cursor);
    }
    for (const dir of parts.reverse()) {
      if (!nodes.has(dir)) {
        nodes.set(dir, { type: 'dir' });
      }
    }
  };

  for (const [rawPath, value] of Object.entries(initial)) {
    const p = norm(rawPath);
    if (value === null || value === 'dir') {
      ensureParents(p);
      nodes.set(p, { type: 'dir' });
    } else if (typeof value === 'string' || Buffer.isBuffer(value)) {
      ensureParents(p);
      nodes.set(p, { type: 'file', content: value, mode: 0o755 });
      let parent = path.dirname(p);
      while (!nodes.has(parent)) {
        nodes.set(parent, { type: 'dir' });
        const next = path.dirname(parent);
        if (next === parent) break;
        parent = next;
      }
    } else if (value && typeof value === 'object') {
      ensureParents(p);
      nodes.set(p, {
        type: value.type ?? 'file',
        content: value.content ?? '',
        mode: value.mode ?? 0o755,
        target: value.target,
      });
    }
  }

  nodes.set(path.resolve('/'), { type: 'dir' });

  const makeStat = (node) => ({
    isDirectory: () => node.type === 'dir',
    isFile: () => node.type === 'file',
    isSymbolicLink: () => node.type === 'symlink',
    isSocket: () => node.type === 'special',
    isFIFO: () => false,
    isBlockDevice: () => false,
    isCharacterDevice: () => node.type === 'special',
    mode: node.mode ?? 0o755,
  });

  const api = {
    _nodes: nodes,
    existsSync(p) {
      return nodes.has(norm(p));
    },
    accessSync(p, _mode) {
      if (!nodes.has(norm(p))) {
        const err = new Error(`ENOENT: ${p}`);
        err.code = 'ENOENT';
        throw err;
      }
      return true;
    },
    statSync(p) {
      const node = nodes.get(norm(p));
      if (!node) {
        const err = new Error(`ENOENT: ${p}`);
        err.code = 'ENOENT';
        throw err;
      }
      return makeStat(node);
    },
    lstatSync(p) {
      return api.statSync(p);
    },
    readdirSync(p, options = {}) {
      const dir = norm(p);
      if (!nodes.has(dir) || nodes.get(dir).type !== 'dir') {
        const err = new Error(`ENOENT: ${p}`);
        err.code = 'ENOENT';
        throw err;
      }
      const prefix = dir.endsWith(path.sep) ? dir : `${dir}${path.sep}`;
      const names = new Set();
      for (const key of nodes.keys()) {
        if (!key.startsWith(prefix)) continue;
        const rest = key.slice(prefix.length);
        if (!rest) continue;
        const name = rest.split(path.sep)[0];
        if (name) names.add(name);
      }
      const list = [...names].sort();
      if (options.withFileTypes) {
        return list.map((name) => {
          const child = nodes.get(path.join(dir, name));
          return {
            name,
            isDirectory: () => child?.type === 'dir',
            isFile: () => child?.type === 'file',
            isSymbolicLink: () => child?.type === 'symlink',
          };
        });
      }
      return list;
    },
    mkdirSync(p, options = {}) {
      const target = norm(p);
      if (nodes.has(target)) return;
      if (options.recursive) {
        ensureParents(target);
      } else {
        const parent = path.dirname(target);
        if (!nodes.has(parent)) {
          const err = new Error(`ENOENT: ${parent}`);
          err.code = 'ENOENT';
          throw err;
        }
      }
      nodes.set(target, { type: 'dir' });
    },
    rmSync(p, options = {}) {
      const target = norm(p);
      if (!nodes.has(target)) {
        if (options.force) return;
        const err = new Error(`ENOENT: ${p}`);
        err.code = 'ENOENT';
        throw err;
      }
      if (options.recursive) {
        for (const key of [...nodes.keys()]) {
          if (key === target || key.startsWith(`${target}${path.sep}`)) {
            nodes.delete(key);
          }
        }
      } else {
        nodes.delete(target);
      }
    },
    renameSync(src, dest) {
      const from = norm(src);
      const to = norm(dest);
      if (!nodes.has(from)) {
        const err = new Error(`ENOENT: ${src}`);
        err.code = 'ENOENT';
        throw err;
      }
      const entries = [];
      for (const [key, value] of nodes.entries()) {
        if (key === from || key.startsWith(`${from}${path.sep}`)) {
          entries.push([key, value]);
        }
      }
      for (const [key] of entries) {
        nodes.delete(key);
      }
      for (const [key, value] of entries) {
        const rel = key === from ? '' : key.slice(from.length + 1);
        const next = rel ? path.join(to, rel) : to;
        ensureParents(next);
        nodes.set(next, value);
      }
    },
    writeFileSync(p, data) {
      const target = norm(p);
      ensureParents(target);
      nodes.set(target, {
        type: 'file',
        content: Buffer.isBuffer(data) ? data : Buffer.from(String(data)),
        mode: 0o644,
      });
    },
    readFileSync(p, options) {
      const node = nodes.get(norm(p));
      if (!node || node.type !== 'file') {
        const err = new Error(`ENOENT: ${p}`);
        err.code = 'ENOENT';
        throw err;
      }
      const buf = Buffer.isBuffer(node.content)
        ? node.content
        : Buffer.from(String(node.content ?? ''));
      if (options === 'utf8' || (options && options.encoding === 'utf8')) {
        return buf.toString('utf8');
      }
      return buf;
    },
    openSync(p, flags, mode = 0o644) {
      const target = norm(p);
      const flag = String(flags);
      if (flag.includes('x') || flag === 'wx' || flag === 'ax') {
        if (nodes.has(target)) {
          const err = new Error(`EEXIST: ${p}`);
          err.code = 'EEXIST';
          throw err;
        }
      }
      if ((flag.includes('r') && !flag.includes('w') && !flag.includes('a') && !flag.includes('x')) && !nodes.has(target)) {
        const err = new Error(`ENOENT: ${p}`);
        err.code = 'ENOENT';
        throw err;
      }
      ensureParents(target);
      if (!nodes.has(target)) {
        nodes.set(target, {
          type: 'file',
          content: Buffer.alloc(0),
          mode,
        });
      }
      // Use path string as a pseudo fd token for tests.
      return target;
    },
    closeSync(_fd) {
      // no-op for memory fs
    },
    writeSync(fd, data) {
      const target = typeof fd === 'string' ? fd : String(fd);
      const buf = Buffer.isBuffer(data) ? data : Buffer.from(String(data));
      const existing = nodes.get(target);
      const prev = existing && existing.type === 'file'
        ? (Buffer.isBuffer(existing.content) ? existing.content : Buffer.from(String(existing.content ?? '')))
        : Buffer.alloc(0);
      nodes.set(target, {
        type: 'file',
        content: Buffer.concat([prev, buf]),
        mode: existing?.mode ?? 0o644,
      });
      return buf.length;
    },
    mkdtempSync(prefix) {
      const dir = `${prefix}${Math.random().toString(16).slice(2, 10)}`;
      const target = norm(dir);
      ensureParents(target);
      nodes.set(target, { type: 'dir' });
      return target;
    },
    tmpdir() {
      return '/tmp';
    },
    homedir() {
      return '/Users/test';
    },
  };

  return api;
}

/**
 * Seed a fake Semantouch.app tree into a memory fs.
 * @param {ReturnType<typeof createMemoryFs>} api
 * @param {string} appPath
 * @param {{ hostContent?: string|Buffer, relayContent?: string|Buffer }} [options]
 */
function seedAppBundle(api, appPath, options = {}) {
  const host = path.join(appPath, HOST_RELATIVE_PATH);
  const relay = path.join(appPath, RELAY_RELATIVE_PATH);
  const plist = path.join(appPath, INFO_PLIST_RELATIVE_PATH);
  api.mkdirSync(path.dirname(host), { recursive: true });
  api.writeFileSync(host, options.hostContent ?? '#!/bin/sh\n');
  api.writeFileSync(relay, options.relayContent ?? '#!/bin/sh\n');
  api.writeFileSync(plist, '<?xml version="1.0"?>\n');
  return { host, relay, plist };
}

/**
 * Build a minimal stored (method 0) ZIP buffer from path → content entries.
 * Paths should use `/` separators. Directory entries end with `/`.
 *
 * @param {Record<string, string | Buffer | null>} files
 * @param {{
 *   unixModeFor?: (name: string) => number | undefined,
 *   versionMadeBy?: number,
 * }} [options]
 * @returns {Buffer}
 */
function createZipBuffer(files, options = {}) {
  /** @type {Buffer[]} */
  const localParts = [];
  /** @type {Buffer[]} */
  const centralParts = [];
  let offset = 0;

  const names = Object.keys(files);
  for (const name of names) {
    const isDir = name.endsWith('/');
    const raw = files[name];
    const data = isDir || raw == null
      ? Buffer.alloc(0)
      : Buffer.isBuffer(raw)
        ? raw
        : Buffer.from(String(raw));
    const nameBuf = Buffer.from(name, 'utf8');
    const flags = 0x0800; // UTF-8
    const compression = 0;
    const crc = crc32(data);
    const unixMode = options.unixModeFor?.(name);
    const versionMadeBy = options.versionMadeBy
      ?? (unixMode != null ? (3 << 8) | 20 : 20);
    let externalAttrs = 0;
    if (unixMode != null) {
      externalAttrs = (unixMode & 0xffff) << 16;
    } else if (isDir) {
      externalAttrs = 0x10; // MS-DOS directory
    }

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4); // version needed
    local.writeUInt16LE(flags, 6);
    local.writeUInt16LE(compression, 8);
    local.writeUInt16LE(0, 10); // time
    local.writeUInt16LE(0, 12); // date
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28); // extra

    const localHeaderOffset = offset;
    localParts.push(local, nameBuf, data);
    offset += local.length + nameBuf.length + data.length;

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(versionMadeBy, 4);
    central.writeUInt16LE(20, 6); // version needed
    central.writeUInt16LE(flags, 8);
    central.writeUInt16LE(compression, 10);
    central.writeUInt16LE(0, 12);
    central.writeUInt16LE(0, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt16LE(0, 30); // extra
    central.writeUInt16LE(0, 32); // comment
    central.writeUInt16LE(0, 34); // disk start
    central.writeUInt16LE(0, 36); // internal attrs
    central.writeUInt32LE(externalAttrs >>> 0, 38);
    central.writeUInt32LE(localHeaderOffset, 42);
    centralParts.push(central, nameBuf);
  }

  const centralDirectory = Buffer.concat(centralParts);
  const localBlob = Buffer.concat(localParts);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(names.length, 8);
  eocd.writeUInt16LE(names.length, 10);
  eocd.writeUInt32LE(centralDirectory.length, 12);
  eocd.writeUInt32LE(localBlob.length, 16);
  eocd.writeUInt16LE(0, 20);

  return Buffer.concat([localBlob, centralDirectory, eocd]);
}

/**
 * CRC-32 (IEEE) for ZIP headers.
 * @param {Buffer} buf
 */
function crc32(buf) {
  let crc = 0xffffffff;
  for (let i = 0; i < buf.length; i += 1) {
    crc ^= buf[i];
    for (let j = 0; j < 8; j += 1) {
      const mask = -(crc & 1);
      crc = (crc >>> 1) ^ (0xedb88320 & mask);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/**
 * Canonical Semantouch.app ZIP used by bootstrap install tests.
 * @param {{ version?: string }} [options]
 */
function createCanonicalAppZip(_options = {}) {
  return createZipBuffer({
    'Semantouch.app/': null,
    'Semantouch.app/Contents/': null,
    'Semantouch.app/Contents/Info.plist': '<?xml version="1.0"?>\n',
    'Semantouch.app/Contents/MacOS/': null,
    'Semantouch.app/Contents/MacOS/SemantouchHost': '#!/bin/sh\necho host\n',
    'Semantouch.app/Contents/MacOS/semantouch': '#!/bin/sh\necho relay\n',
  });
}

/**
 * Fake run() dispatcher for platform tools.
 * @param {(command: string, args: string[]) => {status?: number, stdout?: string, stderr?: string, error?: Error|null} | null} handler
 */
function createRunFake(handler) {
  return (command, args) => {
    const result = handler(command, args);
    if (result == null) {
      return {
        status: 1,
        stdout: '',
        stderr: `unexpected command: ${command} ${args.join(' ')}`,
        error: null,
      };
    }
    return {
      status: result.status ?? 0,
      stdout: result.stdout ?? '',
      stderr: result.stderr ?? '',
      error: result.error ?? null,
    };
  };
}

/**
 * Build a default successful verify run fake for a given version.
 * @param {string} version
 * @param {{
 *   bundleId?: string,
 *   executable?: string,
 *   packageType?: string,
 *   minOs?: string,
 *   archs?: string,
 *   identifier?: string,
 *   team?: string,
 *   authority?: string,
 *   flags?: string,
 *   timestamp?: string | null,
 *   requirement?: string | null,
 *   relayIdentifier?: string,
 *   spctlStatus?: number,
 *   staplerStatus?: number,
 *   fileInfo?: string,
 *   extraMachO?: boolean,
 * }} [overrides]
 */
function createSuccessfulVerifyRun(version, overrides = {}) {
  const bundleId = overrides.bundleId ?? 'tech.watzon.semantouch';
  const executable = overrides.executable ?? 'SemantouchHost';
  const packageType = overrides.packageType ?? 'APPL';
  const minOs = overrides.minOs ?? '14.0';
  const archs = overrides.archs ?? 'arm64 x86_64';
  const identifier = overrides.identifier ?? 'tech.watzon.semantouch';
  const team = overrides.team ?? 'MB5789APU7';
  const authority =
    overrides.authority ?? 'Developer ID Application: Watzon Ventures LLc (MB5789APU7)';
  const flags = Object.prototype.hasOwnProperty.call(overrides, 'flags')
    ? overrides.flags
    : '0x10000(runtime)';
  const timestamp = Object.prototype.hasOwnProperty.call(overrides, 'timestamp')
    ? overrides.timestamp
    : '1 Jan 2026';
  const relayIdentifier = overrides.relayIdentifier ?? 'tech.watzon.semantouch.cli';
  const fileInfo = overrides.fileInfo ?? 'Mach-O universal binary with 2 architectures: [x86_64:Mach-O 64-bit executable x86_64] [arm64]';

  return createRunFake((command, args) => {
    if (command === '/usr/bin/plutil' && args[0] === '-extract') {
      const key = args[1];
      const map = {
        CFBundleIdentifier: bundleId,
        CFBundleExecutable: executable,
        CFBundlePackageType: packageType,
        CFBundleShortVersionString: version,
        CFBundleVersion: version,
        LSMinimumSystemVersion: minOs,
      };
      if (!(key in map)) {
        return { status: 1, stderr: `key ${key} not found` };
      }
      return { status: 0, stdout: `${map[key]}\n` };
    }

    if (command === '/usr/bin/file' && args[0] === '-b') {
      const target = args[1] ?? '';
      if (overrides.extraMachO && /evil/i.test(String(target))) {
        return { status: 0, stdout: 'Mach-O 64-bit executable arm64\n' };
      }
      if (/SemantouchHost$|\/semantouch$/.test(String(target))) {
        return { status: 0, stdout: `${fileInfo}\n` };
      }
      return { status: 0, stdout: 'data\n' };
    }

    if (command === '/usr/bin/lipo' && args[0] === '-archs') {
      return { status: 0, stdout: `${archs}\n` };
    }

    if (command === '/usr/bin/codesign' && args[0] === '--verify') {
      return { status: 0, stdout: '' };
    }

    if (command === '/usr/bin/codesign' && args[0] === '--display') {
      const target = args[args.length - 1];
      if (args.includes('-r-')) {
        if (Object.prototype.hasOwnProperty.call(overrides, 'requirement') && overrides.requirement === null) {
          return { status: 0, stderr: 'designated => anchor apple' };
        }
        if (typeof overrides.requirement === 'string') {
          return { status: 0, stderr: overrides.requirement };
        }
        const id = String(target).endsWith('/semantouch') ? relayIdentifier : identifier;
        return {
          status: 0,
          stderr: `designated => identifier "${id}" and certificate leaf[subject.OU] = "${team}"`,
        };
      }

      const id = String(target).endsWith('/semantouch') ? relayIdentifier : identifier;
      const lines = [
        `Identifier=${id}`,
        `TeamIdentifier=${team}`,
        `Authority=${authority}`,
      ];
      if (flags != null && flags !== '') {
        lines.push(`flags=${flags}`);
      }
      if (timestamp != null && timestamp !== '') {
        lines.push(`Timestamp=${timestamp}`);
      }
      return {
        status: 0,
        stderr: lines.join('\n'),
      };
    }

    if (command === '/usr/bin/xcrun' && args[0] === 'stapler') {
      return {
        status: overrides.staplerStatus ?? 0,
        stdout: overrides.staplerStatus ? 'error: no ticket' : 'The validate action worked!\n',
        stderr: overrides.staplerStatus ? 'no valid ticket' : '',
      };
    }

    if (command === '/usr/sbin/spctl') {
      return { status: overrides.spctlStatus ?? 0, stdout: 'accepted\n' };
    }

    if (command === '/usr/bin/ditto') {
      return { status: 0, stdout: '' };
    }

    return null;
  });
}

module.exports = {
  createMemoryFs,
  seedAppBundle,
  createRunFake,
  createSuccessfulVerifyRun,
  createZipBuffer,
  createCanonicalAppZip,
  crc32,
  APP_BUNDLE_NAME,
  INSTALL_LOCK_NAME,
};
