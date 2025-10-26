{ lib, stdenvNoCC, pkgs, debs ? [] }:

let
  inherit (lib) assertMsg optionalString concatStringsSep shellQuote;
  sanitizedDebs =
    assert assertMsg (debs != []) "services.cuttlefish.debs must supply at least one .deb file";
    map toString debs;
  debsList = concatStringsSep " " (map shellQuote sanitizedDebs);
in
stdenvNoCC.mkDerivation {
  pname = "cuttlefish-host-deb";
  version = "unstable";

  nativeBuildInputs = [ pkgs.dpkg pkgs.findutils pkgs.coreutils ];

  unpackPhase = "true";

  buildPhase = ''
    runHook preBuild
    mkdir -p "$TMP/extracted"
    for deb in ${debsList}; do
      if [ ! -f "$deb" ]; then
        echo "cuttlefish-from-deb: missing deb file $deb" >&2
        exit 1
      fi
      dpkg -x "$deb" "$TMP/extracted"
    done
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -d "$out/opt/cuttlefish"
    cp -a "$TMP/extracted/." "$out/opt/cuttlefish/"

    cfg_constants="$out/opt/cuttlefish/android-cuttlefish/base/cvd/cuttlefish/host/libs/config/config_constants.h"
    if [ -f "$cfg_constants" ]; then
      echo "Patching default UUID prefix for cuttlefish bundle..." >&2
      substituteInPlace "$cfg_constants" \
        --replace '699acfc4-c8c4-11e7-882b-5065f31dc1' '699acfc4-c8c4-11e7-882b-5065f31dc'
    fi

    mkdir -p "$out/bin"
    cat > "$out/bin/cuttlefish-env" <<'EOF'
    #!/usr/bin/env bash
    set -euo pipefail
    export CUTTLEFISH_ROOT="/opt/cuttlefish"
    export PATH="/opt/cuttlefish/usr/bin:/opt/cuttlefish/bin:''${PATH:-}"
    export LD_LIBRARY_PATH="/opt/cuttlefish/usr/lib:/opt/cuttlefish/usr/lib64:/opt/cuttlefish/lib:/opt/cuttlefish/lib64:''${LD_LIBRARY_PATH:-}"
    exec "$@"
    EOF
    chmod +x "$out/bin/cuttlefish-env"
    runHook postInstall
  '';

  meta = with lib; {
    description = "Cuttlefish host utilities unpacked from Debian packages";
    platforms = platforms.linux;
    license = licenses.unfreeRedistributable;
  };
}
