{ lib, pkgs, cuttlefishBundle, trackName ? null }:

let
  # Package name includes track, but binary name is always cuttlefish-fhs for consistency
  fhsName = if trackName != null then "cuttlefish-fhs-${trackName}" else "cuttlefish-fhs";
  
  entrypoint = pkgs.writeShellScript "cuttlefish-fhs-entry" ''
    set -euo pipefail
    export CUTTLEFISH_ROOT="/opt/cuttlefish"
    export PATH="/opt/cuttlefish/usr/bin:/opt/cuttlefish/bin:''${PATH:-}"
    export LD_LIBRARY_PATH="/opt/cuttlefish/usr/lib:/opt/cuttlefish/usr/lib64:/opt/cuttlefish/lib:/opt/cuttlefish/lib64:''${LD_LIBRARY_PATH:-}"
    
    # Track-specific HOME (allows concurrent tracks with separate data dirs)
    export HOME="''${CUTTLEFISH_HOME:-/var/lib/cuttlefish}"
    
    exec "$@"
  '';

  # Base FHS environment without cap modifications
  baseFHS = pkgs.buildFHSEnvBubblewrap {
    name = "${fhsName}-unwrapped";

  targetPkgs = pkgs': with pkgs'; [
    coreutils
    findutils
    procps
    util-linux
    bash
    psmisc        # provides fuser for stop_cvd fallback
    lsof          # used by cleanup tooling
    iproute2
    iptables
    qemu_kvm
    seabios
    openssh
    openssl
    nftables
    alsa-lib
    libpulseaudio
    wayland
    expat
    python3
    which
    libdrm        # Required by QEMU
  ];

  extraBindMounts = [
    { source = "${cuttlefishBundle}/opt"; target = "/opt"; recursive = true; }
    { source = "/dev/kvm"; target = "/dev/kvm"; optional = true; }
    { source = "/dev/net/tun"; target = "/dev/net/tun"; optional = true; }
    { source = "${pkgs.qemu_kvm}/share/qemu"; target = "/usr/share/qemu"; recursive = true; optional = true; }
    { source = "${pkgs.seabios}/share/seabios"; target = "/usr/share/seabios"; recursive = true; optional = true; }
  ];

  extraBuildCommands = ''
    # Pin the bundle to force hash change when bundle changes
    ln -s ${cuttlefishBundle} $out/.bundle-pin
    
    mkdir -p $out/usr/lib64/cuttlefish-common/bin
    cat > $out/usr/lib64/cuttlefish-common/bin/capability_query.py <<'EOF'
#!/usr/bin/env python3

import sys


def main():
    capabilities = {"capability_check", "qemu_cli", "vsock"}
    if len(sys.argv) == 1:
        print("\n".join(capabilities))
    else:
        query = set(sys.argv[1:])
        sys.exit(len(query - capabilities))


if __name__ == "__main__":
    main()
EOF
    chmod +x $out/usr/lib64/cuttlefish-common/bin/capability_query.py
  '';

    runScript = entrypoint;
  };

in
# Patch the generated FHS script to add --cap-add cap_net_admin to bubblewrap
# This grants CAP_NET_ADMIN inside the namespace so QEMU can configure TAP devices
# Bubblewrap is setuid, so it can grant capabilities even when invoked by unprivileged user
pkgs.runCommand fhsName {} ''
  mkdir -p $out/bin
  cp ${baseFHS}/bin/${fhsName}-unwrapped $out/bin/${fhsName}
  chmod +w $out/bin/${fhsName}
  
  # Inject --cap-add cap_net_admin right after the bwrap executable path
  substituteInPlace $out/bin/${fhsName} \
    --replace '/bin/bwrap' '/bin/bwrap --cap-add cap_net_admin'
  
  chmod +x $out/bin/${fhsName}
''
