fn main() {
    let mut config = slint_build::CompilerConfiguration::new();
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("none") {
        config = config.embed_resources(slint_build::EmbedResourcesKind::EmbedForSoftwareRenderer);
    }
    slint_build::compile_with_config("ui/companion.slint", config)
        .expect("compile the Tab5 companion interface");
}
