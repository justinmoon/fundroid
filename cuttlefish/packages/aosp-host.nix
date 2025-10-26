# Standalone builder for AOSP cuttlefish host package
# Usage: nix-build hetzner/build-aosp-host.nix
#
# This builds the patched cuttlefish host tools and stores them in /nix/store
# Subsequent builds will use the cached version unless sources change

{ pkgs ? import <nixpkgs> {} }:

let
  # AOSP source directory on the build machine  
  aospSourceDir = "/home/justin/aosp";
  
  # AOSP build environment packages
  aospBuildPackages = with pkgs; [
    bc git gnumake jdk17_headless lsof m4 ncurses5 libxcrypt-legacy
    openssl psmisc rsync unzip zip util-linux nettools procps freetype
    fontconfig python3 ccache ninja cmake gcc gperf flex bison pkg-config
    libxml2 libxslt zstd lzop curl which perl file nasm gawk coreutils
    diffutils findutils bashInteractive
  ];
  
  # FHS build environment for AOSP
  aospBuildEnv = pkgs.buildFHSEnv {
    name = "aosp-build";
    targetPkgs = pkgs: aospBuildPackages;
    multiPkgs = pkgs: with pkgs; [ zlib ];
    profile = ''
      export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/lib:/usr/lib64
      export USE_CCACHE=1
      export CCACHE_DIR=/var/lib/aosp/ccache
      export ALLOW_NINJA_ENV=true
    '';
  };
  
  # Bluetooth headless patch
  bluetoothPatch = pkgs.writeScript "patch-bluetooth.py" ''
    #!${pkgs.python3}/bin/python3
    import sys, os, shutil
    
    FILE = "${aospSourceDir}/device/google/cuttlefish/host/commands/run_cvd/boot_state_machine.cc"
    
    if not os.path.exists(FILE + ".original"):
        shutil.copy(FILE, FILE + ".original")
    else:
        shutil.copy(FILE + ".original", FILE)
    
    with open(FILE) as f:
        lines = f.readlines()
    
    # Add CuttlefishConfig to constructor
    for i, line in enumerate(lines):
        if 'INJECT(CvdBootStateMachine(ProcessLeader& process_leader,' in line:
            lines[i] = '  INJECT(CvdBootStateMachine(const CuttlefishConfig& config,\n'
            lines.insert(i+1, '                             ProcessLeader& process_leader,\n')
            lines[i+2] = '                             KernelLogPipeProvider& kernel_log_pipe_provider))\n'
            lines[i+3] = '      : config_(config),\n'
            lines.insert(i+4, '        process_leader_(process_leader),\n')
            break
    
    # Add config_ member
    for i, line in enumerate(lines):
        if 'ProcessLeader& process_leader_;' in line:
            lines.insert(i, '  const CuttlefishConfig& config_;\n')
            break
    
    # Patch BootFailed handler
    for i, line in enumerate(lines):
        if ('} else if (read_result->event == monitor::Event::BootFailed)' in line and
            'Virtual device failed to boot' in lines[i+1] and  
            'state_ |= kGuestBootFailed' in lines[i+2]):
            indent = '      '
            new_block = [
                line,
                f'{indent}// Skip Bluetooth failures in headless mode\n',
                f'{indent}bool is_bt_fail = false;\n',
                f'{indent}if (read_result->metadata.isMember("message")) {{\n',
                f'{indent}  auto msg = read_result->metadata["message"].asString();\n',
                f'{indent}  is_bt_fail = msg.find("Bluetooth") != std::string::npos;\n',
                f'{indent}}}\n',
                f'{indent}if (!config_.enable_host_bluetooth() && is_bt_fail) {{\n',
                f'{indent}  LOG(WARNING) << "BT dependency missing (headless mode)";\n',
                f'{indent}}} else {{\n',
                lines[i+1], lines[i+2],
                f'{indent}}}\n'
            ]
            lines[i:i+3] = new_block
            break
    
    with open(FILE, 'w') as f:
        f.writelines(lines)
    
    print("✓ Patched", file=sys.stderr)
  '';

in pkgs.stdenvNoCC.mkDerivation rec {
  pname = "cuttlefish-host-aosp";
  version = "14085914-bluetooth-headless";
  
  dontUnpack = true;
  
  nativeBuildInputs = [ aospBuildEnv pkgs.python3 ];
  
  buildPhase = ''
    echo "==> Applying Bluetooth headless patch..."
    ${bluetoothPatch}
    
    echo "==> Building AOSP cuttlefish host tools..."
    ${aospBuildEnv}/bin/aosp-build <<'BUILDEOF'
    set -euo pipefail
    cd ${aospSourceDir}
    source build/envsetup.sh
    lunch aosp_cf_x86_64_only_phone-userdebug
    m run_cvd kernel_log_monitor -j''${NIX_BUILD_CORES:-8}
    BUILDEOF
  '';
  
  installPhase = ''
    mkdir -p $out/bin $out/lib64
    
    # Main executables
    cp ${aospSourceDir}/out/host/linux-x86/bin/{run_cvd,kernel_log_monitor} $out/bin/
    
    # Supporting tools
    for tool in adb_connector cvd cvd_internal_{start,stop} launch_cvd stop_cvd; do
      [ -f ${aospSourceDir}/out/host/linux-x86/bin/$tool ] && \
        cp ${aospSourceDir}/out/host/linux-x86/bin/$tool $out/bin/ || true
    done
    
    # Libraries
    cp ${aospSourceDir}/out/host/linux-x86/lib64/libcuttlefish*.so $out/lib64/ 2>/dev/null || true
    
    echo "✓ Installed to $out"
  '';
  
  dontFixup = true;
  dontStrip = true;
  
  # NOTE: This derivation is impure - it depends on /home/justin/aosp existing
  # on the build machine. It won't work on arbitrary Nix builders.
  # The Nix store will cache the result, so rebuilds are fast.
  
  meta = {
    description = "Custom AOSP cuttlefish host package with Bluetooth headless patch";
    platforms = [ "x86_64-linux" ];
  };
}
