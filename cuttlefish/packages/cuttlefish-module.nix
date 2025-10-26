{ lib, pkgs, config, ... }:

let
  inherit (lib) mkEnableOption mkOption types mkIf optionalString escapeShellArgs;
  cfg = config.services.cuttlefish;
in {
  options.services.cuttlefish = {
    enable = mkEnableOption "Cuttlefish host services";

    defaultTrack = mkOption {
      type = types.str;
      default = "default";
      description = "Default track to use when CF_TRACK not specified";
    };

    tracks = mkOption {
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          bundle = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "Pre-built cuttlefish bundle package";
          };
          
          debs = mkOption {
            type = types.listOf types.path;
            default = [];
            description = "Debian packages to build bundle from";
          };
          
          package = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "Override FHS package entirely";
          };
          
          dataDir = mkOption {
            type = types.path;
            default = "/var/lib/cuttlefish/${name}";
            description = "Data directory for this track";
          };
          
          command = mkOption {
            type = types.listOf types.str;
            default = [ "cvd" "start" "--daemon" ];
            description = "Command to run";
          };
          
          extraArgs = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Additional arguments";
          };
          
          fetchCommand = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
            description = "Optional fetch command";
          };
          
          environment = mkOption {
            type = types.attrsOf types.str;
            default = {};
            description = "Environment variables";
          };
        };
      }));
      default = {};
      description = "Named cuttlefish tracks with different bundles";
    };

    # Legacy single-track options (for backward compatibility)
    debs = mkOption {
      type = types.listOf types.path;
      default = [];
      description = ''
        Local `.deb` files providing the Cuttlefish host stack (for example
        `cuttlefish-base` and `cuttlefish-user`). These archives are unpacked
        into the execution environment. All files must be present on the
        deployment host.
      '';
    };

    bundle = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = ''
        Optional pre-built bundle (as produced by `cuttlefish-from-deb.nix`).
        When set, {option}`services.cuttlefish.debs` is ignored.
      '';
    };

    package = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = ''
        Override the FHS execution wrapper. By default a wrapper is created
        automatically from the supplied bundle or debs.
      '';
    };

    command = mkOption {
      type = types.listOf types.str;
      default = [ "cvd" "start" "--daemon" ];
      description = "Base command executed inside the Cuttlefish environment.";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional arguments appended to the command.";
    };

    fetchCommand = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = ''
        Optional command executed before service start (commonly `cvd fetch ...`)
        using the same FHS environment as the main service.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "cuttlefish";
      description = "System user that runs the service.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/cuttlefish";
      description = "Persistent working directory for Cuttlefish.";
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Environment variables set for the systemd service.";
    };
  };

  config = mkIf cfg.enable (
    let
      # Check if using legacy single-track mode or new multi-track mode
      useLegacyMode = cfg.tracks == {};
      
      # Build FHS package for a track
      buildTrackFHS = name: trackCfg:
        if trackCfg.package != null then trackCfg.package
        else 
          let
            bundle = 
              if trackCfg.bundle != null then trackCfg.bundle
              else pkgs.callPackage ./cuttlefish-from-deb.nix { debs = trackCfg.debs; };
          in pkgs.callPackage ./cuttlefish-fhs.nix { 
            cuttlefishBundle = bundle;
            trackName = name;
          };
      
      # Legacy single-track setup (backward compatible)
      baseBundle =
        if cfg.bundle != null then cfg.bundle
        else pkgs.callPackage ./cuttlefish-from-deb.nix { debs = cfg.debs; };

      fhsPackage =
        if cfg.package != null then cfg.package
        else pkgs.callPackage ./cuttlefish-fhs.nix { cuttlefishBundle = baseBundle; };

      commandLine = cfg.command ++ cfg.extraArgs;
      execCmd = escapeShellArgs ([ "${fhsPackage}/bin/cuttlefish-fhs" ] ++ commandLine);
      fetchCmd =
        optionalString (cfg.fetchCommand != null)
          (escapeShellArgs ([ "${fhsPackage}/bin/cuttlefish-fhs" ] ++ cfg.fetchCommand));
      
      # Multi-track setup
      trackPackages = lib.mapAttrs buildTrackFHS cfg.tracks;
      
      # cfenv wrapper for track selection
      cfenvWrapper = pkgs.writeShellScriptBin "cfenv" ''
        set -euo pipefail
        
        # Parse arguments
        track="''${CF_TRACK:-${cfg.defaultTrack}}"
        
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -t|--track)
              track="$2"
              shift 2
              ;;
            *)
              break
              ;;
          esac
        done
        
        # Select FHS wrapper for track
        case "$track" in
          ${lib.concatStringsSep "\n      " (lib.mapAttrsToList (name: pkg: ''
          ${name})
            exec "${pkg}/bin/cuttlefish-fhs-${name}" "$@"
            ;;
          '') trackPackages)}
          *)
            echo "Error: Unknown track '$track'" >&2
            echo "Available: ${lib.concatStringsSep ", " (lib.attrNames trackPackages)}" >&2
            exit 1
            ;;
        esac
      '';
    in {
      assertions = 
        let
          # Check for tracks missing bundle/debs/package
          missingTrackBundle = lib.filterAttrs 
            (n: tr: tr.package == null && tr.bundle == null && tr.debs == [])
            cfg.tracks;
        in [
          {
            assertion = if useLegacyMode
              then cfg.bundle != null || cfg.debs != [] || cfg.package != null
              else missingTrackBundle == {};
            message = 
              if useLegacyMode
              then "services.cuttlefish requires `bundle`, `debs`, or `package` when enabled."
              else "services.cuttlefish track(s) '${lib.concatStringsSep ", " (lib.attrNames missingTrackBundle)}' missing bundle/debs/package.";
          }
        ];

      users.groups.cuttlefish = {};
      users.groups.kvm = {};

      users.users.${cfg.user} = {
        isSystemUser = true;
        group = "cuttlefish";
        extraGroups = [ "kvm" "network" ];
        home = cfg.dataDir;
      };
      
      # Export cfenv if using multi-track mode
      environment.systemPackages = lib.optionals (!useLegacyMode) [
        cfenvWrapper
      ];
      
      # Create data directories for all tracks
      systemd.tmpfiles.rules = lib.optionals (!useLegacyMode) (
        lib.mapAttrsToList (name: trackCfg:
          "d ${trackCfg.dataDir} 0755 ${cfg.user} cuttlefish - -"
        ) cfg.tracks
      );

      systemd.services = if useLegacyMode then {
        # Legacy single service
        cuttlefish = {
        description = "Cuttlefish host manager";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];

        environment = cfg.environment;

        serviceConfig = {
          Type = "simple";
          User = cfg.user;
          WorkingDirectory = cfg.dataDir;
          ExecStart = execCmd;
          Restart = "on-failure";
          RestartSec = 10;
          CapabilityBoundingSet = "CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_NET_ADMIN CAP_SYS_ADMIN CAP_MKNOD";
          AmbientCapabilities = "CAP_NET_ADMIN CAP_MKNOD CAP_SYS_ADMIN";
          DeviceAllow = [
            "/dev/kvm rw"
            "/dev/net/tun rw"
          ];
          PrivateDevices = false;
          ProtectSystem = "strict";
          NoNewPrivileges = false;
        };

        preStart = ''
          install -d -m 0755 ${lib.escapeShellArg cfg.dataDir}
          chown ${cfg.user}:cuttlefish ${lib.escapeShellArg cfg.dataDir}
          ${optionalString (cfg.fetchCommand != null)
            "runuser -u ${cfg.user} -- ${fetchCmd}"}
        '';
      };
      } else {
        # Multi-track services
      } // (lib.mapAttrs' (name: trackCfg:
        let
          trackFHS = trackPackages.${name};
          trackCommandLine = trackCfg.command ++ trackCfg.extraArgs;
          trackExecCmd = escapeShellArgs ([ "${trackFHS}/bin/cuttlefish-fhs-${name}" ] ++ trackCommandLine);
          trackFetchCmd = optionalString (trackCfg.fetchCommand != null)
            (escapeShellArgs ([ "${trackFHS}/bin/cuttlefish-fhs-${name}" ] ++ trackCfg.fetchCommand));
        in
        lib.nameValuePair "cuttlefish@${name}" {
          description = "Cuttlefish host manager (${name} track)";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          # Don't auto-start - use cfctl for manual instance management
          # wantedBy = [ "multi-user.target" ];
          
          environment = trackCfg.environment;
          
          serviceConfig = {
            Type = "simple";
            User = cfg.user;
            WorkingDirectory = trackCfg.dataDir;
            ExecStart = trackExecCmd;
            Restart = "on-failure";
            RestartSec = 10;
            CapabilityBoundingSet = "CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_NET_ADMIN CAP_SYS_ADMIN CAP_MKNOD";
            AmbientCapabilities = "CAP_NET_ADMIN CAP_MKNOD CAP_SYS_ADMIN";
            DeviceAllow = [
              "/dev/kvm rw"
              "/dev/net/tun rw"
            ];
            PrivateDevices = false;
            ProtectSystem = "strict";
            NoNewPrivileges = false;
          };
          
          preStart = optionalString (trackCfg.fetchCommand != null)
            "runuser -u ${cfg.user} -- ${trackFetchCmd}";
        }
      ) cfg.tracks);
    }
  );
}
