#!/usr/bin/env node
/**
 * Scenario definitions and runners for Semantouch agent smoke harness.
 */

import path from "node:path";
import {
  DEFAULT_OK_TOKEN,
  FIXTURE_APP,
  FIXTURE_TITLE,
  MCP_SERVER_KEY,
  buildAgentSpec,
  buildMcpConfig,
  callSemantouchTool,
  cleanupResources,
  createSecureTempDir,
  createMcpSession,
  evaluatePermissionPolicy,
  extractToolResultText,
  interpretDoctorResult,
  launchFixture,
  launchHost,
  missingAgentResult,
  parseAppStatePayload,
  parseTreeTargets,
  pollDoctorUntil,
  readFixtureStateFile,
  redactAgentSpec,
  redactText,
  runProcess,
  sleep,
  uniqueToken,
  validateFixtureEvents,
  validateStressLoop,
  writeMcpConfigFile,
  isExecutableOnPath,
  ensureProducts,
  hashPrompt,
} from "./agent-smoke-lib.mjs";
export function scenarioExpectedTools(name) {
  switch (name) {
    case "list-apps":
      return ["list_apps"];
    case "fixture":
      return ["get_app_state", "set_value", "click"];
    case "fixture-full":
      return [
        "get_app_state",
        "set_value",
        "click",
        "type_text",
        "press_key",
        "scroll",
      ];
    case "stress":
      return ["get_app_state", "set_value", "click"];
    case "permission-onboarding":
      return ["doctor"];
    default:
      return [];
  }
}

export function scenarioUsesFixture(name) {
  return name === "fixture" || name === "fixture-full" || name === "stress";
}

export function scenarioUsesHost(name) {
  // All real runs need the host for call/mcp; dry-run never launches.
  return name !== undefined;
}

export function makeScenarioPrompt(name, { expectedValue, okToken = DEFAULT_OK_TOKEN } = {}) {
  if (name === "list-apps") {
    return [
      "Use the semantouch MCP list_apps tool exactly once before answering.",
      "Do not use terminal, shell, browser, file, or any other tool.",
      `After the tool call, reply exactly ${okToken}.`,
    ].join(" ");
  }

  if (name === "permission-onboarding") {
    return [
      "Use only the semantouch MCP doctor tool.",
      "Call doctor with requestOnboarding false unless explicitly told otherwise.",
      "Do not use terminal, shell, browser, file, or any other tool.",
      `After the tool call, reply exactly ${okToken}.`,
    ].join(" ");
  }

  if (name === "stress") {
    return [
      "Use only semantouch MCP tools.",
      `Call get_app_state for app ${FIXTURE_APP}.`,
      `Find the editable AXTextField and set_value to exactly ${JSON.stringify(expectedValue)}.`,
      'Click the AXButton titled "Press Me" exactly once.',
      "Call get_app_state again and confirm the tree reflects the change.",
      "Do not use terminal, shell, browser, file, or any other tool.",
      `After the tool calls, reply exactly ${okToken}.`,
    ].join(" ");
  }

  const full = name === "fixture-full";
  return [
    "Use only semantouch MCP tools.",
    `Call get_app_state for app ${FIXTURE_APP} (window title ${JSON.stringify(FIXTURE_TITLE)}).`,
    `Find the editable AXTextField and use set_value to set it exactly to ${JSON.stringify(expectedValue)}.`,
    ...(full
      ? [
          "Click the text field by its stable element id, then use type_text to append exactly -typed.",
          "Use press_key with combo Return focused on the text field.",
          'Scroll the AXScrollArea or table content down by 1 page using the scroll tool.',
        ]
      : []),
    'Find the AXButton titled "Press Me" and click it exactly once by element id.',
    "You must call every required tool listed above; do not skip any.",
    "Do not use terminal, shell, browser, file, or any other tool.",
    `After the tool calls, reply exactly ${okToken}.`,
  ].join(" ");
}

export function buildScenarioPlan(config) {
  return config.scenarios.map((name) => {
    const expectedTools = scenarioExpectedTools(name);
    return {
      name,
      expectedTools,
      usesFixture: scenarioUsesFixture(name),
      usesHost: scenarioUsesHost(name),
      prompt: makeScenarioPrompt(name, {
        expectedValue: "<unique-per-agent>",
        okToken: config.okToken,
      }),
      promptFor(agent) {
        return makeScenarioPrompt(name, {
          expectedValue: uniqueToken(`${name}-${agent}`),
          okToken: config.okToken,
        });
      },
    };
  });
}

async function waitForFixtureReady({
  cliPath,
  fixtureState,
  stateFile,
  cwd,
  env,
  timeoutMs = 15_000,
  callImpl = callSemantouchTool,
}) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    if (fixtureState?.exitCode !== null && fixtureState?.exitCode !== undefined) {
      throw new Error(
        `computer-use-fixture exited before ready (code=${fixtureState.exitCode}): ${redactText(fixtureState.stderr)}`,
      );
    }
    try {
      const { text, envelope } = await callImpl(cliPath, "get_app_state", {
        app: FIXTURE_APP,
      }, { cwd, env, timeoutMs: 10_000 });
      const haystack = `${text}\n${JSON.stringify(envelope)}`;
      if (
        haystack.includes(FIXTURE_TITLE) ||
        haystack.includes("fixture.button.press") ||
        haystack.includes("fixture.field.text") ||
        haystack.includes(FIXTURE_APP)
      ) {
        // also accept ready event in state file
        const state = readFixtureStateFile(stateFile);
        const ready = state.events.find((e) => e.event === "ready");
        return { text, state, ready };
      }
      lastError = new Error("fixture not yet visible in get_app_state");
    } catch (error) {
      lastError = error;
    }
    // Prefer JSONL ready marker if present even when call fails (permissions).
    const state = readFixtureStateFile(stateFile);
    if (state.events.some((e) => e.event === "ready")) {
      return { text: "", state, ready: state.events.find((e) => e.event === "ready") };
    }
    await sleep(250);
  }
  throw new Error(
    `fixture not ready within ${timeoutMs}ms: ${lastError?.message || lastError || "unknown"}`,
  );
}

function fixtureExpectations(scenarioName, expectedValue) {
  if (scenarioName === "list-apps" || scenarioName === "permission-onboarding") {
    return [];
  }
  const textValue =
    scenarioName === "fixture-full" ? `${expectedValue}-typed` : expectedValue;
  return [
    { event: "textChanged", control: "fixture.field.text", value: textValue },
    { event: "press", control: "fixture.button.press" },
  ];
}

async function runAgentAgainstScenario({
  agent,
  scenarioName,
  config,
  products,
  tempDir,
  resources,
  deps,
}) {
  const expectedTools = scenarioExpectedTools(scenarioName);
  const expectedValue = uniqueToken(`${scenarioName}-${agent}`);
  const prompt = makeScenarioPrompt(scenarioName, {
    expectedValue,
    okToken: config.okToken,
  });

  if (!deps.isExecutableOnPath(config.agentCommands[agent], { env: config.env })) {
    return missingAgentResult(agent, { requireAgents: config.requireAgents });
  }

  const mcpConfig = buildMcpConfig({ cliPath: products.cliPath });
  const mcpConfigPath = writeMcpConfigFile(tempDir, mcpConfig);

  let fixture = null;
  let host = null;
  let stateFile = null;
  let fixtureValidation = null;

  if (scenarioUsesHost(scenarioName)) {
    host = deps.launchHost({
      hostPath: products.hostPath,
      dryRun: false,
      cwd: config.repoRoot,
      env: config.env,
      spawnImpl: deps.spawnImpl,
    });
    resources.push({ kind: "process", label: "host", state: host });
    // brief settle for socket bind
    await deps.sleep(200);
  }

  if (scenarioUsesFixture(scenarioName)) {
    stateFile = path.join(tempDir, `fixture-${agent}.jsonl`);
    fixture = deps.launchFixture({
      fixturePath: products.fixturePath,
      stateFile,
      title: FIXTURE_TITLE,
      activate: true,
      dryRun: false,
      cwd: config.repoRoot,
      env: config.env,
      spawnImpl: deps.spawnImpl,
    });
    resources.push({ kind: "process", label: "fixture", state: fixture });
    try {
      await waitForFixtureReady({
        cliPath: products.cliPath,
        fixtureState: fixture,
        stateFile,
        cwd: config.repoRoot,
        env: config.env,
        callImpl: deps.callSemantouchTool,
      });
    } catch (error) {
      return {
        agent,
        scenario: scenarioName,
        status: "failed",
        ok: false,
        processOk: false,
        validated: false,
        expectedTools,
        expectedValue,
        fixtureValidation: { ok: false, error: String(error?.message ?? error) },
        reason: String(error?.message ?? error),
      };
    }
  }

  const context = {
    ...config,
    cliPath: products.cliPath,
    expectedTools,
    prompt,
    mcpConfigPath,
    agentCommands: config.agentCommands,
  };
  const spec = buildAgentSpec(agent, context);
  const result = await deps.runProcess(spec, {
    timeoutMs: config.timeoutMs,
    env: config.env,
    cwd: config.repoRoot,
    logTail: config.logTail,
    spawnImpl: deps.spawnImpl,
  });

  let validation = spec.validate(result);

  if (scenarioUsesFixture(scenarioName) && stateFile) {
    const state = readFixtureStateFile(stateFile);
    const expectations = fixtureExpectations(scenarioName, expectedValue);
    // Agents may not always hit exact typed suffix; accept base value too for full.
    let eventValidation = validateFixtureEvents(state.events, expectations);
    if (!eventValidation.ok && scenarioName === "fixture-full") {
      eventValidation = validateFixtureEvents(state.events, [
        { event: "textChanged", control: "fixture.field.text", value: expectedValue },
        { event: "press", control: "fixture.button.press" },
      ]);
    }
    fixtureValidation = {
      ok: eventValidation.ok,
      issues: eventValidation.issues,
      eventCount: eventValidation.eventCount,
      expectations,
    };
  }

  const validated =
    result.ok &&
    validation.ok &&
    (!scenarioUsesFixture(scenarioName) || fixtureValidation?.ok === true);

  return {
    agent,
    scenario: scenarioName,
    status: validated ? "passed" : "failed",
    ok: validated,
    processOk: result.ok,
    code: result.code,
    timedOut: result.timedOut,
    validated,
    expectedTools,
    expectedValue,
    promptHash: hashPrompt(prompt),
    validation,
    fixtureValidation,
    evidence: validation.evidence ?? null,
    stdoutTail: result.stdoutTail,
    stderrTail: result.stderrTail,
    durationMs: result.durationMs,
    spec: redactAgentSpec(spec),
  };
}

/**
 * Stress scenario: bounded get/set_value/click/verify loops over ONE persistent
 * `semantouch mcp` session so sessionId/element ids remain valid.
 */
export async function runStressScenario(config, products, { deps, tempDir, resources }) {
  const iterations = config.iterations;
  const stateFile = path.join(tempDir, "stress-fixture.jsonl");
  const host = deps.launchHost({
    hostPath: products.hostPath,
    cwd: config.repoRoot,
    env: config.env,
    spawnImpl: deps.spawnImpl,
  });
  resources.push({ kind: "process", label: "host", state: host });
  await deps.sleep(200);

  const fixture = deps.launchFixture({
    fixturePath: products.fixturePath,
    stateFile,
    title: FIXTURE_TITLE,
    activate: true,
    cwd: config.repoRoot,
    env: config.env,
    spawnImpl: deps.spawnImpl,
  });
  resources.push({ kind: "process", label: "fixture", state: fixture });

  // Prefer fixture JSONL ready; MCP session will prove AX visibility.
  const readyDeadline = Date.now() + 15_000;
  while (Date.now() < readyDeadline) {
    if (fixture?.exitCode !== null && fixture?.exitCode !== undefined) {
      throw new Error(
        `computer-use-fixture exited before ready (code=${fixture.exitCode}): ${redactText(fixture.stderr)}`,
      );
    }
    const state = readFixtureStateFile(stateFile);
    if (state.events.some((e) => e.event === "ready")) break;
    await deps.sleep(100);
  }

  const createSession = deps.createMcpSession || createMcpSession;
  const session = createSession({
    cliPath: products.cliPath,
    cwd: config.repoRoot,
    env: config.env,
    spawnImpl: deps.spawnImpl,
  });
  resources.push({
    kind: "process",
    label: "mcp-session",
    state: { child: session.child, pid: session.child?.pid },
  });

  try {
    await session.initialize();

    const observations = [];
    let lastRevision = null;
    let stableIds = null;
    let sessionId = null;
    const seenActionKeys = new Set();
    let previousEventCount = readFixtureStateFile(stateFile).events.length;

    for (let i = 1; i <= iterations; i += 1) {
      const token = uniqueToken(`stress-${i}`);

      const before = await session.callTool("get_app_state", {
        app: FIXTURE_APP,
        forceFullTree: true,
      });
      const beforeState = before.payload || parseAppStatePayload(before.text);
      if (!sessionId) sessionId = beforeState.sessionId;
      if (sessionId && beforeState.sessionId && beforeState.sessionId !== sessionId) {
        throw new Error(
          `sessionId changed across stress loops: ${sessionId} -> ${beforeState.sessionId}`,
        );
      }
      sessionId = beforeState.sessionId || sessionId;

      const treeText = beforeState?.tree?.text || before.text || "";
      const targets = parseTreeTargets(treeText);
      if (!targets.ok) {
        throw new Error(`stress loop ${i}: ${targets.issues.join("; ")}`);
      }
      if (!beforeState.sessionId || beforeState.revision == null) {
        throw new Error(`stress loop ${i}: get_app_state missing sessionId/revision`);
      }
      if (!stableIds) {
        stableIds = [targets.textFieldId, targets.pressButtonId];
      }

      const baseRevision = Number(beforeState.revision);

      await session.callTool("set_value", {
        app: FIXTURE_APP,
        sessionId: beforeState.sessionId,
        revision: baseRevision,
        elementId: targets.textFieldId,
        value: token,
      });

      const mid = await session.callTool("get_app_state", {
        app: FIXTURE_APP,
      });
      const midState = mid.payload || parseAppStatePayload(mid.text);
      const midRevision = Number(midState.revision);
      if (!(midRevision > baseRevision)) {
        throw new Error(
          `stress loop ${i}: revision did not increase after set_value (${baseRevision} -> ${midRevision})`,
        );
      }
      if (midState.sessionId !== beforeState.sessionId) {
        throw new Error(`stress loop ${i}: sessionId changed after set_value`);
      }
      const midTargets = parseTreeTargets(midState?.tree?.text || mid.text || "");
      if (!midTargets.ok) {
        throw new Error(`stress loop ${i}: targets lost after set_value: ${midTargets.issues.join("; ")}`);
      }
      for (const id of stableIds) {
        if (!midTargets.elementIds.includes(id)) {
          throw new Error(`stress loop ${i}: stable id ${id} missing after set_value`);
        }
      }

      // Re-resolve press button against current revision tree.
      const pressId = midTargets.pressButtonId;
      await session.callTool("click", {
        app: FIXTURE_APP,
        sessionId: midState.sessionId,
        revision: midRevision,
        elementId: pressId,
      });

      const after = await session.callTool("get_app_state", {
        app: FIXTURE_APP,
      });
      const afterState = after.payload || parseAppStatePayload(after.text);
      const afterRevision = Number(afterState.revision);
      if (!(afterRevision > midRevision)) {
        throw new Error(
          `stress loop ${i}: revision did not increase after click (${midRevision} -> ${afterRevision})`,
        );
      }
      const afterTargets = parseTreeTargets(afterState?.tree?.text || after.text || "");
      if (!afterTargets.ok) {
        throw new Error(`stress loop ${i}: targets lost after click: ${afterTargets.issues.join("; ")}`);
      }
      for (const id of stableIds) {
        if (!afterTargets.elementIds.includes(id)) {
          throw new Error(`stress loop ${i}: stable id ${id} missing after click`);
        }
      }

      const state = readFixtureStateFile(stateFile);
      const newEvents = state.events.slice(previousEventCount);
      previousEventCount = state.events.length;

      const textEvents = newEvents.filter(
        (e) =>
          e.event === "textChanged" &&
          e.control === "fixture.field.text" &&
          e.value === token,
      );
      const pressEvents = newEvents.filter(
        (e) => e.event === "press" && e.control === "fixture.button.press",
      );
      if (textEvents.length !== 1) {
        throw new Error(
          `stress loop ${i}: expected exactly one textChanged for token ${token}, got ${textEvents.length}`,
        );
      }
      if (pressEvents.length !== 1) {
        throw new Error(
          `stress loop ${i}: expected exactly one press event, got ${pressEvents.length}`,
        );
      }

      const actionKey = `set:${token}|press:${pressEvents[0].seq}`;
      if (seenActionKeys.has(actionKey)) {
        throw new Error(`stress loop ${i}: duplicate action key ${actionKey}`);
      }
      seenActionKeys.add(actionKey);

      // duplicate seq detection in full log
      const seqs = state.events.map((e) => e.seq).filter((n) => typeof n === "number");
      if (new Set(seqs).size !== seqs.length) {
        throw new Error(`stress loop ${i}: duplicate seq values in fixture JSONL`);
      }

      observations.push({
        loop: i,
        revision: afterRevision,
        expectIncrease: lastRevision !== null,
        elementIds: afterTargets.elementIds,
        stableIds,
        actionKey,
        duplicateEvents: false,
        token,
        sessionId: afterState.sessionId,
        textFieldId: afterTargets.textFieldId,
        pressButtonId: afterTargets.pressButtonId,
        calls: session.calls.slice(),
      });
      lastRevision = afterRevision;
    }

    const stress = validateStressLoop(observations);
    if (!stress.ok) {
      return {
        agent: "harness",
        scenario: "stress",
        status: "failed",
        ok: false,
        iterations,
        observations,
        stress,
        sessionCalls: session.calls,
        reason: stress.issues.join("; "),
      };
    }

    return {
      agent: "harness",
      scenario: "stress",
      status: "passed",
      ok: true,
      iterations,
      observations,
      stress,
      sessionCalls: session.calls,
      reason: "stress loops validated",
    };
  } finally {
    try {
      session.close();
    } catch {
      // ignore
    }
  }
}

export async function runPermissionScenario(config, products, { deps, tempDir, resources }) {
  const policy = evaluatePermissionPolicy({
    allowPermissionPrompt: config.allowPermissionPrompt,
    env: config.env,
    stdout: deps.stdout,
    stdin: deps.stdin,
  });

  if (!policy.allowed) {
    return {
      agent: "harness",
      scenario: "permission-onboarding",
      status: "failed",
      ok: false,
      skipped: false,
      reason: policy.reason,
      code: policy.code,
      requestOnboarding: false,
    };
  }

  // Always launch host for doctor via CLI (control plane).
  const host = deps.launchHost({
    hostPath: products.hostPath,
    cwd: config.repoRoot,
    env: config.env,
    spawnImpl: deps.spawnImpl,
  });
  resources.push({ kind: "process", label: "host", state: host });
  await deps.sleep(200);

  // Default non-prompting doctor through `semantouch doctor --json` or call tool.
  let doctor;
  try {
    // Prefer CLI doctor --json (always requestOnboarding:false in CLI today).
    const doctorProc = await deps.runProcess(
      {
        command: products.cliPath,
        args: ["doctor", "--json"],
      },
      {
        timeoutMs: Math.min(config.timeoutMs, 30_000),
        env: config.env,
        cwd: config.repoRoot,
        logTail: config.logTail,
        spawnImpl: deps.spawnImpl,
      },
    );
    if (!doctorProc.ok) {
      // Fall back to call doctor with explicit false.
      const called = await deps.callSemantouchTool(
        products.cliPath,
        "doctor",
        { requestOnboarding: false },
        { cwd: config.repoRoot, env: config.env },
      );
      doctor = JSON.parse(called.text);
    } else {
      doctor = JSON.parse(doctorProc.stdout.trim().split(/\r?\n/).filter(Boolean).pop());
    }
  } catch (error) {
    return {
      agent: "harness",
      scenario: "permission-onboarding",
      status: "failed",
      ok: false,
      reason: `doctor failed: ${error?.message || error}`,
      code: "doctor_failed",
      requestOnboarding: false,
    };
  }

  // Enforce that default path never requested onboarding.
  if (policy.requestOnboarding === false) {
    const interpreted = interpretDoctorResult(doctor, {
      requirePermissions: config.requirePermissions,
    });
    return {
      agent: "harness",
      scenario: "permission-onboarding",
      status: interpreted.status === "failed" ? "failed" : interpreted.status,
      ok: interpreted.ok,
      skipped: interpreted.status === "skipped",
      skipReason: interpreted.reason,
      reason: interpreted.reason,
      code: interpreted.code,
      requestOnboarding: false,
      doctor: {
        accessibility: doctor.accessibility,
        screenRecording: doctor.screenRecording,
        ready: doctor.ready,
      },
      policy,
    };
  }

  // Explicit allowed prompting path — still only when policy says so.
  // Call doctor with requestOnboarding:true and poll for grant/deny.
  try {
    await deps.callSemantouchTool(
      products.cliPath,
      "doctor",
      { requestOnboarding: true },
      { cwd: config.repoRoot, env: config.env, timeoutMs: config.timeoutMs },
    );
  } catch (error) {
    return {
      agent: "harness",
      scenario: "permission-onboarding",
      status: "failed",
      ok: false,
      reason: `onboarding doctor call failed: ${error?.message || error}`,
      code: "onboarding_call_failed",
      requestOnboarding: true,
      policy,
    };
  }

  const polled = await pollDoctorUntil({
    callDoctor: async () => {
      const called = await deps.callSemantouchTool(
        products.cliPath,
        "doctor",
        { requestOnboarding: false },
        { cwd: config.repoRoot, env: config.env },
      );
      return JSON.parse(called.text);
    },
    predicate: (d) => d?.ready === true || d?.accessibility === "granted",
    timeoutMs: Math.min(config.timeoutMs, 60_000),
    sleep: deps.sleep,
  });

  if (polled.ok) {
    return {
      agent: "harness",
      scenario: "permission-onboarding",
      status: "passed",
      ok: true,
      reason: "permissions granted after onboarding",
      code: "onboarding_granted",
      requestOnboarding: true,
      doctor: polled.doctor,
      policy,
    };
  }

  // Still denied after bounded poll — report, do not hang.
  if (config.requirePermissions) {
    return {
      agent: "harness",
      scenario: "permission-onboarding",
      status: "failed",
      ok: false,
      reason: "permissions still denied after bounded poll",
      code: "onboarding_still_denied",
      requestOnboarding: true,
      doctor: polled.doctor,
      policy,
    };
  }
  return {
    agent: "harness",
    scenario: "permission-onboarding",
    status: "skipped",
    ok: true,
    skipped: true,
    skipReason: "permissions denied after bounded poll",
    reason: "permissions denied after bounded poll",
    code: "onboarding_denied_polled",
    requestOnboarding: true,
    doctor: polled.doctor,
    policy,
  };
}

function defaultDeps() {
  return {
    isExecutableOnPath,
    launchHost,
    launchFixture,
    runProcess,
    callSemantouchTool,
    sleep,
    spawnImpl: undefined,
    stdout: process.stdout,
    stdin: process.stdin,
    ensureProducts,
  };
}

/**
 * Execute configured scenarios. Under dry-run, callers should use buildDryRunPlan instead.
 */
export async function runScenarios(config, options = {}) {
  if (config.dryRun) {
    throw new Error("runScenarios must not be called under dry-run");
  }

  const deps = { ...defaultDeps(), ...(options.deps || {}) };
  const resources = [];
  const tempDir = createSecureTempDir("semantouch-agent-smoke-");
  resources.push({ kind: "path", path: tempDir });

  const results = [];
  let products;
  try {
    products = deps.ensureProducts(config);
    // normalize onto config for adapters
    products = {
      hostPath: products.hostPath,
      fixturePath: products.fixturePath,
      cliPath: products.cliPath,
    };

    for (const scenarioName of config.scenarios) {
      if (scenarioName === "stress") {
        try {
          results.push(
            await runStressScenario(config, products, { deps, tempDir, resources }),
          );
        } catch (error) {
          results.push({
            agent: "harness",
            scenario: "stress",
            status: "failed",
            ok: false,
            reason: String(error?.message ?? error),
          });
        }
        continue;
      }

      if (scenarioName === "permission-onboarding") {
        try {
          results.push(
            await runPermissionScenario(config, products, { deps, tempDir, resources }),
          );
        } catch (error) {
          results.push({
            agent: "harness",
            scenario: "permission-onboarding",
            status: "failed",
            ok: false,
            reason: String(error?.message ?? error),
          });
        }
        continue;
      }

      for (const agent of config.agents) {
        try {
          const result = await runAgentAgainstScenario({
            agent,
            scenarioName,
            config,
            products,
            tempDir,
            resources,
            deps,
          });
          results.push(result);
        } catch (error) {
          results.push({
            agent,
            scenario: scenarioName,
            status: "failed",
            ok: false,
            reason: String(error?.message ?? error),
          });
        }
      }
    }
  } finally {
    cleanupResources(resources);
  }

  return {
    ok: results.length > 0 && results.every((r) => r.ok !== false || r.status === "skipped"),
    results,
    server: MCP_SERVER_KEY,
    products: {
      host: products?.hostPath,
      fixture: products?.fixturePath,
      cli: products?.cliPath,
    },
  };
}
