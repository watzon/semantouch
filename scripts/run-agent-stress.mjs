#!/usr/bin/env node
/**
 * Bounded stress harness: stateful get/action/verify loops against the fixture.
 *
 *   node scripts/run-agent-stress.mjs --iterations=5 --dry-run --json
 */

import {
  ParseError,
  aggregateExitCode,
  loadHarnessConfig,
  printReport,
  redactText,
  redactValue,
} from "./agent-smoke-lib.mjs";
import { runScenarios } from "./agent-smoke-scenarios.mjs";

function usage() {
  return `Usage: node scripts/run-agent-stress.mjs [options]

Options:
  --iterations / --loops <n>  stress iterations 1..100 (default 5)
  --json                      machine-readable report
  --dry-run                   plan only; no build/host/fixture/agent
  --timeout-ms <n>
  --cli / --host / --fixture  binary paths
  --require-agents
  --require-permissions
  --help
`;
}

export async function main(argv = process.argv.slice(2), options = {}) {
  const env = options.env ?? process.env;
  const stdout = options.stdout ?? ((line) => console.log(line));
  const stderr = options.stderr ?? ((line) => console.error(line));
  const exit = options.exit ?? ((code) => process.exit(code));

  // Force stress scenario unless user already selected only stress-compatible ones.
  const forcedArgv = [...argv];
  if (!forcedArgv.some((a) => a === "--scenario" || a.startsWith("--scenario=") || a === "--scenarios" || a.startsWith("--scenarios="))) {
    forcedArgv.push("--scenario=stress");
  }

  let config;
  try {
    config = loadHarnessConfig(forcedArgv, env, {
      scenario: "stress",
      agents: ["claude", "codex"],
      iterations: 5,
    });
    // Ensure stress is present
    if (!config.scenarios.includes("stress")) {
      config.scenarios = ["stress"];
    }
  } catch (error) {
    if (error instanceof ParseError || error?.code === "PARSE_ERROR") {
      stderr(error.message);
      stderr(usage());
      exit(2);
      return 2;
    }
    throw error;
  }

  if (config.help) {
    stdout(usage());
    exit(0);
    return 0;
  }

  if (config.dryRun) {
    const report = {
      dryRun: true,
      ok: true,
      harness: "run-agent-stress",
      agents: [],
      scenarios: ["stress"],
      iterations: config.iterations,
      timeoutMs: config.timeoutMs,
      requireAgents: config.requireAgents,
      requirePermissions: config.requirePermissions,
      products: {
        host: redactText(config.hostPath || "<missing>", { max: 200 }),
        fixture: redactText(config.fixturePath || "<missing>", { max: 200 }),
        cli: redactText(config.cliPath || "<missing>", { max: 200 }),
      },
      plan: [
        {
          scenario: "stress",
          agent: "harness",
          usesFixture: true,
          usesHost: true,
          agents: false,
          mcpSession: "persistent-semantouch-mcp",
          initializeOnce: true,
          iterations: config.iterations,
          loop: [
            "get_app_state",
            "set_value",
            "get_app_state",
            "click",
            "get_app_state",
          ],
          targets: {
            textField: 'AXTextField (visible role)',
            pressButton: 'AXButton "Press Me"',
          },
          assertions: [
            "stable sessionId across loops",
            "strict revision increase after set_value and click",
            "stable element ids retained",
            "exactly one new textChanged token and press event per loop",
            "unique seq/action keys",
          ],
        },
      ],
      sideEffects: {
        build: false,
        host: false,
        fixture: false,
        tcc: false,
        agents: false,
      },
    };
    printReport(report, { json: config.json, stdout, stderr });
    exit(0);
    return 0;
  }

  let report;
  try {
    const ran = await runScenarios(config, { deps: options.deps });
    report = {
      harness: "run-agent-stress",
      ok: aggregateExitCode(ran.results) === 0,
      iterations: config.iterations,
      results: ran.results,
      products: redactValue(ran.products),
    };
  } catch (error) {
    report = {
      harness: "run-agent-stress",
      ok: false,
      error: String(error?.message ?? error),
      results: [{ status: "failed", ok: false, reason: String(error?.message ?? error) }],
    };
  }

  printReport(report, { json: config.json, stdout, stderr });
  const code = report.ok ? 0 : 1;
  exit(code);
  return code;
}

if (
  process.argv[1]?.endsWith("run-agent-stress.mjs")
) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
