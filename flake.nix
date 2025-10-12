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
        # Lightweight composition for CI: just NDK and build tools
        androidCompositionCI = pkgs.androidenv.composeAndroidPackages {
          includeNDK = true;
          platformVersions = [ "34" ];
          buildToolsVersions = [ "34.0.0" ];
        };
        # Full composition for dev: includes emulator and system images
        androidComposition = pkgs.androidenv.composeAndroidPackages {
          includeNDK = true;
          includeEmulator = true;
          includeSources = false;
          includeSystemImages = true;
          systemImageTypes = [ "default" ];
          abiVersions = [ "arm64-v8a" "x86_64" ];
          platformVersions = [ "34" ];
          buildToolsVersions = [ "34.0.0" ];
        };
        ndk = "${androidComposition.androidsdk}/libexec/android-sdk/ndk-bundle";
        # Map Nix system to NDK prebuilt directory name
        ndkHost = if pkgs.stdenv.isDarwin then "darwin-x86_64" else "linux-x86_64";
        androidSdk = "${androidComposition.androidsdk}/libexec/android-sdk";
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
          ANDROID_SDK_ROOT = androidSdk;
          ANDROID_HOME = androidSdk;
          ANDROID_NDK_HOME = ndk;
          ANDROID_NDK_ROOT = ndk;
          CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER  =
            "${ndk}/toolchains/llvm/prebuilt/${ndkHost}/bin/x86_64-linux-android24-clang";
          CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER =
            "${ndk}/toolchains/llvm/prebuilt/${ndkHost}/bin/aarch64-linux-android24-clang";
          shellHook = ''
            export PATH="${androidSdk}/cmdline-tools/latest/bin:${androidSdk}/emulator:${androidSdk}/platform-tools:$PATH"
          '';
        };

        apps.ci = {
          type = "app";
          program = let
            ndkCI = "${androidCompositionCI.androidsdk}/libexec/android-sdk/ndk-bundle";
          in "${pkgs.writeShellScript "ci" ''
            export PATH="${pkgs.lib.makeBinPath [
              rust
              pkgs.android-tools
              pkgs.just
              pkgs.cmake
              pkgs.ninja
              pkgs.pkg-config
            ]}:$PATH"
            export ANDROID_SDK_ROOT="${androidCompositionCI.androidsdk}/libexec/android-sdk"
            export ANDROID_NDK_HOME="${ndkCI}"
            export ANDROID_NDK_ROOT="${ndkCI}"
            export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="${ndkCI}/toolchains/llvm/prebuilt/${ndkHost}/bin/x86_64-linux-android24-clang"
            export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${ndkCI}/toolchains/llvm/prebuilt/${ndkHost}/bin/aarch64-linux-android24-clang"
            exec ${./scripts/ci.sh}
          ''}";
        };
      });
}
