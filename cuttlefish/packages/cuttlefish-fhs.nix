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

  # Base FHS environment
  baseFHS = pkgs.buildFHSEnvBubblewrap {
  name = fhsName;

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
# Wrap the base FHS to replace bwrap path and add capability support
pkgs.runCommand fhsName {
  inherit (baseFHS) meta;
  passthru = baseFHS.passthru or {};
} ''
  mkdir -p $out/bin
  
  # Copy or link everything from base FHS
  for item in ${baseFHS}/*; do
    if [ "$(basename "$item")" != "bin" ]; then
      ln -s "$item" $out/
    fi
  done
  
  # Process bin directory
  if [ -d "${baseFHS}/bin" ]; then
    for item in ${baseFHS}/bin/*; do
      target="$out/bin/$(basename "$item")"
      
      # If it's a script file, modify it
      if [ -f "$item" ] && head -n1 "$item" | grep -q '^#!'; then
        cp "$item" "$target"
        chmod +w "$target"
        
        # Replace nix store bwrap path with system wrapper  
        sed -i 's|/nix/store/[^/]*/bin/bwrap|/run/wrappers/bin/bwrap|g' "$target"
        
        # Add CUTTLEFISH_BWRAP_CAPS support
        ${pkgs.python3}/bin/python3 - "$target" <<'PY'
import sys
from pathlib import Path
import re

script_path = Path(sys.argv[1])
lines = script_path.read_text().splitlines()

# Find the cmd array closing and exec line
cmd_start = None
cmd_close = None
exec_line = None

for idx, line in enumerate(lines):
    if line.startswith("cmd=("):
        cmd_start = idx
    elif cmd_start is not None and cmd_close is None and line.strip() == ")":
        cmd_close = idx
    elif line.startswith("exec \"") and "cmd[@]" in line:
        exec_line = idx
        break

if exec_line is None or cmd_start is None or cmd_close is None:
    # Script doesn't have the expected pattern, skip modification
    sys.exit(0)

# Insert capability handling code before exec
# We need to modify the cmd array construction to insert caps before the last element
snippet = [
    "",
    "# Add capability arguments before the wrapped command",
    "if [ -n \"''${CUTTLEFISH_BWRAP_CAPS:-}\" ]; then",
    "  if [[ -u \"''${cmd[0]}\" ]]; then",
    "    # Get the last element (wrapped command)",
    "    last_idx=$((''${#cmd[@]} - 1))",
    "    last_elem=\"''${cmd[$last_idx]}\"",
    "    # Remove last element",
    "    unset 'cmd[$last_idx]'",
    "    # Add capability args",
    "    # shellcheck disable=SC2206 -- splitting is intentional for cap fragments",
    "    cmd+=( ''${CUTTLEFISH_BWRAP_CAPS} )",
    "    # Re-add last element",
    "    cmd+=(\"$last_elem\")",
    "  else",
    "    echo \"cuttlefish-fhs: skipping CUTTLEFISH_BWRAP_CAPS; ''${cmd[0]} lacks setuid\" >&2",
    "  fi",
    "fi",
    "",
]

lines[exec_line:exec_line] = snippet
script_path.write_text("\n".join(lines) + "\n")
PY
        
        chmod +x "$target"
      else
        # Just symlink non-script files
        ln -s "$item" "$target"
      fi
    done
  fi
''
