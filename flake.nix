{
  description = "webos dev env (macOS + Linux)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ]
      (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };

          rustToolchain =
            # Rust with Android std targets baked in
            (pkgs.rust-bin.selectLatestNightlyWith (toolchain: toolchain.default.override {
              targets = [ "aarch64-linux-android" "x86_64-linux-android" ];
              extensions = [ "rust-src" "clippy" "rustfmt" ];
            }));

          common = with pkgs; [
            rustToolchain
            pkg-config cmake ninja git git-lfs jq unzip zip which
            openssl cacert
            android-tools         # adb/fastboot
            androidenv.androidPkgs.ndk-bundle # NDK
            llvmPackages.clang llvmPackages.lld
            just                  # task runner
          ];
        in {
          devShells = {
            # macOS shell: cross-compile Rust → Android; use 'adb' locally.
            default = pkgs.mkShell {
              packages = common;
              ANDROID_NDK_HOME = "${pkgs.androidenv.androidPkgs.ndk-bundle}/libexec/android-sdk/ndk-bundle";
              ANDROID_NDK_ROOT = "${pkgs.androidenv.androidPkgs.ndk-bundle}/libexec/android-sdk/ndk-bundle";
              shellHook = ''
                echo "✅ webos devshell ready"
                echo "Targets: aarch64-linux-android, x86_64-linux-android"

                # Set up cargo linkers for Android targets
                export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android24-clang"
                export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/x86_64-linux-android24-clang"

                just --list 2>/dev/null || true
              '';
            };

            # Linux shell for building AOSP + running Cuttlefish
            aosp = pkgs.mkShell {
              packages = with pkgs; [
                git python3 openjdk17 go # JDK and Go for AOSP
                gperf libxml2 zip unzip rsync curl bc bison flex
                ninja cmake gn ccache file
                android-tools qemu
                gnumake m4 # Additional build tools
              ];
              shellHook = ''
                echo "✅ AOSP/Cuttlefish build shell"
                echo "Install/enable KVM+libvirt on the host (outside Nix) before running CF."
                echo ""
                echo "Note: Install 'repo' tool separately:"
                echo "  mkdir -p ~/.bin"
                echo "  curl https://storage.googleapis.com/git-repo-downloads/repo > ~/.bin/repo"
                echo "  chmod a+x ~/.bin/repo"
                echo "  export PATH=~/.bin:\$PATH"
              '';
            };
          };
        });
}
