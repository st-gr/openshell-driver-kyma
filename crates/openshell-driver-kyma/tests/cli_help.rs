//! Smoke test: the binary parses `--help` and lists every documented flag.
//! Run via `cargo test -p openshell-driver-kyma --test cli_help`.

#![cfg(unix)]

use assert_cmd::Command;

#[test]
fn help_lists_all_documented_flags() {
    let out = Command::cargo_bin("openshell-driver-kyma")
        .unwrap()
        .arg("--help")
        .output()
        .unwrap();

    assert!(out.status.success(), "--help should exit 0");
    let stdout = String::from_utf8_lossy(&out.stdout);

    for flag in [
        "--socket",
        "--namespace",
        "--supervisor-image",
        "--supervisor-binary-path",
        "--supervisor-mount-path",
        "--gateway-endpoint",
        "--istio-inject-sandboxes",
        "--enable-apirule",
        "--cluster-domain",
        "--gpu-support",
        "--enable-network-policy",
        "--health-port",
        "--log-level",
    ] {
        assert!(
            stdout.contains(flag),
            "expected --help to mention {flag}; got:\n{stdout}"
        );
    }
}
