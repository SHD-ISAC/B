use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

// Pinned plugin releases. Upstream source commits at time of pinning:
// JM 0.0.11: fa2496cf75c7511a2f41031e7ca7eb8692fc5d72
// Bika 0.0.10: 700aa3393d433d1957e16607e0db99a28e44ceee
const PLUGIN_ASSETS: [(&str, &str, &str); 2] = [
    (
        "https://cdn.jsdelivr.net/npm/breeze-plugin-jm-comic@0.0.11/dist/breeze-plugin-jm-comic.bundle.cjs",
        "jm-comic.bundle.cjs",
        "182f8e5c388c052ea80c8c18efdcb2edde6c6d8ee58fbdf41204a6ca131779ea",
    ),
    (
        "https://cdn.jsdelivr.net/npm/breeze-plugin-bika-comic@0.0.10/dist/breeze-plugin-bika-comic.bundle.cjs",
        "bika-comic.bundle.cjs",
        "083a9f1efd45a3935a9b348609fb246236c6395af84d11b53414a6bbd287eb5f",
    ),
];
const USER_AGENT: &str = "Breeze-build-script";

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo::rustc-check-cfg=cfg(frb_expand)");

    // NDK r29 在目标 API >= 28 时默认输出 DT_ANDROID_RELR(0x6fffe000) 压缩相对重定位，
    // 而 bionic 要到 Android 10 (API 29) 才认识这个 tag；旧 linker 把它当作未知 DT 项跳过
    // （日志里就是 "unused DT entry"），整表不应用，.init_array / .data.rel.ro 里的函数指针
    // 保持链接期地址，System.loadLibrary("windcore") 在 call_constructors 阶段直接 SIGSEGV。
    // --pack-dyn-relocs=android 回退到旧版 DT_ANDROID_REL(0x60000011)，bionic 自 API 21 起
    // 支持，同时仍保留压缩收益。已在 Likebook T80D (Android 8.1 / API 27) 实测：
    // 默认(=android+relr) 崩溃，android 与 none 均加载且重定位结果正确。
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        println!("cargo:rustc-link-arg=-Wl,--pack-dyn-relocs=android");
    }

    let manifest_dir = PathBuf::from(
        env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR must be available"),
    );
    let assets_dir = manifest_dir.join("assets");

    fs::create_dir_all(&assets_dir)
        .unwrap_or_else(|err| panic!("failed to create assets dir {:?}: {err}", assets_dir));

    for (url, file_name, expected_sha256) in PLUGIN_ASSETS {
        let destination = assets_dir.join(file_name);
        if let Err(err) = download_to(url, &destination, expected_sha256) {
            if destination.exists() {
                verify_file_sha256(&destination, expected_sha256).unwrap_or_else(|verify_err| {
                    panic!(
                        "failed to refresh {file_name} ({err}); cached file also failed verification: {verify_err}"
                    )
                });
                println!(
                    "cargo:warning=failed to refresh {file_name} ({err}), using verified cached file"
                );
            } else {
                panic!("{err}");
            }
        }
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn verify_file_sha256(path: &Path, expected_sha256: &str) -> Result<(), String> {
    let bytes = fs::read(path)
        .map_err(|err| format!("failed to read {:?} for SHA-256 verification: {err}", path))?;
    let actual = sha256_hex(&bytes);
    if actual != expected_sha256 {
        return Err(format!(
            "SHA-256 mismatch for {:?}: expected {expected_sha256}, got {actual}",
            path
        ));
    }
    Ok(())
}

fn download_to(url: &str, destination: &Path, expected_sha256: &str) -> Result<(), String> {
    let response = ureq::get(url)
        .header("User-Agent", USER_AGENT)
        .call()
        .map_err(|err| format!("failed to download {url}: {err}"))?;

    let mut body = response.into_body();
    let mut reader = body.as_reader();
    let mut bytes = Vec::new();
    io::copy(&mut reader, &mut bytes)
        .map_err(|err| format!("failed to read response body from {url}: {err}"))?;

    let actual = sha256_hex(&bytes);
    if actual != expected_sha256 {
        return Err(format!(
            "SHA-256 mismatch for {url}: expected {expected_sha256}, got {actual}"
        ));
    }

    fs::write(destination, bytes)
        .map_err(|err| format!("failed to write {:?}: {err}", destination))?;

    Ok(())
}
