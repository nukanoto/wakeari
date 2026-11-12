// macOS では CoreBluetooth が Info.plist の利用目的文字列を要求する。
// コマンドラインツールには Info.plist がないので、バイナリの __TEXT,__info_plist に埋め込む。
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=Info.plist");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
        println!("cargo:rustc-link-arg=-Wl,-sectcreate,__TEXT,__info_plist,{dir}/Info.plist");
    }
}
