#!/usr/bin/env node
// render-static-kubeconfig.js — emit a "flattened" kubeconfig where every
// `users[].user.exec` entry has been replaced by a static `token`, with
// the token freshly minted on the host by running the exec auth plugin.
//
// Why this exists: `make test-integration` runs cargo inside the dev
// container, but Kyma kubeconfigs use OIDC via `kubectl-oidc_login`,
// which requires a browser at the first prompt and is not present in
// the container image. Resolving the exec auth on the host once,
// then handing the container a static kubeconfig, sidesteps both
// problems. Tokens expire (typically ~1h); re-run before the next
// integration test.
//
// Output goes to stdout in JSON form (kubectl/kube-rs both accept JSON
// kubeconfigs). Caller redirects to a file and bind-mounts it into the
// container at /root/.kube/config.
//
// Usage:
//   node scripts/render-static-kubeconfig.js > .tmp/kubeconfig
// or with an explicit kubeconfig:
//   KUBECONFIG=/path/to/kubeconfig node scripts/render-static-kubeconfig.js
//
// SECRETS: the resulting kubeconfig contains a bearer token. Caller must
// not commit, share, or print the file. The recipe writes it under .tmp/
// (gitignored) and bind-mounts read-only.

'use strict';

const { execFileSync } = require('child_process');

function die(msg, code = 2) {
  process.stderr.write(`render-static-kubeconfig: ${msg}\n`);
  process.exit(code);
}

function run(cmd, args, opts = {}) {
  try {
    return execFileSync(cmd, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'inherit'],
      ...opts,
    });
  } catch (e) {
    if (e.code === 'ENOENT') die(`'${cmd}' not on PATH`);
    die(`${cmd} failed (exit ${e.status})`);
  }
}

// 1. Pull the current kubeconfig as flat JSON. `--raw` includes inline cert
//    data and tokens (the `:false` redaction is off). KUBECONFIG env is
//    honored by kubectl natively.
const cfg = JSON.parse(run('kubectl', ['config', 'view', '--flatten', '--raw', '-o', 'json']));

// 2. For every user that uses exec auth, run the exec plugin and replace
//    the exec stanza with the resolved token. Preserve everything else.
let resolved = 0;
for (const u of cfg.users || []) {
  const user = u.user;
  if (!user || !user.exec) continue;
  const exec = user.exec;
  // Compose the env for the exec plugin: process env + any exec.env
  // entries the kubeconfig declared (e.g. PATH overrides).
  const env = { ...process.env };
  for (const e of exec.env || []) env[e.name] = e.value;
  const out = run(exec.command, exec.args || [], { env });
  // The plugin returns an ExecCredential JSON.
  let cred;
  try { cred = JSON.parse(out); }
  catch (e) { die(`exec plugin '${exec.command}' returned non-JSON`); }
  const token = cred && cred.status && cred.status.token;
  if (!token) die(`exec plugin '${exec.command}' returned no token`);
  delete user.exec;
  user.token = token;
  resolved += 1;
}

if (resolved === 0) {
  process.stderr.write('render-static-kubeconfig: no exec auth entries found; passing through unchanged\n');
}

process.stdout.write(JSON.stringify(cfg));
