{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.ageism;

  indexPath = pkgs.writers.writeJSON "secret-index.json" cfg.secrets;
in

{
  options = {
    services.ageism = with lib; {
      enable = mkEnableOption "Ageism";

      secrets = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              path = mkOption {
                type = types.str;
              };
              source = mkOption {
                type = types.str;
              };
              owner = mkOption {
                type = types.str;
              };
              mode = mkOption {
                type = types.strMatching "[0-7]{3,4}";
              };
            };
          }
        );
      };

      settings = {
        pruneDirectory = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "/run/ageism";
          description = ''
            Directory whose subdirectories are removed before secrets are
            decrypted. Set it to the directory secrets are installed into to
            clear stale nested secrets left by earlier configurations.
          '';
        };

        lastManifest = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "/var/lib/ageism/last-manifest.json";
          description = ''
            Path to a state file recording the manifest of the last fully
            successful run. Secrets whose entries are unchanged since that
            run are not re-decrypted, provided their target files still
            exist. Use a persistent location; a path on a tmpfs such as
            /run defeats the purpose of this option.
          '';
        };

        agePackage = mkOption {
          type = types.package;
          default = pkgs.age;
          defaultText = literalExpression "pkgs.age";
          description = "Age package (usually age or rage)";
        };

        agePlugins = mkOption {
          type = types.listOf types.package;
          default = [ ];
          description = "Extra packages loaded into the decryption script";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d /run/ageism 0755 root root -"
    ]
    ++ lib.optional (
      cfg.settings.lastManifest != null
    ) "d ${dirOf cfg.settings.lastManifest} 0755 root root -";

    systemd.services.ageism-secrets = {
      wantedBy = [ "multi-user.target" ];
      description = "Decrypt age secrets";
      reloadTriggers = [ indexPath ];

      path = [
        cfg.settings.agePackage
        pkgs.coreutils
      ]
      ++ cfg.settings.agePlugins;

      environment.AGE_BIN = lib.getExe cfg.settings.agePackage;

      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";

        CapabilityBoundingSet = [
          "CAP_CHOWN"
          "CAP_FOWNER"
          "CAP_DAC_OVERRIDE"
          "CAP_DAC_READ_SEARCH"
        ];
        NoNewPrivileges = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        SystemCallArchitectures = "native";

        PrivateTmp = true;
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";

        # Age plugins may talk to local daemons such as pcscd over AF_UNIX.
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
      };

      script = ''
        ${lib.getExe pkgs.nodejs} ${./decrypt-secrets.mjs} ${indexPath} ${
          lib.optionalString (
            cfg.settings.pruneDirectory != null
          ) "--prune ${lib.escapeShellArg cfg.settings.pruneDirectory}"
        } ${
          lib.optionalString (
            cfg.settings.lastManifest != null
          ) "--last-manifest ${lib.escapeShellArg cfg.settings.lastManifest}"
        }
      '';
    };
  };
}
