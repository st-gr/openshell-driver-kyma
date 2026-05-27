fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_prost_build::configure()
        .build_server(true)
        .build_client(true)
        .compile_protos(&["../../proto/compute_driver.proto"], &["../../proto"])?;
    println!("cargo:rerun-if-changed=../../proto/compute_driver.proto");
    Ok(())
}
