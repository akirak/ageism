{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.ageism;

  indexPath = pkgs.writers.writeJSON "secret-index" cfg.secrets;
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
    systemd.tmpfiles.rules = [ "d /run/ageism 0755 root root -" ];

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
        ${lib.getExe pkgs.nodejs} ${./decrypt-secrets.mjs} ${indexPath}
      '';
    };
  };
}
