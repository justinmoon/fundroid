{
  description = "webos mac-only dev";

  nixConfig = {
    "env.NIX_CURL_FLAGS" = "--retry 15 --retry-all-errors --retry-delay 5";
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
    android-nixpkgs.url = "github:tadfisher/android-nixpkgs";
    cuttlefish.url = "path:./cuttlefish";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, flake-utils, rust-overlay, android-nixpkgs, cuttlefish }:
    {
      # Export cuttlefish NixOS modules
      nixosModules = cuttlefish.nixosModules;
    } //
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            rust-overlay.overlays.default
            android-nixpkgs.overlays.default
          ];
          config = {
            allowUnfree = true;
          };
        };

        pkgs-unstable = import nixpkgs-unstable {
          inherit system;
          config = {
            allowUnfree = true;
          };
        };

        rust = pkgs.rust-bin.stable.latest.default.override {
          targets = [ "x86_64-linux-android" "aarch64-linux-android" "x86_64-unknown-linux-musl" ];
          extensions = [ "rust-src" "clippy" "rustfmt" ];
        };

        androidSdkEnv = pkgs.androidSdk (sdkPkgs:
          let
            systemImage =
              if pkgs.stdenv.isDarwin && pkgs.stdenv.isAarch64 then
                sdkPkgs.system-images-android-34-default-arm64-v8a
              else
                sdkPkgs.system-images-android-34-default-x86-64;
          in
          with sdkPkgs; [
            cmdline-tools-latest
            build-tools-34-0-0
            emulator
            ndk-26-3-11579264
            platform-tools
            platforms-android-34
            systemImage
          ]);

        androidSdkStorePath = "${androidSdkEnv}/share/android-sdk";
      in {
        # Export cuttlefish packages (Linux only)
        packages = if pkgs.stdenv.isLinux then {
          inherit (cuttlefish.packages.${system}) cfctl;
          weston-rootfs = pkgs.callPackage ./qemu-init/nix/weston-rootfs.nix {};
          
          # Custom kernel with virtio-gpu and virtio-input support
          qemu-kernel = pkgs.callPackage ./qemu-init/nix/kernel.nix {};
        } else {};
        
        devShells.default = pkgs.mkShell {
          packages = [
            rust
            pkgs.just
            pkgs.cmake
            pkgs.ninja
            pkgs.pkg-config
            pkgs.rsync
            pkgs.jdk17_headless
            pkgs.unzip
            pkgs.python3
            pkgs.e2fsprogs
            pkgs.android-tools
            pkgs.fakeroot
            pkgs.lz4
            androidSdkEnv
            # QEMU init learning environment
            pkgs-unstable.zig  # Use latest Zig from unstable
            pkgs.qemu
            # Note: kernel can't be built on macOS, we download pre-built instead
            # Note: libdrm for drm_rect.zig only available on Linux
          ];
          shellHook = ''
            export JAVA_HOME="${pkgs.jdk17_headless}"
            export PATH="$JAVA_HOME/bin:$PATH"

            export ANDROID_SDK_ROOT="${androidSdkStorePath}"
            export ANDROID_HOME="$ANDROID_SDK_ROOT"
            export ANDROID_USER_HOME="$HOME/.android"
            export ANDROID_AVD_HOME="$ANDROID_USER_HOME/avd"
            unset ANDROID_PREFS_ROOT
            unset ANDROID_SDK_HOME

            if [ -d "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin" ]; then
              export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH"
            elif [ -d "$ANDROID_SDK_ROOT/cmdline-tools/13.0/bin" ]; then
              export PATH="$ANDROID_SDK_ROOT/cmdline-tools/13.0/bin:$PATH"
            fi
            export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH"

            if [ -d "$ANDROID_SDK_ROOT/ndk" ]; then
              ndk_dir="$(find "$ANDROID_SDK_ROOT/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1)"
              if [ -n "$ndk_dir" ]; then
                export ANDROID_NDK_HOME="$ndk_dir"
                export ANDROID_NDK_ROOT="$ndk_dir"
                host_tag="$(ls "$ndk_dir/toolchains/llvm/prebuilt" 2>/dev/null | sort | tail -n1)"
                if [ -n "$host_tag" ]; then
                  export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$ndk_dir/toolchains/llvm/prebuilt/$host_tag/bin/x86_64-linux-android24-clang"
                  export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$ndk_dir/toolchains/llvm/prebuilt/$host_tag/bin/aarch64-linux-android24-clang"
                fi
              fi
            fi
          '';
        };

        apps.ci = {
          type = "app";
          program = let
            script = pkgs.writeShellScript "ci" ''
              export PATH="${pkgs.lib.makeBinPath [
                rust
                pkgs.just
                pkgs.cmake
                pkgs.ninja
                pkgs.pkg-config
                pkgs.openssh
                pkgs.gcc
                pkgs.jdk17_headless
                pkgs.unzip
                pkgs.python3
                pkgs.e2fsprogs
                pkgs.android-tools
                pkgs.fakeroot
                pkgs.lz4
              ]}:$PATH"

              export JAVA_HOME="${pkgs.jdk17_headless}"
              export PATH="$JAVA_HOME/bin:$PATH"

              export ANDROID_SDK_ROOT="${androidSdkStorePath}"
              export ANDROID_HOME="$ANDROID_SDK_ROOT"
              export ANDROID_USER_HOME="$HOME/.android"
              export ANDROID_AVD_HOME="$ANDROID_USER_HOME/avd"
              export ANDROID_PREFS_ROOT="$ANDROID_USER_HOME"
              unset ANDROID_SDK_HOME

              if [ -d "$ANDROID_SDK_ROOT/platform-tools" ]; then
                export PATH="$ANDROID_SDK_ROOT/platform-tools:$PATH"
              fi

              if [ -d "$ANDROID_SDK_ROOT/ndk" ]; then
                ndk_dir="$(find "$ANDROID_SDK_ROOT/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1)"
                if [ -n "$ndk_dir" ]; then
                  export ANDROID_NDK_HOME="$ndk_dir"
                  export ANDROID_NDK_ROOT="$ndk_dir"
                  host_tag="$(ls "$ndk_dir/toolchains/llvm/prebuilt" 2>/dev/null | sort | tail -n1)"
                  if [ -n "$host_tag" ]; then
                    export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$ndk_dir/toolchains/llvm/prebuilt/$host_tag/bin/x86_64-linux-android24-clang"
                    export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$ndk_dir/toolchains/llvm/prebuilt/$host_tag/bin/aarch64-linux-android24-clang"
                  fi
                fi
              fi

              exec ${./scripts/ci.sh}
            '';
          in "${script}";
        };
      });
}
