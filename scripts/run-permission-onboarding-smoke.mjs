#!/usr/bin/env node
/**
 * Permission onboarding smoke.
 *
 * Default: non-prompting doctor (requestOnboarding:false).
 * True onboarding only with --allow-permission-prompt on an interactive TTY
 * outside CI/unattended environments.
 *
 *   node scripts/run-permission-onboarding-smoke.mjs --dry-run --json
 */

import {
  ParseError,
  aggregateExitCode,
  evaluatePermissionPolicy,
  loadHarnessConfig,
  printReport,
  redactText,
  redactValue,
} from "./agent-smoke-lib.mjs";
import { runScenarios } from "./agent-smoke-scenarios.mjs";

function usage() {
  return `Usage: node scripts/run-permission-onboarding-smoke.mjs [options]

Options:
  --json
  --dry-run
  --allow-permission-prompt  interactive TTY only; refused in CI
  --require-permissions      fail when grants are missing
  --timeout-ms <n>
  --cli / --host             binary paths
  --help
`;
}

export async function main(argv = process.argv.slice(2), options = {}) {
  const env = options.env ?? process.env;
  const stdout = options.stdout ?? ((line) => console.log(line));
  const stderr = options.stderr ?? ((line) => console.error(line));
  const exit = options.exit ?? ((code) => process.exit(code));

  const forcedArgv = [...argv];
  if (
    !forcedArgv.some(
      (a) =>
        a === "--scenario" ||
        a.startsWith("--scenario=") ||
        a === "--scenarios" ||
        a.startsWith("--scenarios="),
    )
  ) {
    forcedArgv.push("--scenario=permission-onboarding");
  }

  let config;
  try {
    config = loadHarnessConfig(forcedArgv, env, {
      scenario: "permission-onboarding",
      agents: ["claude", "codex"],
    });
    if (!config.scenarios.includes("permission-onboarding")) {
      config.scenarios = ["permission-onboarding"];
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

  const policy = evaluatePermissionPolicy({
    allowPermissionPrompt: config.allowPermissionPrompt,
    env: config.env,
    stdout: options.ttyStdout ?? process.stdout,
    stdin: options.ttyStdin ?? process.stdin,
  });

  if (config.dryRun) {
    const planEntry = {
      scenario: "permission-onboarding",
      agent: "harness",
      usesFixture: false,
      usesHost: true,
      agents: false,
      initialDoctor: {
        requestOnboarding: false,
      },
      requestOnboarding: policy.requestOnboarding,
      permissionPolicy: policy,
      flow: policy.requestOnboarding
        ? [
            "doctor requestOnboarding:false (baseline)",
            "doctor requestOnboarding:true (explicit allow)",
            "bounded status poll with requestOnboarding:false",
          ]
        : [
            "doctor requestOnboarding:false only",
            "skip when already granted",
            "skip or fail-closed when denied (per --require-permissions)",
          ],
    };
    const base = {
      dryRun: true,
      harness: "run-permission-onboarding-smoke",
      agents: [],
      scenarios: ["permission-onboarding"],
      timeoutMs: config.timeoutMs,
      requireAgents: config.requireAgents,
      requirePermissions: config.requirePermissions,
      allowPermissionPrompt: config.allowPermissionPrompt,
      permissionPolicy: policy,
      products: {
        host: redactText(config.hostPath || "<missing>", { max: 200 }),
        fixture: redactText(config.fixturePath || "<missing>", { max: 200 }),
        cli: redactText(config.cliPath || "<missing>", { max: 200 }),
      },
      plan: [planEntry],
      sideEffects: {
        build: false,
        host: false,
        fixture: false,
        tcc: false,
        agents: false,
      },
    };

    if (config.allowPermissionPrompt && !policy.allowed) {
      const failed = {
        ...base,
        ok: false,
        results: [
          {
            scenario: "permission-onboarding",
            agent: "harness",
            status: "failed",
            ok: false,
            reason: policy.reason,
            code: policy.code,
            requestOnboarding: false,
          },
        ],
      };
      printReport(failed, { json: config.json, stdout, stderr });
      exit(1);
      return 1;
    }

    const report = { ...base, ok: true };
    printReport(report, { json: config.json, stdout, stderr });
    exit(0);
    return 0;
  }

  // Fail closed before any host launch when prompt was requested illegally.
  if (config.allowPermissionPrompt && !policy.allowed) {
    const report = {
      harness: "run-permission-onboarding-smoke",
      ok: false,
      permissionPolicy: policy,
      results: [
        {
          scenario: "permission-onboarding",
          status: "failed",
          ok: false,
          reason: policy.reason,
          code: policy.code,
          requestOnboarding: false,
        },
      ],
    };
    printReport(report, { json: config.json, stdout, stderr });
    exit(1);
    return 1;
  }

  let report;
  try {
    const ran = await runScenarios(config, { deps: options.deps });
    report = {
      harness: "run-permission-onboarding-smoke",
      ok: aggregateExitCode(ran.results) === 0,
      permissionPolicy: policy,
      results: ran.results,
      products: redactValue(ran.products),
    };
  } catch (error) {
    report = {
      harness: "run-permission-onboarding-smoke",
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

if (process.argv[1]?.endsWith("run-permission-onboarding-smoke.mjs")) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
