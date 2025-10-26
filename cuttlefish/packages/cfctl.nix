{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "cfctl";
  version = "0.2.0";  # Bumped for multi-track support

  src = lib.cleanSourceWith {
    src = ../cfctl;
    filter = path: _type: !lib.hasInfix "/target/" (toString path);
  };

  cargoLock.lockFile = ../cfctl/Cargo.lock;
  cargoBuildFlags = [ "--bin" "cfctl" "--bin" "cfctl-daemon" ];
  doCheck = false;
}
