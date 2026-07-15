#!/usr/bin/env node
/**
 * verify-cross-platform-contract.mjs
 *
 * Prove the public MCP tool catalog matches between:
 *   - Swift macOS reference: Sources/MCPServer/ToolCatalog.swift
 *   - Rust Windows/Linux runtime: runtime/crates/semantouch-protocol/src/catalog.rs
 *
 * Parses only currently-enabled tools in source order. Fails on parse
 * ambiguity, duplicates, count drift, or order drift. Dependency-free.
 *
 * Exit codes:
 *   0  exact enabled-name parity
 *   1  parity / parse failure
 *   2  usage error
 */

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, "..");

const SWIFT_CATALOG = path.join(
  REPO_ROOT,
  "Sources",
  "MCPServer",
  "ToolCatalog.swift",
);
const RUST_CATALOG = path.join(
  REPO_ROOT,
  "runtime",
  "crates",
  "semantouch-protocol",
  "src",
  "catalog.rs",
);

/** Public contract: 16 enabled tools in canonical order. */
const EXPECTED_ENABLED_COUNT = 16;

function fail(message) {
  console.error(`verify-cross-platform-contract: ${message}`);
  process.exit(1);
}

function assertUniqueNames(label, names) {
  if (names.length === 0) {
    fail(`${label}: parsed zero enabled tool names`);
  }
  const seen = new Map();
  for (let i = 0; i < names.length; i += 1) {
    const name = names[i];
    if (typeof name !== "string" || name.length === 0) {
      fail(`${label}: empty or non-string tool name at index ${i}`);
    }
    if (seen.has(name)) {
      fail(
        `${label}: duplicate enabled tool "${name}" at indices ${seen.get(name)} and ${i}`,
      );
    }
    seen.set(name, i);
  }
}

/**
 * Extract a balanced `[...]` body starting at `openIndex` (must point at `[`).
 * Returns { body, end } where body excludes the outer brackets.
 */
function extractBracketBody(source, openIndex, label) {
  if (source[openIndex] !== "[") {
    fail(`${label}: expected '[' at index ${openIndex}`);
  }
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = openIndex; i < source.length; i += 1) {
    const ch = source[i];
    if (inString) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch === "\\") {
        escaped = true;
        continue;
      }
      if (ch === '"') {
        inString = false;
      }
      continue;
    }
    if (ch === '"') {
      inString = true;
      continue;
    }
    if (ch === "[") {
      depth += 1;
      continue;
    }
    if (ch === "]") {
      depth -= 1;
      if (depth === 0) {
        return { body: source.slice(openIndex + 1, i), end: i };
      }
    }
  }
  fail(`${label}: unbalanced '[' starting at index ${openIndex}`);
}

/**
 * Extract a balanced `{...}` body starting at `openIndex` (must point at `{`).
 */
function extractBraceBody(source, openIndex, label) {
  if (source[openIndex] !== "{") {
    fail(`${label}: expected '{' at index ${openIndex}`);
  }
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = openIndex; i < source.length; i += 1) {
    const ch = source[i];
    if (inString) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch === "\\") {
        escaped = true;
        continue;
      }
      if (ch === '"') {
        inString = false;
      }
      continue;
    }
    if (ch === '"') {
      inString = true;
      continue;
    }
    if (ch === "{") {
      depth += 1;
      continue;
    }
    if (ch === "}") {
      depth -= 1;
      if (depth === 0) {
        return { body: source.slice(openIndex + 1, i), end: i };
      }
    }
  }
  fail(`${label}: unbalanced '{' starting at index ${openIndex}`);
}

function parseSwiftEnabledNames(source) {
  const label = "Swift ToolCatalog";
  const header =
    /public\s+static\s+let\s+all\s*:\s*\[ToolDescriptorInfo\]\s*=\s*\[/g;
  const headers = [...source.matchAll(header)];
  if (headers.length !== 1) {
    fail(
      `${label}: expected exactly one \`public static let all: [ToolDescriptorInfo] = [\` (found ${headers.length})`,
    );
  }
  const openIndex = headers[0].index + headers[0][0].length - 1;
  const { body } = extractBracketBody(source, openIndex, label);

  // Reject alternate call-site shapes so parse is unique.
  if (/ToolDescriptorInfo\s*\{/.test(body)) {
    fail(`${label}: unsupported ToolDescriptorInfo brace initializer in catalog`);
  }

  const descriptor =
    /ToolDescriptorInfo\(\s*name:\s*"([^"]+)"\s*,\s*phase:\s*(\d+)\s*,\s*enabledNow:\s*(true|false)\s*\)/g;
  const names = [];
  let match;
  let lastIndex = 0;
  let count = 0;
  while ((match = descriptor.exec(body)) !== null) {
    count += 1;
    // Ensure we did not skip an unparsed constructor between matches.
    const between = body.slice(lastIndex, match.index);
    if (/ToolDescriptorInfo\s*\(/.test(between)) {
      fail(
        `${label}: ambiguous/unparsed ToolDescriptorInfo before "${match[1]}"`,
      );
    }
    lastIndex = match.index + match[0].length;
    if (match[3] === "true") {
      names.push(match[1]);
    }
  }
  if (count === 0) {
    fail(`${label}: no ToolDescriptorInfo entries parsed inside all`);
  }
  const trailing = body.slice(lastIndex);
  if (/ToolDescriptorInfo\s*\(/.test(trailing)) {
    fail(`${label}: trailing unparsed ToolDescriptorInfo after last match`);
  }
  assertUniqueNames(label, names);
  return names;
}

function parseRustEnabledNames(source) {
  const label = "Rust TOOL_CATALOG";
  const header =
    /pub\s+const\s+TOOL_CATALOG\s*:\s*&\[ToolDescriptor\]\s*=\s*&\[/g;
  const headers = [...source.matchAll(header)];
  if (headers.length !== 1) {
    fail(
      `${label}: expected exactly one \`pub const TOOL_CATALOG: &[ToolDescriptor] = &[\` (found ${headers.length})`,
    );
  }
  const openIndex = headers[0].index + headers[0][0].length - 1;
  const { body } = extractBracketBody(source, openIndex, label);

  const names = [];
  let cursor = 0;
  let entryCount = 0;
  while (cursor < body.length) {
    const next = body.indexOf("ToolDescriptor", cursor);
    if (next === -1) {
      const rest = body.slice(cursor);
      if (/[A-Za-z_]/.test(rest.replace(/\/\/[^\n]*/g, ""))) {
        // Non-comment residual tokens after the last descriptor are ambiguous.
        const stripped = rest
          .replace(/\/\/[^\n]*/g, "")
          .replace(/\/\*[\s\S]*?\*\//g, "")
          .trim();
        if (stripped.length > 0 && /[A-Za-z_]/.test(stripped)) {
          fail(`${label}: unparsed residual content after ToolDescriptor entries`);
        }
      }
      break;
    }
    // Allow only `ToolDescriptor { ... }` entries inside the array.
    const afterName = body.slice(next + "ToolDescriptor".length);
    const braceOffset = afterName.search(/\S/);
    if (braceOffset === -1 || afterName[braceOffset] !== "{") {
      fail(
        `${label}: expected \`ToolDescriptor {\` at index ${next}, found other form`,
      );
    }
    const braceIndex = next + "ToolDescriptor".length + braceOffset;
    const between = body.slice(cursor, next);
    if (/ToolDescriptor/.test(between)) {
      fail(`${label}: overlapping/ambiguous ToolDescriptor parse`);
    }
    const { body: entry, end } = extractBraceBody(body, braceIndex, label);
    entryCount += 1;

    const nameMatches = [...entry.matchAll(/\bname\s*:\s*"([^"]+)"/g)];
    if (nameMatches.length !== 1) {
      fail(
        `${label}: expected exactly one name field in ToolDescriptor #${entryCount} (found ${nameMatches.length})`,
      );
    }
    const enabledMatches = [
      ...entry.matchAll(/\benabled_now\s*:\s*(true|false)/g),
    ];
    if (enabledMatches.length !== 1) {
      fail(
        `${label}: expected exactly one enabled_now field in ToolDescriptor #${entryCount} (found ${enabledMatches.length})`,
      );
    }
    if (enabledMatches[0][1] === "true") {
      names.push(nameMatches[0][1]);
    }
    cursor = end + 1;
  }

  if (entryCount === 0) {
    fail(`${label}: no ToolDescriptor entries parsed inside TOOL_CATALOG`);
  }
  assertUniqueNames(label, names);
  return names;
}

function formatList(names) {
  return names.map((name, i) => `  ${String(i + 1).padStart(2, " ")}. ${name}`).join("\n");
}

function main(argv) {
  if (argv.length > 0) {
    console.error("usage: node scripts/verify-cross-platform-contract.mjs");
    process.exit(2);
  }

  let swiftSource;
  let rustSource;
  try {
    swiftSource = readFileSync(SWIFT_CATALOG, "utf8");
  } catch (err) {
    fail(`cannot read Swift catalog at ${SWIFT_CATALOG}: ${err.message}`);
  }
  try {
    rustSource = readFileSync(RUST_CATALOG, "utf8");
  } catch (err) {
    fail(`cannot read Rust catalog at ${RUST_CATALOG}: ${err.message}`);
  }

  const swiftNames = parseSwiftEnabledNames(swiftSource);
  const rustNames = parseRustEnabledNames(rustSource);

  if (swiftNames.length !== EXPECTED_ENABLED_COUNT) {
    fail(
      `Swift enabled count drift: expected ${EXPECTED_ENABLED_COUNT}, got ${swiftNames.length}\n${formatList(swiftNames)}`,
    );
  }
  if (rustNames.length !== EXPECTED_ENABLED_COUNT) {
    fail(
      `Rust enabled count drift: expected ${EXPECTED_ENABLED_COUNT}, got ${rustNames.length}\n${formatList(rustNames)}`,
    );
  }
  if (swiftNames.length !== rustNames.length) {
    fail(
      `enabled count drift: Swift=${swiftNames.length} Rust=${rustNames.length}\nSwift:\n${formatList(swiftNames)}\nRust:\n${formatList(rustNames)}`,
    );
  }

  const drifts = [];
  for (let i = 0; i < swiftNames.length; i += 1) {
    if (swiftNames[i] !== rustNames[i]) {
      drifts.push(
        `  index ${i}: Swift="${swiftNames[i]}" Rust="${rustNames[i]}"`,
      );
    }
  }
  if (drifts.length > 0) {
    fail(
      `enabled order/name drift (${drifts.length} position(s)):\n${drifts.join("\n")}\nSwift:\n${formatList(swiftNames)}\nRust:\n${formatList(rustNames)}`,
    );
  }

  console.log(
    `verify-cross-platform-contract: OK — ${swiftNames.length} enabled tools match in canonical order`,
  );
  console.log(formatList(swiftNames));
  console.log(
    `sources:\n  Swift: ${path.relative(REPO_ROOT, SWIFT_CATALOG)}\n  Rust:  ${path.relative(REPO_ROOT, RUST_CATALOG)}`,
  );
}

main(process.argv.slice(2));
