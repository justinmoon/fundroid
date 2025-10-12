{
  description = "webos mac-only dev";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
          config = {
            android_sdk.accept_license = true;
            allowUnfree = true;
          };
        };
        rust = pkgs.rust-bin.stable.latest.default.override {
          targets = [ "x86_64-linux-android" "aarch64-linux-android" ];
          extensions = [ "rust-src" "clippy" "rustfmt" ];
        };
        androidComposition = pkgs.androidenv.composeAndroidPackages {
          includeNDK = true;
          platformVersions = [ "34" ];
          buildToolsVersions = [ "34.0.0" ];
        };
        ndk = "${androidComposition.androidsdk}/libexec/android-sdk/ndk-bundle";
        # Map Nix system to NDK prebuilt directory name
        ndkHost = if pkgs.stdenv.isDarwin then "darwin-x86_64" else "linux-x86_64";
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            rust
            pkgs.android-tools
            pkgs.just
            pkgs.cmake
            pkgs.ninja
            pkgs.pkg-config
          ];
          ANDROID_SDK_ROOT = "${androidComposition.androidsdk}/libexec/android-sdk";
          ANDROID_NDK_HOME = ndk;
          ANDROID_NDK_ROOT = ndk;
          CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER  =
            "${ndk}/toolchains/llvm/prebuilt/${ndkHost}/bin/x86_64-linux-android24-clang";
          CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER =
            "${ndk}/toolchains/llvm/prebuilt/${ndkHost}/bin/aarch64-linux-android24-clang";
        };

        apps.ci = {
          type = "app";
          program = "${pkgs.writeShellScript "ci" ''
            export PATH="${pkgs.lib.makeBinPath [
              rust
              pkgs.android-tools
              pkgs.just
              pkgs.cmake
              pkgs.ninja
              pkgs.pkg-config
            ]}:$PATH"
            export ANDROID_SDK_ROOT="${androidComposition.androidsdk}/libexec/android-sdk"
            export ANDROID_NDK_HOME="${ndk}"
            export ANDROID_NDK_ROOT="${ndk}"
            export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="${ndk}/toolchains/llvm/prebuilt/${ndkHost}/bin/x86_64-linux-android24-clang"
            export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${ndk}/toolchains/llvm/prebuilt/${ndkHost}/bin/aarch64-linux-android24-clang"
            exec ${./scripts/ci.sh}
          ''}";
        };
      });
}
