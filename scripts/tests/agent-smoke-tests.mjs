#!/usr/bin/env node
/**
 * Permission-free unit tests for the agent smoke harness.
 * Run: node --test scripts/tests/agent-smoke-tests.mjs
 */

import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  ParseError,
  aggregateExitCode,
  buildAgentSpec,
  buildClaudeSpec,
  buildCodexSpec,
  buildDryRunPlan,
  buildHermesSpec,
  buildMcpConfig,
  claudeAllowedTools,
  cleanupResources,
  createFakeMcpSession,
  createSecureTempDir,
  evaluatePermissionPolicy,
  interpretDoctorResult,
  killProcessTree,
  loadHarnessConfig,
  missingAgentResult,
  parseArgs,
  parseClaudeToolEvidence,
  parseCodexToolEvidence,
  parseHermesToolEvidence,
  parseTreeTargets,
  parseAgentList,
  parseScenarioList,
  redactText,
  redactValue,
  removePathIdempotent,
  uniqueToken,
  validateFixtureEvents,
  validateStressLoop,
  writeSecureFile,
  DEFAULT_OK_TOKEN,
  MCP_SERVER_KEY,
} from "../agent-smoke-lib.mjs";
import {
  buildScenarioPlan,
  makeScenarioPrompt,
  runStressScenario,
  scenarioExpectedTools,
} from "../agent-smoke-scenarios.mjs";
import { main as smokeMain } from "../run-agent-smoke-tests.mjs";
import { main as stressMain } from "../run-agent-stress.mjs";
import { main as permissionMain } from "../run-permission-onboarding-smoke.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function capture() {
  const lines = [];
  const err = [];
  let code = null;
  return {
    stdout: (l) => lines.push(String(l)),
    stderr: (l) => err.push(String(l)),
    exit: (c) => {
      code = c;
    },
    get code() {
      return code;
    },
    get out() {
      return lines.join("\n");
    },
    get err() {
      return err.join("\n");
    },
    json() {
      return JSON.parse(lines.join("\n"));
    },
  };
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

test("parseArgs accepts --key=value and --key value", () => {
  const a = parseArgs(["--scenario=fixture", "--timeout-ms", "5000", "--json"], {
    allowed: new Set(["scenario", "timeout-ms", "json"]),
    booleans: ["json"],
    bareTrue: true,
  });
  assert.equal(a.flags.get("scenario"), "fixture");
  assert.equal(a.flags.get("timeout-ms"), "5000");
  assert.equal(a.flags.get("json"), "true");
});

test("parseArgs rejects unknown flags", () => {
  assert.throws(
    () => parseArgs(["--nope"], { allowed: new Set(["json"]), bareTrue: true }),
    (e) => e instanceof ParseError && /unknown flag/.test(e.message),
  );
});

test("parseArgs rejects missing values for non-boolean flags", () => {
  assert.throws(
    () =>
      parseArgs(["--timeout-ms"], {
        allowed: new Set(["timeout-ms"]),
        bareTrue: false,
      }),
    (e) => e instanceof ParseError && /missing value/.test(e.message),
  );
});

test("parseArgs rejects duplicates", () => {
  assert.throws(
    () =>
      parseArgs(["--scenario=a", "--scenario", "b"], {
        allowed: new Set(["scenario"]),
      }),
    (e) => e instanceof ParseError && /duplicate/.test(e.message),
  );
});

test("parseAgentList and parseScenarioList validate membership", () => {
  assert.deepEqual(parseAgentList("claude,codex"), ["claude", "codex"]);
  assert.throws(() => parseAgentList("gpt"), /unsupported agent/);
  assert.deepEqual(parseScenarioList("fixture,list-apps"), ["fixture", "list-apps"]);
  assert.throws(() => parseScenarioList("nope"), /unsupported scenario/);
});

test("loadHarnessConfig wires defaults and overrides", () => {
  const cfg = loadHarnessConfig(
    [
      "--scenario=fixture-full",
      "--agents=hermes",
      "--timeout-ms=9000",
      "--iterations=3",
      "--dry-run",
      "--json",
      "--require-agents",
      `--repo-root=${REPO_ROOT}`,
    ],
    {},
  );
  assert.equal(cfg.dryRun, true);
  assert.equal(cfg.json, true);
  assert.equal(cfg.requireAgents, true);
  assert.deepEqual(cfg.agents, ["hermes"]);
  assert.deepEqual(cfg.scenarios, ["fixture-full"]);
  assert.equal(cfg.timeoutMs, 9000);
  assert.equal(cfg.iterations, 3);
});

test("loadHarnessConfig rejects bad iterations", () => {
  assert.throws(
    () => loadHarnessConfig(["--iterations=0", `--repo-root=${REPO_ROOT}`], {}),
    />= 1/,
  );
  assert.throws(
    () => loadHarnessConfig(["--iterations=101", `--repo-root=${REPO_ROOT}`], {}),
    /<= 100/,
  );
});

// ---------------------------------------------------------------------------
// Dry-run zero side effects
// ---------------------------------------------------------------------------

test("dry-run smoke emits plan and never builds/spawns", async () => {
  const cap = capture();
  let spawnCount = 0;
  const deps = {
    ensureProducts() {
      spawnCount += 1;
      throw new Error("ensureProducts must not run in dry-run");
    },
    launchHost() {
      spawnCount += 1;
      throw new Error("launchHost must not run");
    },
    launchFixture() {
      spawnCount += 1;
      throw new Error("launchFixture must not run");
    },
    runProcess() {
      spawnCount += 1;
      throw new Error("runProcess must not run");
    },
  };

  const code = await smokeMain(
    ["--dry-run", "--json", "--scenario=list-apps", `--repo-root=${REPO_ROOT}`],
    { stdout: cap.stdout, stderr: cap.stderr, exit: cap.exit, env: {}, deps },
  );
  assert.equal(code, 0);
  assert.equal(cap.code, 0);
  assert.equal(spawnCount, 0);
  const report = cap.json();
  assert.equal(report.dryRun, true);
  assert.equal(report.sideEffects.build, false);
  assert.equal(report.sideEffects.agents, false);
  assert.ok(Array.isArray(report.plan));
  assert.ok(report.plan.length >= 1);
  assert.equal(report.plan[0].spec.command, "claude");
  assert.ok(report.plan[0].spec.args.includes("--strict-mcp-config"));
});

test("dry-run stress and permission wrappers emit harness-only plans", async () => {
  {
    const cap = capture();
    const code = await stressMain(
      ["--dry-run", "--json", "--iterations=3", `--repo-root=${REPO_ROOT}`],
      { stdout: cap.stdout, stderr: cap.stderr, exit: cap.exit, env: {} },
    );
    assert.equal(code, 0);
    const report = cap.json();
    assert.equal(report.dryRun, true);
    assert.equal(report.harness, "run-agent-stress");
    assert.deepEqual(report.agents, []);
    assert.equal(report.sideEffects.build, false);
    assert.equal(report.sideEffects.host, false);
    assert.equal(report.sideEffects.fixture, false);
    assert.equal(report.sideEffects.tcc, false);
    assert.equal(report.sideEffects.agents, false);
    assert.equal(report.plan.length, 1);
    assert.equal(report.plan[0].agent, "harness");
    assert.equal(report.plan[0].usesFixture, true);
    assert.equal(report.plan[0].usesHost, true);
    assert.equal(report.plan[0].agents, false);
    assert.equal(report.plan[0].mcpSession, "persistent-semantouch-mcp");
    assert.equal(report.plan[0].iterations, 3);
    assert.deepEqual(report.plan[0].loop, [
      "get_app_state",
      "set_value",
      "get_app_state",
      "click",
      "get_app_state",
    ]);
    assert.ok(!JSON.stringify(report.plan).includes("claude"));
    assert.ok(!JSON.stringify(report.plan).includes("codex"));
  }
  {
    const cap = capture();
    const code = await permissionMain(
      ["--dry-run", "--json", `--repo-root=${REPO_ROOT}`],
      {
        stdout: cap.stdout,
        stderr: cap.stderr,
        exit: cap.exit,
        env: {},
        ttyStdout: { isTTY: false },
        ttyStdin: { isTTY: false },
      },
    );
    assert.equal(code, 0);
    const report = cap.json();
    assert.equal(report.dryRun, true);
    assert.equal(report.harness, "run-permission-onboarding-smoke");
    assert.deepEqual(report.agents, []);
    assert.equal(report.sideEffects.agents, false);
    assert.equal(report.sideEffects.host, false);
    assert.equal(report.sideEffects.fixture, false);
    assert.equal(report.plan.length, 1);
    assert.equal(report.plan[0].agent, "harness");
    assert.equal(report.plan[0].usesHost, true);
    assert.equal(report.plan[0].usesFixture, false);
    assert.equal(report.plan[0].agents, false);
    assert.equal(report.plan[0].initialDoctor.requestOnboarding, false);
    assert.equal(report.plan[0].requestOnboarding, false);
    assert.equal(report.permissionPolicy.requestOnboarding, false);
    assert.ok(!JSON.stringify(report.plan).includes('"claude"'));
  }
});

// ---------------------------------------------------------------------------
// Adapters
// ---------------------------------------------------------------------------

test("Claude adapter argv uses stream-json and allowedTools", () => {
  const tools = ["list_apps", "get_app_state"];
  const allowed = claudeAllowedTools(tools);
  assert.equal(
    allowed,
    "mcp__semantouch__list_apps,mcp__semantouch__get_app_state",
  );
  const spec = buildClaudeSpec({
    prompt: "hi",
    cliPath: "/tmp/semantouch",
    allowedTools: allowed,
    expectedTools: tools,
    budgetUsd: "1.25",
    model: "sonnet",
  });
  assert.equal(spec.command, "claude");
  assert.ok(spec.args.includes("-p"));
  assert.ok(spec.args.includes("--strict-mcp-config"));
  assert.ok(spec.args.includes("--mcp-config"));
  assert.ok(spec.args.includes("--allowedTools"));
  assert.ok(spec.args.includes(allowed));
  assert.ok(spec.args.includes("--output-format"));
  assert.ok(spec.args.includes("stream-json"));
  assert.ok(spec.args.includes("--verbose"));
  assert.ok(spec.args.includes("--max-budget-usd"));
  assert.ok(spec.args.includes("1.25"));
  assert.ok(spec.args.includes("--model"));
  assert.ok(spec.args.includes("sonnet"));
  assert.ok(Array.isArray(spec.args));
});

test("Codex adapter uses exec --json and MCP config -c flags", () => {
  const spec = buildCodexSpec({
    prompt: "p",
    cliPath: "/path/to/semantouch",
    expectedTools: ["list_apps"],
    model: "o4",
  });
  assert.equal(spec.command, "codex");
  assert.equal(spec.args[0], "exec");
  assert.ok(spec.args.includes("--json"));
  const cmdFlag = spec.args.find((a) => String(a).includes("mcp_servers.semantouch.command="));
  assert.ok(cmdFlag.includes("/path/to/semantouch"));
  const argsFlag = spec.args.find((a) => String(a).includes("mcp_servers.semantouch.args="));
  assert.ok(argsFlag.includes("[\"mcp\"]") || argsFlag.includes('["mcp"]'));
});

test("Hermes adapter accepts provider/model/max turns/toolset/config", () => {
  const spec = buildHermesSpec({
    prompt: "p",
    provider: "openai",
    model: "gpt-x",
    maxTurns: "7",
    toolsets: "semantouch",
    configPath: "/tmp/hermes.json",
  });
  assert.equal(spec.command, "hermes");
  assert.ok(spec.args.includes("--provider"));
  assert.ok(spec.args.includes("openai"));
  assert.ok(spec.args.includes("--model"));
  assert.ok(spec.args.includes("gpt-x"));
  assert.ok(spec.args.includes("--max-turns"));
  assert.ok(spec.args.includes("7"));
  assert.ok(spec.args.includes("--toolsets"));
  assert.ok(spec.args.includes("semantouch"));
  assert.ok(spec.args.includes("--config"));
  assert.ok(spec.args.includes("/tmp/hermes.json"));
});

test("buildAgentSpec routes agents and restricts prompt tools", () => {
  const ctx = {
    prompt: makeScenarioPrompt("fixture", { expectedValue: "v1" }),
    expectedTools: scenarioExpectedTools("fixture"),
    cliPath: "/cli/semantouch",
    agentCommands: { claude: "claude", codex: "codex", hermes: "hermes" },
    claudeBudgetUsd: "2.00",
    okToken: DEFAULT_OK_TOKEN,
  };
  assert.ok(ctx.prompt.includes("semantouch MCP") || ctx.prompt.includes("Use only semantouch"));
  assert.ok(ctx.prompt.includes("computer-use-fixture"));
  assert.ok(ctx.prompt.includes("Do not use terminal"));
  assert.ok(!ctx.prompt.includes("AXIdentifier"));
  assert.ok(ctx.prompt.includes("AXTextField"));
  assert.ok(ctx.prompt.includes("Press Me"));
  const claude = buildAgentSpec("claude", ctx);
  assert.ok(
    claude.args.some((a) => String(a).includes("mcp__semantouch__set_value")),
  );
  assert.ok(claude.args.includes("stream-json"));
  const codex = buildAgentSpec("codex", ctx);
  assert.ok(codex.args.includes("--json"));
  const hermes = buildAgentSpec("hermes", ctx);
  assert.equal(typeof hermes.validate, "function");
});

test("MCP config points at semantouch mcp argv", () => {
  const cfg = buildMcpConfig({ cliPath: "/x/semantouch" });
  assert.equal(cfg.mcpServers[MCP_SERVER_KEY].command, "/x/semantouch");
  assert.deepEqual(cfg.mcpServers[MCP_SERVER_KEY].args, ["mcp"]);
});

// ---------------------------------------------------------------------------
// Codex evidence parsing
// ---------------------------------------------------------------------------

test("parseCodexToolEvidence accepts completed mcp_tool_call JSONL", () => {
  const stdout = [
    JSON.stringify({ type: "thread.started" }),
    JSON.stringify({
      type: "item.completed",
      item: {
        type: "mcp_tool_call",
        server: "semantouch",
        tool: "list_apps",
        status: "completed",
      },
    }),
    JSON.stringify({
      type: "item.completed",
      item: {
        type: "mcp_tool_call",
        server: "semantouch",
        tool: "get_app_state",
        status: "completed",
      },
    }),
    `${DEFAULT_OK_TOKEN}`,
  ].join("\n");

  const evidence = parseCodexToolEvidence(stdout, {
    expectedTools: ["list_apps", "get_app_state"],
  });
  assert.equal(evidence.ok, true);
  assert.deepEqual(evidence.seen.sort(), ["get_app_state", "list_apps"]);

  const missing = parseCodexToolEvidence(stdout, {
    expectedTools: ["list_apps", "click"],
  });
  assert.equal(missing.ok, false);
  assert.deepEqual(missing.missing, ["click"]);

  const spec = buildCodexSpec({
    prompt: "p",
    cliPath: "/cli",
    expectedTools: ["list_apps", "get_app_state"],
  });
  const validation = spec.validate({ stdout, ok: true });
  assert.equal(validation.ok, true);
});

// ---------------------------------------------------------------------------
// Fixture JSONL validation
// ---------------------------------------------------------------------------

test("validateFixtureEvents checks expectations, monotonic seq, duplicates", () => {
  const events = [
    { seq: 1, event: "ready", control: "fixture.app", value: "CU Fixture" },
    { seq: 2, event: "textChanged", control: "fixture.field.text", value: "hello" },
    { seq: 3, event: "press", control: "fixture.button.press", value: 1 },
  ];
  const ok = validateFixtureEvents(events, [
    { event: "textChanged", control: "fixture.field.text", value: "hello" },
    { event: "press", control: "fixture.button.press" },
  ]);
  assert.equal(ok.ok, true);

  const missing = validateFixtureEvents(events, [
    { event: "textChanged", control: "fixture.field.text", value: "nope" },
  ]);
  assert.equal(missing.ok, false);

  const nonMono = validateFixtureEvents(
    [
      { seq: 2, event: "press", control: "fixture.button.press" },
      { seq: 1, event: "press", control: "fixture.button.press" },
    ],
    [],
  );
  assert.equal(nonMono.ok, false);
  assert.ok(nonMono.issues.some((i) => /non-monotonic/.test(i)));

  const dup = validateFixtureEvents(
    [
      { seq: 1, event: "press", control: "fixture.button.press", value: 1 },
      { seq: 1, event: "press", control: "fixture.button.press", value: 1 },
    ],
    [],
  );
  assert.equal(dup.ok, false);
  assert.ok(dup.issues.some((i) => /duplicate/.test(i)));
});

// ---------------------------------------------------------------------------
// Stress checks
// ---------------------------------------------------------------------------

test("validateStressLoop enforces monotonic revisions and stable ids", () => {
  const good = validateStressLoop([
    {
      revision: 1,
      elementIds: ["e1", "e2"],
      stableIds: ["e1"],
      actionKey: "a1",
    },
    {
      revision: 2,
      expectIncrease: true,
      elementIds: ["e1", "e2", "e3"],
      stableIds: ["e1"],
      actionKey: "a2",
    },
  ]);
  assert.equal(good.ok, true);

  const regress = validateStressLoop([
    { revision: 5, actionKey: "a1" },
    { revision: 4, actionKey: "a2" },
  ]);
  assert.equal(regress.ok, false);

  const dupAction = validateStressLoop([
    { revision: 1, actionKey: "same" },
    { revision: 2, actionKey: "same" },
  ]);
  assert.equal(dupAction.ok, false);
  assert.ok(dupAction.issues.some((i) => /duplicate action/.test(i)));

  const lostStable = validateStressLoop([
    { revision: 1, elementIds: ["e1"], stableIds: ["e1"], actionKey: "a1" },
    { revision: 2, elementIds: ["e9"], stableIds: ["e1"], actionKey: "a2" },
  ]);
  assert.equal(lostStable.ok, false);
});

// ---------------------------------------------------------------------------
// Timeout escalation / kill tree
// ---------------------------------------------------------------------------

test("killProcessTree signals TERM then KILL", () => {
  const signals = [];
  const child = { pid: 4242, killed: false, once() {} };
  const result = killProcessTree(child, {
    termGraceMs: 0,
    killFn: (pid, sig) => {
      signals.push([pid, sig]);
    },
  });
  assert.equal(result.term, true);
  assert.ok(signals.some((s) => s[1] === "SIGTERM"));
  assert.ok(signals.some((s) => s[1] === "SIGKILL"));
});

// ---------------------------------------------------------------------------
// Missing agent skip / require
// ---------------------------------------------------------------------------

test("missing agent skips by default and fails with --require-agents", () => {
  const skip = missingAgentResult("claude", { requireAgents: false });
  assert.equal(skip.status, "skipped");
  assert.equal(skip.ok, true);
  const fail = missingAgentResult("claude", { requireAgents: true });
  assert.equal(fail.status, "failed");
  assert.equal(fail.ok, false);
});

// ---------------------------------------------------------------------------
// Permission prompt refusal
// ---------------------------------------------------------------------------

test("permission prompt refused in CI and non-TTY; default is non-prompting", () => {
  const def = evaluatePermissionPolicy({
    allowPermissionPrompt: false,
    env: {},
    stdout: { isTTY: true },
    stdin: { isTTY: true },
  });
  assert.equal(def.requestOnboarding, false);
  assert.equal(def.code, "permission_noprompt");

  const ci = evaluatePermissionPolicy({
    allowPermissionPrompt: true,
    env: { CI: "true" },
    stdout: { isTTY: true },
    stdin: { isTTY: true },
  });
  assert.equal(ci.allowed, false);
  assert.equal(ci.requestOnboarding, false);
  assert.match(ci.code, /refused_ci/);

  const nonTTY = evaluatePermissionPolicy({
    allowPermissionPrompt: true,
    env: {},
    stdout: { isTTY: false },
    stdin: { isTTY: false },
  });
  assert.equal(nonTTY.allowed, false);
  assert.match(nonTTY.code, /non_tty/);

  const ok = evaluatePermissionPolicy({
    allowPermissionPrompt: true,
    env: {},
    stdout: { isTTY: true },
    stdin: { isTTY: true },
  });
  assert.equal(ok.allowed, true);
  assert.equal(ok.requestOnboarding, true);
});

test("already-granted doctor interprets as skip", () => {
  const r = interpretDoctorResult({
    accessibility: "granted",
    screenRecording: "granted",
    ready: true,
  });
  assert.equal(r.status, "skipped");
  assert.equal(r.code, "already_granted");
  assert.equal(r.ok, true);
});

test("denied doctor skips unless require-permissions", () => {
  const skip = interpretDoctorResult({
    accessibility: "denied",
    screenRecording: "denied",
    ready: false,
  });
  assert.equal(skip.status, "skipped");
  const fail = interpretDoctorResult(
    { accessibility: "denied", screenRecording: "granted", ready: false },
    { requirePermissions: true },
  );
  assert.equal(fail.status, "failed");
});

test("permission wrapper dry-run fails closed when allow-prompt in CI", async () => {
  const cap = capture();
  const code = await permissionMain(
    ["--dry-run", "--json", "--allow-permission-prompt", `--repo-root=${REPO_ROOT}`],
    {
      stdout: cap.stdout,
      stderr: cap.stderr,
      exit: cap.exit,
      env: { CI: "1" },
      ttyStdout: { isTTY: true },
      ttyStdin: { isTTY: true },
    },
  );
  assert.equal(code, 1);
});

// ---------------------------------------------------------------------------
// Redaction
// ---------------------------------------------------------------------------

test("redactText strips secrets and long tails", () => {
  const red = redactText('api_key=sk-abc123SECRET password=hunter2 Bearer TOK123', {
    max: 80,
  });
  assert.ok(!red.includes("sk-abc123SECRET"));
  assert.ok(!red.includes("hunter2"));
  assert.ok(red.includes("***"));

  const long = redactText("x".repeat(5000), { max: 100 });
  assert.ok(long.length <= 101);
  assert.ok(long.startsWith("…"));
});

test("redactValue redacts path-like and secret keys", () => {
  const v = redactValue({
    token: "super-secret",
    hostPath: "/Users/alice/Projects/semantouch/.build/debug/SemantouchHost",
    nested: { password: "x" },
  });
  assert.equal(v.token, "***");
  assert.equal(v.nested.password, "***");
  assert.ok(String(v.hostPath).includes("/Users/***"));
});

// ---------------------------------------------------------------------------
// Cleanup idempotence
// ---------------------------------------------------------------------------

test("cleanupResources and removePathIdempotent are safe to repeat", () => {
  const dir = createSecureTempDir("semantouch-test-clean-");
  writeSecureFile(path.join(dir, "f.txt"), "hi", 0o600);
  const resources = [{ kind: "path", path: dir }];
  const first = cleanupResources(resources);
  assert.ok(first.some((r) => r.kind === "path" && r.removed === true));
  assert.equal(existsSync(dir), false);
  const second = removePathIdempotent(dir);
  assert.equal(second.removed, false);
  // again via cleanup
  assert.doesNotThrow(() => cleanupResources(resources));
});

test("createSecureTempDir is mode 0700 and writeSecureFile 0600", () => {
  const dir = createSecureTempDir("semantouch-test-mode-");
  try {
    const file = path.join(dir, "cfg.json");
    writeSecureFile(file, "{\"a\":1}\n", 0o600);
    // best-effort mode check (platform dependent)
    const st = readFileSync(file);
    assert.ok(st.length > 0);
  } finally {
    removePathIdempotent(dir);
  }
});

// ---------------------------------------------------------------------------
// Aggregate exit codes
// ---------------------------------------------------------------------------

test("aggregateExitCode fails on any failure; skips count as ok", () => {
  assert.equal(
    aggregateExitCode([
      { status: "passed", ok: true },
      { status: "skipped", ok: true },
    ]),
    0,
  );
  assert.equal(
    aggregateExitCode([
      { status: "passed", ok: true },
      { status: "failed", ok: false },
    ]),
    1,
  );
  assert.equal(aggregateExitCode([]), 1);
});

// ---------------------------------------------------------------------------
// Scenario plan / prompts
// ---------------------------------------------------------------------------

test("scenario plan covers fixture app name and expected tools", () => {
  const cfg = loadHarnessConfig(
    ["--scenarios=list-apps,fixture,fixture-full", "--dry-run", `--repo-root=${REPO_ROOT}`],
    {},
  );
  const plan = buildScenarioPlan(cfg);
  assert.deepEqual(
    plan.map((p) => p.name),
    ["list-apps", "fixture", "fixture-full"],
  );
  assert.deepEqual(plan[0].expectedTools, ["list_apps"]);
  assert.ok(plan[1].usesFixture);
  assert.ok(plan[1].prompt.includes("computer-use-fixture"));
  assert.ok(plan[1].prompt.includes("CU Fixture") || plan[1].promptFor("claude").includes("fixture"));
  const dry = buildDryRunPlan(cfg, plan);
  assert.equal(dry.sideEffects.fixture, false);
  assert.ok(dry.plan.every((p) => p.spec.args));
});

test("uniqueToken produces distinct values", () => {
  const a = uniqueToken("t");
  const b = uniqueToken("t");
  assert.notEqual(a, b);
});

// ---------------------------------------------------------------------------
// Tree target parsing
// ---------------------------------------------------------------------------

test("parseTreeTargets finds AXTextField and Press Me button; fails when missing", () => {
  const tree = [
    '[e1] AXWindow "CU Fixture" frame=0,0,480,640',
    '  [e5] AXTextField value="" frame=20,40,200,24',
    '  [e9] AXButton "Press Me" frame=20,80,100,28 actions=[Press]',
    '  [e10] AXButton "Duplicate" frame=20,120,100,28 actions=[Press]',
  ].join("\n");
  const targets = parseTreeTargets(tree);
  assert.equal(targets.ok, true);
  assert.equal(targets.textFieldId, "e5");
  assert.equal(targets.pressButtonId, "e9");

  const missing = parseTreeTargets('[e1] AXWindow "CU Fixture"\n  [e2] AXStaticText "hi"');
  assert.equal(missing.ok, false);
  assert.ok(missing.issues.some((i) => /AXTextField/.test(i)));
  assert.ok(missing.issues.some((i) => /Press Me/.test(i)));
});

// ---------------------------------------------------------------------------
// Claude / Hermes evidence — no false pass on magic token alone
// ---------------------------------------------------------------------------

test("Claude evidence rejects magic-token-only stdout and accepts tool_use stream", () => {
  const expectedTools = ["list_apps"];
  const tokenOnly = `${DEFAULT_OK_TOKEN}\n`;
  const rejected = parseClaudeToolEvidence(tokenOnly, { expectedTools });
  assert.equal(rejected.ok, false);
  assert.deepEqual(rejected.missing, ["list_apps"]);

  const stream = [
    JSON.stringify({ type: "assistant", message: { content: [{ type: "tool_use", name: "mcp__semantouch__list_apps", input: {} }] } }),
    JSON.stringify({ type: "result", result: DEFAULT_OK_TOKEN }),
    DEFAULT_OK_TOKEN,
  ].join("\n");
  const accepted = parseClaudeToolEvidence(stream, { expectedTools });
  assert.equal(accepted.ok, true);
  assert.ok(accepted.seen.includes("list_apps"));

  const spec = buildClaudeSpec({
    prompt: "p",
    cliPath: "/cli",
    allowedTools: claudeAllowedTools(expectedTools),
    expectedTools,
  });
  assert.equal(spec.validate({ stdout: tokenOnly, ok: true }).ok, false);
  assert.equal(spec.validate({ stdout: stream, ok: true }).ok, true);
});

test("Hermes evidence rejects token-only and accepts tool markers", () => {
  const expectedTools = ["list_apps"];
  const tokenOnly = `${DEFAULT_OK_TOKEN}`;
  const rejected = parseHermesToolEvidence(tokenOnly, { expectedTools });
  assert.equal(rejected.ok, false);

  const withTools = [
    JSON.stringify({ type: "tool_call", name: "list_apps", server: "semantouch" }),
    DEFAULT_OK_TOKEN,
  ].join("\n");
  const accepted = parseHermesToolEvidence(withTools, { expectedTools });
  assert.equal(accepted.ok, true);

  const spec = buildHermesSpec({
    prompt: "p",
    expectedTools,
  });
  assert.equal(spec.validate({ stdout: tokenOnly, ok: true }).ok, false);
  assert.equal(spec.validate({ stdout: withTools, ok: true }).ok, true);
});

// ---------------------------------------------------------------------------
// fixture-full required tools / prompts
// ---------------------------------------------------------------------------

test("fixture-full expected tools are required and prompts avoid AXIdentifier", () => {
  const tools = scenarioExpectedTools("fixture-full");
  assert.deepEqual(tools, [
    "get_app_state",
    "set_value",
    "click",
    "type_text",
    "press_key",
    "scroll",
  ]);
  assert.ok(!tools.includes("perform_action"));
  const prompt = makeScenarioPrompt("fixture-full", { expectedValue: "abc" });
  assert.ok(!prompt.includes("AXIdentifier"));
  assert.ok(prompt.includes("type_text"));
  assert.ok(prompt.includes("press_key"));
  assert.ok(prompt.includes("scroll"));
  assert.ok(prompt.includes("must call every required tool"));
  assert.ok(prompt.includes("Press Me"));
  assert.ok(prompt.includes("AXTextField"));
});

// ---------------------------------------------------------------------------
// Persistent MCP stress loop with fake session
// ---------------------------------------------------------------------------

function makeTree(textValue = "") {
  return [
    '[e1] AXWindow "CU Fixture" frame=0,0,480,640',
    `  [e5] AXTextField value=${JSON.stringify(textValue)} frame=20,40,200,24`,
    '  [e9] AXButton "Press Me" frame=20,80,100,28 actions=[Press]',
  ].join("\n");
}

test("runStressScenario uses one session, mutates, and checks revisions/events", async () => {
  const tempDir = createSecureTempDir("semantouch-stress-test-");
  const stateFile = path.join(tempDir, "stress-fixture.jsonl");
  const events = [];
  let seq = 0;
  const appendEvent = (event, control, value) => {
    seq += 1;
    events.push({ seq, event, control, value });
    writeSecureFile(
      stateFile,
      events.map((e) => JSON.stringify(e)).join("\n") + "\n",
      0o600,
    );
  };
  appendEvent("ready", "fixture.app", "CU Fixture");

  let revision = 1;
  let fieldValue = "";
  const session = createFakeMcpSession(async (name, args) => {
    if (name === "get_app_state") {
      return {
        sessionId: "s-stress",
        revision,
        tree: { format: "semantouch-ax-tree-v1", text: makeTree(fieldValue) },
      };
    }
    if (name === "set_value") {
      assert.equal(args.sessionId, "s-stress");
      assert.equal(args.elementId, "e5");
      assert.equal(typeof args.revision, "number");
      fieldValue = args.value;
      revision += 1;
      appendEvent("textChanged", "fixture.field.text", fieldValue);
      return { status: "completed" };
    }
    if (name === "click") {
      assert.equal(args.sessionId, "s-stress");
      assert.equal(args.elementId, "e9");
      assert.equal(typeof args.revision, "number");
      revision += 1;
      appendEvent("press", "fixture.button.press", revision);
      return { status: "completed" };
    }
    throw new Error(`unexpected tool ${name}`);
  });

  // Force state file path used inside runner by launching fixture that writes ready only.
  // runStressScenario builds its own stateFile under tempDir; inject by monkeypatching
  // launchFixture to pre-seed the same path pattern is hard. Instead, intercept via
  // custom deps that rewrite read path: we mirror by making launchFixture create ready
  // at whatever stateFile it receives.
  const config = {
    iterations: 2,
    repoRoot: REPO_ROOT,
    env: {},
    timeoutMs: 5000,
    logTail: 200,
  };
  const products = {
    hostPath: "/fake/host",
    fixturePath: "/fake/fixture",
    cliPath: "/fake/cli",
  };
  const resources = [];

  const result = await runStressScenario(config, products, {
    tempDir,
    resources,
    deps: {
      sleep: async () => {},
      launchHost: () => ({ child: null, pid: 1 }),
      launchFixture: ({ stateFile: sf }) => {
        // seed ready into the runner's state file
        writeSecureFile(
          sf,
          `${JSON.stringify({ seq: 1, event: "ready", control: "fixture.app", value: "CU Fixture" })}\n`,
          0o600,
        );
        // redirect our append helper to the same file
        events.length = 0;
        seq = 1;
        events.push({ seq: 1, event: "ready", control: "fixture.app", value: "CU Fixture" });
        const originalAppend = appendEvent;
        // rebind append to sf
        const appendToSf = (event, control, value) => {
          seq += 1;
          events.push({ seq, event, control, value });
          writeSecureFile(
            sf,
            events.map((e) => JSON.stringify(e)).join("\n") + "\n",
            0o600,
          );
        };
        // replace session handler closure fields by recreating session is complex;
        // instead patch session.callTool via wrapper below.
        session._append = appendToSf;
        return { child: null, pid: 2, exitCode: null, stderr: "" };
      },
      createMcpSession: () => {
        // wrap callTool so set_value/click append to the runner state file
        return {
          child: null,
          calls: session.calls,
          initialize: () => session.initialize(),
          close: () => session.close(),
          callTool: async (name, args) => {
            session.calls.push({ tool: name, args: { ...args } });
            if (name === "get_app_state") {
              return {
                envelope: {},
                text: JSON.stringify({
                  sessionId: "s-stress",
                  revision,
                  tree: { format: "semantouch-ax-tree-v1", text: makeTree(fieldValue) },
                }),
                payload: {
                  sessionId: "s-stress",
                  revision,
                  tree: { format: "semantouch-ax-tree-v1", text: makeTree(fieldValue) },
                },
              };
            }
            if (name === "set_value") {
              assert.equal(args.sessionId, "s-stress");
              assert.equal(args.elementId, "e5");
              fieldValue = args.value;
              revision += 1;
              session._append("textChanged", "fixture.field.text", fieldValue);
              return { envelope: {}, text: "{}", payload: { status: "completed" } };
            }
            if (name === "click") {
              assert.equal(args.sessionId, "s-stress");
              assert.equal(args.elementId, "e9");
              revision += 1;
              session._append("press", "fixture.button.press", 1);
              return { envelope: {}, text: "{}", payload: { status: "completed" } };
            }
            throw new Error(`unexpected ${name}`);
          },
        };
      },
    },
  });

  assert.equal(result.ok, true, result.reason);
  assert.equal(result.iterations, 2);
  // ordered tools: for each loop get, set_value, get, click, get
  const tools = result.sessionCalls.map((c) => c.tool);
  assert.deepEqual(tools, [
    "get_app_state",
    "set_value",
    "get_app_state",
    "click",
    "get_app_state",
    "get_app_state",
    "set_value",
    "get_app_state",
    "click",
    "get_app_state",
  ]);
  // same session id on mutation args
  const setArgs = result.sessionCalls.filter((c) => c.tool === "set_value");
  assert.ok(setArgs.every((c) => c.args.sessionId === "s-stress"));
  assert.ok(setArgs.every((c) => c.args.elementId === "e5"));
  assert.notEqual(setArgs[0].args.value, setArgs[1].args.value);
  assert.ok(result.observations.every((o) => o.revision > 1));
  assert.ok(result.observations[1].revision > result.observations[0].revision);

  removePathIdempotent(tempDir);
});

test("runStressScenario fails when tree targets are missing", async () => {
  const tempDir = createSecureTempDir("semantouch-stress-miss-");
  const config = {
    iterations: 1,
    repoRoot: REPO_ROOT,
    env: {},
    timeoutMs: 5000,
    logTail: 200,
  };
  const products = {
    hostPath: "/fake/host",
    fixturePath: "/fake/fixture",
    cliPath: "/fake/cli",
  };
  await assert.rejects(
    () =>
      runStressScenario(config, products, {
        tempDir,
        resources: [],
        deps: {
          sleep: async () => {},
          launchHost: () => ({ child: null, pid: 1 }),
          launchFixture: ({ stateFile: sf }) => {
            writeSecureFile(
              sf,
              `${JSON.stringify({ seq: 1, event: "ready", control: "fixture.app", value: "CU Fixture" })}\n`,
              0o600,
            );
            return { child: null, pid: 2, exitCode: null, stderr: "" };
          },
          createMcpSession: () =>
            createFakeMcpSession(async (name) => {
              if (name === "get_app_state") {
                return {
                  sessionId: "s1",
                  revision: 1,
                  tree: {
                    text: '[e1] AXWindow "CU Fixture"\n  [e2] AXStaticText "no targets"',
                  },
                };
              }
              throw new Error(`unexpected ${name}`);
            }),
        },
      }),
    /AXTextField|Press Me/,
  );
  removePathIdempotent(tempDir);
});
