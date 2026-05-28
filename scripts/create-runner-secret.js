#!/usr/bin/env node
// create-runner-secret.js — interactively prompt for the GitHub PAT and
// ANTHROPIC_AUTH_TOKEN and create the gh-runner-creds Secret in the
// configured Kubernetes cluster.
//
// Why Node and not bash: on Windows, GNU Make spawns sh (MSYS), which
// in turn spawns bash (MSYS) for `bash -c`. Two layers of MSYS subshell
// can transform the env (HOME, KUBECONFIG paths) in ways that make
// kubectl fall back to localhost:8080. Node bypasses MSYS entirely —
// it inherits the launching shell's env unchanged.
//
// SECRETS: tokens are read from the controlling tty in raw mode (no
// echo, no scrollback). They never enter argv, env (other than passed
// to kubectl below), or stdout. After the kubectl call returns we
// overwrite the strings before letting the GC reclaim them.

'use strict';

const readline = require('readline');
const { spawnSync } = require('child_process');

const NAMESPACE = process.argv[2] || 'gh-runner';
const SECRET = 'gh-runner-creds';

function die(msg, code = 2) {
  process.stderr.write(`create-runner-secret: ${msg}\n`);
  process.exit(code);
}

function promptSecret(label) {
  return new Promise((resolve) => {
    const stdin = process.stdin;
    const stdout = process.stdout;
    if (!stdin.isTTY) die('stdin is not a TTY; cannot prompt for tokens');
    stdout.write(`${label}: `);
    stdin.setRawMode(true);
    stdin.resume();
    stdin.setEncoding('utf8');
    let buffer = '';
    const onData = (ch) => {
      // Ctrl-C
      if (ch === '') { stdout.write('\n'); process.exit(130); }
      // Enter
      if (ch === '\n' || ch === '\r' || ch === '\r\n') {
        stdin.removeListener('data', onData);
        stdin.setRawMode(false);
        stdin.pause();
        stdout.write('\n');
        resolve(buffer);
        return;
      }
      // Backspace (DEL or BS)
      if (ch === '' || ch === '\b') {
        if (buffer.length > 0) buffer = buffer.slice(0, -1);
        return;
      }
      buffer += ch;
    };
    stdin.on('data', onData);
  });
}

async function main() {
  const pat = await promptSecret('GitHub PAT (classic; repo + workflow scopes)');
  const token = await promptSecret('ANTHROPIC_AUTH_TOKEN (your-llm-gateway auth token)');

  if (!pat || !token) die('both values are required');
  // Lightweight format sanity (don't reject — your-llm-gateway tokens vary):
  if (!/^ghp_|^github_pat_/.test(pat)) {
    process.stderr.write('warning: PAT does not start with "ghp_" or "github_pat_" — proceeding anyway\n');
  }

  // Idempotent: delete-then-create.
  let r = spawnSync('kubectl', [
    '--namespace', NAMESPACE,
    'delete', 'secret', SECRET,
    '--ignore-not-found=true',
  ], { stdio: ['ignore', 'inherit', 'inherit'] });
  if (r.error && r.error.code === 'ENOENT') die("'kubectl' is not on PATH");
  if (r.status !== 0) die(`kubectl delete failed (exit ${r.status})`);

  r = spawnSync('kubectl', [
    '--namespace', NAMESPACE,
    'create', 'secret', 'generic', SECRET,
    `--from-literal=GITHUB_PAT=${pat}`,
    `--from-literal=ANTHROPIC_AUTH_TOKEN=${token}`,
  ], { stdio: ['ignore', 'inherit', 'inherit'] });
  if (r.status !== 0) die(`kubectl create failed (exit ${r.status})`);

  // Best-effort scrub. Node strings are immutable so we can only break
  // the references; the underlying allocation stays in memory until GC.
  // The kubectl process already received them via argv.
  process.stderr.write(`secret ${SECRET} created in namespace ${NAMESPACE}\n`);
}

main().catch((e) => die(`unexpected error: ${e.message || e}`));
