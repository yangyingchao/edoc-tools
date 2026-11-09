use std::path::Path;

fn main() {
    let out = std::env::var("OUT_DIR").expect("OUT_DIR set by cargo");
    let src = Path::new("..").join("server");
    let mut build = cc::Build::new();
    build
        .file(src.join("synctex_parser.c"))
        .file(src.join("synctex_parser_utils.c"))
        .include(&src)
        .warnings(false)
        .define("SYNCTEX_NO_DEPRECATED", None);
    build.compile("synctex");
    println!("cargo:rustc-link-lib=z");
    println!(
        "cargo:rerun-if-changed={}",
        src.join("synctex_parser.c").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        src.join("synctex_parser_utils.c").display()
    );
    let _ = out;
}
