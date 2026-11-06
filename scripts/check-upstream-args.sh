#!/usr/bin/env bash
# Fail when the driver's mirrored upstream option surface drifts from upstream
# NVIDIA/OpenShell's openshell-driver-kubernetes at the pinned tag.
#
# Compares two regions of crates/openshell-driver-kyma/src/upstream_args.rs
# against upstream's crates/openshell-driver-kubernetes/src/main.rs:
#   A. the body of `pub struct UpstreamArgs { ... }` against the body of
#      upstream's `struct Args { ... }` (our fields carry `pub `; stripped);
#   B. the `KubernetesComputeConfig { ... }` literal in compute_config()
#      against the one upstream's main() builds (leading whitespace ignored);
# and guards the rest of upstream's main.rs (its main(): tracing, socket and TCP
# serving, the RPC layer), which crates/openshell-driver-kyma/src/main.rs mirrors
# by hand:
#   C. the sha256 of upstream's main.rs with the bodies of regions A and B
#      removed must equal the one recorded in scripts/upstream-main-rs.sha256.
#      On a change it prints the diff against the recorded tag's main.rs (same
#      regions removed) and the line to record once the change is mirrored.
#
# Usage:
#   scripts/check-upstream-args.sh              check (exit 0 match, 1 drift)
#   scripts/check-upstream-args.sh --print-env  list every upstream env var
# Exit 2 means the check could not run: bad usage, a fetch failure, or a
# region that could not be found or read. It is never reported as a match.
# UPSTREAM_TAG overrides the tag read from the workspace Cargo.toml.
# UPSTREAM_MAIN_RS points at a local upstream main.rs instead of fetching, and
# UPSTREAM_MAIN_SHA256 at another recorded-hash file (both for tests).
# --print-env resolves `env = CONSTANT` through openshell-core's config.rs and
# sandbox_env.rs at the same tag (or UPSTREAM_CORE_CONFIG_RS and
# UPSTREAM_SANDBOX_ENV_RS), and also lists the options of a flattened struct in
# upstream's Args. Only `SupervisorOtlpArgs` (upstream v0.1.7 and later, in
# sandbox_env.rs) is known; any other flattened struct, or a constant neither
# file defines, exits 2, so no option can drop out of the list unnoticed.
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

RECORDED=${UPSTREAM_MAIN_SHA256:-$SCRIPT_DIR/upstream-main-rs.sha256}
[[ $MODE == --print-env || -r $RECORDED ]] || { echo "error: cannot read $RECORDED" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
if [[ -n ${UPSTREAM_MAIN_RS:-} ]]; then
	cp "$UPSTREAM_MAIN_RS" "$WORK/upstream.rs"
else
	url="https://raw.githubusercontent.com/NVIDIA/OpenShell/${TAG}/crates/openshell-driver-kubernetes/src/main.rs"
	curl -fsSL --retry 3 "$url" -o "$WORK/upstream.rs" || { echo "could not fetch $url" >&2; exit 2; }
fi
: >"$WORK/sandbox_env.rs"
: >"$WORK/core_config.rs"
core_file() { # local-override destination path-in-openshell-core
	if [[ -n $1 ]]; then
		cp "$1" "$2"
	else
		url="https://raw.githubusercontent.com/NVIDIA/OpenShell/${TAG}/crates/openshell-core/src/$3"
		curl -fsSL --retry 3 "$url" -o "$2" || { echo "could not fetch $url" >&2; exit 2; }
	fi
}
if [[ $MODE == --print-env ]]; then
	core_file "${UPSTREAM_SANDBOX_ENV_RS:-}" "$WORK/sandbox_env.rs" sandbox_env.rs
	core_file "${UPSTREAM_CORE_CONFIG_RS:-}" "$WORK/core_config.rs" config.rs
fi

python3 - "$WORK/upstream.rs" "$OURS" "$MODE" "$TAG" "$RECORDED" "$WORK/sandbox_env.rs" "$WORK/core_config.rs" <<'PY'
import difflib, hashlib, re, subprocess, sys

upstream_path, ours_path, mode, tag, recorded_path, sandbox_env_path, core_config_path = sys.argv[1:8]
upstream = open(upstream_path).read().splitlines()

def span(lines, start_re, what, where):
    """(first, end) indices of the body lines of the block whose first line
    matches start_re: the lines between it and its closing brace."""
    for i, line in enumerate(lines):
        if re.search(start_re, line):
            depth = 0
            for j in range(i, len(lines)):
                depth += lines[j].count("{") - lines[j].count("}")
                if j > i and depth <= 0:
                    return i + 1, j
    print(f"error: could not find {what} in {where}", file=sys.stderr)
    sys.exit(2)

def body(lines, start_re, what, where):
    first, end = span(lines, start_re, what, where)
    return lines[first:end]

ARGS_RE, LITERAL_RE = r"^struct Args \{", r"^\s*KubernetesComputeConfig \{\s*$"

def rest_of_main(lines, where):
    """upstream's main.rs without the bodies of the two regions compared line by
    line below (the same bodies body() extracts), so each line is checked once."""
    drop = set()
    for start_re, what in ((ARGS_RE, "struct Args"), (LITERAL_RE, "config literal")):
        first, end = span(lines, start_re, what, where)
        drop.update(range(first, end))
    return [l for i, l in enumerate(lines) if i not in drop]

def env_names(text, consts):
    """The env names of `#[arg(..., env = ...)]` attributes in text: string
    literals, and identifiers resolved through consts."""
    names = []
    # `env` as a whole word; a constant may be path-qualified (sandbox_env::X).
    for literal, ident in re.findall(
            r'\benv\s*=\s*(?:"([A-Z0-9_]+)"|((?:[a-z_][a-z0-9_]*::)*[A-Z][A-Z0-9_]*)\b)', text):
        ident = ident.rsplit("::", 1)[-1]
        if literal:
            names.append(literal)
        elif ident in consts:
            names.append(consts[ident])
        else:
            print(f"error: cannot resolve env = {ident}", file=sys.stderr)
            sys.exit(2)
    return names

if mode == "--print-env":
    const_re = r'pub const ([A-Z0-9_]+): &str = "([A-Z0-9_]+)";'
    sandbox_env = open(sandbox_env_path).read()
    consts = dict(re.findall(const_re, open(core_config_path).read()))
    consts.update(re.findall(const_re, sandbox_env))
    args = body(upstream, ARGS_RE, "struct Args", f"upstream {tag}")
    names = env_names("\n".join(args), consts)
    names += re.findall(r'std::env::var\(\s*"([A-Z0-9_]+)"', "\n".join(upstream))
    for i, line in enumerate(args):
        # Any #[command(...)] or #[clap(...)] attribute that flattens.
        if not re.search(r"#\[(?:command|clap)\([^)]*\bflatten\b", line):
            continue
        field = args[i + 1] if i + 1 < len(args) else ""
        if not re.search(r":\s*SupervisorOtlpArgs,\s*$", field):
            print(f"error: unknown flattened struct in upstream Args: {field.strip()}", file=sys.stderr)
            sys.exit(2)
        lines = sandbox_env.splitlines()
        flat = body(lines, r"^pub struct SupervisorOtlpArgs \{", "pub struct SupervisorOtlpArgs",
                    f"upstream {tag} sandbox_env.rs")
        names += env_names("\n".join(flat), consts)
    print("\n".join(dict.fromkeys(names)))
    sys.exit(0)

ours = open(ours_path).read().splitlines()
up_args = body(upstream, ARGS_RE, "struct Args", f"upstream {tag}")
our_args = [re.sub(r"^(\s*)pub ", r"\1", l)
            for l in body(ours, r"^pub struct UpstreamArgs \{", "pub struct UpstreamArgs", ours_path)]
up_lit = [l.strip() for l in body(upstream, LITERAL_RE, "config literal", f"upstream {tag}")]
our_lit = [l.strip() for l in body(ours, LITERAL_RE, "config literal", ours_path)]

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

# C. The rest of upstream's main.rs is what src/main.rs mirrors by hand.
recorded = [l.split() for l in open(recorded_path).read().splitlines() if l.strip() and not l.startswith("#")]
if len(recorded) != 1 or len(recorded[0]) != 2 or not re.fullmatch(r"[0-9a-f]{64}", recorded[0][0]):
    print(f"error: {recorded_path} must hold one '<sha256>  <tag>' line", file=sys.stderr)
    sys.exit(2)
recorded_hash, recorded_tag = recorded[0]
rest = rest_of_main(upstream, f"upstream {tag}")
digest = hashlib.sha256(("\n".join(rest) + "\n").encode()).hexdigest()
if digest != recorded_hash:
    drift = True
    print(f"UPSTREAM_MAIN_DRIFT: upstream {tag}'s main.rs outside the two regions above differs from "
          f"what was reviewed at {recorded_tag} ({recorded_path})")
    url = (f"https://raw.githubusercontent.com/NVIDIA/OpenShell/{recorded_tag}"
           "/crates/openshell-driver-kubernetes/src/main.rs")
    fetched = subprocess.run(["curl", "-fsSL", "--retry", "3", url], capture_output=True, text=True)
    if fetched.returncode == 0:
        before = rest_of_main(fetched.stdout.splitlines(), f"upstream {recorded_tag}")
        sys.stdout.writelines(l + "\n" for l in difflib.unified_diff(
            before, rest, f"upstream {recorded_tag} (main.rs, regions removed)",
            f"upstream {tag} (main.rs, regions removed)", lineterm=""))
    else:
        print(f"(could not fetch {url} to diff; compare in an upstream clone with "
              f"`git diff {recorded_tag} {tag} -- crates/openshell-driver-kubernetes/src/main.rs`)")
    print("Mirror what changed in upstream's main() into crates/openshell-driver-kyma/src/main.rs, "
          f"then record the reviewed state by replacing the last line of {recorded_path} with:")
    print(f"  {digest}  {tag}")
if drift:
    sys.exit(1)
print(f"UPSTREAM_ARGS_MATCH: {len(up_args)} option lines and {len(up_lit)} config lines match upstream {tag}, "
      f"and the rest of its main.rs is the one reviewed at {recorded_tag}")
PY
