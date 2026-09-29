#!/usr/bin/env bash
# Fail when the driver's mirrored upstream option surface drifts from upstream
# NVIDIA/OpenShell's openshell-driver-kubernetes at the pinned tag.
#
# Compares two regions of crates/openshell-driver-kyma/src/upstream_args.rs
# against upstream's crates/openshell-driver-kubernetes/src/main.rs:
#   A. the body of `pub struct UpstreamArgs { ... }` against the body of
#      upstream's `struct Args { ... }` (our fields carry `pub `; stripped);
#   B. the `KubernetesComputeConfig { ... }` literal in compute_config()
#      against the one upstream's main() builds (leading whitespace ignored).
#
# Usage:
#   scripts/check-upstream-args.sh              check (exit 0 match, 1 drift)
#   scripts/check-upstream-args.sh --print-env  list every upstream env var
# Exit 2 means the check could not run: bad usage, a fetch failure, or a
# region that could not be found or read. It is never reported as a match.
# UPSTREAM_TAG overrides the tag read from the workspace Cargo.toml.
# UPSTREAM_MAIN_RS points at a local upstream main.rs instead of fetching.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proto-lib.sh
. "${SCRIPT_DIR}/proto-lib.sh"

MODE=${1:-check}
if [[ $# -gt 1 || ( $MODE != check && $MODE != --print-env ) ]]; then
	echo "usage: ${0##*/} [--print-env]" >&2
	exit 2
fi

ROOT=$(git rev-parse --show-toplevel)
OURS=${OURS_ARGS_RS:-$ROOT/crates/openshell-driver-kyma/src/upstream_args.rs}
[[ -r $OURS ]] || { echo "error: cannot read $OURS" >&2; exit 2; }
TAG=${UPSTREAM_TAG:-$(pinned_upstream_tag)} \
	|| { echo "error: could not read the pinned upstream tag from Cargo.toml" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
if [[ -n ${UPSTREAM_MAIN_RS:-} ]]; then
	cp "$UPSTREAM_MAIN_RS" "$WORK/upstream.rs"
else
	url="https://raw.githubusercontent.com/NVIDIA/OpenShell/${TAG}/crates/openshell-driver-kubernetes/src/main.rs"
	curl -fsSL --retry 3 "$url" -o "$WORK/upstream.rs" || { echo "could not fetch $url" >&2; exit 2; }
fi

python3 - "$WORK/upstream.rs" "$OURS" "$MODE" "$TAG" <<'PY'
import difflib, re, sys

upstream_path, ours_path, mode, tag = sys.argv[1:5]
upstream = open(upstream_path).read().splitlines()

def body(lines, start_re, what, where):
    for i, line in enumerate(lines):
        if re.search(start_re, line):
            depth, out = 0, []
            for j in range(i, len(lines)):
                depth += lines[j].count("{") - lines[j].count("}")
                if j > i:
                    if depth <= 0:
                        return out
                    out.append(lines[j])
    print(f"error: could not find {what} in {where}", file=sys.stderr)
    sys.exit(2)

if mode == "--print-env":
    text = "\n".join(upstream)
    names = re.findall(r'env\s*=\s*"([A-Z0-9_]+)"', text)
    names += re.findall(r'std::env::var\(\s*"([A-Z0-9_]+)"', text)
    print("\n".join(dict.fromkeys(names)))
    sys.exit(0)

ours = open(ours_path).read().splitlines()
up_args = body(upstream, r"^struct Args \{", "struct Args", f"upstream {tag}")
our_args = [re.sub(r"^(\s*)pub ", r"\1", l)
            for l in body(ours, r"^pub struct UpstreamArgs \{", "pub struct UpstreamArgs", ours_path)]
up_lit = [l.strip() for l in body(upstream, r"^\s*KubernetesComputeConfig \{\s*$", "config literal", f"upstream {tag}")]
our_lit = [l.strip() for l in body(ours, r"^\s*KubernetesComputeConfig \{\s*$", "config literal", ours_path)]

drift = False
for name, a, b in (("option struct", up_args, our_args), ("config literal", up_lit, our_lit)):
    if a != b:
        drift = True
        print(f"UPSTREAM_ARGS_DRIFT: {name} differs from upstream {tag}")
        sys.stdout.writelines(l + "\n" for l in difflib.unified_diff(
            b, a, f"ours ({name})", f"upstream {tag} ({name})", lineterm=""))
if drift:
    print("Mirror the upstream side of the diff above into "
          "crates/openshell-driver-kyma/src/upstream_args.rs.")
    sys.exit(1)
print(f"UPSTREAM_ARGS_MATCH: {len(up_args)} option lines and {len(up_lit)} config lines match upstream {tag}")
PY
