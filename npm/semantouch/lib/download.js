'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const https = require('node:https');
const { URL } = require('node:url');
const {
  PACKAGE_NAME,
  PACKAGE_VERSION,
  appZipAssetName,
  appZipChecksumAssetName,
  defaultReleaseBaseUrl,
  MAX_REDIRECTS,
  REQUEST_TIMEOUT_MS,
  OVERALL_DOWNLOAD_TIMEOUT_MS,
  MAX_CHECKSUM_BYTES,
  MAX_ZIP_BYTES,
} = require('./constants');
const { die } = require('./errors');

/**
 * Parse a GitHub-style SHA-256 sidecar: lowercase 64-hex, two spaces, exact basename.
 * Also accepts a lone 64-hex digest (first whitespace-delimited token) for resilience,
 * but prefers the exact `digest  basename` form when present.
 *
 * @param {string | Buffer} text
 * @param {string} [expectedBasename]
 * @returns {string} lowercase 64-hex digest
 */
function parseChecksumSidecar(text, expectedBasename) {
  const raw = Buffer.isBuffer(text) ? text.toString('utf8') : String(text);
  const line = raw.split(/\r?\n/).find((entry) => entry.trim().length > 0);
  if (!line) {
    die('checksum sidecar is empty', { code: 'INVALID_CHECKSUM' });
  }

  const match = /^([0-9a-fA-F]{64})(?:  (.+))?$/.exec(line.trimEnd());
  if (!match) {
    // Fall back to first whitespace token when the line is "hex filename" with one space.
    const token = line.trim().split(/\s+/)[0] ?? '';
    if (!/^[0-9a-fA-F]{64}$/.test(token)) {
      die('checksum sidecar is not a valid SHA-256 digest', { code: 'INVALID_CHECKSUM' });
    }
    return token.toLowerCase();
  }

  const digest = match[1].toLowerCase();
  const basename = match[2];
  if (expectedBasename && basename && basename !== expectedBasename) {
    die(
      `checksum sidecar basename ${basename} does not match ${expectedBasename}`,
      { code: 'INVALID_CHECKSUM' },
    );
  }
  return digest;
}

/**
 * @param {Buffer} data
 * @returns {string}
 */
function sha256Hex(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

/**
 * @param {string} actual
 * @param {string} expected
 */
function assertChecksumMatch(actual, expected) {
  if (actual.toLowerCase() !== expected.toLowerCase()) {
    die('downloaded release failed SHA-256 verification', {
      code: 'CHECKSUM_MISMATCH',
      exitCode: 1,
    });
  }
}

/**
 * Load immutable release digest pin baked into the package at publish time.
 * Shape: { version, sha256, asset }.
 *
 * @param {{
 *   version?: string,
 *   pinPath?: string,
 *   pin?: { version?: string, sha256?: string, asset?: string } | null,
 *   readFileSync?: (path: string, encoding: string) => string,
 * }} [options]
 * @returns {{ version: string, sha256: string, asset: string } | null}
 */
function loadReleaseDigestPin(options = {}) {
  if (Object.prototype.hasOwnProperty.call(options, 'pin')) {
    return normalizeReleaseDigestPin(options.pin, options.version);
  }

  const pinPath =
    options.pinPath
    ?? path.join(__dirname, '..', 'release-digest.json');
  const readFileSync = options.readFileSync ?? ((p, enc) => fs.readFileSync(p, enc));

  let raw;
  try {
    raw = readFileSync(pinPath, 'utf8');
  } catch (error) {
    if (error && error.code === 'ENOENT') {
      return null;
    }
    die(`failed to read release digest pin: ${error.message}`, {
      code: 'INVALID_RELEASE_DIGEST',
    });
  }

  let parsed;
  try {
    parsed = JSON.parse(String(raw));
  } catch (error) {
    die(`release digest pin is not valid JSON: ${error.message}`, {
      code: 'INVALID_RELEASE_DIGEST',
    });
  }
  return normalizeReleaseDigestPin(parsed, options.version);
}

/**
 * @param {unknown} pin
 * @param {string} [expectedVersion]
 * @returns {{ version: string, sha256: string, asset: string } | null}
 */
function normalizeReleaseDigestPin(pin, expectedVersion) {
  if (pin == null) {
    return null;
  }
  if (typeof pin !== 'object' || Array.isArray(pin)) {
    die('release digest pin must be an object', { code: 'INVALID_RELEASE_DIGEST' });
  }

  const version = String(/** @type {{version?: unknown}} */ (pin).version ?? '').trim();
  const sha256 = String(/** @type {{sha256?: unknown}} */ (pin).sha256 ?? '').trim().toLowerCase();
  const asset = String(/** @type {{asset?: unknown}} */ (pin).asset ?? '').trim();

  if (!version || !sha256 || !asset) {
    die('release digest pin requires version, sha256, and asset', {
      code: 'INVALID_RELEASE_DIGEST',
    });
  }
  if (!/^[0-9a-f]{64}$/.test(sha256)) {
    die('release digest pin sha256 must be 64 lowercase hex chars', {
      code: 'INVALID_RELEASE_DIGEST',
    });
  }
  if (expectedVersion && version !== expectedVersion) {
    die(
      `release digest pin version ${version} does not match package version ${expectedVersion}`,
      { code: 'INVALID_RELEASE_DIGEST' },
    );
  }
  const expectedAsset = appZipAssetName(expectedVersion ?? version);
  if (asset !== expectedAsset) {
    die(
      `release digest pin asset ${asset} does not match ${expectedAsset}`,
      { code: 'INVALID_RELEASE_DIGEST' },
    );
  }
  return { version, sha256, asset };
}

/**
 * Reject non-HTTPS URLs for production transport (no cleartext, no file:, etc.).
 * @param {string} url
 * @param {string} [context]
 */
function assertHttpsUrl(url, context = 'download') {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    die(`invalid ${context} URL: ${url}`, { code: 'INVALID_URL' });
  }
  if (parsed.protocol !== 'https:') {
    die(
      `${context} URL must use HTTPS (got ${parsed.protocol}): ${url}`,
      { code: 'INSECURE_URL' },
    );
  }
  return parsed;
}

/**
 * @param {string} url
 * @param {{
 *   fetch?: (url: string, options?: object) => Promise<Buffer>,
 *   maxRedirects?: number,
 *   maxBytes?: number,
 *   requestTimeoutMs?: number,
 *   overallTimeoutMs?: number,
 *   userAgent?: string,
 *   now?: () => number,
 *   transportGet?: Function,
 * }} [options]
 * @returns {Promise<Buffer>}
 */
async function downloadBuffer(url, options = {}) {
  if (typeof options.fetch === 'function') {
    return options.fetch(url, options);
  }

  const maxRedirects = options.maxRedirects ?? MAX_REDIRECTS;
  const maxBytes = options.maxBytes ?? MAX_ZIP_BYTES;
  const requestTimeoutMs = options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS;
  const overallTimeoutMs = options.overallTimeoutMs ?? OVERALL_DOWNLOAD_TIMEOUT_MS;
  const userAgent = options.userAgent ?? `${PACKAGE_NAME}/${PACKAGE_VERSION}`;
  const now = options.now ?? (() => Date.now());
  const transportGet = options.transportGet ?? https.get.bind(https);
  const startedAt = now();

  assertHttpsUrl(url);

  return new Promise((resolve, reject) => {
    let redirects = 0;
    let settled = false;

    const fail = (error) => {
      if (settled) return;
      settled = true;
      reject(error);
    };

    const succeed = (buffer) => {
      if (settled) return;
      settled = true;
      resolve(buffer);
    };

    const get = (target) => {
      if (now() - startedAt > overallTimeoutMs) {
        fail(Object.assign(new Error(`overall download timeout after ${overallTimeoutMs}ms`), {
          code: 'DOWNLOAD_TIMEOUT',
        }));
        return;
      }

      let parsed;
      try {
        parsed = assertHttpsUrl(target);
      } catch (error) {
        fail(error);
        return;
      }

      /** @type {import('node:http').ClientRequest | null} */
      let req = null;
      /** @type {NodeJS.Timeout | null} */
      let requestTimer = null;

      const clearRequestTimer = () => {
        if (requestTimer) {
          clearTimeout(requestTimer);
          requestTimer = null;
        }
      };

      try {
        req = transportGet(
          parsed,
          {
            headers: {
              Accept: 'application/octet-stream',
              'User-Agent': userAgent,
            },
          },
          (res) => {
            clearRequestTimer();
            const status = res.statusCode ?? 0;
            if (status >= 300 && status < 400 && res.headers.location) {
              res.resume();
              redirects += 1;
              if (redirects > maxRedirects) {
                fail(Object.assign(new Error(`too many redirects fetching ${url}`), {
                  code: 'TOO_MANY_REDIRECTS',
                }));
                return;
              }
              let next;
              try {
                next = new URL(res.headers.location, parsed).toString();
                assertHttpsUrl(next, 'redirect');
              } catch (error) {
                fail(error);
                return;
              }
              get(next);
              return;
            }

            if (status < 200 || status >= 300) {
              res.resume();
              fail(Object.assign(new Error(`HTTP ${status} fetching ${url}`), {
                code: 'HTTP_ERROR',
              }));
              return;
            }

            const contentLength = Number.parseInt(String(res.headers['content-length'] ?? ''), 10);
            if (Number.isFinite(contentLength) && contentLength > maxBytes) {
              res.resume();
              fail(Object.assign(
                new Error(`response Content-Length ${contentLength} exceeds limit ${maxBytes}`),
                { code: 'RESPONSE_TOO_LARGE' },
              ));
              return;
            }

            /** @type {Buffer[]} */
            const chunks = [];
            let total = 0;

            res.on('data', (chunk) => {
              const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
              total += buf.length;
              if (total > maxBytes) {
                if (typeof res.destroy === 'function') {
                  res.destroy();
                }
                fail(Object.assign(
                  new Error(`response exceeded size limit ${maxBytes} bytes`),
                  { code: 'RESPONSE_TOO_LARGE' },
                ));
                return;
              }
              if (now() - startedAt > overallTimeoutMs) {
                if (typeof res.destroy === 'function') {
                  res.destroy();
                }
                fail(Object.assign(new Error(`overall download timeout after ${overallTimeoutMs}ms`), {
                  code: 'DOWNLOAD_TIMEOUT',
                }));
                return;
              }
              chunks.push(buf);
            });
            res.on('end', () => {
              succeed(Buffer.concat(chunks));
            });
            res.on('error', fail);
          },
        );
      } catch (error) {
        fail(error);
        return;
      }

      requestTimer = setTimeout(() => {
        try {
          req?.destroy(Object.assign(new Error(`request timeout after ${requestTimeoutMs}ms`), {
            code: 'REQUEST_TIMEOUT',
          }));
        } catch {
          // ignore
        }
        fail(Object.assign(new Error(`request timeout after ${requestTimeoutMs}ms`), {
          code: 'REQUEST_TIMEOUT',
        }));
      }, requestTimeoutMs);
      if (typeof requestTimer.unref === 'function') {
        requestTimer.unref();
      }

      req.on('error', (error) => {
        clearRequestTimer();
        fail(error);
      });
    };

    get(url);
  });
}

/**
 * Resolve download URLs for the package version's canonical ZIP + checksum.
 *
 * @param {string} version
 * @param {{ baseUrl?: string }} [options]
 */
function releaseAssetUrls(version, options = {}) {
  const base = (options.baseUrl ?? defaultReleaseBaseUrl(version)).replace(/\/$/, '');
  const zipName = appZipAssetName(version);
  const checksumName = appZipChecksumAssetName(version);
  return {
    zipName,
    checksumName,
    zipUrl: `${base}/${zipName}`,
    checksumUrl: `${base}/${checksumName}`,
  };
}

/**
 * Download and verify the canonical ZIP for `version`.
 *
 * When a release-digest pin is present (published packages), the downloaded ZIP
 * must match the pin, the sidecar, and each other. Local/dev without a pin still
 * verifies the downloaded sidecar only.
 *
 * @param {string} version
 * @param {{
 *   baseUrl?: string,
 *   fetch?: (url: string, options?: object) => Promise<Buffer>,
 *   requestTimeoutMs?: number,
 *   overallTimeoutMs?: number,
 *   maxZipBytes?: number,
 *   maxChecksumBytes?: number,
 *   pin?: { version?: string, sha256?: string, asset?: string } | null,
 *   pinPath?: string,
 *   requirePin?: boolean,
 * }} [options]
 * @returns {Promise<{ zipBuffer: Buffer, checksum: string, zipName: string }>}
 */
async function downloadVerifiedZip(version, options = {}) {
  const assets = releaseAssetUrls(version, { baseUrl: options.baseUrl });
  const fetchImpl = options.fetch;
  const shared = {
    fetch: fetchImpl,
    requestTimeoutMs: options.requestTimeoutMs,
    overallTimeoutMs: options.overallTimeoutMs,
  };

  const pinOptions = {
    version,
    pinPath: options.pinPath,
  };
  if (Object.prototype.hasOwnProperty.call(options, 'pin')) {
    pinOptions.pin = options.pin;
  }
  const pin = loadReleaseDigestPin(pinOptions);
  if (options.requirePin === true && !pin) {
    die('release digest pin is required but missing', {
      code: 'INVALID_RELEASE_DIGEST',
    });
  }

  const [zipBuffer, checksumBuffer] = await Promise.all([
    downloadBuffer(assets.zipUrl, {
      ...shared,
      maxBytes: options.maxZipBytes ?? MAX_ZIP_BYTES,
    }),
    downloadBuffer(assets.checksumUrl, {
      ...shared,
      maxBytes: options.maxChecksumBytes ?? MAX_CHECKSUM_BYTES,
    }),
  ]);

  const expected = parseChecksumSidecar(checksumBuffer, assets.zipName);
  const actual = sha256Hex(zipBuffer);
  assertChecksumMatch(actual, expected);

  if (pin) {
    assertChecksumMatch(actual, pin.sha256);
    if (pin.sha256 !== expected) {
      die('release digest pin does not match downloaded checksum sidecar', {
        code: 'CHECKSUM_MISMATCH',
      });
    }
  }

  return {
    zipBuffer,
    checksum: expected,
    zipName: assets.zipName,
  };
}

module.exports = {
  parseChecksumSidecar,
  sha256Hex,
  assertChecksumMatch,
  assertHttpsUrl,
  loadReleaseDigestPin,
  downloadBuffer,
  releaseAssetUrls,
  downloadVerifiedZip,
};
