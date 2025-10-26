# SPDX-License-Identifier: MIT
# Build Cuttlefish host tools from AOSP
# Inspired by robotnix: https://github.com/nix-community/robotnix

{ config, pkgs, lib, ... }:

let
  # AOSP build environment packages
  # From robotnix modules/envpackages.nix and build/soong/ui/build/paths/config.go
  aospBuildPackages = with pkgs; [
    bc
    git
    gnumake
    jdk17_headless
    lsof
    m4
    ncurses5
    libxcrypt-legacy
    openssl
    psmisc
    rsync
    unzip
    zip
    util-linux
    nettools
    procps
    freetype
    fontconfig
    python3
    ccache
    ninja
    cmake
    gcc
    gperf
    flex
    bison
    pkg-config
    libxml2
    libxslt
    zstd
    lzop
    curl
    which
    perl
    file
    nasm
    gawk
    coreutils
    diffutils
    findutils
    bashInteractive
  ];

  # FHS build environment for AOSP
  # AOSP expects a traditional Linux filesystem layout
  aospBuildEnv = pkgs.buildFHSEnv {
    name = "aosp-build";
    targetPkgs = pkgs: aospBuildPackages;
    multiPkgs = pkgs: with pkgs; [ zlib ];
    profile = ''
      export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/lib:/usr/lib64
      export USE_CCACHE=1
      export CCACHE_DIR=/var/lib/aosp/ccache
      # Android 11+ ninja filters env vars - this allows them through
      export ALLOW_NINJA_ENV=true
    '';
  };

  # AOSP source directory (impure reference - already synced on VM)
  aospSourceDir = "/home/justin/aosp";

  # Patch script for Bluetooth headless support
  bluetoothPatch = pkgs.writeScript "apply-bluetooth-patch.py" ''
    #!${pkgs.python3}/bin/python3
    import sys
    import os
    import shutil
    
    FILE_PATH = "${aospSourceDir}/device/google/cuttlefish/host/commands/run_cvd/boot_state_machine.cc"
    
    # Backup original if not already backed up
    if not os.path.exists(FILE_PATH + ".original"):
        shutil.copy(FILE_PATH, FILE_PATH + ".original")
    else:
        # Restore from original backup for idempotency
        shutil.copy(FILE_PATH + ".original", FILE_PATH)
    
    with open(FILE_PATH, 'r') as f:
        lines = f.readlines()
    
    # 1. Add CuttlefishConfig to constructor
    for i, line in enumerate(lines):
        if 'INJECT(CvdBootStateMachine(ProcessLeader& process_leader,' in line:
            lines[i] = '  INJECT(CvdBootStateMachine(const CuttlefishConfig& config,\n'
            lines.insert(i+1, '                             ProcessLeader& process_leader,\n')
            lines[i+2] = '                             KernelLogPipeProvider& kernel_log_pipe_provider))\n'
            lines[i+3] = '      : config_(config),\n'
            lines.insert(i+4, '        process_leader_(process_leader),\n')
            break
    
    # 2. Add config_ member variable  
    for i, line in enumerate(lines):
        if 'ProcessLeader& process_leader_;' in line:
            lines.insert(i, '  const CuttlefishConfig& config_;\n')
            break
    
    # 3. Patch BootFailed handler
    for i, line in enumerate(lines):
        if ('} else if (read_result->event == monitor::Event::BootFailed)' in line and
            'Virtual device failed to boot' in lines[i+1] and
            'state_ |= kGuestBootFailed' in lines[i+2]):
            indent = '      '
            new_block = [
                line,
                f'{indent}// Skip Bluetooth failures in headless mode (patched)\n',
                f'{indent}bool is_bluetooth_failure = false;\n',
                f'{indent}if (read_result->metadata.isMember("message")) {{\n',
                f'{indent}  std::string msg = read_result->metadata["message"].asString();\n',
                f'{indent}  is_bluetooth_failure = (msg.find("Bluetooth") != std::string::npos);\n',
                f'{indent}}}\n',
                f'{indent}if (!config_.enable_host_bluetooth() && is_bluetooth_failure) {{\n',
                f'{indent}  LOG(WARNING) << "Bluetooth dependency missing; continuing (headless mode)";\n',
                f'{indent}}} else {{\n',
                lines[i+1], lines[i+2],
                f'{indent}}}\n'
            ]
            lines[i:i+3] = new_block
            break
    
    with open(FILE_PATH, 'w') as f:
        f.writelines(lines)
    
    print("✓ Bluetooth headless patch applied", file=sys.stderr)
  '';

  # Build the cuttlefish host package from AOSP sources
  cuttlefishHostPackage = pkgs.stdenvNoCC.mkDerivation {
    name = "cuttlefish-host-aosp-14085914-bluetooth-headless";
    version = "aosp-14085914-patched";
    
    dontUnpack = true;
    
    nativeBuildInputs = [ aospBuildEnv pkgs.python3 ];
    
    # Build entirely within the sandbox using the FHS environment
    buildPhase = ''
      echo "==> Applying Bluetooth headless patch..."
      ${bluetoothPatch}
      
      echo "==> Building cuttlefish host tools in FHS environment..."
      ${aospBuildEnv}/bin/aosp-build <<'EOF'
      set -e -o pipefail
      cd ${aospSourceDir}
      source build/envsetup.sh
      lunch aosp_cf_x86_64_only_phone-userdebug
      m run_cvd kernel_log_monitor -j''${NIX_BUILD_CORES:-8}
      echo "✓ Build completed"
      EOF
    '';
    
    installPhase = ''
      mkdir -p $out/bin $out/lib64
      
      # Copy host binaries
      cp ${aospSourceDir}/out/host/linux-x86/bin/run_cvd $out/bin/
      cp ${aospSourceDir}/out/host/linux-x86/bin/kernel_log_monitor $out/bin/
      
      # Copy other host tools
      for tool in adb_connector cvd cvd_internal_start cvd_internal_stop \
                  launch_cvd stop_cvd restart_cvd; do
        [ -f ${aospSourceDir}/out/host/linux-x86/bin/$tool ] && \
          cp ${aospSourceDir}/out/host/linux-x86/bin/$tool $out/bin/ || true
      done
      
      # Copy cuttlefish libraries
      cp ${aospSourceDir}/out/host/linux-x86/lib64/libcuttlefish*.so $out/lib64/ || true
    '';
    
    dontFixup = true;
    dontStrip = true;  # Keep debug symbols
    
    # This is impure (depends on /home/justin/aosp) but that's ok for local builds
    __impure = true;
  };

in
{
  # Make the build environment available system-wide for interactive builds
  environment.systemPackages = [ aospBuildEnv ];
}
