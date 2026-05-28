#!/usr/bin/env node
// remove-runner-repo.js — un-register the self-hosted runner for one repo.
// Deletes the cluster Deployment AND the committed manifest under
// deploy/runner/deployments/. The runner pod's SIGTERM trap deregisters
// it from GitHub before the container exits.
//
// Tokens are not handled here — same hygiene as add-runner-repo.js.
//
// Usage:
//   node scripts/remove-runner-repo.js --owner <owner> --repo <repo>
//                                      [--namespace <ns>] [--keep-file]

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const REPO_ROOT = path.resolve(__dirname, '..');
const DEPLOYMENTS_DIR = path.join(REPO_ROOT, 'deploy/runner/deployments');

function die(msg, code = 2) {
  process.stderr.write(`remove-runner-repo: ${msg}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const args = { namespace: 'gh-runner', keepFile: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      if (i + 1 >= argv.length) die(`${a} requires a value`);
      return argv[++i];
    };
    switch (a) {
      case '--owner':     args.owner     = next(); break;
      case '--repo':      args.repo      = next(); break;
      case '--namespace': args.namespace = next(); break;
      case '--keep-file': args.keepFile  = true;   break;
      case '-h': case '--help':
        process.stdout.write([
          'Usage: node scripts/remove-runner-repo.js \\',
          '  --owner <owner> --repo <repo> [--namespace <ns>] [--keep-file]',
          '',
          'Deletes the runner Deployment from the cluster and removes the',
          'rendered manifest under deploy/runner/deployments/. With',
          '--keep-file the rendered manifest stays committed but the',
          'cluster object is still deleted.',
          '',
        ].join('\n'));
        process.exit(0);
      default:
        die(`unknown argument: ${a}`);
    }
  }
  if (!args.owner || !args.repo) die('--owner and --repo are required');
  if (!/^[A-Za-z0-9._-]+$/.test(args.owner)) die(`invalid owner: ${args.owner}`);
  if (!/^[A-Za-z0-9._-]+$/.test(args.repo)) die(`invalid repo: ${args.repo}`);
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const filename = `${args.owner}-${args.repo}.yaml`;
  const filePath = path.join(DEPLOYMENTS_DIR, filename);

  if (!fs.existsSync(filePath)) {
    die(`no rendered manifest at deploy/runner/deployments/${filename}`);
  }

  const r = spawnSync('kubectl', ['delete', '-n', args.namespace, '-f', filePath, '--ignore-not-found=true'], {
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  if (r.error && r.error.code === 'ENOENT') die("'kubectl' is not on PATH");
  if (r.status !== 0) die(`kubectl delete failed (exit ${r.status})`);

  if (!args.keepFile) {
    fs.unlinkSync(filePath);
    process.stderr.write(`removed deploy/runner/deployments/${filename}\n`);
  } else {
    process.stderr.write(`kept deploy/runner/deployments/${filename} (--keep-file)\n`);
  }
}

main();
