#!/usr/bin/env node
'use strict';

const { BootstrapError } = require('../lib/errors');
const { resolveRelayPath } = require('../lib/bootstrap');
const { execRelay } = require('../lib/exec');

async function main(argv = process.argv.slice(2)) {
  const relayPath = await resolveRelayPath();
  execRelay(relayPath, argv);
}

main(process.argv.slice(2)).catch((error) => {
  if (error instanceof BootstrapError) {
    process.stderr.write(`semantouch: ${error.message}\n`);
    process.exit(error.exitCode || 1);
  }
  const message = error && error.message ? error.message : String(error);
  process.stderr.write(`semantouch: ${message}\n`);
  process.exit(1);
});
