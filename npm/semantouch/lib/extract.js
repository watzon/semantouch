'use strict';

const path = require('node:path');
const { APP_BUNDLE_NAME } = require('./constants');
const { defaultFs, locateExactlyOneApp } = require('./fs');
const { runChecked } = require('./run');
const { die } = require('./errors');

/** ZIP local file header signature. */
const LOCAL_FILE_HEADER = 0x04034b50;
/** ZIP central directory file header signature. */
const CENTRAL_DIRECTORY_HEADER = 0x02014b50;
/** ZIP end of central directory signature. */
const END_OF_CENTRAL_DIRECTORY = 0x06054b50;

// General purpose bit flags
const GPBF_ENCRYPTED = 0x0001;
const GPBF_UTF8 = 0x0800;

// Compression methods we accept for preflight (ditto will extract; we only validate metadata).
// We still reject traversal/special entries regardless of method.
const ALLOWED_COMPRESSION = new Set([0, 8]); // store, deflate

// External file attributes (Unix mode in high 16 bits when made-by is Unix)
const S_IFMT = 0o170000;
const S_IFDIR = 0o040000;
const S_IFREG = 0o100000;
const S_IFLNK = 0o120000;
const S_IFCHR = 0o020000;
const S_IFBLK = 0o060000;
const S_IFIFO = 0o010000;
const S_IFSOCK = 0o140000;

/**
 * @param {Buffer} buffer
 * @param {number} offset
 */
function readUInt16LE(buffer, offset) {
  if (offset + 2 > buffer.length) {
    die('ZIP archive truncated while reading field', { code: 'INVALID_ARCHIVE' });
  }
  return buffer.readUInt16LE(offset);
}

/**
 * @param {Buffer} buffer
 * @param {number} offset
 */
function readUInt32LE(buffer, offset) {
  if (offset + 4 > buffer.length) {
    die('ZIP archive truncated while reading field', { code: 'INVALID_ARCHIVE' });
  }
  return buffer.readUInt32LE(offset);
}

/**
 * Locate the End of Central Directory record (supports standard EOCD only; ZIP64 rejected).
 * @param {Buffer} buffer
 * @returns {number} offset of EOCD signature
 */
function findEndOfCentralDirectory(buffer) {
  // EOCD is at least 22 bytes; comment can be up to 65535 bytes.
  const minSize = 22;
  if (buffer.length < minSize) {
    die('ZIP archive too small to contain EOCD', { code: 'INVALID_ARCHIVE' });
  }
  const maxBack = Math.min(buffer.length - minSize, 0xffff + minSize);
  const start = buffer.length - minSize;
  for (let i = 0; i <= maxBack; i += 1) {
    const offset = start - i;
    if (readUInt32LE(buffer, offset) === END_OF_CENTRAL_DIRECTORY) {
      return offset;
    }
  }
  die('ZIP end of central directory not found', { code: 'INVALID_ARCHIVE' });
}

/**
 * Normalize a ZIP entry path for containment checks.
 * Uses POSIX separators as stored in ZIP.
 * @param {string} name
 */
function normalizeZipEntryName(name) {
  // ZIP paths use `/` as separator.
  return name.replace(/\\/g, '/');
}

/**
 * True when the path is absolute on POSIX or Windows (drive / UNC).
 * @param {string} name
 */
function isAbsoluteZipPath(name) {
  if (!name) return false;
  if (name.startsWith('/') || name.startsWith('\\')) return true;
  if (/^[A-Za-z]:[\\/]/.test(name)) return true;
  if (name.startsWith('//') || name.startsWith('\\\\')) return true;
  return false;
}

/**
 * Resolve a ZIP entry relative to extractDir and ensure it stays inside.
 * @param {string} extractDir
 * @param {string} entryName
 * @returns {string} absolute resolved path
 */
function resolveContainedEntryPath(extractDir, entryName) {
  const normalized = normalizeZipEntryName(entryName);
  if (normalized.includes('\0')) {
    die(`ZIP entry contains NUL: ${JSON.stringify(entryName)}`, { code: 'INVALID_ARCHIVE' });
  }
  if (isAbsoluteZipPath(normalized)) {
    die(`ZIP entry is absolute: ${normalized}`, { code: 'INVALID_ARCHIVE' });
  }

  const parts = normalized.split('/').filter((part) => part.length > 0 && part !== '.');
  for (const part of parts) {
    if (part === '..') {
      die(`ZIP entry escapes extract root via ..: ${normalized}`, { code: 'INVALID_ARCHIVE' });
    }
  }

  const root = path.resolve(extractDir);
  // Build platform path from safe parts only.
  const resolved = path.resolve(root, ...parts);
  const rootWithSep = root.endsWith(path.sep) ? root : `${root}${path.sep}`;
  if (resolved !== root && !resolved.startsWith(rootWithSep)) {
    die(`ZIP entry resolves outside extract root: ${normalized}`, { code: 'INVALID_ARCHIVE' });
  }
  return resolved;
}

/**
 * Decode a ZIP name field.
 * @param {Buffer} nameBuf
 * @param {number} flags
 */
function decodeZipName(nameBuf, flags) {
  if (flags & GPBF_UTF8) {
    return nameBuf.toString('utf8');
  }
  // Prefer latin1 for historical CP437-ish bytes without inventing a full codepage table.
  return nameBuf.toString('latin1');
}

/**
 * @typedef {object} ZipCentralEntry
 * @property {string} name
 * @property {number} versionMadeBy
 * @property {number} flags
 * @property {number} compression
 * @property {number} externalAttrs
 * @property {number} compressedSize
 * @property {number} uncompressedSize
 * @property {boolean} isDirectory
 * @property {boolean} isSymlink
 * @property {boolean} isSpecial
 */

/**
 * Parse central-directory entries from a ZIP buffer (metadata only).
 * @param {Buffer} buffer
 * @returns {ZipCentralEntry[]}
 */
function parseCentralDirectory(buffer) {
  const eocdOffset = findEndOfCentralDirectory(buffer);
  const diskNumber = readUInt16LE(buffer, eocdOffset + 4);
  const cdDisk = readUInt16LE(buffer, eocdOffset + 6);
  const entriesOnDisk = readUInt16LE(buffer, eocdOffset + 8);
  const totalEntries = readUInt16LE(buffer, eocdOffset + 10);
  const cdSize = readUInt32LE(buffer, eocdOffset + 12);
  const cdOffset = readUInt32LE(buffer, eocdOffset + 16);

  if (diskNumber !== 0 || cdDisk !== 0) {
    die('multi-disk ZIP archives are not supported', { code: 'INVALID_ARCHIVE' });
  }
  if (entriesOnDisk !== totalEntries) {
    die('ZIP central directory entry count mismatch', { code: 'INVALID_ARCHIVE' });
  }
  // ZIP64 uses 0xffffffff / 0xffff sentinels — reject rather than silently under-read.
  if (
    totalEntries === 0xffff
    || cdSize === 0xffffffff
    || cdOffset === 0xffffffff
  ) {
    die('ZIP64 archives are not supported', { code: 'INVALID_ARCHIVE' });
  }
  if (cdOffset + cdSize > buffer.length) {
    die('ZIP central directory extends past end of file', { code: 'INVALID_ARCHIVE' });
  }

  /** @type {ZipCentralEntry[]} */
  const entries = [];
  let cursor = cdOffset;
  const cdEnd = cdOffset + cdSize;

  while (cursor < cdEnd) {
    const sig = readUInt32LE(buffer, cursor);
    if (sig !== CENTRAL_DIRECTORY_HEADER) {
      die(`invalid central directory signature at offset ${cursor}`, {
        code: 'INVALID_ARCHIVE',
      });
    }
    if (cursor + 46 > cdEnd) {
      die('ZIP central directory entry truncated', { code: 'INVALID_ARCHIVE' });
    }

    const versionMadeBy = readUInt16LE(buffer, cursor + 4);
    const flags = readUInt16LE(buffer, cursor + 8);
    const compression = readUInt16LE(buffer, cursor + 10);
    const compressedSize = readUInt32LE(buffer, cursor + 20);
    const uncompressedSize = readUInt32LE(buffer, cursor + 24);
    const nameLen = readUInt16LE(buffer, cursor + 28);
    const extraLen = readUInt16LE(buffer, cursor + 30);
    const commentLen = readUInt16LE(buffer, cursor + 32);
    const externalAttrs = readUInt32LE(buffer, cursor + 38);
    const headerSize = 46 + nameLen + extraLen + commentLen;
    if (cursor + headerSize > cdEnd) {
      die('ZIP central directory name/extra/comment truncated', { code: 'INVALID_ARCHIVE' });
    }

    const nameBuf = buffer.subarray(cursor + 46, cursor + 46 + nameLen);
    if (nameBuf.includes(0)) {
      die('ZIP entry name contains NUL', { code: 'INVALID_ARCHIVE' });
    }
    const name = decodeZipName(nameBuf, flags);

    const madeByUnix = (versionMadeBy >> 8) === 3;
    const unixMode = madeByUnix ? (externalAttrs >>> 16) & 0xffff : 0;
    const fileType = unixMode & S_IFMT;
    const msDosDir = (externalAttrs & 0x10) !== 0;
    const isDirectory =
      name.endsWith('/')
      || fileType === S_IFDIR
      || msDosDir;
    const isSymlink = fileType === S_IFLNK;
    const isSpecial =
      fileType === S_IFCHR
      || fileType === S_IFBLK
      || fileType === S_IFIFO
      || fileType === S_IFSOCK
      || (madeByUnix && fileType !== 0 && fileType !== S_IFREG && fileType !== S_IFDIR && fileType !== S_IFLNK);

    entries.push({
      name,
      versionMadeBy,
      flags,
      compression,
      externalAttrs,
      compressedSize,
      uncompressedSize,
      isDirectory,
      isSymlink,
      isSpecial,
    });

    cursor += headerSize;
  }

  if (entries.length !== totalEntries) {
    die(
      `ZIP central directory declared ${totalEntries} entries but parsed ${entries.length}`,
      { code: 'INVALID_ARCHIVE' },
    );
  }

  return entries;
}

/**
 * Case-fold for collision detection on case-insensitive volumes.
 * @param {string} name
 */
function caseFold(name) {
  return name.normalize('NFKC').toLowerCase();
}

/**
 * Preflight ZIP central-directory metadata before any extraction.
 * Rejects absolute paths, `..`, NUL, symlinks, hardlinks/device/specials,
 * duplicates / case-fold collisions, encryption, and non-canonical top-level shape.
 *
 * @param {Buffer} zipBuffer
 * @param {{ extractDir?: string }} [options]
 * @returns {{ entries: ZipCentralEntry[], appEntryPrefix: string }}
 */
function preflightZipBuffer(zipBuffer, options = {}) {
  if (!Buffer.isBuffer(zipBuffer) || zipBuffer.length === 0) {
    die('ZIP buffer is empty', { code: 'INVALID_ARCHIVE' });
  }

  // Quick signature check
  if (readUInt32LE(zipBuffer, 0) !== LOCAL_FILE_HEADER && zipBuffer.indexOf(Buffer.from([0x50, 0x4b])) !== 0) {
    // Allow non-local-first only if EOCD can still be found; still require PK magic somewhere near start.
    if (zipBuffer[0] !== 0x50 || zipBuffer[1] !== 0x4b) {
      die('not a ZIP archive (missing PK signature)', { code: 'INVALID_ARCHIVE' });
    }
  }

  const entries = parseCentralDirectory(zipBuffer);
  if (entries.length === 0) {
    die('ZIP archive contains no entries', { code: 'INVALID_ARCHIVE' });
  }

  const extractDir = options.extractDir ?? path.resolve('/tmp/semantouch-zip-preflight');
  /** @type {Map<string, string>} */
  const seenExact = new Map();
  /** @type {Map<string, string>} */
  const seenFolded = new Map();

  for (const entry of entries) {
    const name = normalizeZipEntryName(entry.name);
    if (!name) {
      die('ZIP entry has empty name', { code: 'INVALID_ARCHIVE' });
    }
    if (name.includes('\0')) {
      die(`ZIP entry contains NUL: ${JSON.stringify(entry.name)}`, { code: 'INVALID_ARCHIVE' });
    }
    if (entry.flags & GPBF_ENCRYPTED) {
      die(`ZIP entry is encrypted: ${name}`, { code: 'INVALID_ARCHIVE' });
    }
    if (!ALLOWED_COMPRESSION.has(entry.compression)) {
      die(
        `ZIP entry uses unsupported compression method ${entry.compression}: ${name}`,
        { code: 'INVALID_ARCHIVE' },
      );
    }
    if (entry.isSymlink) {
      die(`ZIP entry is a symlink: ${name}`, { code: 'INVALID_ARCHIVE' });
    }
    if (entry.isSpecial) {
      die(`ZIP entry is a special/device node: ${name}`, { code: 'INVALID_ARCHIVE' });
    }

    // Hardlinks are not a first-class ZIP type; treat non-regular/non-dir Unix types as special (above).
    // Also reject MS-DOS volume labels / system attrs that are not plain files/dirs.
    const msDosSystem = (entry.externalAttrs & 0x04) !== 0;
    if (msDosSystem && !entry.isDirectory) {
      die(`ZIP entry has system/special DOS attributes: ${name}`, { code: 'INVALID_ARCHIVE' });
    }

    resolveContainedEntryPath(extractDir, name);

    if (seenExact.has(name)) {
      die(`ZIP archive contains duplicate entry: ${name}`, { code: 'INVALID_ARCHIVE' });
    }
    seenExact.set(name, name);

    const folded = caseFold(name.replace(/\/+$/, ''));
    if (folded) {
      const prior = seenFolded.get(folded);
      if (prior && prior !== name.replace(/\/+$/, '')) {
        die(
          `ZIP archive contains case-fold collision: ${prior} vs ${name}`,
          { code: 'INVALID_ARCHIVE' },
        );
      }
      seenFolded.set(folded, name.replace(/\/+$/, ''));
    }
  }

  // Canonical top-level shape: exactly one top-level entry Semantouch.app/ (optionally
  // with nested files only under that prefix). No sibling files/dirs.
  const topLevels = new Set();
  for (const entry of entries) {
    const name = normalizeZipEntryName(entry.name).replace(/^\/+/, '');
    const top = name.split('/')[0];
    if (top) topLevels.add(top);
  }

  if (topLevels.size !== 1) {
    die(
      `ZIP archive must contain exactly one top-level entry ${APP_BUNDLE_NAME}; found: ${[...topLevels].join(', ') || '<none>'}`,
      { code: 'INVALID_ARCHIVE' },
    );
  }

  const onlyTop = [...topLevels][0];
  if (onlyTop !== APP_BUNDLE_NAME) {
    die(
      `ZIP archive top-level entry must be ${APP_BUNDLE_NAME} (got: ${onlyTop})`,
      { code: 'INVALID_ARCHIVE' },
    );
  }

  return {
    entries,
    appEntryPrefix: `${APP_BUNDLE_NAME}/`,
  };
}

/**
 * After extraction, walk the tree and ensure every path remains contained and
 * that no symlinks/special nodes were materialised.
 *
 * @param {string} extractDir
 * @param {import('./fs').FsApi} [api]
 */
function assertExtractedTreeContained(extractDir, api = defaultFs) {
  const root = path.resolve(extractDir);
  const rootWithSep = root.endsWith(path.sep) ? root : `${root}${path.sep}`;

  /** @type {string[]} */
  const stack = [root];
  while (stack.length > 0) {
    const current = stack.pop();
    if (!current) continue;

    let entries;
    try {
      entries = api.readdirSync(current, { withFileTypes: true });
    } catch (error) {
      die(`failed to read extract tree at ${current}: ${error.message}`, {
        code: 'INVALID_EXTRACTION',
      });
    }

    for (const entry of entries) {
      const child = path.resolve(current, entry.name);
      if (child !== root && !child.startsWith(rootWithSep)) {
        die(`extracted path escapes extract root: ${child}`, {
          code: 'INVALID_EXTRACTION',
        });
      }
      if (entry.name.includes('\0')) {
        die(`extracted path contains NUL under ${current}`, {
          code: 'INVALID_EXTRACTION',
        });
      }

      // Prefer lstat when available so symlinks are not followed.
      let st;
      try {
        if (typeof api.lstatSync === 'function') {
          st = api.lstatSync(child);
        } else {
          st = api.statSync(child);
        }
      } catch (error) {
        die(`failed to stat extracted path ${child}: ${error.message}`, {
          code: 'INVALID_EXTRACTION',
        });
      }

      if (typeof st.isSymbolicLink === 'function' && st.isSymbolicLink()) {
        die(`extracted tree contains symlink: ${child}`, {
          code: 'INVALID_EXTRACTION',
        });
      }
      if (typeof st.isFile === 'function' && typeof st.isDirectory === 'function') {
        if (!st.isFile() && !st.isDirectory()) {
          die(`extracted tree contains special node: ${child}`, {
            code: 'INVALID_EXTRACTION',
          });
        }
      }

      const isDir =
        (typeof entry.isDirectory === 'function' && entry.isDirectory())
        || (typeof st.isDirectory === 'function' && st.isDirectory());
      if (isDir) {
        stack.push(child);
      }
    }
  }
}

/**
 * Extract a ZIP with ditto after central-directory preflight; return Semantouch.app path.
 *
 * @param {string} zipPath
 * @param {string} extractDir
 * @param {{
 *   fs?: import('./fs').FsApi,
 *   run?: Function,
 *   zipBuffer?: Buffer,
 * }} [options]
 * @returns {string} path to extracted Semantouch.app
 */
function extractAppZip(zipPath, extractDir, options = {}) {
  const api = options.fs ?? defaultFs;
  api.mkdirSync(extractDir, { recursive: true });

  let zipBuffer = options.zipBuffer;
  if (!zipBuffer) {
    try {
      const raw = api.readFileSync(zipPath);
      zipBuffer = Buffer.isBuffer(raw) ? raw : Buffer.from(String(raw));
    } catch (error) {
      die(`failed to read app archive for preflight: ${error.message}`, {
        code: 'INVALID_ARCHIVE',
      });
    }
  }

  preflightZipBuffer(zipBuffer, { extractDir });

  try {
    runChecked('/usr/bin/ditto', ['-x', '-k', zipPath, extractDir], {
      run: options.run,
    });
  } catch (error) {
    die(`failed to extract app archive: ${error.message}`, {
      code: 'INVALID_EXTRACTION',
    });
  }

  assertExtractedTreeContained(extractDir, api);

  try {
    return locateExactlyOneApp(extractDir, api);
  } catch (error) {
    die(error.message, { code: 'INVALID_EXTRACTION' });
  }
}

/**
 * Write zip bytes to a staging path.
 *
 * @param {Buffer} zipBuffer
 * @param {string} zipPath
 * @param {import('./fs').FsApi} [api]
 */
function writeZipFile(zipBuffer, zipPath, api = defaultFs) {
  api.mkdirSync(path.dirname(zipPath), { recursive: true });
  api.writeFileSync(zipPath, zipBuffer);
}

module.exports = {
  preflightZipBuffer,
  parseCentralDirectory,
  resolveContainedEntryPath,
  assertExtractedTreeContained,
  extractAppZip,
  writeZipFile,
  // Exported for tests
  findEndOfCentralDirectory,
  normalizeZipEntryName,
  isAbsoluteZipPath,
  caseFold,
};
