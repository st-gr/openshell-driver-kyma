fn main() -> Result<(), Box<dyn std::error::Error>> {
    // `options.proto` is deliberately NOT in the compile list. It contains only
    // `extend google.protobuf.FieldOptions { bool secret = 50001; }`, which
    // `compute_driver.proto` imports for the `sandbox_token` annotation. protoc
    // resolves it through the include path below; compiling it directly would
    // emit an empty module for a file that declares no messages.
    tonic_prost_build::configure()
        .build_server(true)
        .build_client(true)
        .compile_protos(&["../../proto/compute_driver.proto"], &["../../proto"])?;
    println!("cargo:rerun-if-changed=../../proto/compute_driver.proto");
    println!("cargo:rerun-if-changed=../../proto/options.proto");
    Ok(())
}
