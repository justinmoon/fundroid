{
  description = "Cuttlefish Android Virtual Device Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      # Packages
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          # cfctl CLI and daemon
          cfctl = pkgs.callPackage ./packages/cfctl.nix { };
          
          # Cuttlefish bundle builders
          mkCuttlefishFromTarball = pkgs.callPackage ./packages/cuttlefish-from-tarball.nix { };
          mkCuttlefishFromDeb = pkgs.callPackage ./packages/cuttlefish-from-deb.nix { };
          
          # FHS wrapper builder (requires a bundle)
          # Users should call this with their bundle: mkCuttlefishFHS { cuttlefishBundle = ...; }
          mkCuttlefishFHS = pkgs.callPackage ./packages/cuttlefish-fhs.nix;
          
          # AOSP host builder (impure - requires AOSP checkout on build machine)
          aosp-host = pkgs.callPackage ./packages/aosp-host.nix { };
          
          # Default package is cfctl
          default = self.packages.${system}.cfctl;
        });

      # NixOS modules
      nixosModules = {
        cuttlefish = { config, lib, pkgs, ... }: {
          imports = [ ./modules/cuttlefish-module.nix ];
          
          # Override callPackage paths in the module to use our packages
          config = lib.mkIf config.services.cuttlefish.enable {
            nixpkgs.overlays = [
              (final: prev: {
                # Make our cuttlefish package builders available
                mkCuttlefishFromTarball = self.packages.${prev.system}.mkCuttlefishFromTarball;
                mkCuttlefishFromDeb = self.packages.${prev.system}.mkCuttlefishFromDeb;
                mkCuttlefishFHS = self.packages.${prev.system}.mkCuttlefishFHS;
              })
            ];
          };
        };
        
        default = self.nixosModules.cuttlefish;
      };

      # Development shells
      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              rustc
              cargo
              clippy
              rustfmt
              rust-analyzer
            ];
            
            shellHook = ''
              echo "Cuttlefish development environment"
              echo "Build cfctl: nix build .#cfctl"
              echo "Run cfctl: nix run .#cfctl -- --help"
            '';
          };
        });
    };
}
