# Runbook: cutting a release

Releases are tag-driven. Pushing a `v*` tag to `main` runs
`.github/workflows/release-tag.yml`, which builds and pushes the driver
image, packages and pushes the Helm chart, and publishes a GitHub
release with the chart tarball attached.

Nothing here is automatic before the tag. Bumping the chart version,
`Chart.AppVersion`, and the CHANGELOG entry are ordinary commits on a
release branch, reviewed like anything else.

## What runs, and when

| Trigger | Workflow | Effect |
|---|---|---|
| push `v*` tag | `release-tag.yml` | image + chart published, GitHub release created |
| push to `main` | `docker-build.yml` | image at `:<sha>` and `:latest` |

## Before you tag: check the pins

`release-tag.yml`'s first real step runs `scripts/check-image-pins.sh` and
writes the result to the run summary. It is **advisory** — it always exits
0 and never blocks a release. You can also run it locally at any time:

```bash
./scripts/check-image-pins.sh
```

It reports four pins, each of which is deliberate and each of which goes
stale silently if nothing asks:

- **sandbox base** — the `e2e-sandbox` digest in `e2e/sandbox-claude/Dockerfile`
- **claude-code** — `ARG CLAUDE_CODE_VERSION` in the same file
- **gateway** — `gateway.image.tag` in `values.yaml`, a `sha256:` digest
- **supervisor** — `driver.supervisorImage`, version-matched to the gateway

A `stale` line is not a reason to stop the release. It is a prompt to
decide, in a separate reviewable commit, whether to bump. The
re-resolve command sits in a comment beside each pin.

`scripts/check-pin-status.sh` is the sibling for the `GATEWAY_REF` knob in
`.github/upstream-compat.env`, which governs which gateway the interop
smoke tests against. That one is reported weekly by `upstream-sync.yml`.

## Situations

### The GitHub release step fails

`softprops/action-gh-release` publishes the release and uploads
`dist/*.tgz`. It was bumped v2 → v3 on 2026-08-21.

That major was **proven before merge** against a throwaway private repo
using the same three inputs this workflow passes — `name`,
`generate_release_notes: true`, and `files` — and it published the
release, generated notes, and attached the asset correctly. So a failure
here is unlikely to be the action version itself.

What the probe did *not* cover: a real chart tarball, a real tag name, and
the `contents: write` permission in this repo. If the step fails, check
those three before suspecting v3.

The release is the last step, so a failure here means the image and chart
are already published. Do not re-tag: delete the failed GitHub release if
one was partially created, fix forward, and re-run the job.

### A pin shows `unknown`

The check could not reach the registry or npm. This is common on a
network blip and is never fatal — `PINS_UNCHECKED: true` is reported and
the release continues. Re-run the script locally if you want a real
answer.

### `gateway` and `supervisor` both show stale at once

Expected. They are version-matched on purpose, so upstream publishing a
new release makes both stale together. Bump them in the same commit, and
re-resolve both digests — never one alone, or a sandbox gets a supervisor
that does not match its gateway.
