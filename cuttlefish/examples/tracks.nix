# Example: Multi-Track Cuttlefish Configuration
#
# To enable multi-track support:
# 1. Uncomment the services.cuttlefish section in configuration.nix
# 2. Import this file or copy its content
# 3. Run: just hetzner
# 4. Use: CF_TRACK=<name> cfenv run_cvd ...
#
# See MULTI_TRACK_CUTTLEFISH.md for full documentation

{ config, lib, pkgs, ... }:

let
  mkCuttlefishBundle = pkgs.callPackage ../pkgs/cuttlefish-from-tarball.nix {};
in
{
  services.cuttlefish = {
    enable = true;
    defaultTrack = "stock";
    
    tracks = {
      # Track 1: Stock Google package (stable, default)
      stock = {
        bundle = mkCuttlefishBundle {
          url = "https://justinmoon.com/s/cuttlefish/cvd-host_package.tar.gz";
          sha256 = "sha256-owJJyyFlL0Siqd+jpFuyWqZHI59tdaa35iBMa+n/xNE=";
          version = "aosp-14085914";
        };
      };
      
      # Track 2: AOSP with Bluetooth headless patch (opt-in)
      # Uncomment when ready to test:
      # bluetooth-headless = {
      #   bundle = let
      #     tarball = builtins.path {
      #       path = /var/lib/aosp/artifacts/cvd-host_package-complete.tar.gz;
      #       name = "cvd-host-bluetooth-headless.tar.gz";
      #     };
      #   in pkgs.runCommand "cuttlefish-host-aosp-complete" { src = tarball; } ''
      #     mkdir -p $out/opt/cuttlefish
      #     tar xzf $src -C $out/opt/cuttlefish
      #   '';
      # };
      
      # Track 3: Your custom experiment (template)
      # my-experiment = {
      #   bundle = let
      #     tarball = builtins.path {
      #       path = /var/lib/aosp/artifacts/my-build-$(date).tar.gz;
      #       name = "my-experiment.tar.gz";
      #     };
      #   in pkgs.runCommand "cuttlefish-my-experiment" { src = tarball; } ''
      #     mkdir -p $out/opt/cuttlefish  
      #     tar xzf $src -C $out/opt/cuttlefish
      #   '';
      #   dataDir = "/var/lib/cuttlefish/my-experiment";
      # };
    };
  };
  
  # Usage examples:
  # 
  # Default (stock):
  #   cfenv run_cvd --help
  #   cfctl instance create-start --purpose ci
  #
  # Specific track:
  #   CF_TRACK=bluetooth-headless cfenv run_cvd --help
  #   CF_TRACK=my-experiment cfctl instance create-start --purpose ci
  #
  # Systemd:
  #   systemctl start cuttlefish@stock
  #   systemctl start cuttlefish@bluetooth-headless
  #
  # Concurrent testing:
  #   CF_TRACK=stock cfctl instance create-start ... &
  #   CF_TRACK=my-experiment cfctl instance create-start ... &
}
