'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const EventEmitter = require('node:events');
const { execRelay, forwardSignals } = require('../lib/exec');

function createFakeProcess() {
  const proc = new EventEmitter();
  proc.pid = 4242;
  proc.env = { PATH: '/usr/bin' };
  proc.stderr = {
    chunks: [],
    write(chunk) {
      this.chunks.push(String(chunk));
      return true;
    },
  };
  proc.exitCode = null;
  proc.exit = (code) => {
    proc.exitCode = code;
  };
  proc.killedSignal = null;
  proc.kill = (_pid, signal) => {
    proc.killedSignal = signal;
    return true;
  };
  // EventEmitter already provides on/off
  return proc;
}

function createFakeChild() {
  const child = new EventEmitter();
  child.killed = false;
  child.signals = [];
  child.kill = (signal) => {
    child.signals.push(signal);
    child.killed = true;
    return true;
  };
  return child;
}

describe('forwardSignals', () => {
  it('forwards SIGINT/SIGTERM to the child and detaches cleanly', () => {
    const proc = createFakeProcess();
    const child = createFakeChild();
    const detach = forwardSignals(child, proc);

    proc.emit('SIGINT');
    proc.emit('SIGTERM');
    assert.deepEqual(child.signals, ['SIGINT', 'SIGTERM']);

    detach();
    proc.emit('SIGINT');
    assert.deepEqual(child.signals, ['SIGINT', 'SIGTERM']);
  });
});

describe('execRelay', () => {
  it('spawns without a shell and forwards argv', () => {
    const proc = createFakeProcess();
    const child = createFakeChild();
    /** @type {any[]} */
    const calls = [];

    const fakeSpawn = (command, args, options) => {
      calls.push({ command, args, options });
      return child;
    };

    execRelay('/Applications/Semantouch.app/Contents/MacOS/semantouch', ['doctor', '--json'], {
      spawn: fakeSpawn,
      process: proc,
      onExit: () => {},
    });

    assert.equal(calls.length, 1);
    assert.equal(calls[0].command, '/Applications/Semantouch.app/Contents/MacOS/semantouch');
    assert.deepEqual(calls[0].args, ['doctor', '--json']);
    assert.equal(calls[0].options.shell, false);
    assert.equal(calls[0].options.stdio, 'inherit');
  });

  it('forwards numeric exit codes via onExit', () => {
    const proc = createFakeProcess();
    const child = createFakeChild();
    /** @type {Array<[number|null, string|null]>} */
    const exits = [];

    execRelay('/relay', ['mcp'], {
      spawn: () => child,
      process: proc,
      onExit: (code, signal) => exits.push([code, signal]),
    });

    child.emit('exit', 7, null);
    assert.deepEqual(exits, [[7, null]]);
  });

  it('forwards termination signals via onExit', () => {
    const proc = createFakeProcess();
    const child = createFakeChild();
    /** @type {Array<[number|null, string|null]>} */
    const exits = [];

    execRelay('/relay', [], {
      spawn: () => child,
      process: proc,
      onExit: (code, signal) => exits.push([code, signal]),
    });

    child.emit('exit', null, 'SIGTERM');
    assert.deepEqual(exits, [[null, 'SIGTERM']]);
  });

  it('exits 1 when spawn fails', () => {
    const proc = createFakeProcess();
    const child = createFakeChild();

    execRelay('/missing', [], {
      spawn: () => child,
      process: proc,
    });

    child.emit('error', new Error('ENOENT'));
    assert.equal(proc.exitCode, 1);
    assert.match(proc.stderr.chunks.join(''), /failed to exec/);
  });
});
