#!/usr/bin/env node
/**
 * Real-agent smoke harness for Semantouch.
 *
 *   node scripts/run-agent-smoke-tests.mjs --scenario=list-apps --dry-run --json
 *   node scripts/run-agent-smoke-tests.mjs --scenario=fixture --agents=claude,codex
 *
 * Dry-run never builds, hosts, fixtures, TCC prompts, or agents.
 */

import {
  ParseError,
  aggregateExitCode,
  buildDryRunPlan,
  loadHarnessConfig,
  printReport,
  redactValue,
} from "./agent-smoke-lib.mjs";
import { buildScenarioPlan, runScenarios } from "./agent-smoke-scenarios.mjs";

function usage() {
  return `Usage: node scripts/run-agent-smoke-tests.mjs [options]

Options:
  --scenario <name>          list-apps|fixture|fixture-full|stress|permission-onboarding
  --scenarios <a,b>          comma-separated scenarios
  --agents <a,b>             claude,codex,hermes (default: claude,codex)
  --json                     machine-readable report on stdout
  --dry-run                  emit redacted plan only; no build/host/fixture/TCC/agent
  --timeout-ms <n>           per-agent timeout (default 120000)
  --require-agents           fail when an agent binary is missing (default: skip)
  --require-permissions      fail when TCC grants are missing
  --allow-permission-prompt  allow doctor requestOnboarding:true (interactive TTY only)
  --cli / --command <path>   semantouch CLI path
  --host <path>              SemantouchHost path
  --fixture <path>           computer-use-fixture path
  --iterations / --loops <n> stress iterations 1..100
  --help
`;
}

export async function main(argv = process.argv.slice(2), options = {}) {
  const env = options.env ?? process.env;
  const stdout = options.stdout ?? ((line) => console.log(line));
  const stderr = options.stderr ?? ((line) => console.error(line));
  const exit = options.exit ?? ((code) => process.exit(code));

  let config;
  try {
    config = loadHarnessConfig(argv, env, {
      scenario: "list-apps",
      agents: ["claude", "codex"],
    });
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

  const scenarioPlan = buildScenarioPlan(config);

  if (config.dryRun) {
    const plan = buildDryRunPlan(config, scenarioPlan);
    const report = {
      ...plan,
      harness: "run-agent-smoke-tests",
    };
    printReport(report, { json: config.json, stdout, stderr });
    exit(0);
    return 0;
  }

  let report;
  try {
    const ran = await runScenarios(config, {
      deps: options.deps,
    });
    report = {
      harness: "run-agent-smoke-tests",
      ok: ran.ok && aggregateExitCode(ran.results) === 0,
      agents: config.agents,
      scenarios: config.scenarios,
      results: ran.results,
      products: redactValue(ran.products),
    };
    report.ok = aggregateExitCode(report.results) === 0;
  } catch (error) {
    report = {
      harness: "run-agent-smoke-tests",
      ok: false,
      error: String(error?.message ?? error),
      results: [
        {
          status: "failed",
          ok: false,
          reason: String(error?.message ?? error),
        },
      ],
    };
  }

  printReport(report, { json: config.json, stdout, stderr });
  const code = report.ok ? 0 : 1;
  exit(code);
  return code;
}

const isDirect =
  import.meta.url === `file://${process.argv[1]}` ||
  process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, "/"));

if (isDirect || process.argv[1]?.endsWith("run-agent-smoke-tests.mjs")) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
