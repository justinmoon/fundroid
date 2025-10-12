{
  description = "webos dev env (macOS + Linux)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachSystem
      [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ]
      (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };

          lib = pkgs.lib;

          rustToolchain =
            pkgs.rust-bin.selectLatestStableWith
              (toolchain: toolchain.default.override {
                targets = [
                  "aarch64-linux-android"
                  "x86_64-linux-android"
                ];
                extensions = [ "rust-src" "clippy" "rustfmt" ];
              });

          androidNdk = pkgs.android-ndk;

          ndkPrebuilt =
            if pkgs.stdenv.hostPlatform.isDarwin then "darwin-x86_64"
            else if pkgs.stdenv.hostPlatform.isLinux &&
                    pkgs.stdenv.hostPlatform.isAarch64 then "linux-arm64"
            else "linux-x86_64";

          commonPackages = [
            rustToolchain
            pkgs.pkg-config
            pkgs.cmake
            pkgs.ninja
            pkgs.git
            pkgs.git-lfs
            pkgs.jq
            pkgs.unzip
            pkgs.zip
            pkgs.which
            pkgs.openssl
            pkgs.cacert
            pkgs.android-tools
            androidNdk
            pkgs.llvmPackages.clang
            pkgs.llvmPackages.lld
            pkgs.just
          ];
        in {
          devShells = {
            default = pkgs.mkShell {
              packages = commonPackages;
              ANDROID_NDK_HOME = androidNdk;
              ANDROID_NDK_ROOT = androidNdk;
              CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER =
                "${androidNdk}/toolchains/llvm/prebuilt/${ndkPrebuilt}/bin/aarch64-linux-android24-clang";
              CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER =
                "${androidNdk}/toolchains/llvm/prebuilt/${ndkPrebuilt}/bin/x86_64-linux-android24-clang";
              shellHook = ''
                echo "✅ webos devshell ready"
                echo "Targets: aarch64-linux-android, x86_64-linux-android"
                just --list 2>/dev/null || true
              '';
            };

            aosp = pkgs.mkShell {
              packages =
                (with pkgs; [
                  git
                  repo
                  python312
                  python312Packages.pyopenssl
                  openjdk17_headless
                  gperf
                  libxml2
                  unzip
                  zip
                  rsync
                  curl
                  bc
                  bison
                  flex
                  ninja
                  cmake
                  gn
                  ccache
                  file
                  android-tools
                  qemu
                  just
                ])
                ++ lib.optionals pkgs.stdenv.isLinux [
                  pkgs.qemu_kvm
                  pkgs.libvirt
                ];
              shellHook = ''
                echo "✅ AOSP/Cuttlefish build shell"
                echo "Make sure KVM + libvirt are installed and the user is in the libvirt group."
              '';
            };
          };
        });
}
