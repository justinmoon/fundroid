use std::env;
use std::path::PathBuf;

fn main() {
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os != "android" {
        println!(
            "cargo:warning=hal_ndk targets Android; skipping binder_ndk_shim linkage for {}",
            target_os
        );
        return;
    }

    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let abi_dir = match target_arch.as_str() {
        "aarch64" => "arm64-v8a",
        "x86_64" => "x86_64",
        other => {
            panic!(
                "Unsupported target architecture '{}' for binder_ndk_shim",
                other
            );
        }
    };

    let shim_root = env::var("HAL_SHIM_BUILD_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR set"))
                .join("..")
                .join("..")
                .join("target")
                .join("hal_shims")
        });

    let lib_dir = shim_root.join(abi_dir);
    if !lib_dir.exists() {
        panic!(
            "binder_ndk_shim archive directory not found: {}",
            lib_dir.display()
        );
    }

    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=binder_ndk_shim");
    println!("cargo:rustc-link-lib=binder_ndk");
}
