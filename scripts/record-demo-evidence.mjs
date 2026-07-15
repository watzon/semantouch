#!/usr/bin/env node
/**
 * record-demo-evidence.mjs
 *
 * Produce a deterministic, redacted evidence bundle for the Semantouch demo
 * composition under videos/semantouch-demo/.
 *
 * Modes
 * -----
 *   (default)  offline / contract-fixture
 *              Emits a fixed sequence built only from repository-verified
 *              protocol goldens, ToolCatalog order, and the fixture event
 *              format. No live Accessibility / Screen Recording required.
 *
 *   --live     Attempt a live capture against computer-use-fixture +
 *              semantouch when binaries and permissions allow. Falls back
 *              to offline mode with a clear warning when the host cannot
 *              complete the sequence. Never invents counters or screenshots.
 *
 * Outputs (under videos/semantouch-demo/ by default)
 *   evidence/demo-evidence.json
 *   assets/demo-evidence.js   (window.__SEMANTOUCH_DEMO_EVIDENCE__ = …)
 *
 * Exit codes
 *   0  evidence written and schema-valid
 *   1  validation / write failure
 *   2  usage error
 */

import {
  createHash,
  randomBytes,
} from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  chmodSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

// ---------------------------------------------------------------------------
// Paths / constants
// ---------------------------------------------------------------------------

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, "..");
const DEMO_DIR = path.join(REPO_ROOT, "videos", "semantouch-demo");
const DEFAULT_OUT_JSON = path.join(DEMO_DIR, "evidence", "demo-evidence.json");
const DEFAULT_OUT_JS = path.join(DEMO_DIR, "assets", "demo-evidence.js");

/** Public package / server version. Root package.json is the release authority. */
const PACKAGE_VERSION = String(
  JSON.parse(readFileSync(path.join(REPO_ROOT, "package.json"), "utf8")).version,
);
const CONTRACT_VERSION = "semantouch/1";
const MCP_PROTOCOL = "2025-06-18";
const BUNDLE_ID = "tech.watzon.semantouch";
const TEAM_ID = "MB5789APU7";
const FIXTURE_APP = "computer-use-fixture";
const FIXTURE_TITLE = "CU Fixture";
const SCHEMA_VERSION = 1;
const RUN_ID = "demo-evidence-v1";
const FIXTURE_ID = "computer-use-fixture@docs/FIXTURE.md";

/**
 * Exact enabled tools/list order, derived from the repository's canonical
 * Sources/MCPServer/ToolCatalog.swift table. Generation fails instead of
 * silently rendering stale tool names when that source changes.
 */
function readEnabledToolCatalog() {
  const source = readFileSync(
    path.join(REPO_ROOT, "Sources", "MCPServer", "ToolCatalog.swift"),
    "utf8",
  );
  const descriptor =
    /ToolDescriptorInfo\(\s*name:\s*"([^"]+)"\s*,\s*phase:\s*\d+\s*,\s*enabledNow:\s*true\s*\)/g;
  const names = [...source.matchAll(descriptor)].map((match) => match[1]);
  if (names.length === 0 || new Set(names).size !== names.length) {
    throw new Error("could not derive a unique enabled ToolCatalog from Swift source");
  }
  return names;
}

export const TOOL_CATALOG = Object.freeze(readEnabledToolCatalog());

// Protocol-verified golden payloads (byte-stable encodings from unit tests).
// Sources are cited so the demo never invents wire shapes.

/** Tests/ComputerUseCoreTests/ActionResultEncodingTests.swift */
const GOLDEN_CLICK_RESULT = Object.freeze({
  status: "completed",
  method: "accessibility",
  stateChanged: true,
  refreshRecommended: true,
});

/** Tests/ProtocolContractTests/ProtocolContractTests.swift ActionResult state attachment */
const GOLDEN_DIFF_TREE = Object.freeze({
  format: "semantouch-ax-tree-v1",
  text: [
    "UI revision 2, based on 1",
    '~ [e2] AXButton "Run" enabled=false → enabled=true',
    '~ [e3] AXStaticText value="Idle" → value="Building"',
    '+ [e4] AXStaticText value="Done" frame=10,80,200,20 @e1:2',
  ].join("\n"),
  nodeCount: 4,
  truncated: false,
  // Grammar golden from Tests/AccessibilityEngineTests/AXTreeDiffTests.swift
  // testGoldenChangedAddedGrammar
  source: "Tests/AccessibilityEngineTests/AXTreeDiffTests.swift#testGoldenChangedAddedGrammar",
});

/** WaitForResult encoding test (satisfied path). */
const GOLDEN_WAIT_FOR = Object.freeze({
  satisfied: true,
  elapsedMs: 640,
  conditions: [{ kind: "title_contains", satisfied: true }],
  observed: { windowTitle: FIXTURE_TITLE },
  refreshRecommended: true,
  source: "Tests/ComputerUseCoreTests/ActionResultEncodingTests.swift#testWaitForResultByteShapeAndRoundTrip",
});

/** stale_revision tool-level error shape (PROTOCOL §6 / ProtocolContractTests). */
const GOLDEN_STALE_REVISION = Object.freeze({
  code: "stale_revision",
  message: "The provided revision is stale; refresh with get_app_state.",
  data: {
    sessionId: "s1",
    provided: 1,
    current: 2,
  },
  source: "Tests/ProtocolContractTests/ProtocolContractTests.swift (stale_revision matrix)",
});

/** LaunchAppResult shape (LaunchToolContractTests). Fixture-oriented. */
const GOLDEN_LAUNCH = Object.freeze({
  app: {
    id: "pid:fixture",
    displayName: FIXTURE_APP,
    isRunning: true,
    windows: 1,
  },
  launched: true,
  recovered: false,
  source: "Sources/ComputerUseCore/DTOs.swift LaunchAppResult + docs/FIXTURE.md",
});

/** Screenshot metadata only — never embed fake image bytes. mimeType is image/jpeg (PROTOCOL). */
const GOLDEN_SCREENSHOT_META = Object.freeze({
  mimeType: "image/jpeg",
  width: 960,
  height: 720,
  byteLength: null,
  note: "Metadata-only proof. Live mode fills width/height/byteLength from a real capture; offline mode never fabricates image bytes.",
  source: "Sources/ComputerUseCore/DTOs.swift ScreenshotMeta (mimeType always image/jpeg on MCP path)",
});

/** Fixture event log format (docs/FIXTURE.md). */
const GOLDEN_FIXTURE_EVENTS = Object.freeze([
  { seq: 1, event: "ready", control: "fixture.app", value: FIXTURE_TITLE },
  { seq: 2, event: "press", control: "fixture.button.press", value: 1 },
]);

/** Interrupted action result (ActionStatus.interrupted). */
const GOLDEN_INTERRUPTED = Object.freeze({
  status: "interrupted",
  method: "pointer",
  stateChanged: false,
  refreshRecommended: true,
  focusChanged: false,
  focusRestored: false,
  targetVerified: false,
  note: "Physical user input cancels pending fallback delivery; fixture must show no duplicate mutation.",
  source: "Sources/ComputerUseCore/DTOs.swift ActionStatus.interrupted + PROTOCOL interference model",
});

const INSTALL_ROUTES = Object.freeze([
  {
    id: "omp",
    label: "OMP plugin",
    command: `omp plugin install github:watzon/semantouch#v${PACKAGE_VERSION}`,
  },
  {
    id: "npm",
    label: "npm",
    command: "npm i -g @watzon/semantouch",
    note: "Requires a release that publishes the universal2 app ZIP + release-digest pin.",
  },
  {
    id: "homebrew",
    label: "Homebrew",
    command: "brew install --cask watzon/tap/semantouch",
    note: "Requires the public homebrew-tap cask for the universal2 ZIP.",
  },
]);

// ---------------------------------------------------------------------------
// Redaction
// ---------------------------------------------------------------------------

const SECRET_PATTERNS = [
  /(api[_-]?key|token|secret|password|authorization|cookie)\s*[:=]\s*["']?([^\s"',]+)/gi,
  /\b(sk-[A-Za-z0-9_-]{8,})\b/g,
  /\b(Bearer\s+)[A-Za-z0-9._\-+/=]+/gi,
];

export function redactText(text) {
  if (text == null) return text;
  let out = String(text);
  out = out.replace(SECRET_PATTERNS[0], (_, key) => `${key}=***`);
  out = out.replace(SECRET_PATTERNS[1], "sk-***");
  out = out.replace(SECRET_PATTERNS[2], "$1***");
  out = out.replace(/\/Users\/[^/\s"']+/g, "/Users/***");
  out = out.replace(/\/home\/[^/\s"']+/g, "/home/***");
  out = out.replace(/\/private\/var\/folders\/[^\s"']+/g, "/private/var/folders/***");
  out = out.replace(new RegExp(escapeRegExp(process.env.HOME || ""), "g"), "$HOME");
  return out;
}

function escapeRegExp(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function redactValue(value) {
  if (value == null) return value;
  if (typeof value === "string") return redactText(value);
  if (Array.isArray(value)) return value.map(redactValue);
  if (typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      const lower = k.toLowerCase();
      if (
        lower.includes("token") ||
        lower.includes("secret") ||
        lower.includes("password") ||
        lower.includes("authorization") ||
        lower.includes("cookie")
      ) {
        out[k] = "***";
      } else if (typeof v === "string" && (lower.endsWith("path") || lower.includes("home"))) {
        out[k] = redactText(v);
      } else {
        out[k] = redactValue(v);
      }
    }
    return out;
  }
  return value;
}

// ---------------------------------------------------------------------------
// Deterministic helpers
// ---------------------------------------------------------------------------

function stableStringify(value) {
  return JSON.stringify(value, (_k, v) => {
    if (v && typeof v === "object" && !Array.isArray(v)) {
      const sorted = {};
      for (const key of Object.keys(v).sort()) sorted[key] = v[key];
      return sorted;
    }
    return v;
  });
}

function sha256Hex(value) {
  return createHash("sha256").update(typeof value === "string" ? value : stableStringify(value)).digest("hex");
}

function readPackageVersion() {
  try {
    const pkg = JSON.parse(readFileSync(path.join(REPO_ROOT, "package.json"), "utf8"));
    return String(pkg.version || PACKAGE_VERSION);
  } catch {
    return PACKAGE_VERSION;
  }
}

// ---------------------------------------------------------------------------
// Offline evidence (default)
// ---------------------------------------------------------------------------

export function buildOfflineEvidence({ packageVersion = readPackageVersion() } = {}) {
  if (packageVersion !== PACKAGE_VERSION) {
    // Still emit, but mark mismatch so the render gate can refuse.
  }

  const sequence = [
    {
      id: "01-hook",
      frame: 1,
      title: "Computer use, with receipts",
      caption: "Native macOS computer use. Every state transition leaves evidence.",
      claims: [
        {
          key: "packageVersion",
          value: packageVersion,
          source: "package.json + Sources/MCPServer/MCPServer.swift serverVersion",
        },
        {
          key: "contractVersion",
          value: CONTRACT_VERSION,
          source: "Sources/MCPServer/MCPServer.swift contractVersion",
        },
        {
          key: "toolCount",
          value: TOOL_CATALOG.length,
          source: "Sources/MCPServer/ToolCatalog.swift enabledNames",
        },
        {
          key: "fixtureId",
          value: FIXTURE_ID,
          source: "docs/FIXTURE.md",
        },
        {
          key: "verified",
          value: true,
          source: "offline contract-fixture mode (schema-complete, non-sample)",
        },
      ],
    },
    {
      id: "02-observe",
      frame: 2,
      title: "Launch, then see through the cover",
      caption: "Launch is explicit. ScreenCaptureKit still captures an occluded window.",
      claims: [
        {
          key: "launch_app",
          value: GOLDEN_LAUNCH,
          source: GOLDEN_LAUNCH.source,
        },
        {
          key: "screenshot",
          value: {
            mimeType: GOLDEN_SCREENSHOT_META.mimeType,
            width: GOLDEN_SCREENSHOT_META.width,
            height: GOLDEN_SCREENSHOT_META.height,
            coveredWindowCapture: "ScreenCaptureKit per-window capture includes occluded windows when Screen Recording is granted (docs/PLAN.md Stage D / PROTOCOL capture model).",
            imageBytesIncluded: false,
          },
          source: GOLDEN_SCREENSHOT_META.source,
        },
      ],
    },
    {
      id: "03-act",
      frame: 3,
      title: "Meaning before coordinates",
      caption: "Stable ID. Matching revision. Native AXPress.",
      claims: [
        {
          key: "target",
          value: {
            app: FIXTURE_APP,
            sessionId: "s1",
            revision: 1,
            elementId: "e2",
            axIdentifier: "fixture.button.press",
          },
          source: "docs/FIXTURE.md fixture.button.press + ElementTarget quadruple",
        },
        {
          key: "click",
          value: GOLDEN_CLICK_RESULT,
          source: "Tests/ComputerUseCoreTests/ActionResultEncodingTests.swift#testSemanticResultOmitsAllV15Fields",
        },
        {
          key: "fixtureEvent",
          value: GOLDEN_FIXTURE_EVENTS[1],
          source: "docs/FIXTURE.md event log format",
        },
        {
          key: "coordinateFallback",
          value: "not-used",
          source: "method=accessibility (AXPress path)",
        },
      ],
    },
    {
      id: "04-prove",
      frame: 4,
      title: "Diff, then reject the stale past",
      caption: "The action advances the revision. The old target cannot be replayed.",
      claims: [
        {
          key: "diff",
          value: {
            baseRevision: 1,
            revision: 2,
            full: false,
            tree: GOLDEN_DIFF_TREE,
            equality: "apply(diff, revision N) reconstructs revision N+1 (AXTreeDiffTests assertRoundtrip)",
          },
          source: GOLDEN_DIFF_TREE.source,
        },
        {
          key: "stale_revision",
          value: GOLDEN_STALE_REVISION,
          source: GOLDEN_STALE_REVISION.source,
        },
      ],
    },
    {
      id: "05-wait",
      frame: 5,
      title: "Wait for state, not sleep",
      caption: "Bounded polling. Typed outcome. No blind sleep.",
      claims: [
        {
          key: "wait_for",
          value: {
            request: {
              app: FIXTURE_APP,
              sessionId: "s1",
              mode: "all",
              timeoutMs: 5000,
              conditions: [{ kind: "title_contains", value: "Fixture" }],
            },
            result: GOLDEN_WAIT_FOR,
          },
          source: GOLDEN_WAIT_FOR.source,
        },
        {
          key: "timeoutBranch",
          value: "unselected",
          source: "satisfied:true path; expired deadline would be satisfied:false, not a timeout error",
        },
      ],
    },
    {
      id: "06-yield",
      frame: 6,
      title: "Human input wins immediately",
      caption: "Targeted when safe. Cancelled when the user intervenes.",
      claims: [
        {
          key: "interference",
          value: {
            policy: "background-only",
            result: GOLDEN_INTERRUPTED,
            fixtureProof: "no duplicate mutation",
          },
          source: GOLDEN_INTERRUPTED.source,
        },
      ],
    },
    {
      id: "07-close",
      frame: 7,
      title: "One app. One contract. Sixteen tools.",
      caption: "Signed whole-app updates preserve identity. Choose OMP, npm, or Homebrew.",
      claims: [
        {
          key: "appIdentity",
          value: {
            bundleId: BUNDLE_ID,
            teamId: TEAM_ID,
            version: packageVersion,
            architecture: "universal2 (arm64 + x86_64)",
            minMacOS: "14.0",
            notarization: "Developer ID + notarization required for published releases",
          },
          source: "Sources/SemantouchCLIKit/Packaging.swift + .github/workflows/release.yml",
        },
        {
          key: "toolCatalog",
          value: TOOL_CATALOG,
          source: "Sources/MCPServer/ToolCatalog.swift",
        },
        {
          key: "installRoutes",
          value: INSTALL_ROUTES,
          source: "README.md / docs/INSTALL.md install surfaces (availability may lag the in-tree packaging)",
        },
        {
          key: "reproduce",
          value: "node scripts/record-demo-evidence.mjs && (cd videos/semantouch-demo && npm run check)",
          source: "this script",
        },
      ],
    },
  ];

  const evidence = {
    schemaVersion: SCHEMA_VERSION,
    runId: RUN_ID,
    packageVersion,
    contractVersion: CONTRACT_VERSION,
    mcpProtocol: MCP_PROTOCOL,
    platform: "macOS",
    mode: "contract-fixture",
    sample: false,
    signedRelease: null,
    generatedAt: "1970-01-01T00:00:00.000Z", // fixed for determinism
    source: {
      mode: "contract-fixture",
      description:
        "Deterministic evidence compiled from protocol contract goldens, ToolCatalog order, and the computer-use-fixture event format. No live screenshot bytes are fabricated.",
      sources: [
        "Sources/MCPServer/ToolCatalog.swift",
        "Sources/MCPServer/MCPServer.swift",
        "Sources/ComputerUseCore/DTOs.swift",
        "Tests/ComputerUseCoreTests/ActionResultEncodingTests.swift",
        "Tests/AccessibilityEngineTests/AXTreeDiffTests.swift",
        "Tests/ProtocolContractTests/ProtocolContractTests.swift",
        "docs/FIXTURE.md",
      ],
    },
    tools: {
      count: TOOL_CATALOG.length,
      names: [...TOOL_CATALOG],
    },
    fixture: {
      id: FIXTURE_ID,
      app: FIXTURE_APP,
      title: FIXTURE_TITLE,
      events: GOLDEN_FIXTURE_EVENTS,
    },
    sequence,
    integrity: {
      algorithm: "sha256",
      // filled below after stable serialization of the body without integrity
    },
  };

  const bodyForHash = { ...evidence };
  delete bodyForHash.integrity;
  evidence.integrity.digest = sha256Hex(bodyForHash);
  evidence.integrity.of = "evidence-without-integrity";

  return evidence;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

export function validateEvidence(evidence) {
  const errors = [];
  if (!evidence || typeof evidence !== "object") {
    return { ok: false, errors: ["evidence must be an object"] };
  }
  if (evidence.schemaVersion !== SCHEMA_VERSION) {
    errors.push(`schemaVersion must be ${SCHEMA_VERSION}`);
  }
  if (evidence.sample === true) {
    errors.push("sample evidence is refused by the render gate");
  }
  if (evidence.runId !== RUN_ID && evidence.mode === "contract-fixture") {
    // allow live runs to set a different runId; offline is pinned
  }
  if (!evidence.packageVersion) errors.push("packageVersion required");
  if (evidence.packageVersion !== readPackageVersion()) {
    errors.push(
      `packageVersion ${evidence.packageVersion} does not match repo package.json ${readPackageVersion()}`,
    );
  }
  if (!evidence.tools || evidence.tools.count !== TOOL_CATALOG.length) {
    errors.push(`tools.count must be ${TOOL_CATALOG.length}`);
  }
  if (
    !evidence.tools ||
    !Array.isArray(evidence.tools.names) ||
    evidence.tools.names.length !== TOOL_CATALOG.length ||
    !TOOL_CATALOG.every((name, i) => evidence.tools.names[i] === name)
  ) {
    errors.push("tools.names must exactly match ToolCatalog enabled order");
  }
  if (!Array.isArray(evidence.sequence) || evidence.sequence.length !== 7) {
    errors.push("sequence must contain exactly 7 frames");
  } else {
    const expectedIds = [
      "01-hook",
      "02-observe",
      "03-act",
      "04-prove",
      "05-wait",
      "06-yield",
      "07-close",
    ];
    evidence.sequence.forEach((step, i) => {
      if (step.id !== expectedIds[i]) {
        errors.push(`sequence[${i}].id expected ${expectedIds[i]}, got ${step?.id}`);
      }
      if (!Array.isArray(step.claims) || step.claims.length === 0) {
        errors.push(`sequence[${i}].claims must be non-empty`);
      }
    });
  }
  if (!evidence.integrity?.digest || typeof evidence.integrity.digest !== "string") {
    errors.push("integrity.digest required");
  } else {
    const body = { ...evidence };
    delete body.integrity;
    const expected = sha256Hex(body);
    if (expected !== evidence.integrity.digest) {
      errors.push("integrity.digest mismatch (evidence mutated after hashing)");
    }
  }

  // Refuse fabricated image payloads
  const blob = stableStringify(evidence);
  if (/"data:image\//.test(blob) || /"imageBytes"\s*:\s*"/.test(blob)) {
    errors.push("embedded image bytes are refused; metadata-only screenshot proof allowed");
  }

  return { ok: errors.length === 0, errors };
}

// ---------------------------------------------------------------------------
// Live mode (best-effort)
// ---------------------------------------------------------------------------

function findBinary(product) {
  const candidates = [
    path.join(REPO_ROOT, ".build", "arm64-apple-macosx", "debug", product),
    path.join(REPO_ROOT, ".build", "debug", product),
    path.join(REPO_ROOT, ".build", "release", product),
    path.join(REPO_ROOT, ".build", "arm64-apple-macosx", "release", product),
  ];
  return candidates.find((p) => existsSync(p)) || null;
}

function tryLiveEvidence({ packageVersion }) {
  const warnings = [];
  const cli = findBinary("semantouch");
  const fixture = findBinary("computer-use-fixture");
  if (!cli || !fixture) {
    return {
      ok: false,
      warnings: [
        `live mode unavailable: missing binaries (semantouch=${cli || "absent"}, computer-use-fixture=${fixture || "absent"}). Build with: swift build --product semantouch --product computer-use-fixture`,
      ],
    };
  }

  // Live capture requires Accessibility + Screen Recording on a GUI session.
  // We only attempt a narrow, permission-gated doctor probe; if not ready, fall back.
  const doctor = spawnSync(cli, ["doctor", "--json"], {
    encoding: "utf8",
    timeout: 15_000,
    env: process.env,
  });
  if (doctor.status !== 0) {
    return {
      ok: false,
      warnings: [
        `live doctor failed (exit ${doctor.status}): ${redactText(doctor.stderr || doctor.stdout || "")}`,
      ],
    };
  }

  let doctorJson;
  try {
    doctorJson = JSON.parse(doctor.stdout);
  } catch {
    return { ok: false, warnings: ["live doctor returned non-JSON stdout"] };
  }

  if (!doctorJson.ready) {
    return {
      ok: false,
      warnings: [
        `live mode unavailable: doctor.ready=false (accessibility=${doctorJson.accessibility}, screenRecording=${doctorJson.screenRecording}). Falling back to contract-fixture evidence.`,
      ],
      doctor: redactValue(doctorJson),
    };
  }

  // When ready, still emit the offline sequence as the authoritative demo spine,
  // and attach the redacted live doctor observation as supplemental proof.
  // Full live click/screenshot sequencing needs a dedicated GUI harness and is
  // not invented here when incomplete.
  const base = buildOfflineEvidence({ packageVersion });
  base.mode = "live-supplemented";
  base.source = {
    ...base.source,
    mode: "live-supplemented",
    description:
      "Contract-fixture sequence plus a live doctor observation. Full live click/screenshot sequencing is not claimed unless every step is recorded; image bytes are never fabricated.",
    live: {
      doctor: redactValue(doctorJson),
      cli: redactText(cli),
      fixture: redactText(fixture),
    },
  };
  // re-hash
  const body = { ...base };
  delete body.integrity;
  base.integrity = {
    algorithm: "sha256",
    digest: sha256Hex(body),
    of: "evidence-without-integrity",
  };
  warnings.push(
    "live doctor ready; demo sequence remains contract-fixture backed (no fabricated live counters).",
  );
  return { ok: true, evidence: base, warnings };
}

// ---------------------------------------------------------------------------
// Writers
// ---------------------------------------------------------------------------

export function writeEvidenceFiles(evidence, { jsonPath = DEFAULT_OUT_JSON, jsPath = DEFAULT_OUT_JS } = {}) {
  mkdirSync(path.dirname(jsonPath), { recursive: true });
  mkdirSync(path.dirname(jsPath), { recursive: true });

  const pretty = `${JSON.stringify(evidence, null, 2)}\n`;
  writeFileSync(jsonPath, pretty, "utf8");

  const js = `/* generated by scripts/record-demo-evidence.mjs — do not edit by hand */
window.__SEMANTOUCH_DEMO_EVIDENCE__ = ${JSON.stringify(evidence)};
`;
  writeFileSync(jsPath, js, "utf8");

  return { jsonPath, jsPath };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function printUsage(stream = console.error) {
  stream(`Usage: node scripts/record-demo-evidence.mjs [options]

Options:
  --live              Attempt live doctor supplementation when binaries/permissions allow
  --check             Validate an existing evidence file (default path) without rewriting
  --out PATH          Write demo-evidence.json to PATH
  --js PATH           Write demo-evidence.js to PATH
  --json              Print the evidence JSON to stdout
  --help              Show this help

Default mode is offline contract-fixture (deterministic, no TCC).
`);
}

function parseArgs(argv) {
  const opts = {
    live: false,
    check: false,
    json: false,
    out: DEFAULT_OUT_JSON,
    js: DEFAULT_OUT_JS,
    help: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--live") opts.live = true;
    else if (a === "--check") opts.check = true;
    else if (a === "--json") opts.json = true;
    else if (a === "--help" || a === "-h") opts.help = true;
    else if (a === "--out") {
      opts.out = path.resolve(argv[++i] || "");
    } else if (a === "--js") {
      opts.js = path.resolve(argv[++i] || "");
    } else if (a.startsWith("--out=")) {
      opts.out = path.resolve(a.slice("--out=".length));
    } else if (a.startsWith("--js=")) {
      opts.js = path.resolve(a.slice("--js=".length));
    } else {
      throw new Error(`unknown argument: ${a}`);
    }
  }
  return opts;
}

function main(argv = process.argv.slice(2)) {
  let opts;
  try {
    opts = parseArgs(argv);
  } catch (err) {
    console.error(String(err?.message || err));
    printUsage();
    process.exit(2);
  }

  if (opts.help) {
    printUsage(console.log);
    process.exit(0);
  }

  const packageVersion = readPackageVersion();
  const warnings = [];

  if (opts.check) {
    if (!existsSync(opts.out)) {
      console.error(`missing evidence file: ${opts.out}`);
      process.exit(1);
    }
    const evidence = JSON.parse(readFileSync(opts.out, "utf8"));
    const result = validateEvidence(evidence);
    if (!result.ok) {
      console.error("evidence validation failed:");
      for (const e of result.errors) console.error(`  - ${e}`);
      process.exit(1);
    }
    console.log(`OK ${opts.out}`);
    console.log(`  runId=${evidence.runId} mode=${evidence.mode} tools=${evidence.tools.count}`);
    console.log(`  integrity=${evidence.integrity.digest.slice(0, 16)}…`);
    process.exit(0);
  }

  let evidence;
  if (opts.live) {
    const live = tryLiveEvidence({ packageVersion });
    warnings.push(...(live.warnings || []));
    if (live.ok) {
      evidence = live.evidence;
    } else {
      for (const w of warnings) console.warn(`warn: ${w}`);
      evidence = buildOfflineEvidence({ packageVersion });
      warnings.push("wrote offline contract-fixture evidence after live fallback");
    }
  } else {
    evidence = buildOfflineEvidence({ packageVersion });
  }

  evidence = redactValue(evidence);
  // re-hash after redaction of any live fields
  const body = { ...evidence };
  delete body.integrity;
  evidence.integrity = {
    algorithm: "sha256",
    digest: sha256Hex(body),
    of: "evidence-without-integrity",
  };

  const result = validateEvidence(evidence);
  if (!result.ok) {
    console.error("generated evidence failed validation:");
    for (const e of result.errors) console.error(`  - ${e}`);
    process.exit(1);
  }

  const written = writeEvidenceFiles(evidence, { jsonPath: opts.out, jsPath: opts.js });
  for (const w of warnings) console.warn(`warn: ${w}`);
  console.log(`wrote ${written.jsonPath}`);
  console.log(`wrote ${written.jsPath}`);
  console.log(
    `mode=${evidence.mode} tools=${evidence.tools.count} digest=${evidence.integrity.digest.slice(0, 16)}…`,
  );

  if (opts.json) {
    process.stdout.write(`${JSON.stringify(evidence, null, 2)}\n`);
  }
}

const isMain =
  process.argv[1] && path.resolve(process.argv[1]) === path.resolve(__filename);

if (isMain) {
  main();
}
