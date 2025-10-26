{ lib, stdenvNoCC, fetchurl }:

{ url, sha256, version }:

stdenvNoCC.mkDerivation {
  pname = "cuttlefish-host";
  inherit version;

  src = fetchurl {
    inherit url sha256;
  };

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/opt/cuttlefish
    tar xzf $src -C $out/opt/cuttlefish --strip-components=0
  '';

  meta = with lib; {
    description = "Cuttlefish host utilities from tarball";
    platforms = platforms.linux;
    license = licenses.unfreeRedistributable;
  };
}
