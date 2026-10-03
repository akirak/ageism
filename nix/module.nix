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
                type = types.str;
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
    systemd.services.ageism-decrypt = {
      wantedBy = [ "multi-user.target" ];
      description = "Decrypt age secrets";
      reloadTriggers = [ indexPath ];

      path = [
        cfg.settings.agePackage
        pkgs.coreutils
      ]
      ++ cfg.settings.agePlugins;

      environment.AGE_BIN = lib.getExe cfg.settings.agePackage;

      serviceConfig.Type = "oneshot";
      script = ''
        ${lib.getExe pkgs.nodejs} ${./decrypt-secrets.mjs} ${indexPath}
      '';
    };
  };
}
