{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.ageism;

  hasUserSecrets = lib.any (secret: secret.neededForUsers) (lib.attrValues cfg.secrets);

  # neededForUsers controls scheduling, not the decryption manifest format.
  mkIndex =
    predicate:
    pkgs.writers.writeJSON "secret-index.json" (
      lib.mapAttrs (_: secret: removeAttrs secret [ "neededForUsers" ]) (
        lib.filterAttrs (_: secret: predicate secret) cfg.secrets
      )
    );

  indexPathForRegularSecrets = mkIndex (secret: !secret.neededForUsers);
  indexPathForUserSecrets = mkIndex (secret: secret.neededForUsers);

  mkSecretsService =
    {
      indexPath,
      forUsers ? false,
    }:
    let
      # Prune once, before either set of secrets is installed.
      pruneDirectory = if forUsers || !hasUserSecrets then cfg.settings.pruneDirectory else null;
      lastManifest =
        if cfg.settings.lastManifest == null then
          null
        else
          cfg.settings.lastManifest + lib.optionalString forUsers ".for-users";
    in
    {
      # userborn.service is aliased as systemd-sysusers.service, so userborn doesn't need an extra care.
      wantedBy = [ (if forUsers then "systemd-sysusers.service" else "multi-user.target") ];
      before = lib.optional forUsers "systemd-sysusers.service";
      after =
        if forUsers then
          [ "local-fs.target" ]
        else
          lib.optional hasUserSecrets "ageism-secrets-for-users.service";
      unitConfig.DefaultDependencies = !forUsers;
      description = if forUsers then "Decrypt age secrets for user creation" else "Decrypt age secrets";
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

        # PrivateTmp adds an implicit dependency on tmpfiles, which runs after sysusers.
        PrivateTmp = !forUsers;
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

      # The early service cannot wait for tmpfiles to create the state directory.
      preStart = lib.optionalString (forUsers && lastManifest != null) ''
        install -d -m 0755 -- ${lib.escapeShellArg (dirOf lastManifest)}
      '';

      script = ''
        ${lib.getExe pkgs.nodejs} ${./decrypt-secrets.mjs} ${indexPath} ${
          lib.optionalString (pruneDirectory != null) "--prune ${lib.escapeShellArg pruneDirectory}"
        } ${lib.optionalString (lastManifest != null) "--last-manifest ${lib.escapeShellArg lastManifest}"}
      '';
    };
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
              neededForUsers = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Decrypt this secret before systemd-sysusers creates users, for
                  example for users.users.<name>.hashedPasswordFile. The secret
                  must be owned by root.
                '';
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
            /run defeats the purpose of this option. Secrets needed for user
            creation use a separate state file with a .for-users suffix.
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
    assertions = lib.mapAttrsToList (name: secret: {
      assertion =
        !secret.neededForUsers
        || lib.elem (lib.head (lib.splitString ":" secret.owner)) [
          "root"
          "0"
        ];
      message = "services.ageism.secrets.${name}: secrets with neededForUsers = true must be owned by root (owner must be root or UID 0, optionally followed by a group).";
    }) cfg.secrets;

    systemd.tmpfiles.rules = [
      "d /run/ageism 0755 root root -"
    ]
    ++ lib.optional (
      cfg.settings.lastManifest != null
    ) "d ${dirOf cfg.settings.lastManifest} 0755 root root -";

    systemd.services.ageism-secrets = mkSecretsService {
      indexPath = indexPathForRegularSecrets;
    };

    systemd.services.ageism-secrets-for-users = lib.mkIf hasUserSecrets (mkSecretsService {
      indexPath = indexPathForUserSecrets;
      forUsers = true;
    });
  };
}
