fn main() -> Result<(), Box<dyn std::error::Error>> {
    // `options.proto` is deliberately NOT in the compile list. It contains only
    // `extend google.protobuf.FieldOptions { bool secret = 50001; }`, which
    // `compute_driver.proto` imports for the `sandbox_token` annotation. protoc
    // resolves it through the include path below; compiling it directly would
    // emit an empty module for a file that declares no messages.
    //
    // `extension.proto` (openshell.extension.v1.PeerMetadata) and
    // `sandbox.proto` (openshell.sandbox.v1.SandboxPolicy, which itself
    // imports datamodel.proto) declare messages compute_driver.proto now
    // references directly, so they must be compiled rather than left to
    // include-path resolution.
    tonic_prost_build::configure()
        .build_server(true)
        .build_client(true)
        .compile_protos(
            &[
                "../../proto/compute_driver.proto",
                "../../proto/extension.proto",
                "../../proto/sandbox.proto",
            ],
            &["../../proto"],
        )?;
    println!("cargo:rerun-if-changed=../../proto/compute_driver.proto");
    println!("cargo:rerun-if-changed=../../proto/options.proto");
    println!("cargo:rerun-if-changed=../../proto/extension.proto");
    println!("cargo:rerun-if-changed=../../proto/sandbox.proto");
    println!("cargo:rerun-if-changed=../../proto/datamodel.proto");
    Ok(())
}
