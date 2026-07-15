#!/usr/bin/env node
/**
 * Shared, dependency-free helpers for Semantouch agent smoke / stress /
 * permission-onboarding harnesses.
 *
 * Contract:
 * - Node 18+ built-ins only
 * - spawn with argv arrays (never shell:true)
 * - fail closed; TERM then KILL process groups
 * - redacted / truncated logs
 * - dry-run never builds, hosts, fixtures, TCC, or agents
 */

import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
  chmodSync,
  accessSync,
  constants as fsConstants,
} from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const SUPPORTED_AGENTS = Object.freeze(["claude", "codex", "hermes"]);
export const DEFAULT_AGENTS = Object.freeze(["claude", "codex"]);
export const SMOKE_SCENARIOS = Object.freeze([
  "list-apps",
  "fixture",
  "fixture-full",
  "stress",
  "permission-onboarding",
]);
export const FIXTURE_APP = "computer-use-fixture";
export const FIXTURE_TITLE = "CU Fixture";
export const MCP_SERVER_KEY = "semantouch";
export const DEFAULT_TIMEOUT_MS = 120_000;
export const DEFAULT_STRESS_ITERATIONS = 5;
export const MAX_STRESS_ITERATIONS = 100;
export const DEFAULT_LOG_TAIL = 1200;
export const DEFAULT_OK_TOKEN = "SEMANTOUCH_AGENT_OK";

const BOOL_TRUE = new Set(["1", "true", "yes", "on"]);
const BOOL_FALSE = new Set(["0", "false", "no", "off"]);

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

export function repoRootFrom(moduleUrl = import.meta.url) {
  return path.resolve(path.dirname(fileURLToPath(moduleUrl)), "..");
}

export function defaultBinaryCandidates(repoRoot, product) {
  return [
    path.join(repoRoot, ".build", "debug", product),
    path.join(repoRoot, ".build", "release", product),
    path.join(repoRoot, ".build", "arm64-apple-macosx", "debug", product),
    path.join(repoRoot, ".build", "arm64-apple-macosx", "release", product),
  ];
}

export function findExistingBinary(candidates) {
  for (const candidate of candidates) {
    if (candidate && existsSync(candidate)) return candidate;
  }
  return null;
}

export function resolveLocalProducts(repoRoot, options = {}) {
  const host =
    options.hostPath ||
    findExistingBinary(defaultBinaryCandidates(repoRoot, "SemantouchHost"));
  const fixture =
    options.fixturePath ||
    findExistingBinary(defaultBinaryCandidates(repoRoot, "computer-use-fixture"));
  const cli =
    options.cliPath ||
    findExistingBinary(defaultBinaryCandidates(repoRoot, "semantouch")) ||
    path.join(repoRoot, "scripts", "semantouch");
  return { host, fixture, cli };
}

// ---------------------------------------------------------------------------
// Arg parsing — strict --key=value / --key value
// ---------------------------------------------------------------------------

export class ParseError extends Error {
  constructor(message) {
    super(message);
    this.name = "ParseError";
    this.code = "PARSE_ERROR";
  }
}

/**
 * Parse argv into a Map of flag → value.
 * Bare flags become "true". Rejects unknown flags when `allowed` is provided.
 * Supports both `--key=value` and `--key value`.
 */
export function parseArgs(argv, options = {}) {
  const allowed = options.allowed ? new Set(options.allowed) : null;
  const aliases = options.aliases ?? {};
  const booleans = new Set(options.booleans ?? []);
  const out = new Map();
  const positionals = [];

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--") {
      positionals.push(...argv.slice(i + 1));
      break;
    }
    if (!token.startsWith("--")) {
      positionals.push(token);
      continue;
    }
    if (token === "--") continue;

    let name;
    let value;
    const eq = token.indexOf("=");
    if (eq !== -1) {
      name = token.slice(2, eq);
      value = token.slice(eq + 1);
      if (name === "") throw new ParseError(`invalid flag: ${token}`);
    } else {
      name = token.slice(2);
      if (name === "") throw new ParseError(`invalid flag: ${token}`);
      if (booleans.has(name) || booleans.has(aliases[name] ?? "")) {
        value = "true";
      } else if (i + 1 < argv.length && !argv[i + 1].startsWith("--")) {
        value = argv[i + 1];
        i += 1;
      } else if (booleans.has(name) || options.bareTrue) {
        value = "true";
      } else {
        throw new ParseError(`missing value for --${name}`);
      }
    }

    const canonical = aliases[name] ?? name;
    if (allowed && !allowed.has(canonical)) {
      throw new ParseError(`unknown flag --${name}`);
    }
    if (out.has(canonical)) {
      throw new ParseError(`duplicate flag --${canonical}`);
    }
    out.set(canonical, value);
  }

  return { flags: out, positionals };
}

export function flagString(flags, name, fallback = undefined) {
  if (!flags.has(name)) return fallback;
  const value = flags.get(name);
  if (value === undefined || value === null || value === "") {
    throw new ParseError(`--${name} requires a non-empty value`);
  }
  return value;
}

export function flagBool(flags, name, fallback = false) {
  if (!flags.has(name)) return fallback;
  const raw = String(flags.get(name)).toLowerCase();
  if (BOOL_TRUE.has(raw)) return true;
  if (BOOL_FALSE.has(raw)) return false;
  // bare presence / "true" from parser
  if (raw === "") return true;
  throw new ParseError(`--${name} expects a boolean, got ${JSON.stringify(flags.get(name))}`);
}

export function flagInt(flags, name, fallback, { min = null, max = null } = {}) {
  if (!flags.has(name)) return fallback;
  const raw = flags.get(name);
  if (!/^-?\d+$/.test(String(raw))) {
    throw new ParseError(`--${name} expects an integer, got ${JSON.stringify(raw)}`);
  }
  const n = Number(raw);
  if (!Number.isSafeInteger(n)) {
    throw new ParseError(`--${name} is not a safe integer`);
  }
  if (min !== null && n < min) {
    throw new ParseError(`--${name} must be >= ${min}`);
  }
  if (max !== null && n > max) {
    throw new ParseError(`--${name} must be <= ${max}`);
  }
  return n;
}

export function parseAgentList(raw, { defaultAgents = DEFAULT_AGENTS } = {}) {
  const text = raw == null || raw === "" ? defaultAgents.join(",") : String(raw);
  const agents = text
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  if (agents.length === 0) {
    throw new ParseError("agent list is empty");
  }
  const unknown = agents.filter((a) => !SUPPORTED_AGENTS.includes(a));
  if (unknown.length) {
    throw new ParseError(
      `unsupported agent(s): ${unknown.join(", ")} (supported: ${SUPPORTED_AGENTS.join(", ")})`,
    );
  }
  // preserve order, unique
  return [...new Set(agents)];
}

export function parseScenarioList(raw, { allowed = SMOKE_SCENARIOS, defaultScenario = "list-apps" } = {}) {
  const text = raw == null || raw === "" ? defaultScenario : String(raw);
  const scenarios = text
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (scenarios.length === 0) {
    throw new ParseError("scenario list is empty");
  }
  const unknown = scenarios.filter((s) => !allowed.includes(s));
  if (unknown.length) {
    throw new ParseError(
      `unsupported scenario(s): ${unknown.join(", ")} (supported: ${allowed.join(", ")})`,
    );
  }
  return [...new Set(scenarios)];
}

// ---------------------------------------------------------------------------
// Config assembly for wrappers
// ---------------------------------------------------------------------------

export const COMMON_FLAGS = Object.freeze([
  "help",
  "json",
  "dry-run",
  "agents",
  "scenario",
  "scenarios",
  "timeout-ms",
  "command",
  "cli",
  "host",
  "fixture",
  "repo-root",
  "require-agents",
  "require-permissions",
  "allow-permission-prompt",
  "iterations",
  "loops",
  "ok-token",
  "claude-command",
  "claude-model",
  "claude-budget-usd",
  "codex-command",
  "codex-model",
  "hermes-command",
  "hermes-provider",
  "hermes-model",
  "hermes-max-turns",
  "hermes-toolsets",
  "hermes-config",
  "log-tail",
  "scratch-path",
  "skip-build",
  "build-config",
]);

export function loadHarnessConfig(argv, env = process.env, defaults = {}) {
  const { flags, positionals } = parseArgs(argv, {
    allowed: COMMON_FLAGS,
    booleans: [
      "help",
      "json",
      "dry-run",
      "require-agents",
      "require-permissions",
      "allow-permission-prompt",
      "skip-build",
    ],
    bareTrue: true,
    aliases: {
      h: "help",
    },
  });

  if (positionals.length) {
    throw new ParseError(`unexpected positional argument(s): ${positionals.join(" ")}`);
  }

  const repoRoot = path.resolve(
    flagString(flags, "repo-root", defaults.repoRoot ?? repoRootFrom()),
  );
  const products = resolveLocalProducts(repoRoot, {
    hostPath: flagString(flags, "host", env.SEMANTOUCH_HOST || undefined),
    fixturePath: flagString(flags, "fixture", env.SEMANTOUCH_FIXTURE || undefined),
    cliPath: flagString(
      flags,
      "cli",
      flagString(flags, "command", env.SEMANTOUCH_BIN || env.SEMANTOUCH_CLI || undefined),
    ),
  });

  const scenarioRaw =
    flagString(flags, "scenarios", undefined) ??
    flagString(flags, "scenario", defaults.scenario ?? "list-apps");

  const iterations = flagInt(
    flags,
    "iterations",
    flagInt(flags, "loops", defaults.iterations ?? DEFAULT_STRESS_ITERATIONS, {
      min: 1,
      max: MAX_STRESS_ITERATIONS,
    }),
    { min: 1, max: MAX_STRESS_ITERATIONS },
  );

  return {
    help: flagBool(flags, "help", false),
    json: flagBool(flags, "json", false),
    dryRun: flagBool(flags, "dry-run", false),
    requireAgents: flagBool(flags, "require-agents", false),
    requirePermissions: flagBool(flags, "require-permissions", false),
    allowPermissionPrompt: flagBool(flags, "allow-permission-prompt", false),
    skipBuild: flagBool(flags, "skip-build", false),
    agents: parseAgentList(
      flagString(flags, "agents", env.SEMANTOUCH_AGENT_AGENTS || undefined),
      { defaultAgents: defaults.agents ?? DEFAULT_AGENTS },
    ),
    scenarios: parseScenarioList(scenarioRaw, {
      defaultScenario: defaults.scenario ?? "list-apps",
    }),
    timeoutMs: flagInt(
      flags,
      "timeout-ms",
      Number(env.SEMANTOUCH_AGENT_TIMEOUT_MS || defaults.timeoutMs || DEFAULT_TIMEOUT_MS),
      { min: 1 },
    ),
    iterations,
    okToken: flagString(flags, "ok-token", defaults.okToken ?? DEFAULT_OK_TOKEN),
    logTail: flagInt(flags, "log-tail", defaults.logTail ?? DEFAULT_LOG_TAIL, { min: 64 }),
    buildConfig: flagString(flags, "build-config", defaults.buildConfig ?? "debug"),
    scratchPath: flagString(flags, "scratch-path", defaults.scratchPath ?? undefined),
    repoRoot,
    hostPath: products.host,
    fixturePath: products.fixture,
    cliPath: products.cli,
    agentCommands: {
      claude: flagString(
        flags,
        "claude-command",
        env.SEMANTOUCH_CLAUDE_COMMAND || env.CLAUDE_COMMAND || "claude",
      ),
      codex: flagString(
        flags,
        "codex-command",
        env.SEMANTOUCH_CODEX_COMMAND || env.CODEX_COMMAND || "codex",
      ),
      hermes: flagString(
        flags,
        "hermes-command",
        env.SEMANTOUCH_HERMES_COMMAND || env.HERMES_COMMAND || "hermes",
      ),
    },
    claudeModel: flagString(flags, "claude-model", env.SEMANTOUCH_CLAUDE_MODEL || undefined),
    claudeBudgetUsd: flagString(
      flags,
      "claude-budget-usd",
      env.SEMANTOUCH_CLAUDE_BUDGET_USD || "2.00",
    ),
    codexModel: flagString(flags, "codex-model", env.SEMANTOUCH_CODEX_MODEL || undefined),
    hermesProvider: flagString(
      flags,
      "hermes-provider",
      env.SEMANTOUCH_HERMES_PROVIDER || undefined,
    ),
    hermesModel: flagString(flags, "hermes-model", env.SEMANTOUCH_HERMES_MODEL || undefined),
    hermesMaxTurns: flagString(
      flags,
      "hermes-max-turns",
      env.SEMANTOUCH_HERMES_MAX_TURNS || "12",
    ),
    hermesToolsets: flagString(
      flags,
      "hermes-toolsets",
      env.SEMANTOUCH_HERMES_TOOLSETS || MCP_SERVER_KEY,
    ),
    hermesConfig: flagString(flags, "hermes-config", env.SEMANTOUCH_HERMES_CONFIG || undefined),
    env,
  };
}

// ---------------------------------------------------------------------------
// Redaction / tails
// ---------------------------------------------------------------------------

const SECRET_PATTERNS = [
  /(api[_-]?key|token|secret|password|authorization|cookie)\s*[:=]\s*["']?([^\s"',]+)/gi,
  /\b(sk-[A-Za-z0-9_-]{8,})\b/g,
  /\b(Bearer\s+)[A-Za-z0-9._\-+/=]+/gi,
  /("?(?:HOME|USER|PATH|TMPDIR|SEMANTOUCH_[A-Z0-9_]+)"?\s*:\s*")([^"]+)(")/g,
];

export function redactText(text, { max = DEFAULT_LOG_TAIL } = {}) {
  if (text == null) return "";
  let out = String(text);
  out = out.replace(SECRET_PATTERNS[0], (_, key) => `${key}=***`);
  out = out.replace(SECRET_PATTERNS[1], "sk-***");
  out = out.replace(SECRET_PATTERNS[2], "$1***");
  out = out.replace(SECRET_PATTERNS[3], '$1***$3');
  // collapse absolute home-ish paths somewhat
  out = out.replace(/\/Users\/[^/\s"']+/g, "/Users/***");
  out = out.replace(/\/home\/[^/\s"']+/g, "/home/***");
  if (out.length > max) {
    out = `…${out.slice(-max)}`;
  }
  return out;
}

export function redactValue(value, { max = DEFAULT_LOG_TAIL } = {}) {
  if (value == null) return value;
  if (typeof value === "string") return redactText(value, { max });
  if (Array.isArray(value)) return value.map((v) => redactValue(v, { max }));
  if (typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      const lower = k.toLowerCase();
      if (
        lower.includes("token") ||
        lower.includes("secret") ||
        lower.includes("password") ||
        lower.includes("authorization")
      ) {
        out[k] = "***";
      } else if (typeof v === "string" && (lower.endsWith("path") || lower.includes("home"))) {
        out[k] = redactText(v, { max });
      } else {
        out[k] = redactValue(v, { max });
      }
    }
    return out;
  }
  return value;
}

export function uniqueToken(prefix = "smoke") {
  const stamp = Date.now().toString(36);
  const rand = randomBytes(4).toString("hex");
  return `${prefix}-${stamp}-${rand}`;
}

// ---------------------------------------------------------------------------
// Temp dirs / secure files
// ---------------------------------------------------------------------------

export function createSecureTempDir(prefix = "semantouch-agent-smoke-", base = tmpdir()) {
  const dir = mkdtempSync(path.join(base, prefix));
  chmodSync(dir, 0o700);
  return dir;
}

export function writeSecureFile(filePath, contents, mode = 0o600) {
  writeFileSync(filePath, contents, { encoding: "utf8", mode });
  chmodSync(filePath, mode);
  return filePath;
}

export function removePathIdempotent(target) {
  if (!target) return { removed: false, path: target };
  if (!existsSync(target)) {
    return { removed: false, path: target };
  }
  try {
    rmSync(target, { recursive: true, force: true });
    return { removed: true, path: target };
  } catch (error) {
    // force:true should not throw for missing paths; surface unexpected errors
    if (error && (error.code === "ENOENT" || error.code === "ENOTDIR")) {
      return { removed: false, path: target };
    }
    throw error;
  }
}

// ---------------------------------------------------------------------------
// Process management — argv only, process groups, TERM→KILL
// ---------------------------------------------------------------------------

export function isExecutableOnPath(command, { env = process.env, whichImpl } = {}) {
  if (!command) return false;
  if (command.includes("/") || command.includes("\\")) {
    try {
      accessSync(command, fsConstants.X_OK);
      return true;
    } catch {
      return existsSync(command);
    }
  }
  if (typeof whichImpl === "function") {
    return Boolean(whichImpl(command));
  }
  const result = spawnSync("which", [command], {
    env,
    encoding: "utf8",
    shell: false,
  });
  return result.status === 0 && Boolean(result.stdout?.trim());
}

/**
 * Spawn a child with detached process group (when supported) so cleanup can
 * signal the whole tree. Never uses shell:true.
 */
export function spawnArgv(command, args, options = {}) {
  if (options.shell) {
    throw new Error("shell:true is forbidden in the agent smoke harness");
  }
  const child = spawn(command, args, {
    cwd: options.cwd,
    env: options.env ?? process.env,
    stdio: options.stdio ?? ["ignore", "pipe", "pipe"],
    detached: options.detached !== false,
    shell: false,
    windowsHide: true,
  });
  return child;
}

export function killProcessTree(child, { termGraceMs = 3000, killFn = process.kill } = {}) {
  if (!child || child.killed) {
    return { term: false, kill: false };
  }
  const pid = child.pid;
  if (!pid) return { term: false, kill: false };

  let term = false;
  let kill = false;
  try {
    killFn(-pid, "SIGTERM");
    term = true;
  } catch {
    try {
      killFn(pid, "SIGTERM");
      term = true;
    } catch {
      // already gone
    }
  }

  const escalate = () => {
    try {
      killFn(-pid, "SIGKILL");
      kill = true;
    } catch {
      try {
        killFn(pid, "SIGKILL");
        kill = true;
      } catch {
        // gone
      }
    }
  };

  if (termGraceMs <= 0) {
    escalate();
    return { term, kill: true };
  }

  const timer = setTimeout(escalate, termGraceMs);
  if (typeof timer.unref === "function") timer.unref();
  child.once?.("exit", () => clearTimeout(timer));
  return { term, kill, timer };
}

export function runProcess(spec, {
  timeoutMs = DEFAULT_TIMEOUT_MS,
  env = process.env,
  cwd = process.cwd(),
  logTail = DEFAULT_LOG_TAIL,
  spawnImpl = spawnArgv,
  now = Date.now,
} = {}) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawnImpl(spec.command, spec.args, {
        cwd,
        env: { ...env, ...(spec.env ?? {}) },
        stdio: ["ignore", "pipe", "pipe"],
        detached: true,
        shell: false,
      });
    } catch (error) {
      resolve({
        ok: false,
        code: null,
        signal: null,
        timedOut: false,
        error: String(error?.message ?? error),
        stdout: "",
        stderr: String(error?.message ?? error),
        stdoutTail: "",
        stderrTail: redactText(String(error?.message ?? error), { max: logTail }),
        durationMs: 0,
      });
      return;
    }

    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let settled = false;
    const started = now();

    const finish = (payload) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({
        ...payload,
        stdout,
        stderr,
        stdoutTail: redactText(stdout, { max: logTail }),
        stderrTail: redactText(stderr, { max: logTail }),
        durationMs: now() - started,
      });
    };

    const timer = setTimeout(() => {
      timedOut = true;
      killProcessTree(child, { termGraceMs: 3000 });
    }, timeoutMs);

    child.stdout?.on("data", (chunk) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr?.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (error) => {
      finish({
        ok: false,
        code: null,
        signal: null,
        timedOut,
        error: String(error?.message ?? error),
      });
    });
    child.on("close", (code, signal) => {
      finish({
        ok: code === 0 && !timedOut,
        code,
        signal,
        timedOut,
        error: timedOut ? `timed out after ${timeoutMs}ms` : null,
      });
    });
  });
}

// ---------------------------------------------------------------------------
// Build / host / fixture lifecycle (skipped under dry-run)
// ---------------------------------------------------------------------------

export function buildProduct(product, {
  repoRoot,
  configuration = "debug",
  dryRun = false,
  skipBuild = false,
  spawnSyncImpl = spawnSync,
} = {}) {
  if (dryRun) {
    return { skipped: true, reason: "dry-run", product, configuration };
  }
  if (skipBuild) {
    return { skipped: true, reason: "skip-build", product, configuration };
  }
  const args = ["build", "--product", product];
  if (configuration === "release") args.push("-c", "release");
  const result = spawnSyncImpl("swift", args, {
    cwd: repoRoot,
    encoding: "utf8",
    shell: false,
  });
  if (result.status !== 0) {
    const err = redactText(result.stderr || result.stdout || "swift build failed");
    throw new Error(`failed to build ${product}: ${err}`);
  }
  return { skipped: false, product, configuration, status: result.status };
}

export function ensureProducts(config, { spawnSyncImpl = spawnSync } = {}) {
  const actions = [];
  if (config.dryRun) {
    return {
      hostPath: config.hostPath,
      fixturePath: config.fixturePath,
      cliPath: config.cliPath,
      actions: [{ skipped: true, reason: "dry-run" }],
    };
  }

  let { hostPath, fixturePath, cliPath } = resolveLocalProducts(config.repoRoot, {
    hostPath: config.hostPath,
    fixturePath: config.fixturePath,
    cliPath: config.cliPath,
  });

  if (!hostPath) {
    actions.push(
      buildProduct("SemantouchHost", {
        repoRoot: config.repoRoot,
        configuration: config.buildConfig,
        skipBuild: config.skipBuild,
        spawnSyncImpl,
      }),
    );
    hostPath = findExistingBinary(defaultBinaryCandidates(config.repoRoot, "SemantouchHost"));
  }
  if (!fixturePath) {
    actions.push(
      buildProduct("computer-use-fixture", {
        repoRoot: config.repoRoot,
        configuration: config.buildConfig,
        skipBuild: config.skipBuild,
        spawnSyncImpl,
      }),
    );
    fixturePath = findExistingBinary(
      defaultBinaryCandidates(config.repoRoot, "computer-use-fixture"),
    );
  }
  if (!cliPath || !existsSync(cliPath)) {
    actions.push(
      buildProduct("semantouch", {
        repoRoot: config.repoRoot,
        configuration: config.buildConfig,
        skipBuild: config.skipBuild,
        spawnSyncImpl,
      }),
    );
    cliPath =
      findExistingBinary(defaultBinaryCandidates(config.repoRoot, "semantouch")) ||
      path.join(config.repoRoot, "scripts", "semantouch");
  }

  if (!hostPath || !existsSync(hostPath)) {
    throw new Error("SemantouchHost binary not found; build locally or pass --host");
  }
  if (!fixturePath || !existsSync(fixturePath)) {
    throw new Error("computer-use-fixture binary not found; build locally or pass --fixture");
  }
  if (!cliPath || !existsSync(cliPath)) {
    throw new Error("semantouch CLI binary not found; build locally or pass --cli");
  }

  return { hostPath, fixturePath, cliPath, actions };
}

export function launchManagedProcess(command, args, {
  cwd,
  env,
  label,
  spawnImpl = spawnArgv,
} = {}) {
  const child = spawnImpl(command, args, {
    cwd,
    env,
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
    shell: false,
  });
  const state = {
    label,
    command,
    args,
    child,
    pid: child.pid,
    stdout: "",
    stderr: "",
    exitCode: null,
    signal: null,
  };
  child.stdout?.on("data", (c) => {
    state.stdout += c.toString("utf8");
  });
  child.stderr?.on("data", (c) => {
    state.stderr += c.toString("utf8");
  });
  child.on("close", (code, signal) => {
    state.exitCode = code;
    state.signal = signal;
  });
  return state;
}

export function stopManagedProcess(state, { termGraceMs = 3000 } = {}) {
  if (!state?.child) return { term: false, kill: false };
  return killProcessTree(state.child, { termGraceMs });
}

export function launchFixture({
  fixturePath,
  stateFile,
  title = FIXTURE_TITLE,
  activate = true,
  dryRun = false,
  cwd,
  env = process.env,
  spawnImpl = spawnArgv,
} = {}) {
  if (dryRun) {
    return {
      dryRun: true,
      command: fixturePath,
      args: [
        "--state-file",
        stateFile,
        "--title",
        title,
        ...(activate ? ["--activate"] : []),
      ],
    };
  }
  if (!fixturePath) throw new Error("fixturePath is required");
  if (!stateFile) throw new Error("stateFile is required");
  // truncate/create state file with secure mode
  writeSecureFile(stateFile, "", 0o600);
  const args = ["--state-file", stateFile, "--title", title];
  if (activate) args.push("--activate");
  return launchManagedProcess(fixturePath, args, {
    cwd,
    env,
    label: "fixture",
    spawnImpl,
  });
}

export function launchHost({
  hostPath,
  dryRun = false,
  cwd,
  env = process.env,
  spawnImpl = spawnArgv,
} = {}) {
  if (dryRun) {
    return { dryRun: true, command: hostPath, args: [] };
  }
  if (!hostPath) throw new Error("hostPath is required");
  return launchManagedProcess(hostPath, [], {
    cwd,
    env,
    label: "host",
    spawnImpl,
  });
}

// ---------------------------------------------------------------------------
// semantouch call helpers
// ---------------------------------------------------------------------------

export function parseJSONL(text) {
  const events = [];
  const errors = [];
  const lines = String(text || "")
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean);
  for (const [index, line] of lines.entries()) {
    try {
      events.push(JSON.parse(line));
    } catch (error) {
      errors.push({ index, line: redactText(line, { max: 200 }), error: String(error.message) });
    }
  }
  return { events, errors };
}

export function readFixtureStateFile(stateFile) {
  if (!existsSync(stateFile)) return { events: [], errors: [], raw: "" };
  const raw = readFileSync(stateFile, "utf8");
  const parsed = parseJSONL(raw);
  return { ...parsed, raw };
}

/**
 * Validate fixture JSONL for expected control events with unique values.
 * Rejects duplicate (event, control, value, seq) tuples and non-monotonic seq.
 */
export function validateFixtureEvents(events, expectations = []) {
  const issues = [];
  const seen = new Set();
  let lastSeq = 0;

  for (const event of events) {
    if (typeof event.seq === "number") {
      if (event.seq <= lastSeq) {
        issues.push(`non-monotonic seq: ${event.seq} after ${lastSeq}`);
      }
      lastSeq = event.seq;
    }
    const key = `${event.seq}|${event.event}|${event.control}|${JSON.stringify(event.value)}`;
    if (seen.has(key)) {
      issues.push(`duplicate event: ${key}`);
    }
    seen.add(key);
  }

  const matched = [];
  for (const exp of expectations) {
    const hit = events.find((e) => {
      if (exp.event && e.event !== exp.event) return false;
      if (exp.control && e.control !== exp.control) return false;
      if (Object.prototype.hasOwnProperty.call(exp, "value") && e.value !== exp.value) {
        return false;
      }
      return true;
    });
    if (!hit) {
      issues.push(
        `missing expected event ${JSON.stringify(exp)}; saw ${events
          .map((e) => `${e.event}/${e.control}`)
          .join(", ")}`,
      );
    } else {
      matched.push(hit);
    }
  }

  return { ok: issues.length === 0, issues, matched, eventCount: events.length };
}

export function extractToolResultText(result) {
  if (result == null) return "";
  if (typeof result === "string") return result;
  if (Array.isArray(result?.content)) {
    return result.content
      .filter((c) => c && c.type === "text" && typeof c.text === "string")
      .map((c) => c.text)
      .join("\n");
  }
  if (typeof result?.text === "string") return result.text;
  return JSON.stringify(result);
}

export async function callSemantouchTool(cliPath, tool, toolArgs = {}, {
  cwd,
  env = process.env,
  timeoutMs = 30_000,
  runProcessImpl = runProcess,
} = {}) {
  const result = await runProcessImpl(
    {
      command: cliPath,
      args: ["call", tool, "--args", JSON.stringify(toolArgs)],
    },
    { cwd, env, timeoutMs },
  );
  if (!result.ok) {
    throw new Error(
      `semantouch call ${tool} failed (code=${result.code}): ${result.stderrTail || result.error || "unknown"}`,
    );
  }
  const stdout = result.stdout.trim();
  // one JSON line expected (tools/call result envelope)
  const line = stdout.split(/\r?\n/).filter(Boolean).pop() || stdout;
  let parsed;
  try {
    parsed = JSON.parse(line);
  } catch (error) {
    throw new Error(`failed to parse semantouch call ${tool} output: ${error.message}`);
  }
  return { envelope: parsed, text: extractToolResultText(parsed), raw: result };
}

/**
 * Parse a semantouch-ax-tree-v1 text blob for stress targets.
 * AXIdentifier is not rendered; match role + visible title only.
 */
export function parseTreeTargets(treeText) {
  const text = String(treeText || "");
  const elementIds = [...text.matchAll(/\[(e\d+)\]/g)].map((m) => m[1]);
  let textFieldId = null;
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/\[(e\d+)\]\s+AXTextField(?!\.AXSecureTextField)\b/);
    if (m) {
      textFieldId = m[1];
      break;
    }
  }
  if (!textFieldId) {
    const m = text.match(/\[(e\d+)\]\s+AXTextField\b/);
    if (m) textFieldId = m[1];
  }
  let pressButtonId = null;
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/\[(e\d+)\]\s+AXButton\s+"Press Me"/);
    if (m) {
      pressButtonId = m[1];
      break;
    }
  }
  const issues = [];
  if (!textFieldId) issues.push("missing editable AXTextField target in tree");
  if (!pressButtonId) issues.push('missing AXButton "Press Me" target in tree');
  return {
    ok: issues.length === 0,
    issues,
    textFieldId,
    pressButtonId,
    elementIds,
  };
}

export function parseAppStatePayload(textOrEnvelope) {
  if (textOrEnvelope == null) return {};
  if (typeof textOrEnvelope === "object" && !Array.isArray(textOrEnvelope)) {
    if (textOrEnvelope.sessionId || textOrEnvelope.revision != null || textOrEnvelope.tree) {
      return textOrEnvelope;
    }
    const text = extractToolResultText(textOrEnvelope);
    try {
      return JSON.parse(text);
    } catch {
      return { tree: { text } };
    }
  }
  const raw = String(textOrEnvelope);
  try {
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === "object") {
      if (parsed.sessionId || parsed.revision != null || parsed.tree) return parsed;
      const inner = extractToolResultText(parsed);
      try {
        return JSON.parse(inner);
      } catch {
        return parsed;
      }
    }
  } catch {
    // plain tree text
  }
  return { tree: { text: raw } };
}

/**
 * Persistent newline-delimited JSON-RPC MCP client over one `semantouch mcp` child.
 * Initializes once; every tools/call shares the same host session context.
 */
export function createMcpSession({
  cliPath,
  cwd,
  env = process.env,
  spawnImpl = spawnArgv,
  clientName = "semantouch-agent-smoke",
  clientVersion = "0.2.1",
  protocolVersion = "2024-11-05",
  requestTimeoutMs = 30_000,
} = {}) {
  if (!cliPath) throw new Error("createMcpSession requires cliPath");

  const child = spawnImpl(cliPath, ["mcp"], {
    cwd,
    env: { ...env, SEMANTOUCH_VISUAL_CURSOR: "0" },
    stdio: ["pipe", "pipe", "pipe"],
    detached: true,
    shell: false,
  });

  let nextId = 1;
  let buffer = "";
  let closed = false;
  const pending = new Map();
  const calls = [];

  const rejectAll = (error) => {
    for (const [, entry] of pending) {
      clearTimeout(entry.timer);
      entry.reject(error);
    }
    pending.clear();
  };

  child.stdout?.setEncoding?.("utf8");
  child.stdout?.on("data", (chunk) => {
    buffer += String(chunk);
    let nl;
    while ((nl = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (msg.id == null) continue;
      const entry = pending.get(msg.id);
      if (!entry) continue;
      pending.delete(msg.id);
      clearTimeout(entry.timer);
      entry.resolve(msg);
    }
  });

  child.stderr?.on("data", () => {});
  child.on("error", (error) => {
    closed = true;
    rejectAll(error);
  });
  child.on("close", (code, signal) => {
    closed = true;
    rejectAll(new Error(`mcp session closed code=${code} signal=${signal}`));
  });

  function writeMessage(message) {
    if (closed) throw new Error("mcp session is closed");
    child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  function request(method, params, { timeoutMs = requestTimeoutMs } = {}) {
    const id = nextId;
    nextId += 1;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`mcp request ${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      if (typeof timer.unref === "function") timer.unref();
      pending.set(id, { resolve, reject, timer });
      try {
        writeMessage({ jsonrpc: "2.0", id, method, params });
      } catch (error) {
        pending.delete(id);
        clearTimeout(timer);
        reject(error);
      }
    });
  }

  async function initialize() {
    const response = await request("initialize", {
      protocolVersion,
      capabilities: {},
      clientInfo: { name: clientName, version: clientVersion },
    });
    if (response.error) {
      throw new Error(`mcp initialize failed: ${JSON.stringify(response.error)}`);
    }
    writeMessage({ jsonrpc: "2.0", method: "notifications/initialized" });
    return response.result;
  }

  async function callTool(name, args = {}, options = {}) {
    calls.push({ tool: name, args: { ...args } });
    const response = await request(
      "tools/call",
      { name, arguments: args },
      options,
    );
    if (response.error) {
      throw new Error(`tools/call ${name} RPC error: ${JSON.stringify(response.error)}`);
    }
    const result = response.result ?? {};
    if (result.isError) {
      const text = extractToolResultText(result);
      throw new Error(`tools/call ${name} isError: ${text}`);
    }
    const text = extractToolResultText(result);
    return { envelope: result, text, payload: parseAppStatePayload(text || result) };
  }

  function close() {
    if (closed) return;
    closed = true;
    try {
      child.stdin?.end?.();
    } catch {
      // ignore
    }
    killProcessTree(child, { termGraceMs: 1000 });
  }

  return {
    child,
    calls,
    initialize,
    callTool,
    close,
    get closed() {
      return closed;
    },
  };
}

/** In-memory MCP session double with ordered call log (tests). */
export function createFakeMcpSession(handler) {
  const calls = [];
  let closed = false;
  let initialized = false;
  return {
    calls,
    async initialize() {
      initialized = true;
      return { protocolVersion: "2024-11-05" };
    },
    async callTool(name, args = {}) {
      if (!initialized) throw new Error("fake mcp session not initialized");
      if (closed) throw new Error("fake mcp session closed");
      calls.push({ tool: name, args: { ...args } });
      const result = await handler(name, args, calls);
      if (result && result.envelope) return result;
      if (result && result.payload) {
        return {
          envelope: { content: [{ type: "text", text: JSON.stringify(result.payload) }] },
          text: JSON.stringify(result.payload),
          payload: result.payload,
        };
      }
      const payload = result ?? {};
      return {
        envelope: { content: [{ type: "text", text: JSON.stringify(payload) }] },
        text: JSON.stringify(payload),
        payload,
      };
    },
    close() {
      closed = true;
    },
    get closed() {
      return closed;
    },
  };
}

// ---------------------------------------------------------------------------
// MCP config + agent adapters
// ---------------------------------------------------------------------------

export function buildMcpConfig({ cliPath, serverKey = MCP_SERVER_KEY, env = {} } = {}) {
  return {
    mcpServers: {
      [serverKey]: {
        type: "stdio",
        command: cliPath,
        args: ["mcp"],
        env: {
          SEMANTOUCH_VISUAL_CURSOR: "0",
          ...env,
        },
      },
    },
  };
}

export function writeMcpConfigFile(tempDir, config, fileName = "mcp-config.json") {
  const filePath = path.join(tempDir, fileName);
  writeSecureFile(filePath, `${JSON.stringify(config, null, 2)}\n`, 0o600);
  return filePath;
}

export function claudeAllowedTools(toolNames, serverKey = MCP_SERVER_KEY) {
  return toolNames.map((tool) => `mcp__${serverKey}__${tool}`).join(",");
}

export function buildClaudeSpec({
  prompt,
  cliPath,
  allowedTools,
  command = "claude",
  model,
  budgetUsd = "2.00",
  mcpConfig,
  mcpConfigPath,
  expectedTools = [],
  okToken = DEFAULT_OK_TOKEN,
} = {}) {
  const configArg =
    mcpConfigPath ||
    JSON.stringify(mcpConfig || buildMcpConfig({ cliPath }));
  const args = [
    "-p",
    "--strict-mcp-config",
    "--mcp-config",
    configArg,
    "--permission-mode",
    "bypassPermissions",
    "--allowedTools",
    allowedTools,
    "--output-format",
    "stream-json",
    "--verbose",
    "--max-budget-usd",
    String(budgetUsd),
  ];
  if (model) args.push("--model", model);
  args.push(prompt);
  return {
    agent: "claude",
    command,
    args,
    expectedTools,
    validate: (result) => {
      const hasToken = Boolean(result.stdout?.includes(okToken));
      const evidence = parseClaudeToolEvidence(result.stdout, { expectedTools });
      return {
        ok: hasToken && evidence.ok,
        reason: !hasToken
          ? `missing ok token ${okToken}`
          : evidence.ok
            ? "ok-token+tool-evidence"
            : `missing tools: ${evidence.missing.join(", ")}`,
        evidence,
      };
    },
  };
}

function collectToolNameCandidates(node, into, server = MCP_SERVER_KEY) {
  if (node == null) return;
  if (typeof node === "string") {
    const mcpMatch = node.match(new RegExp(`mcp__${server}__([A-Za-z0-9_]+)`, "g"));
    if (mcpMatch) {
      for (const m of mcpMatch) {
        const tool = m.split("__").pop();
        if (tool) into.add(tool);
      }
    }
    return;
  }
  if (Array.isArray(node)) {
    for (const item of node) collectToolNameCandidates(item, into, server);
    return;
  }
  if (typeof node !== "object") return;

  const type = node.type || node.event || node.kind;
  const name = node.name || node.tool || node.tool_name || node.toolName;
  const serverName = node.server || node.mcp_server || node.server_name;

  if (typeof name === "string") {
    if (name.startsWith(`mcp__${server}__`)) {
      into.add(name.slice(`mcp__${server}__`.length));
    } else if (
      type === "tool_use" ||
      type === "tool_result" ||
      type === "mcp_tool_call" ||
      type === "tool-call" ||
      type === "tool_call" ||
      node.tool ||
      node.tool_name
    ) {
      if (!serverName || serverName === server) into.add(name);
    }
  }

  for (const value of Object.values(node)) {
    collectToolNameCandidates(value, into, server);
  }
}

/**
 * Parse Claude stream-json / verbose transcripts for completed semantouch tool use.
 */
export function parseClaudeToolEvidence(stdout, {
  expectedTools = [],
  server = MCP_SERVER_KEY,
} = {}) {
  const seen = new Set();
  const calls = [];
  const text = String(stdout || "");

  for (const line of text.split(/\n+/).filter(Boolean)) {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      // non-JSON line may still contain mcp__semantouch__tool markers
      collectToolNameCandidates(line, seen, server);
      continue;
    }
    const before = seen.size;
    collectToolNameCandidates(event, seen, server);
    if (seen.size > before) {
      for (const tool of seen) {
        if (!calls.some((c) => c.tool === tool)) {
          calls.push({ tool, server, status: "completed" });
        }
      }
    }
  }

  // whole-stdout fallback for concatenated stream without clean newlines
  collectToolNameCandidates(text, seen, server);

  const missing = expectedTools.filter((t) => !seen.has(t));
  return {
    ok: missing.length === 0 && (expectedTools.length === 0 || seen.size > 0),
    seen: [...seen],
    missing,
    calls,
  };
}

/**
 * Parse Codex JSONL for completed mcp_tool_call items against semantouch.
 */
export function parseCodexToolEvidence(stdout, {
  expectedTools = [],
  server = MCP_SERVER_KEY,
} = {}) {
  const seen = new Set();
  const calls = [];
  for (const line of String(stdout || "")
    .split(/\n+/)
    .filter(Boolean)) {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    const item = event.item ?? event;
    const type = event.type || item.type;
    const isTool =
      type === "item.completed" ||
      type === "mcp_tool_call" ||
      item?.type === "mcp_tool_call";
    if (!isTool) continue;

    const toolCall =
      item?.type === "mcp_tool_call"
        ? item
        : event.type === "mcp_tool_call"
          ? event
          : null;
    const candidate = toolCall || item;
    if (!candidate) continue;

    const toolServer = candidate.server || candidate.mcp_server || candidate.server_name;
    const toolName = candidate.tool || candidate.tool_name || candidate.name;
    const status = candidate.status || event.status;
    if (toolServer && toolServer !== server) continue;
    if (status && status !== "completed" && status !== "success") continue;
    if (toolName) {
      const normalized = String(toolName).startsWith(`mcp__${server}__`)
        ? String(toolName).slice(`mcp__${server}__`.length)
        : toolName;
      seen.add(normalized);
      calls.push({
        tool: normalized,
        server: toolServer || server,
        status: status || "completed",
      });
    }
  }
  const missing = expectedTools.filter((t) => !seen.has(t));
  return {
    ok: missing.length === 0,
    seen: [...seen],
    missing,
    calls,
  };
}

/**
 * Generic Hermes / multi-format tool evidence parser.
 * Accepts JSONL tool markers, mcp__semantouch__* names, and {tool,name} objects.
 */
export function parseHermesToolEvidence(stdout, {
  expectedTools = [],
  server = MCP_SERVER_KEY,
} = {}) {
  const seen = new Set();
  const calls = [];
  const text = String(stdout || "");

  for (const line of text.split(/\n+/).filter(Boolean)) {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      collectToolNameCandidates(line, seen, server);
      continue;
    }
    collectToolNameCandidates(event, seen, server);
  }
  collectToolNameCandidates(text, seen, server);

  for (const tool of seen) {
    calls.push({ tool, server, status: "completed" });
  }
  const missing = expectedTools.filter((t) => !seen.has(t));
  return {
    ok: missing.length === 0 && (expectedTools.length === 0 || seen.size > 0),
    seen: [...seen],
    missing,
    calls,
  };
}

export function buildCodexSpec({
  prompt,
  cliPath,
  command = "codex",
  model,
  expectedTools = [],
  okToken = DEFAULT_OK_TOKEN,
} = {}) {
  const args = [
    "exec",
    "--ignore-user-config",
    "--skip-git-repo-check",
    "--dangerously-bypass-approvals-and-sandbox",
    "--disable",
    "image_generation",
    "--disable",
    "js_repl",
    "--json",
    "-c",
    `mcp_servers.${MCP_SERVER_KEY}.command=${JSON.stringify(cliPath)}`,
    "-c",
    `mcp_servers.${MCP_SERVER_KEY}.args=${JSON.stringify(["mcp"])}`,
  ];
  if (model) {
    args.push("-c", `model=${JSON.stringify(model)}`);
  }
  args.push(prompt);
  return {
    agent: "codex",
    command,
    args,
    expectedTools,
    validate: (result) => {
      const hasToken = Boolean(result.stdout?.includes(okToken));
      const evidence = parseCodexToolEvidence(result.stdout, { expectedTools });
      return {
        ok: hasToken && evidence.ok,
        reason: !hasToken
          ? `missing ok token ${okToken}`
          : evidence.ok
            ? "ok-token+tool-evidence"
            : `missing tools: ${evidence.missing.join(", ")}`,
        evidence,
      };
    },
  };
}

export function buildHermesSpec({
  prompt,
  command = "hermes",
  provider,
  model,
  maxTurns = "12",
  toolsets = MCP_SERVER_KEY,
  configPath,
  expectedTools = [],
  okToken = DEFAULT_OK_TOKEN,
  requireToolEvidence = true,
} = {}) {
  const args = [
    "chat",
    "--query",
    prompt,
    "--quiet",
    "--yolo",
    "--max-turns",
    String(maxTurns),
    "--toolsets",
    toolsets,
  ];
  if (provider) args.push("--provider", provider);
  if (model) args.push("--model", model);
  if (configPath) args.push("--config", configPath);
  return {
    agent: "hermes",
    command,
    args,
    expectedTools,
    validate: (result) => {
      const hasToken = Boolean(result.stdout?.includes(okToken));
      const evidence = parseHermesToolEvidence(result.stdout, { expectedTools });
      if (!requireToolEvidence) {
        return {
          ok: hasToken,
          reason: hasToken ? "ok-token" : `missing ok token ${okToken}`,
          evidence,
        };
      }
      return {
        ok: hasToken && evidence.ok,
        reason: !hasToken
          ? `missing ok token ${okToken}`
          : evidence.ok
            ? "ok-token+tool-evidence"
            : `missing tools: ${evidence.missing.join(", ")}`,
        evidence,
      };
    },
  };
}

export function buildAgentSpec(agent, context) {
  const allowedTools = claudeAllowedTools(context.expectedTools, MCP_SERVER_KEY);
  const mcpConfig = buildMcpConfig({
    cliPath: context.cliPath,
  });
  switch (agent) {
    case "claude":
      return buildClaudeSpec({
        prompt: context.prompt,
        cliPath: context.cliPath,
        allowedTools,
        command: context.agentCommands.claude,
        model: context.claudeModel,
        budgetUsd: context.claudeBudgetUsd,
        mcpConfig,
        mcpConfigPath: context.mcpConfigPath,
        expectedTools: context.expectedTools,
        okToken: context.okToken,
      });
    case "codex":
      return buildCodexSpec({
        prompt: context.prompt,
        cliPath: context.cliPath,
        command: context.agentCommands.codex,
        model: context.codexModel,
        expectedTools: context.expectedTools,
        okToken: context.okToken,
      });
    case "hermes":
      return buildHermesSpec({
        prompt: context.prompt,
        command: context.agentCommands.hermes,
        provider: context.hermesProvider,
        model: context.hermesModel,
        maxTurns: context.hermesMaxTurns,
        toolsets: context.hermesToolsets,
        configPath: context.hermesConfig || context.mcpConfigPath,
        expectedTools: context.expectedTools,
        okToken: context.okToken,
        requireToolEvidence: true,
      });
    default:
      throw new ParseError(`unsupported agent: ${agent}`);
  }
}

export function redactAgentSpec(spec) {
  return redactValue({
    agent: spec.agent,
    command: spec.command,
    args: spec.args,
  });
}

// ---------------------------------------------------------------------------
// Stress validation
// ---------------------------------------------------------------------------

/**
 * Verify a stress loop observation:
 * - revision strictly increases (or stays equal only when no mutation expected)
 * - stable element ids reappear across revisions
 * - action event fingerprints are unique
 */
export function validateStressLoop(observations) {
  const issues = [];
  if (!Array.isArray(observations) || observations.length === 0) {
    return { ok: false, issues: ["no observations"] };
  }

  let lastRevision = null;
  const actionKeys = new Set();
  const firstIds = new Map();

  for (const [index, obs] of observations.entries()) {
    if (typeof obs.revision !== "number") {
      issues.push(`loop ${index}: missing revision`);
      continue;
    }
    if (lastRevision !== null && obs.revision < lastRevision) {
      issues.push(
        `loop ${index}: revision ${obs.revision} is not monotonic (prev ${lastRevision})`,
      );
    }
    if (
      lastRevision !== null &&
      obs.expectIncrease &&
      obs.revision <= lastRevision
    ) {
      issues.push(
        `loop ${index}: expected revision increase after mutation (prev ${lastRevision}, got ${obs.revision})`,
      );
    }
    lastRevision = obs.revision;

    if (Array.isArray(obs.elementIds)) {
      for (const id of obs.elementIds) {
        if (!firstIds.has(id)) firstIds.set(id, index);
      }
      if (obs.stableIds) {
        for (const id of obs.stableIds) {
          if (!obs.elementIds.includes(id)) {
            issues.push(`loop ${index}: stable id ${id} missing from tree`);
          }
        }
      }
    }

    if (obs.actionKey) {
      if (actionKeys.has(obs.actionKey)) {
        issues.push(`loop ${index}: duplicate action event ${obs.actionKey}`);
      }
      actionKeys.add(obs.actionKey);
    }

    if (obs.duplicateEvents === true) {
      issues.push(`loop ${index}: duplicate fixture events detected`);
    }
  }

  return { ok: issues.length === 0, issues, loops: observations.length };
}

// ---------------------------------------------------------------------------
// Permission onboarding
// ---------------------------------------------------------------------------

export function detectCI(env = process.env) {
  return Boolean(
    env.CI ||
      env.GITHUB_ACTIONS ||
      env.GITLAB_CI ||
      env.BUILDKITE ||
      env.CIRCLECI ||
      env.TF_BUILD ||
      env.SEMANTOUCH_UNATTENDED === "1" ||
      env.SEMANTOUCH_UNATTENDED === "true",
  );
}

export function isInteractiveTTY(stdout = process.stdout, stdin = process.stdin) {
  return Boolean(stdout?.isTTY) && Boolean(stdin?.isTTY);
}

/**
 * Permission scenario policy:
 * - default: doctor with requestOnboarding:false (never prompts)
 * - true onboarding only with explicit allow flag + interactive TTY + not CI
 * - already granted → skip
 * - denied + no allow → report denied (skip or fail per requirePermissions)
 */
export function evaluatePermissionPolicy({
  allowPermissionPrompt = false,
  env = process.env,
  stdout = process.stdout,
  stdin = process.stdin,
} = {}) {
  const ci = detectCI(env);
  const tty = isInteractiveTTY(stdout, stdin);
  if (allowPermissionPrompt) {
    if (ci) {
      return {
        allowed: false,
        requestOnboarding: false,
        reason: "refusing --allow-permission-prompt in CI/unattended environment",
        code: "permission_prompt_refused_ci",
      };
    }
    if (!tty) {
      return {
        allowed: false,
        requestOnboarding: false,
        reason: "refusing --allow-permission-prompt without an interactive TTY",
        code: "permission_prompt_refused_non_tty",
      };
    }
    return {
      allowed: true,
      requestOnboarding: true,
      reason: "explicit allow on interactive TTY",
      code: "permission_prompt_allowed",
    };
  }
  return {
    allowed: true,
    requestOnboarding: false,
    reason: "default non-prompting doctor",
    code: "permission_noprompt",
  };
}

export function interpretDoctorResult(doctor, { requirePermissions = false } = {}) {
  const accessibility = doctor?.accessibility;
  const screenRecording = doctor?.screenRecording;
  const ready = doctor?.ready === true
    || (accessibility === "granted" && screenRecording === "granted");

  if (ready) {
    return {
      status: "skipped",
      ok: true,
      reason: "permissions already granted",
      code: "already_granted",
      accessibility,
      screenRecording,
      ready: true,
    };
  }

  const denied = accessibility === "denied" || screenRecording === "denied";
  if (denied) {
    if (requirePermissions) {
      return {
        status: "failed",
        ok: false,
        reason: "permissions denied and --require-permissions set",
        code: "permissions_required",
        accessibility,
        screenRecording,
        ready: false,
      };
    }
    return {
      status: "skipped",
      ok: true,
      reason: "permissions denied; not prompting (use --allow-permission-prompt interactively)",
      code: "permissions_denied_noprompt",
      accessibility,
      screenRecording,
      ready: false,
    };
  }

  return {
    status: "failed",
    ok: false,
    reason: "unable to interpret doctor result",
    code: "doctor_unknown",
    accessibility,
    screenRecording,
    ready: false,
  };
}

export async function pollDoctorUntil({
  callDoctor,
  predicate,
  timeoutMs = 10_000,
  intervalMs = 250,
  now = Date.now,
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
} = {}) {
  const deadline = now() + timeoutMs;
  let last = null;
  while (now() <= deadline) {
    last = await callDoctor();
    if (predicate(last)) {
      return { ok: true, doctor: last, timedOut: false };
    }
    await sleep(intervalMs);
  }
  return { ok: false, doctor: last, timedOut: true };
}

// ---------------------------------------------------------------------------
// Reporting / exit codes
// ---------------------------------------------------------------------------

export function aggregateExitCode(results) {
  if (!results || results.length === 0) return 1;
  let sawFailure = false;
  let sawSuccess = false;
  for (const r of results) {
    if (r.status === "failed" || r.ok === false) sawFailure = true;
    else if (r.status === "passed" || r.status === "skipped" || r.ok === true) {
      sawSuccess = true;
    }
  }
  if (sawFailure) return 1;
  if (sawSuccess) return 0;
  return 1;
}

export function printReport(report, { json = false, stdout = console.log, stderr = console.error } = {}) {
  if (json) {
    stdout(JSON.stringify(redactValue(report), null, 2));
    return;
  }
  const ok = report.ok ? "ok" : "failed";
  stdout(`agent-smoke: ${ok}`);
  for (const result of report.results || []) {
    const line = [
      `- ${result.agent || result.scenario || "run"}`,
      `status=${result.status}`,
      `ok=${result.ok}`,
      result.code != null ? `code=${result.code}` : null,
      result.timedOut ? "timedOut=true" : null,
      result.skipped ? `skip=${result.skipReason || result.reason || true}` : null,
    ]
      .filter(Boolean)
      .join(" ");
    stdout(line);
    if (!result.ok && result.stderrTail) {
      stderr(`  stderr: ${String(result.stderrTail).replace(/\n/g, " ").slice(0, 500)}`);
    }
  }
}

export function missingAgentResult(agent, { requireAgents = false } = {}) {
  if (requireAgents) {
    return {
      agent,
      status: "failed",
      ok: false,
      skipped: false,
      reason: `agent binary not found and --require-agents set`,
      code: "agent_required_missing",
    };
  }
  return {
    agent,
    status: "skipped",
    ok: true,
    skipped: true,
    skipReason: "agent binary not found",
    reason: "agent binary not found",
    code: "agent_missing",
  };
}

export function hashPrompt(prompt) {
  return createHash("sha256").update(String(prompt)).digest("hex").slice(0, 12);
}

/**
 * Build a dry-run plan: redacted agent specs + scenario outline. No side effects.
 */
export function buildDryRunPlan(config, scenarioPlan) {
  const specs = [];
  for (const scenario of scenarioPlan) {
    for (const agent of config.agents) {
      const ctx = {
        ...config,
        prompt: scenario.promptFor?.(agent) ?? scenario.prompt ?? "",
        expectedTools: scenario.expectedTools ?? [],
        mcpConfigPath: "<temp>/mcp-config.json",
        cliPath: config.cliPath || "<resolved-cli>",
      };
      const spec = buildAgentSpec(agent, ctx);
      specs.push({
        scenario: scenario.name,
        agent,
        expectedTools: scenario.expectedTools,
        usesFixture: Boolean(scenario.usesFixture),
        usesHost: Boolean(scenario.usesHost),
        promptHash: hashPrompt(ctx.prompt),
        spec: redactAgentSpec(spec),
      });
    }
  }
  return {
    dryRun: true,
    ok: true,
    agents: config.agents,
    scenarios: scenarioPlan.map((s) => s.name),
    timeoutMs: config.timeoutMs,
    iterations: config.iterations,
    requireAgents: config.requireAgents,
    requirePermissions: config.requirePermissions,
    allowPermissionPrompt: config.allowPermissionPrompt,
    permissionPolicy: evaluatePermissionPolicy({
      allowPermissionPrompt: config.allowPermissionPrompt,
      env: config.env,
    }),
    products: {
      host: redactText(config.hostPath || "<missing>", { max: 200 }),
      fixture: redactText(config.fixturePath || "<missing>", { max: 200 }),
      cli: redactText(config.cliPath || "<missing>", { max: 200 }),
    },
    plan: specs,
    sideEffects: {
      build: false,
      host: false,
      fixture: false,
      tcc: false,
      agents: false,
    },
  };
}

export function cleanupResources(resources = []) {
  const report = [];
  for (const resource of resources) {
    if (!resource) continue;
    if (resource.kind === "process") {
      report.push({
        kind: "process",
        label: resource.label,
        ...stopManagedProcess(resource.state),
      });
    } else if (resource.kind === "path") {
      report.push({
        kind: "path",
        ...removePathIdempotent(resource.path),
      });
    }
  }
  // second pass for idempotence proof
  for (const resource of resources) {
    if (resource?.kind === "path") {
      removePathIdempotent(resource.path);
    }
  }
  return report;
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
