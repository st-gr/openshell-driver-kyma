#!/usr/bin/env node
// add-runner-repo.js — register a self-hosted GitHub Actions runner for one
// repository. Renders deploy/runner/deployment-template.yaml with the given
// owner/repo, writes the result to deploy/runner/deployments/<owner>-<repo>.yaml,
// and (with --apply) pipes it to kubectl.
//
// SECRETS: this script NEVER accepts a token via argv or env. The PAT and
// ANTHROPIC_AUTH_TOKEN are loaded by the runner pod from the Kubernetes
// Secret `gh-runner-creds` (created out-of-band by the operator with
// `kubectl create secret`). Rendered manifests reference that Secret via
// secretKeyRef and contain no inline credentials.
//
// Zero npm dependencies — uses only Node.js stdlib + `gh` CLI for repo
// validation. Run from the repo root.
//
// Usage:
//   node scripts/add-runner-repo.js --owner <owner> --repo <repo> [--name <name>]
//                                   [--namespace <ns>]
//                                   (--apply | --dry-run)

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');

const REPO_ROOT = path.resolve(__dirname, '..');
const TEMPLATE_PATH = path.join(REPO_ROOT, 'deploy/runner/deployment-template.yaml');
const DEPLOYMENTS_DIR = path.join(REPO_ROOT, 'deploy/runner/deployments');

function die(msg, code = 2) {
  process.stderr.write(`add-runner-repo: ${msg}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const args = { namespace: 'gh-runner', apply: false, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      if (i + 1 >= argv.length) die(`${a} requires a value`);
      return argv[++i];
    };
    switch (a) {
      case '--owner':     args.owner     = next(); break;
      case '--repo':      args.repo      = next(); break;
      case '--name':      args.name      = next(); break;
      case '--namespace': args.namespace = next(); break;
      case '--apply':     args.apply     = true;   break;
      case '--dry-run':   args.dryRun    = true;   break;
      case '-h': case '--help':
        process.stdout.write([
          'Usage: node scripts/add-runner-repo.js \\',
          '  --owner <owner> --repo <repo> \\',
          '  [--name <runner-name>] [--namespace <ns>] \\',
          '  (--apply | --dry-run)',
          '',
          'Renders deploy/runner/deployment-template.yaml and either applies it',
          'to the cluster (--apply) or prints it to stdout (--dry-run).',
          '',
          'Tokens are NEVER passed as arguments. The runner pod reads the PAT',
          'and ANTHROPIC_AUTH_TOKEN from the gh-runner-creds Secret, which the',
          'operator creates out-of-band with `kubectl create secret`.',
          '',
        ].join('\n'));
        process.exit(0);
      default:
        die(`unknown argument: ${a}`);
    }
  }
  if (!args.owner || !args.repo) die('--owner and --repo are required');
  if (args.apply && args.dryRun) die('--apply and --dry-run are mutually exclusive');
  if (!args.apply && !args.dryRun) die('one of --apply or --dry-run is required');
  if (!/^[A-Za-z0-9._-]+$/.test(args.owner)) die(`invalid owner: ${args.owner}`);
  if (!/^[A-Za-z0-9._-]+$/.test(args.repo)) die(`invalid repo: ${args.repo}`);
  if (!args.name) {
    // K8s label values are 63 chars max. Build a deterministic name and
    // truncate if needed.
    const raw = `runner-${args.owner}-${args.repo}`.toLowerCase();
    args.name = raw.length > 63 ? raw.slice(0, 63) : raw;
  }
  if (!/^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/.test(args.name)) {
    die(`derived name "${args.name}" is not a valid DNS-1123 label`);
  }
  return args;
}

function validateRepoExists(owner, repo) {
  // gh CLI authenticates with the operator's existing credentials; if the
  // repo doesn't exist or the operator can't read it, gh exits non-zero.
  const r = spawnSync('gh', ['api', `repos/${owner}/${repo}`, '--jq', '.full_name'], {
    encoding: 'utf8',
  });
  if (r.error && r.error.code === 'ENOENT') {
    die("'gh' CLI is not on PATH. Install from https://cli.github.com/");
  }
  if (r.status !== 0) {
    die(`repository ${owner}/${repo} not found or not accessible to your gh CLI auth`);
  }
  const fullName = r.stdout.trim();
  if (fullName.toLowerCase() !== `${owner}/${repo}`.toLowerCase()) {
    die(`gh API returned ${fullName}; expected ${owner}/${repo}`);
  }
}

function render(template, args) {
  // Plain string substitution — the template uses literal __OWNER__,
  // __REPO__, __NAME__ tokens. No YAML library needed.
  return template
    .replace(/__OWNER__/g, args.owner)
    .replace(/__REPO__/g, args.repo)
    .replace(/__NAME__/g, args.name);
}

function applyToCluster(manifest, args) {
  const r = spawnSync('kubectl', ['apply', '-n', args.namespace, '-f', '-'], {
    input: manifest,
    encoding: 'utf8',
    stdio: ['pipe', 'inherit', 'inherit'],
  });
  if (r.error && r.error.code === 'ENOENT') {
    die("'kubectl' is not on PATH");
  }
  if (r.status !== 0) {
    die(`kubectl apply failed (exit ${r.status})`);
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  if (!fs.existsSync(TEMPLATE_PATH)) die(`template not found at ${TEMPLATE_PATH}`);
  const template = fs.readFileSync(TEMPLATE_PATH, 'utf8');

  validateRepoExists(args.owner, args.repo);

  const manifest = render(template, args);

  // Sanity: rendered manifest must not contain any leftover placeholder.
  for (const ph of ['__OWNER__', '__REPO__', '__NAME__']) {
    if (manifest.includes(ph)) {
      die(`rendered manifest still contains placeholder ${ph} — template bug`);
    }
  }

  if (args.dryRun) {
    process.stdout.write(manifest);
    return;
  }

  // --apply path: write the rendered manifest into deployments/ for
  // reproducibility, then kubectl apply.
  fs.mkdirSync(DEPLOYMENTS_DIR, { recursive: true });
  const outPath = path.join(DEPLOYMENTS_DIR, `${args.owner}-${args.repo}.yaml`);
  fs.writeFileSync(outPath, manifest);
  process.stderr.write(`wrote ${path.relative(REPO_ROOT, outPath)}\n`);

  applyToCluster(manifest, args);

  process.stderr.write(`\nrunner registered. follow logs with:\n`);
  process.stderr.write(`  kubectl -n ${args.namespace} logs -f deployment/${args.name}\n`);
  process.stderr.write(`\nverify in GitHub UI:\n`);
  process.stderr.write(`  https://github.com/${args.owner}/${args.repo}/settings/actions/runners\n`);
}

main();
