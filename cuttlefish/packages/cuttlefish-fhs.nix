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

script_path = Path(sys.argv[1])
lines = script_path.read_text().splitlines()

# Find the exec line
exec_line = None
for idx, line in enumerate(lines):
    if line.startswith("exec \"") and "cmd[@]" in line:
        exec_line = idx
        break

if exec_line is None:
    # Script doesn't have the expected pattern, skip modification
    sys.exit(0)

# Insert capability handling code before exec
# We need to find container-init and insert caps BEFORE it
snippet = [
    "",
    "# Add capability arguments before container-init (so bwrap sees them)",
    "if [[ -n ''${CUTTLEFISH_BWRAP_CAPS:-} && -u ''${cmd[0]} ]]; then",
    "  # Locate the container-init element",
    "  ci_idx=-1",
    "  for i in \"''${!cmd[@]}\"; do",
    "    [[ ''${cmd[$i]} == /nix/store/*-container-init ]] && { ci_idx=$i; break; }",
    "  done",
    "",
    "  if (( ci_idx != -1 )); then",
    "    # Split caps safely into words",
    "    read -r -a __caps <<<\"''${CUTTLEFISH_BWRAP_CAPS}\"",
    "    # Rebuild argv: [bwrap ... <caps> container-init \"$@\"]",
    "    set -- \"''${cmd[@]:0:ci_idx}\" \"''${__caps[@]}\" \"''${cmd[@]:ci_idx}\"",
    "",
    "    # Optional tracing",
    "    if [[ -n ''${CUTTLEFISH_BWRAP_TRACE:-} ]]; then",
    "      for j in \"$@\"; do printf 'argv: %q\\n' \"$j\"; done >&2",
    "    fi",
    "",
    "    exec \"$@\"",
    "  else",
    "    echo \"cuttlefish-fhs: container-init not found; not injecting caps\" >&2",
    "  fi",
    "fi",
    "",
    "# Fallback: original path",
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
